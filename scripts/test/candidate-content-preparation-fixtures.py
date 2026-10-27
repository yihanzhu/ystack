#!/usr/bin/env python3
"""Private fixture and oracle support for candidate content preparation tests."""

from __future__ import annotations

import argparse
import base64
import binascii
import dataclasses
import errno
import hashlib
import importlib.util
import json
import os
import resource
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
FIXTURE_STARTUP_CLEANUP_SECONDS = 5
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


def mutate_pack_index(index: Path, pack: Path, algorithm: str, case: str) -> tuple[bytes, bytes]:
    data = bytearray(index.read_bytes())
    original_reverse = make_reverse_index(index, pack, algorithm)
    hash_size = hashlib.new(algorithm).digest_size
    if len(data) < 8 + 1024 + 2 * hash_size or data[:4] != b"\xfftOc":
        raise FixtureError("unsupported pack index fixture")
    count = struct.unpack(">I", data[8 + 255 * 4:8 + 256 * 4])[0]
    offsets_start = 8 + 1024 + count * hash_size + count * 4
    if case == "framing":
        data[:4] = b"BAD!"
    elif case == "offset":
        if count == 0 or offsets_start + 4 > len(data) - 2 * hash_size:
            raise FixtureError("pack index fixture has no ordinary offset")
        data[offsets_start:offsets_start + 4] = struct.pack(">I", pack.stat().st_size)
    else:
        raise FixtureError("unknown pack-index mutation")
    data[-hash_size:] = hashlib.new(algorithm, data[:-hash_size]).digest()
    replace_bytes(index, bytes(data))
    reverse = original_reverse if case == "framing" else make_reverse_index(index, pack, algorithm)
    return bytes(data), reverse


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
    elif case == "depth-32":
        value = strict_load(source)
        if not isinstance(value, dict):
            raise FixtureError("depth-32 semantic fixture needs an object")
        value["fixture_depth"] = nested_json(30)
        result = canonical_json(value)
    elif case == "depth-33":
        result = canonical_json(nested_json(32))
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


def command_pack_index(args: argparse.Namespace) -> None:
    write_bytes(args.output_index, args.index.read_bytes())
    index, reverse = mutate_pack_index(args.output_index, args.pack, args.algorithm, args.case)
    if args.output_index.read_bytes() != index:
        raise FixtureError("pack index replacement mismatch")
    write_bytes(args.output_reverse, reverse)


def replace_strings(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, str):
        return replacements.get(value, value)
    if isinstance(value, list):
        return [replace_strings(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: replace_strings(item, replacements) for key, item in value.items()}
    return value


def command_raw_storage(args: argparse.Namespace) -> None:
    response = strict_load(args.response)
    payload = response["payloads"][0]
    old_receipt_sha = payload["sha256"]
    receipt = json.loads(payload["data"])
    algorithm = receipt["candidate"]["hash_algorithm"]
    old_commit = receipt["candidate"]["commit_id"]
    old_tree = receipt["candidate"]["tree_id"]
    git = ["/usr/bin/git", "--no-replace-objects", "--git-dir", str(args.repository)]
    blob = subprocess.check_output([*git, "ls-tree", "-r", old_tree]).split()[2].decode("ascii")
    raw = lambda mode, name, oid: mode + b" " + name + b"\0" + bytes.fromhex(oid)
    if args.case == "slash":
        tree_body = raw(b"100644", b"bad/name", blob)
    elif args.case == "order":
        tree_body = raw(b"100644", b"z", blob) + raw(b"100644", b"a", blob)
    elif args.case == "mode":
        tree_body = raw(b"100664", b"source.txt", blob)
    elif args.case == "prefix":
        child = write_loose(args.repository, algorithm, "tree", raw(b"100644", b"a", blob))
        tree_body = raw(b"40000", b"dir", child) + raw(b"100644", b"dir/a", blob)
    else:
        raise FixtureError("unknown raw-storage mutation")
    new_tree = write_loose(args.repository, algorithm, "tree", tree_body)
    commit = subprocess.check_output([*git, "cat-file", "commit", old_commit])
    commit = commit.replace(("tree " + old_tree).encode(), ("tree " + new_tree).encode(), 1)
    new_commit = write_loose(args.repository, algorithm, "commit", commit)
    candidate_ref = args.repository / "refs/heads/candidate"
    candidate_ref.chmod(0o600)
    replace_bytes(candidate_ref, (new_commit + "\n").encode("ascii"))
    response = replace_strings(response, {old_commit: new_commit, old_tree: new_tree})
    payload = response["payloads"][0]
    receipt = replace_strings(receipt, {old_commit: new_commit, old_tree: new_tree})
    receipt_bytes = canonical_json(receipt)
    new_receipt_sha = hashlib.sha256(receipt_bytes).hexdigest()
    response = replace_strings(response, {old_receipt_sha: new_receipt_sha})
    payload = response["payloads"][0]
    payload["data"] = receipt_bytes.decode("utf-8")
    payload["sha256"] = new_receipt_sha
    replace_bytes(args.output, canonical_json(response))
    for path in args.repository.rglob("*"):
        path.chmod(0o700 if path.is_dir() else 0o400)


def command_json(args: argparse.Namespace) -> None:
    corrupt_json(args.input, args.output, args.case)


def command_depth_probes(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    module.strict_json(canonical_json(nested_json(31)), "E_INPUT")
    try:
        module.strict_json(canonical_json(nested_json(32)), "E_INPUT")
    except module.Refusal as exc:
        if exc.token != "E_INPUT":
            raise FixtureError(f"depth overflow returned {exc.token}") from exc
    else:
        raise FixtureError("depth overflow was accepted")


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
    retained: list[bytearray] = []
    retained_peak = 0

    class TrackingBytearray(bytearray):
        def __init__(self, *values: Any) -> None:
            super().__init__(*values)
            retained.append(self)

        def extend(self, value: Any) -> None:
            nonlocal retained_peak
            super().extend(value)
            retained_peak = max(retained_peak, sum(len(item) for item in retained))

    payload_size = module.LIMITS["chunk_bytes"] * 4 + 17
    script = (
        "import os,sys\n"
        f"data=b'x'*{payload_size}\n"
        "for at in range(0,len(data),4093):\n"
        " os.write(1,data[at:at+4093]); os.write(2,b'e')\n"
    )
    module.bytearray = TrackingBytearray
    try:
        output = module.run_child(
            context, [sys.executable, "-I", "-c", script], output_limit=payload_size,
            stdout_consumer=digest.update,
        )
    finally:
        del module.bytearray
    if output or digest.hexdigest() != hashlib.sha256(b"x" * payload_size).hexdigest() or \
            context.ledger.high_water_chunk > module.LIMITS["chunk_bytes"] or len(retained) != 2 or \
            retained[0] or retained_peak != context.ledger.child_output_bytes or \
            retained_peak > module.LIMITS["child_diagnostic_bytes"]:
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
    deadline_process = subprocess.Popen(
        [sys.executable, "-B", "-I", str(Path(__file__)), "deadline-child",
         "--component", str(args.component)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    status, output, diagnostic = supervise_process(deadline_process, 5.0)
    if status != 0 or output or diagnostic:
        raise FixtureError(f"operation-deadline watchdog failed: {status} {diagnostic!r}")
    stalled = subprocess.Popen(
        [sys.executable, "-I", "-c",
         "import os,signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);"
         "os.write(1,b'out');os.write(2,b'err');time.sleep(30)"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        supervise_process(stalled, 0.05)
    except FixtureError as exc:
        if str(exc) != "fixture watchdog expired" or stalled.poll() is None:
            raise FixtureError("independent watchdog did not kill and reap") from exc
    else:
        raise FixtureError("independent watchdog accepted a stalled child")


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
    partial_boundary = module.hold_boundary(args.root, "directory", time.monotonic() + 10,
                                            private_leaf=True)
    partial_context = module.Context(args=types.SimpleNamespace(), repo_root=Path("/"), scratch=args.root,
        copied_repo=args.root, sidecars=args.root, deps_root=args.root, ledger=module.Ledger(),
        deadline=time.monotonic() + 10, boundaries={"scratch_work": partial_boundary})

    def partial_write(fd: int, data: bytes) -> int:
        original_write(fd, data[:max(1, len(data) // 2)])
        raise OSError(5, "fixture partial write")

    module.os.write = partial_write
    try:
        try:
            module.write_exclusive(partial, b"0123456789", 0o400, partial_context, "scratch_bytes")
        except module.Refusal as exc:
            if exc.token != "E_IO" or partial.stat().st_size >= 10 or \
                    partial_context.ledger.scratch_bytes != 10:
                raise FixtureError("partial write did not retain a bounded failed file") from exc
        else:
            raise FixtureError("partial write was accepted")
    finally:
        module.os.write = original_write
        partial_boundary.close()

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
    result, _output, diagnostic = supervise_process(
        process, LIMITS["operation_seconds"] + FIXTURE_STARTUP_CLEANUP_SECONDS
    )
    if result != 1 or diagnostic != b"E_IO\n":
        raise FixtureError(f"closed pipe returned {result}: {diagnostic!r}")
    sys.stdout.buffer.write(diagnostic)


def supervise_process(process: subprocess.Popen[bytes], timeout: float) -> tuple[int, bytes, bytes]:
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        for name in buffers:
            stream = getattr(process, name)
            if stream is not None and not stream.closed:
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
        deadline = time.monotonic() + timeout
        while selector.get_map() or process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.terminate()
                try:
                    process.wait(1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(1)
                raise FixtureError("fixture watchdog expired")
            for key, _ in selector.select(min(remaining, 0.1)):
                chunk = os.read(key.fileobj.fileno(), CHUNK)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                else:
                    buffers[key.data].extend(chunk)
                    if sum(len(value) for value in buffers.values()) > 1024 * 1024:
                        raise FixtureError("fixture watchdog output overflow")
        return process.wait(0), bytes(buffers["stdout"]), bytes(buffers["stderr"])
    finally:
        selector.close()
        for name in buffers:
            stream = getattr(process, name)
            if stream is not None and not stream.closed:
                stream.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(1)


def command_deadline_child(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    children: list[subprocess.Popen[bytes]] = []
    original_popen = module.subprocess.Popen

    def capture(*values: Any, **keywords: Any) -> subprocess.Popen[bytes]:
        child = original_popen(*values, **keywords)
        children.append(child)
        return child

    context = module.Context(args=types.SimpleNamespace(), repo_root=Path("/"), scratch=Path("/"),
        copied_repo=Path("/"), sidecars=Path("/"), deps_root=Path("/"), ledger=module.Ledger(),
        deadline=time.monotonic() + 0.05, boundaries={})
    module.subprocess.Popen = capture
    try:
        try:
            module.run_child(context, [sys.executable, "-I", "-c", "import time;time.sleep(30)"])
        except module.Refusal as exc:
            if exc.token != "E_TIMEOUT":
                raise FixtureError(f"operation deadline returned {exc.token}") from exc
        else:
            raise FixtureError("operation deadline was accepted")
    finally:
        module.subprocess.Popen = original_popen
    if len(children) != 1 or children[0].poll() is None:
        raise FixtureError("operation-deadline child was not reaped")


def command_supervised_probe(args: argparse.Namespace) -> None:
    process = subprocess.Popen(
        [sys.executable, "-B", "-I", str(Path(__file__)), args.probe,
         "--component", str(args.component)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    status, output, diagnostic = supervise_process(process, 20.0)
    if status != 0 or output or diagnostic:
        raise FixtureError(f"supervised {args.probe} failed: {status} {diagnostic!r}")


def command_real_io(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    args.root.mkdir(mode=0o700)
    source = args.root / "source"
    source.write_bytes(b"preserved\n")
    source.chmod(0o400)
    target = args.root / "target"
    original_limit = resource.getrlimit(resource.RLIMIT_NOFILE)

    def refuse_at(target_path: Path, operation: Any) -> None:
        lowered = min(original_limit[0], 64)
        opened: list[int] = []
        resource.setrlimit(resource.RLIMIT_NOFILE, (lowered, original_limit[1]))
        try:
            while True:
                opened.append(os.open("/dev/null", os.O_RDONLY))
        except OSError as exc:
            if exc.errno != errno.EMFILE:
                raise
        try:
            try:
                operation()
            except module.Refusal as exc:
                if exc.token != "E_IO":
                    raise FixtureError(f"real I/O refusal returned {exc.token}") from exc
            else:
                raise FixtureError("real I/O failure was accepted")
        finally:
            for fd in opened:
                os.close(fd)
            resource.setrlimit(resource.RLIMIT_NOFILE, original_limit)
        if target_path.exists():
            raise FixtureError("real I/O failure created its target")

    refuse_at(args.root / "read-result", lambda: module.read_limited(source, 64))
    refuse_at(target, lambda: module.write_exclusive(target, b"new\n", 0o400))
    if source.read_bytes() != b"preserved\n":
        raise FixtureError("real I/O failure changed its source")


def command_accounting_probes(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    invocations = [strict_load(path) for path in
                   (args.argv_json, args.inclusive_argv_json, args.overflow_argv_json)]
    if any(not isinstance(value, list) or not all(isinstance(item, str) for item in value)
           for value in invocations):
        raise FixtureError("accounting argv must contain string lists")
    original_copy = module.copy_storage
    original_charge = module.Ledger.charge
    peak = 0
    charges: list[int] = []
    copies = 0
    copy_attempts = 0
    contexts: list[Any] = []
    before_copy: list[int] = []
    refused_charges: list[tuple[bool, int, int, int]] = []
    copy_active = False

    candidate = Path(invocations[0][invocations[0].index("--candidate-repository") + 1])
    copied_bytes = sum(
        path.stat().st_size for path in candidate.rglob("*")
        if path.is_file() and (path.suffix in (".pack", ".idx", ".rev") or
                               path.relative_to(candidate).parts[0] == "objects")
    )
    if copied_bytes <= 8 * 1024 * 1024 + 128:
        raise FixtureError("owned storage does not control the scratch peak")

    def tracked_charge(ledger: Any, field: str, amount: int, maximum: int) -> None:
        nonlocal peak
        if field == "scratch_bytes" and ledger.scratch_bytes + amount > maximum:
            refused_charges.append((copy_active, ledger.scratch_bytes, amount, maximum))
        original_charge(ledger, field, amount, maximum)
        if field == "scratch_bytes":
            charges.append(amount)
            peak = max(peak, ledger.scratch_bytes)

    def checked_copy(context: Any) -> None:
        nonlocal copies, copy_attempts, copy_active
        copy_attempts += 1
        before_charges = len(charges)
        copy_active = True
        try:
            before_copy.append(context.ledger.scratch_bytes)
            original_copy(context)
        finally:
            copy_active = False
        copied = [fact for name, fact in context.source_facts.items()
                  if name.endswith((".rev", ".pack", ".idx")) or
                  name.startswith("objects/") and name not in ("objects/info", "objects/pack")]
        sidecars = [fact for name, fact in context.source_facts.items() if name.endswith(".rev")]
        unmatched = list(charges[before_charges:])
        for fact in copied:
            if fact.size not in unmatched:
                raise FixtureError("copied storage lacked its scratch charge")
            unmatched.remove(fact.size)
        if not sidecars or list(context.copied_repo.rglob("*.rev")) or not list(context.sidecars.glob("*.rev")):
            raise FixtureError("sidecar crossed the private Git-reading boundary")
        contexts.append(context)
        copies += 1

    module.Ledger.charge = tracked_charge
    module.copy_storage = checked_copy
    try:
        baseline = module.main(invocations[0])
        threshold = peak
        if baseline != 0 or copies != 1 or contexts[-1].ledger.scratch_bytes != threshold or \
                threshold <= before_copy[0] + 8 * 1024 * 1024 + 128:
            raise FixtureError("baseline scratch measurement failed")
        peak = 0
        module.LIMITS["scratch_bytes"] = threshold
        inclusive = module.main(invocations[1])
        if inclusive != 0 or peak != threshold or copies != 2 or \
                contexts[-1].ledger.scratch_bytes != threshold:
            raise FixtureError("inclusive scratch boundary failed")
        peak = 0
        module.LIMITS["scratch_bytes"] = threshold - 1
        overflow = module.main(invocations[2])
    finally:
        module.copy_storage = original_copy
        module.Ledger.charge = original_charge
    overflow_scratch = Path(invocations[2][invocations[2].index("--scratch") + 1])
    overflow_output = Path(invocations[2][invocations[2].index("--output") + 1])
    if overflow != 1 or copies != 2 or copy_attempts != 3 or \
            not refused_charges or refused_charges[-1][0] is not True or \
            refused_charges[-1][3] != threshold - 1 or \
            not any(overflow_scratch.iterdir()) or \
            (overflow_output / "record.json").exists():
        raise FixtureError("scratch inclusive/overflow behavior is wrong")


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


def command_dependency_phase(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    if args.value < 0:
        raise FixtureError("invalid dependency phase limit")
    invocation = strict_load(args.argv_json)
    if not isinstance(invocation, list) or not all(isinstance(item, str) for item in invocation):
        raise FixtureError("dependency phase invocation must be a string list")
    original_copy = module.copy_dependencies
    original_limit = module.LIMITS["dependency_bytes"]
    calls = 0

    def bounded_copy(context: Any) -> tuple[Path, Path]:
        nonlocal calls
        calls += 1
        module.LIMITS["dependency_bytes"] = args.value
        try:
            return original_copy(context)
        finally:
            module.LIMITS["dependency_bytes"] = original_limit

    module.copy_dependencies = bounded_copy
    try:
        result = module.main(invocation)
    finally:
        module.copy_dependencies = original_copy
        restored = module.LIMITS["dependency_bytes"] == original_limit
        module.LIMITS["dependency_bytes"] = original_limit
    if calls != 1 or not restored:
        raise FixtureError("dependency phase boundary was not restored")
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

    index_parser = commands.add_parser("pack-index", allow_abbrev=False)
    index_parser.add_argument("--algorithm", required=True, choices=("sha1", "sha256"))
    index_parser.add_argument("--index", required=True, type=Path)
    index_parser.add_argument("--pack", required=True, type=Path)
    index_parser.add_argument("--output-index", required=True, type=Path)
    index_parser.add_argument("--output-reverse", required=True, type=Path)
    index_parser.add_argument("--case", required=True, choices=("framing", "offset"))
    index_parser.set_defaults(run=command_pack_index)

    raw_storage_parser = commands.add_parser("raw-storage", allow_abbrev=False)
    raw_storage_parser.add_argument("--repository", required=True, type=Path)
    raw_storage_parser.add_argument("--response", required=True, type=Path)
    raw_storage_parser.add_argument("--output", required=True, type=Path)
    raw_storage_parser.add_argument("--case", required=True, choices=("slash", "order", "mode", "prefix"))
    raw_storage_parser.set_defaults(run=command_raw_storage)

    json_parser = commands.add_parser("json-case", allow_abbrev=False)
    json_parser.add_argument("--input", required=True, type=Path)
    json_parser.add_argument("--output", required=True, type=Path)
    json_parser.add_argument(
        "--case",
        required=True,
        choices=(
            "bom", "trailing", "duplicate-member", "lone-surrogate",
            "nonfinite", "depth-32", "depth-33", "invalid-utf8",
        ),
    )
    json_parser.set_defaults(run=command_json)

    depth_parser = commands.add_parser("depth-probes", allow_abbrev=False)
    depth_parser.add_argument("--component", required=True, type=Path)
    depth_parser.set_defaults(run=command_depth_probes)

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

    deadline_parser = commands.add_parser("deadline-child", allow_abbrev=False)
    deadline_parser.add_argument("--component", required=True, type=Path)
    deadline_parser.set_defaults(run=command_deadline_child)

    supervised_parser = commands.add_parser("supervised-probe", allow_abbrev=False)
    supervised_parser.add_argument("--component", required=True, type=Path)
    supervised_parser.add_argument("--probe", required=True,
                                   choices=("child-setup-cleanup", "child-streaming"))
    supervised_parser.set_defaults(run=command_supervised_probe)

    io_parser = commands.add_parser("real-io", allow_abbrev=False)
    io_parser.add_argument("--component", required=True, type=Path)
    io_parser.add_argument("--root", required=True, type=Path)
    io_parser.set_defaults(run=command_real_io)

    accounting_parser = commands.add_parser("accounting-probes", allow_abbrev=False)
    accounting_parser.add_argument("--component", required=True, type=Path)
    accounting_parser.add_argument("--argv-json", required=True, type=Path)
    accounting_parser.add_argument("--inclusive-argv-json", required=True, type=Path)
    accounting_parser.add_argument("--overflow-argv-json", required=True, type=Path)
    accounting_parser.set_defaults(run=command_accounting_probes)

    limit_parser = commands.add_parser("limit-invoke", allow_abbrev=False)
    limit_parser.add_argument("--component", required=True, type=Path)
    limit_parser.add_argument("--name", required=True, choices=tuple(LIMITS))
    limit_parser.add_argument("--value", required=True, type=int)
    limit_parser.add_argument("--argv-json", required=True, type=Path)
    limit_parser.set_defaults(run=command_limit_invoke)

    dependency_parser = commands.add_parser("dependency-phase", allow_abbrev=False)
    dependency_parser.add_argument("--component", required=True, type=Path)
    dependency_parser.add_argument("--value", required=True, type=int)
    dependency_parser.add_argument("--argv-json", required=True, type=Path)
    dependency_parser.set_defaults(run=command_dependency_phase)
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


def raw16_t_lifecycle(root: Path) -> None:
    import ast
    import shutil
    import tempfile
    import textwrap

    def load(name, relative):
        spec = importlib.util.spec_from_file_location(name, root / relative)
        value = importlib.util.module_from_spec(spec)
        sys.modules[name] = value
        spec.loader.exec_module(value)
        return value

    e = load('raw16_T_caller', 'shadow/v1/enforced-reproduction.py')
    c = e.c
    original_acl = c._acl_state
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    completed, receipts = [], []
    with tempfile.TemporaryDirectory(prefix='ystack-raw16-T-') as temporary:
        base = Path(temporary).resolve()
        base.chmod(0o700)
        fixtures = base / 'runtime'
        fixtures.mkdir(mode=0o700)
        runtime = {}
        for role in ('python', 'git', 'jq'):
            path = fixtures / role
            path.write_bytes((b'synthetic unexecutable runtime ' + role.encode()) * 103)
            path.chmod(0o400)
            runtime[role] = path
        input_raw, response_raw = b'actual fixture input', b'actual fixture response'
        caller_raw = c.canonical({'schema_version': 1, 'kind': 'shadow_enforced_request',
                                  'id': 'raw16.t.fixture', 'body': {}})

        def produce(scratch, operation, fault=None):
            p = load('raw16_T_producer', 'preparation/v1/prepare-candidate.py')
            deadline = time.monotonic() + 60
            boundaries = {'scratch': p.hold_boundary(scratch, 'directory', deadline, private_leaf=True),
                          'component_source': p.hold_boundary(root / 'preparation/v1/prepare-candidate.py', 'file', deadline)}
            boundaries.update({role: p.hold_boundary(path, 'file', deadline) for role, path in runtime.items()})
            args = types.SimpleNamespace(operation=operation, scratch=str(scratch), jq=str(runtime['jq']),
                                         _boundaries=boundaries)
            ctx = p.create_context(args, deadline)
            native = ctx.scratch
            child, git, python = p.run_child, p.GIT, sys.executable
            commands = []
            try:
                ctx.input_hashes = {'input': p.sha256(input_raw), 'response': p.sha256(response_raw)}
                def version(context, argv, **_options):
                    commands.append(argv)
                    assert argv[-1] == '--version'
                    if argv[0] == str(runtime['git']):
                        return b'git version synthetic\n'
                    assert argv[0] == str(ctx.deps_root / 'tools/jq')
                    return b'jq-1.6\n'
                p.run_child, p.GIT, sys.executable = version, str(runtime['git']), str(runtime['python'])
                if fault is not None:
                    fault(p, ctx)
                p.copy_dependencies(ctx)
                identity = p.producer_identity(ctx)
                assert identity['source_sha256'] == p.sha256((root / 'preparation/v1/prepare-candidate.py').read_bytes())
                assert set(identity['core']['files'][0]) == {'path', 'sha256'}
                p._write_preparation_observations(ctx, True)
                receipts.append({'operation': operation, 'native_name': native.name,
                    'runtime_paths': {key: str(path) for key, path in runtime.items()},
                    'version_fixture_commands': commands, 'T_work': ctx.recording_work,
                    'old_native_scratch_ledger': dataclasses.asdict(ctx.ledger),
                    'original_source_identity': identity['source_sha256'],
                    'Q_M_host_parent_qualification': 'UNKNOWN'})
                return ctx, native
            finally:
                p.run_child, p.GIT, sys.executable = child, git, python
                ctx.close_boundaries()

        def retain(work, operation, anchor=None):
            holder = e.stable_directory(work)
            try:
                anchor = anchor or c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
                result = holder._retain_preparation(anchor, 'preparation-scratch', operation,
                                                     input_raw, response_raw, caller_raw)
                receipts.append({'P_fees': {key: anchor.recording_work.get(key) for key in
                    ('read_bytes', 'write_bytes', 'physical_bytes', 'files', 'runtime', 'accounting', 'accounting_incomplete')},
                    'P_leaves': [{key: leaf.get(key) for key in ('failure', 'release_failure', 'transfer_incomplete',
                        'runtime', 'read_bytes', 'write_bytes', 'physical_bytes', 'observation_calls')}
                        for leaf in anchor.recording_work.get('preparation_leaves', [])],
                    'unusable': anchor.private_observations.get('unusable', False)})
                return result, anchor
            finally:
                holder.close()

        source = (root / 'shadow/v1/enforced-reproduction.py').read_text()
        begin = source.index('        prep = work / "preparation-parent/preparation";')
        end = source.index('        record_raw = read_regular(', begin)
        segment = textwrap.dedent(source[begin:end])
        work = base / 'lifecycle'
        work.mkdir(mode=0o700)
        (work / 'preparation-scratch').mkdir(mode=0o700)
        holder = e.stable_directory(work)
        anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
        calls, native_paths = [], []
        def execute(role, argv, component, **options):
            operation = argv[5]
            assert operation in ('prepare', 'inspect')
            assert argv[:5] == [sys.executable, '-I', '-S', '-B', str(root / 'preparation/v1/prepare-candidate.py')]
            assert options == {'timeout': 300, 'env': {'fixture': 'unchanged'}, 'deadline': 123}
            scratch = Path(argv[argv.index('--scratch') + 1])
            if operation == 'inspect':
                assert all(not path.exists() for path in native_paths)
                assert len(list(scratch.glob('raw16-t-v1-prepare-*'))) == 5
                assert not (scratch / 'raw16-t-v1-prepare-runtime-unknown-00.bin').exists()
            ctx, native = produce(scratch, operation)
            assert ctx.recording_work.get('seal_returned', [False])[0] is True and not ctx.recording_unusable
            native_paths.append(native)
            calls.append(role)
        unknown = work / 'preparation-scratch/raw16-t-v1-prepare-runtime-unknown-00.bin'
        unknown.write_bytes(b'native unknown child must be removed')
        # Unknown occupancy is deliberately introduced after prepare retention.
        old_retain = holder._retain_preparation
        def retained_then_unknown(*args):
            result = old_retain(*args)
            if args[2] == 'prepare':
                unknown.write_bytes(b'native unknown child must be removed')
            return result
        unknown.unlink()
        holder._retain_preparation = retained_then_unknown
        env = {'work': work, 'SOURCE': root, 'sys': sys, 'sha': e.sha, 'mapped': {'materialization_input': work/'input'},
            'response_path': work/'response', 'candidate': work/'candidate', 'jq': types.SimpleNamespace(snapshot=types.SimpleNamespace(path=str(runtime['jq']))),
            'execute': execute, 'env': {'fixture': 'unchanged'}, 'deadline': 123, 'work_hold': holder,
            'anchor': anchor, 'input_raw': input_raw, 'response_raw': response_raw, 'request_raw': caller_raw,
            'shutil': shutil, 'c': c}
        try:
            exec(compile(segment, str(root / 'shadow/v1/enforced-reproduction.py') + ':actual-T-sequence', 'exec'), env)
            assert calls == ['candidate-preparation', 'candidate-inspection']
            assert set(anchor.private_observations['preparation']) == {'prepare'}
            assert anchor.private_observations.get('unusable') is True
            assert not any(source.stable and not source.closed for carrier in holder.runtime_copies for source in carrier.T_companions)
            assert not native_paths[0].exists() and native_paths[1].is_dir()
            assert len(list((work/'preparation-scratch').glob('raw16-t-v1-*'))) == 10
            completed.append('native cleanup unchanged; tainted T recording refused')
        finally:
            holder.close()
        writer_source = (root / 'shadow/v1/write-shadow.py').read_text()
        begin = writer_source.index('    for operation, scratch in (("prepare", "preparation-scratch"),')
        end = writer_source.index('    prep_raw = ws.hold(', begin)
        writer_segment = textwrap.dedent(writer_source[begin:end])
        work = base / 'writer-two-roots'
        work.mkdir(mode=0o700)
        for name in ('preparation-scratch', 'inspection-scratch'):
            (work / name).mkdir(mode=0o700)
        holder = e.stable_directory(work)
        anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
        writer_calls = []
        def writer_execute(role, argv, component, **options):
            operation = argv[5]
            scratch = Path(argv[argv.index('--scratch') + 1])
            assert scratch == work / ('preparation-scratch' if operation == 'prepare' else 'inspection-scratch')
            ctx, _native = produce(scratch, operation)
            assert ctx.recording_work.get('seal_returned', [False])[0] is True
            writer_calls.append((role, str(scratch)))
        ws = types.SimpleNamespace(execute=writer_execute, work_hold=holder, anchor=anchor,
                                   request=types.SimpleNamespace(raw=caller_raw))
        try:
            exec(compile(writer_segment, str(root / 'shadow/v1/write-shadow.py') + ':actual-T-two-roots', 'exec'),
                {'ws': ws, 'work': work, 'sys': sys, 'preparation': root/'preparation/v1/prepare-candidate.py',
                 'common': [], 'input_raw': input_raw, 'response_raw': response_raw})
            assert len(writer_calls) == 2 and not anchor.private_observations.get('unusable', False)
            assert set(anchor.private_observations['preparation']) == {'prepare', 'inspect'}
            assert len(list((work/'preparation-scratch').glob('raw16-t-v1-prepare-*'))) == 5
            assert len(list((work/'inspection-scratch').glob('raw16-t-v1-inspect-*'))) == 5
            completed.append('actual writer two separate roots')
        finally:
            holder.close()
        cleanup_source = segment[segment.index('for child in prep_scratch.iterdir():'):segment.index('execute("candidate-inspection"')]
        scratch = base/'cleanup-error'
        scratch.mkdir(mode=0o700)
        native = scratch/'candidate-preparation-0000000000000000'
        native.mkdir(mode=0o700)
        partial = scratch/'raw16-t-v1-prepare-runtime-python-00.bin'
        partial.write_bytes(b'preserved actual partial')
        original_rmtree = shutil.rmtree
        error = OSError(errno.EACCES, 'actual native cleanup failure fixture')
        def rmtree(path, *args, **kwargs):
            assert path == native
            raise error
        shutil.rmtree = rmtree
        try:
            try:
                exec(compile(cleanup_source, 'actual-native-cleanup', 'exec'),
                    {'prep_scratch': scratch, 'reserved_preparation_name': c._preparation_reserved_name, 'shutil': shutil})
            except OSError as observed:
                assert observed is error and partial.read_bytes() == b'preserved actual partial'
            else:
                raise AssertionError('native cleanup failure was swallowed')
            completed.append('native cleanup exact first error and partial retained')
        finally:
            shutil.rmtree = original_rmtree
        assert not c._preparation_reserved_name('raw16-t-v1-prepare-runtime-python-64.bin')
        assert not c._preparation_reserved_name('raw16-t-v1-prepare-runtime-unknown-00.bin')
        assert not c._preparation_reserved_name('raw16-t-v1-prepare-complete-' + 'G' * 64)
        assert c._preparation_reserved_name('raw16-t-v1-inspect-runtime-python-63.bin')
        for scenario in ('missing-marker', 'wrong-marker', 'nonempty-marker', 'extra-runtime', 'runtime-drift',
                         'capture-drift', 'capture-and-marker-drift', 'occupied-runtime', 'mkdir-failed', 'mkdir-uncertain'):
            work = base / scenario
            work.mkdir(mode=0o700)
            scratch = work / 'preparation-scratch'
            scratch.mkdir(mode=0o700)
            original_mkdir = os.mkdir
            def fault(p, ctx):
                if scenario.startswith('mkdir-'):
                    def mkdir(name, *args, **kwargs):
                        if str(name).startswith('raw16-t-v1-prepare-complete-'):
                            if scenario == 'mkdir-uncertain':original_mkdir(name, *args, **kwargs)
                            raise OSError(errno.EIO, 'controlled completion mkdir result unknown')
                        return original_mkdir(name, *args, **kwargs)
                    p.os.mkdir = mkdir
            if scenario == 'occupied-runtime':
                (scratch/'raw16-t-v1-prepare-runtime-jq-00.bin').write_bytes(b'preserved preexisting occupancy')
            try:
                ctx, native = produce(scratch, 'prepare', fault)
            finally:
                os.mkdir = original_mkdir
            capture = scratch / 'raw16-t-v1-prepare-capture.json'
            markers = list(scratch.glob('raw16-t-v1-prepare-complete-*'))
            if scenario in ('occupied-runtime', 'mkdir-failed', 'mkdir-uncertain'):
                assert ctx.recording_unusable and not ctx.recording_work.get('seal_returned', [False])[0]
                if scenario == 'mkdir-uncertain':
                    assert len(markers) == 1
                    # An observed failed commit is never offered to the reader as a qualified success.
                    completed.append(scenario)
                    continue
            else:
                marker = markers[0]
                if scenario == 'missing-marker':marker.rmdir()
                elif scenario == 'wrong-marker':marker.rename(scratch/('raw16-t-v1-prepare-complete-'+'0'*64))
                elif scenario == 'nonempty-marker':(marker/'extra').write_bytes(b'extra')
                elif scenario == 'extra-runtime':(scratch/'raw16-t-v1-prepare-runtime-python-63.bin').write_bytes(b'extra')
                elif scenario == 'runtime-drift':
                    path = scratch/ctx.runtime_inventory[0]['file'];path.chmod(0o600);path.write_bytes(b'drift');path.chmod(0o400)
                else:
                    value = json.loads(capture.read_bytes());value['binding']['input_sha256'] = '0'*64
                    capture.chmod(0o600);capture.write_bytes(c.canonical(value));capture.chmod(0o400)
                    if scenario == 'capture-and-marker-drift':marker.rename(scratch/('raw16-t-v1-prepare-complete-'+c.digest(capture.read_bytes())))
            result, anchor = retain(work, 'prepare')
            assert result is None and anchor.private_observations.get('unusable') is True, scenario
            assert native.is_dir() and capture.exists()
            completed.append(scenario)
        for count in (128, 129):
            work = base / ('root-entry-bound-' + str(count))
            work.mkdir(mode=0o700)
            scratch = work / 'preparation-scratch'
            scratch.mkdir(mode=0o700)
            ctx, _native = produce(scratch, 'prepare')
            existing = len(list(scratch.iterdir()))
            for index in range(count - existing):
                (scratch / ('candidate-preparation-' + format(index, '016x'))).mkdir(mode=0o700)
            assert len(list(scratch.iterdir())) == count
            result, anchor = retain(work, 'prepare')
            assert (result is not None) == (count == 128)
            assert bool(anchor.private_observations.get('unusable')) == (count == 129)
            completed.append('root total entries ' + str(count))
        for scenario in ('runtime-write', 'runtime-fsync', 'runtime-close', 'runtime-readback',
                         'capture-write-zero', 'capture-fsync', 'capture-close', 'capture-readback',
                         'capture-readback-close', 'parent-sync', 'ledger-before-marker', 'ledger-return-cell'):
            work = base / scenario
            work.mkdir(mode=0o700)
            scratch = work / 'preparation-scratch'
            scratch.mkdir(mode=0o700)
            saved = {name: getattr(os, name) for name in ('open', 'write', 'read', 'pread', 'fsync', 'close')}
            tracked, closed, fired = {}, {}, []
            def fault(p, ctx):
                prefix = 'raw16-t-v1-prepare-'
                def opened(name, flags, *args, **kwargs):
                    fd = saved['open'](name, flags, *args, **kwargs)
                    if str(name).startswith(prefix):
                        tracked[fd] = (str(name), bool(flags & os.O_WRONLY))
                    return fd
                def reached(fd, phase):
                    if fired or fd not in tracked:
                        return False
                    name, writer = tracked[fd]
                    group = 'capture' if name.endswith('capture.json') else 'runtime'
                    match = scenario == group + '-' + phase
                    if phase == 'close' and not writer:
                        match = scenario == group + '-readback-close'
                    if match:
                        fired.append((name, phase))
                    return match
                def write(fd, raw):
                    if reached(fd, 'write'):
                        raise OSError(errno.ENOSPC, 'controlled new T write failure')
                    if scenario == 'capture-write-zero' and not fired and fd in tracked and tracked[fd][0].endswith('capture.json'):
                        fired.append(('capture', 'write-zero'))
                        return 0
                    return saved['write'](fd, raw)
                def pread(fd, count, offset):
                    if reached(fd, 'readback'):
                        raise OSError(errno.EIO, 'controlled T runtime readback')
                    return saved['pread'](fd, count, offset)
                def read(fd, count):
                    if reached(fd, 'readback'):
                        raise OSError(errno.EIO, 'controlled T C readback')
                    return saved['read'](fd, count)
                def fsync(fd):
                    if reached(fd, 'fsync'):
                        raise OSError(errno.EIO, 'controlled T fsync')
                    if scenario == 'parent-sync' and fd == ctx.boundaries['scratch'].fd and not fired:
                        fired.append(('scratch-parent', 'fsync'))
                        raise OSError(errno.EIO, 'controlled T parent sync')
                    return saved['fsync'](fd)
                def close(fd):
                    if fd in tracked:
                        state = tracked.pop(fd)
                        closed[state] = closed.get(state, 0) + 1
                        tracked[fd] = state
                        fail = reached(fd, 'close')
                        tracked.pop(fd)
                        saved['close'](fd)
                        if fail:
                            raise OSError(errno.EIO, 'controlled close result failure')
                        return None
                    return saved['close'](fd)
                if scenario in ('ledger-before-marker', 'ledger-return-cell'):
                    class FailLedger(dict):
                        def __setitem__(self, key, value):
                            if key == ('seal_returned' if scenario == 'ledger-return-cell' else 'seal_mkdir_attempts'):
                                fired.append(('ledger', key))
                                raise MemoryError('controlled precommit observation failure')
                            return super().__setitem__(key, value)
                    ctx.recording_work = FailLedger(ctx.recording_work)
                p.os.open, p.os.write, p.os.read = opened, write, read
                p.os.pread, p.os.fsync, p.os.close = pread, fsync, close
            try:
                ctx, native = produce(scratch, 'prepare', fault)
            finally:
                for name, value in saved.items():setattr(os, name, value)
            assert fired and ctx.recording_unusable and not list(scratch.glob('raw16-t-v1-prepare-complete-*')), scenario
            assert not tracked and all(count == 1 for count in closed.values()), (scenario, tracked, closed)
            assert native.is_dir() and (scratch/'raw16-t-v1-prepare-capture.json').exists()
            completed.append(scenario)
        import ctypes
        for scenario in ('linux-access-present', 'linux-access-empty', 'linux-default-present',
                         'linux-default-empty', 'linux-unknown-errno', 'darwin-present',
                         'darwin-present-free-failure', 'darwin-parent-present', 'darwin-null-zero', 'darwin-bind-error'):
            work = base / scenario
            work.mkdir(mode=0o700)
            scratch = work / 'preparation-scratch'
            scratch.mkdir(mode=0o700)
            platform, getxattr, cdll = sys.platform, getattr(os, 'getxattr', None), ctypes.CDLL
            calls, frees = [], []
            def fault(p, ctx):
                if scenario.startswith('linux'):
                    sys.platform = 'linux'
                    def xattr(fd, name):
                        calls.append((fd, name))
                        wanted = 'system.posix_acl_default' if 'default' in scenario else 'system.posix_acl_access'
                        if name == wanted:
                            if scenario == 'linux-unknown-errno':
                                raise OSError(errno.ENOTSUP, 'controlled unsupported')
                            return b'' if scenario.endswith('empty') else b'controlled present ACL bytes'
                        raise OSError(getattr(errno, 'ENODATA', getattr(errno, 'ENOATTR', 93)), 'controlled absent')
                    os.getxattr = xattr
                else:
                    sys.platform = 'darwin'
                    if scenario == 'darwin-bind-error':
                        def load_library(*args, **kwargs):
                            calls.append(('binding', args))
                            raise OSError(errno.ENOENT, 'controlled library binding error')
                        p._preparation_acl_library = None
                        ctypes.CDLL = load_library
                    else:
                        def get_acl(fd, kind):
                            calls.append((fd, kind))
                            if scenario == 'darwin-parent-present' and fd != ctx.boundaries['scratch'].fd:
                                ctypes.set_errno(errno.ENOENT)
                                return None
                            ctypes.set_errno(0)
                            return None if scenario == 'darwin-null-zero' else 123
                        def free_acl(pointer):
                            frees.append(pointer)
                            ctypes.set_errno(errno.EIO if scenario.endswith('free-failure') else 0)
                            return -1 if scenario.endswith('free-failure') else 0
                        p._preparation_acl_library = types.SimpleNamespace(acl_get_fd_np=get_acl, acl_free=free_acl)
            try:
                ctx, native = produce(scratch, 'prepare', fault)
            finally:
                sys.platform = platform
                ctypes.CDLL = cdll
                if getxattr is None:
                    if hasattr(os, 'getxattr'):del os.getxattr
                else:os.getxattr = getxattr
            assert calls and ctx.recording_unusable and native.is_dir(), scenario
            assert not list(scratch.glob('raw16-t-v1-prepare-complete-*')), scenario
            if scenario.startswith('darwin-present'):
                assert len(frees) == len(calls) and all(pointer == 123 for pointer in frees)
            elif scenario == 'darwin-parent-present':
                assert frees and len(frees) < len(calls) and all(pointer == 123 for pointer in frees)
            else:
                assert not frees
            if scenario == 'darwin-present-free-failure':
                assert ctx.recording_work['failure']['site'] == 'acl-absence'
                assert ctx.recording_work['failure']['token'] == 'E_IDENTITY'
                assert any(row['site'] == 'acl-free' and row['errno'] == errno.EIO
                           for row in ctx.recording_work['secondary_errors'])
            completed.append(scenario + ' mocked negative only')
    c._acl_state = original_acl
    print(json.dumps({'raw16_T_controls': completed, 'ordinary_synthetic_runtime_only': True,
        'actual_source_segments_not_full_native_route': True, 'receipts': receipts}, sort_keys=True))

def raw16_preparation_P_handoff(root: Path) -> None:
    body=(root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix=body.split('        copied_inventory.close();copied_inventory.close()\n',1)[0]
    footer=body[body.rfind('finally:\n    if copied_inventory'):]
    before="        parent=c._open_held(str(private),True,c._store_rule(uid,gid,0o700,True),'E_STORE')\n"
    prefix=prefix.replace(before,"        scratch=private/'preparation-scratch';scratch.mkdir(mode=0o700)\n"+before)
    edge="        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)\n"
    head,tail=prefix.split(edge,1)
    setup='''        import errno,ast
        holder=e.StableDirectory(parent)
        input_raw,response_raw=b'synthetic T input',b'synthetic T response'
        caller=c.canonical({'kind':'shadow_write_request','id':'t.p.fixture'})
        def create_T(operation):
            rows=[]
            for ordinal,role in enumerate(('python','git','jq')):
                filename='raw16-t-v1-'+operation+'-runtime-'+role+'-'+str(ordinal).zfill(2)+'.bin'
                payload=(b'synthetic T bytes never executed '+role.encode())*101
                path=scratch/filename;path.write_bytes(payload);path.chmod(0o400)
                rows.append({'slot':role,'index':0,'ordinal':ordinal,'locator':str(path),'file':filename,
                    'size_bytes':len(payload),'sha256':c.digest(payload),'errno':None})
            value={'operation':operation,'binding':{'input_sha256':c.digest(input_raw),'response_sha256':c.digest(response_raw)},
                'entropy':[],'clocks':[],'storage':[],'commands':[],'runtime':{'files':rows},'complete':True}
            raw=c.canonical(value);path=scratch/('raw16-t-v1-'+operation+'-capture.json')
            path.write_bytes(raw);path.chmod(0o400)
            (scratch/('raw16-t-v1-'+operation+'-complete-'+c.digest(raw))).mkdir(mode=0o700)
            return value
        expected=create_T('prepare')
        actual_close,actual_transfer,actual_acquire=c._close_paths,c._capture_transfer_work,c._HeldCaptureCopy.acquire
        acquired=[];fired=[];cancellations=[]
        syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
        main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
        handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
        namespace={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),namespace)
        def acquire(self,*args,**kwargs):
            result=actual_acquire(self,*args,**kwargs);acquired.append(self);return result
        def close(items):
            is_T=any(item.path.endswith('/preparation-runtime-prepare') for item in items)
            result=actual_close(items)
            if is_T and T_case in ('T-close-failure','T-close-cancel') and not fired:
                fired.append('T-close')
                if T_case=='T-close-cancel':
                    try:namespace['cancel'](15,None)
                    except InterruptedError as error:cancellations.append(error);raise
                raise OSError(errno.EIO,'controlled original T final close')
            return result
        def transfer(leaf,*args,**kwargs):
            if T_case=='T-transfer-failure' and leaf in anchor.recording_work.get('preparation_leaves',[]) and not fired:
                fired.append('T-transfer');raise MemoryError('controlled original T final transfer')
            return actual_transfer(leaf,*args,**kwargs)
        c._close_paths,c._capture_transfer_work,c._HeldCaptureCopy.acquire=close,transfer,acquire
        caught=None;returned=None
        try:
            try:returned=holder._retain_preparation(anchor,'preparation-scratch','prepare',input_raw,response_raw,caller)
            except InterruptedError as error:caught=error
        finally:c._close_paths,c._capture_transfer_work,c._HeldCaptureCopy.acquire=actual_close,actual_transfer,actual_acquire
'''
    failed='''        assert len(acquired)==1 and acquired[0].closed and not acquired[0].owned, 'T-P failed tail owner must close'
        assert returned is None and not holder.runtime_copies and anchor.private_observations.get('unusable') is True
        if T_case=='T-close-cancel':assert len(cancellations)==1 and caught is cancellations[0]
        else:assert caught is None
        print(json.dumps({'T_to_P_original_finally_failure':T_case,'P_work':anchor.recording_work,
            'T_input':'synthetic canonical consumer input, not actual producer/qualification'}))
'''
    success='''        assert acquired and holder.runtime_copies, ('T-P acquisition', [leaf.get('failure') for leaf in anchor.recording_work.get('preparation_leaves',[])])
        assert returned is acquired[0] and returned is holder.runtime_copies[0] and not returned.closed
        assert anchor.private_observations['preparation']['prepare']==expected
        assert set(returned.members)=={'capture.json'}|set(returned.runtime_sha256)
        assert len(returned.runtime_sha256)==3
        create_T('inspect')
        inspected=holder._retain_preparation(anchor,'preparation-scratch','inspect',input_raw,response_raw,caller)
        assert inspected is holder.runtime_copies[1] and not inspected.closed
'''
    final='''        if T_case=='P-target-drift':
            target=Path(next(item.path for name,item in returned.members.items() if name!='capture.json'))
            target.chmod(0o600)
            with target.open('r+b') as stream:stream.write(b'!')
            target.chmod(0o400)
        if T_case=='parent-mode':private.chmod(0o750)
        if T_case=='parent-inode':
            private.rename(base/'original-private');private.mkdir(mode=0o700)
        for item in holder.runtime_copies:item.recheck()
        assert bool(anchor.private_observations.get('unusable'))==(T_case!='stable'), 'T-P final held check'
        e._seal_capture_recording(anchor,parent,None,copied_inventory,holder)
        assert not holder.runtime_copies and returned.closed and inspected.closed
        assert anchor.private_observations.get('recording_sealed') is not True
        print(json.dumps({'actual_prepare_inspect_Hcopy_seal':T_case,'P_work':anchor.recording_work,
            'P_hold_leaves':[returned.leaf,inspected.leaf],
            'T_input':'synthetic canonical consumer input, not actual producer/qualification',
            'extra_fixture_runtime_P_reads':len(source_raw),'qualification':'BLOCKED original UNKNOWN/T/M gates'}))
'''
    for case in ('stable','P-target-drift','parent-mode','parent-inode','T-close-failure','T-transfer-failure','T-close-cancel'):
        script=head+setup
        if case.startswith('T-'):script+=failed
        else:script+=success+edge+'        holder._refresh_runtime_parents()\n'+tail+final
        namespace={'T_case':case};argv=sys.argv;sys.argv=['T-P-fixture',str(root)]
        try:exec(compile(script+footer,'<actual-preparation-P-handoff>','exec'),namespace)
        finally:
            sys.argv=argv
            if namespace.get('holder') is not None:namespace['holder'].close()


def raw16_local_P_after_H_copy(root: Path) -> None:
    text = (root/'scripts/test/evals-malicious.test.sh').read_text()
    body = text.split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix = body.split('        copied_inventory.close();copied_inventory.close()\n',1)[0]
    footer = body[body.rfind('finally:\n    if copied_inventory'):]
    setup = '''        holder=e.StableDirectory(parent)
        local_source=c._open_held(str(source),False,c._store_rule(uid,gid,0o400,False),'E_STORE')
        holder._retain_runtime(anchor,'python',local_source,source_raw,c.canonical({'kind':'shadow_write_request','id':'local.hcopy'}))
        assert len(holder.runtime_copies)==1
        local_P=holder.runtime_copies[0]
'''
    edge = "        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)\n"
    assert prefix.count(edge) == 1
    prefix = prefix.replace(edge, setup + edge + '        holder._refresh_runtime_parents()\n')
    checks = '''        anchor.seal_local_runtime(parent)
        local_source.close()
        local_name=next(iter(local_P.members))
        if local_case=='P-drift':
            target=private/local_name;target.chmod(0o600)
            with target.open('r+b') as stream:stream.write(b'!')
            target.chmod(0o400)
        holder.close_runtime_copies()
        assert local_P.closed and not holder.runtime_copies
        assert bool(anchor.private_observations.get('unusable'))==(local_case=='P-drift'), 'local-P after Hcopy final availability'
        print(json.dumps({'local_P_to_actual_Hcopy':local_case,'P_work':anchor.recording_work,
            'additional_fixture_P_read_bytes':len(source_raw),'full_M_Q_host_cost':'UNKNOWN'}))
'''
    for case in ('stable','P-drift'):
        namespace={'sys':sys,'local_case':case}
        original=sys.argv;sys.argv=['local-P-Hcopy',str(root)]
        try:exec(compile(prefix+checks+footer,'<actual-local-P-Hcopy>','exec'),namespace)
        finally:
            sys.argv=original
            if namespace.get('local_source') is not None:namespace['local_source'].close()
            if namespace.get('holder') is not None:namespace['holder'].close()


def raw16_local_P_clone_allocation(root: Path) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('local_P_clone_allocation',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    original_acl, original_clone, original_init, original_close=c._acl_state,c._clone,c.HeldPath.__init__,os.close
    c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    cloned, closed, expected=[],[],MemoryError('controlled HeldPath construction after complete clone')
    try:
        with tempfile.TemporaryDirectory(prefix='ystack-P-clone-failure-') as temporary:
            work=Path(temporary).resolve();work.chmod(0o700)
            parent=c._open_held(str(work),True,c._store_rule(os.geteuid(),os.getegid(),0o700,True),'E_STORE')
            anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
            copied=c._HeldCaptureCopy(anchor,anchor.recording_work,c._capture_work_values(anchor.recording_work,'clone-case'))
            def clone(*args,**kwargs):
                rows=original_clone(*args,**kwargs);cloned.extend(row.fd for row in rows);return rows
            def initialize(self,*args,**kwargs):raise expected
            def close(fd):
                result=original_close(fd)
                if fd in cloned:closed.append(fd)
                return result
            try:
                c._clone,c.HeldPath.__init__,os.close=clone,initialize,close
                caught=None
                try:copied.acquire(parent,None,{}, {})
                except MemoryError as error:caught=error
                assert caught is expected
                assert cloned and set(closed)==set(cloned) and len(closed)==len(cloned)
                assert copied.closed and not copied.owned and copied.directory is None
                copied.close();assert len(closed)==len(cloned)
                for fd in cloned:
                    try:os.fstat(fd)
                    except OSError as error:assert error.errno==errno.EBADF
                    else:raise AssertionError('P clone allocation leaked a live fd')
                assert all(os.fstat(component.fd) for component in parent.components)
                print(json.dumps({'P_clone_allocation_failure':True,'same_exception':True,
                    'new_FD_onceclose':len(closed),'P_work':anchor.recording_work},sort_keys=True))
            finally:
                c._clone,c.HeldPath.__init__,os.close=original_clone,original_init,original_close
                parent.close();anchor.close()
    finally:c._acl_state=original_acl


def raw16_local_P_handoff(root: Path) -> None:
    import ast
    import tempfile
    spec = importlib.util.spec_from_file_location('raw16_local_P_fixture', root/'shadow/v1/enforced-reproduction.py')
    e = importlib.util.module_from_spec(spec);sys.modules[spec.name] = e;spec.loader.exec_module(e)
    c = e.c
    original_acl, original_open, original_observe, original_close = c._acl_state, c._open_held, c._capture_observe, os.close
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    syntax = ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main = next(node for node in syntax.body if isinstance(node, ast.FunctionDef) and node.name == 'main')
    cancel = next(node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == 'cancel')
    callbacks = {};exec(compile(ast.Module(body=[cancel],type_ignores=[]),'<actual-scope-cancel>','exec'),callbacks)
    output = []
    try:
        for case in ('runtime', 'sudo', 'two-runtime', 'P-drift', 'parent-mode', 'parent-inode', 'close-observer', 'close-error', 'close-cancel', 'registration'):
            with tempfile.TemporaryDirectory(prefix='ystack-local-P-') as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                source, work = base/'synthetic-runtime', base/'private-recorder'
                work.mkdir(mode=0o700)
                raw = b'TMP synthetic runtime never executed\n' * 2049
                source.write_bytes(raw);source.chmod(0o400)
                holder = e.stable_directory(work)
                anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
                original = original_open(str(source), False, c._store_rule(os.geteuid(),os.getegid(),0o400,False), 'E_STORE')
                native = e.FixedSudo(os.open(source, os.O_RDONLY), source.stat())
                native.recheck = lambda: c._require(c._identity(os.fstat(native.fd)) == c._identity(native.before), 'E_STORE')
                requests, closed, events, fired = [], [], [], []
                def fixed_open(path, directory, rule, code, *args, **kwargs):
                    if path == '/usr/bin/sudo':
                        requests.append(path)
                        return original_open(str(source), False, c._store_rule(os.geteuid(),os.getegid(),0o400,False), code, *args, **kwargs)
                    return original_open(path, directory, rule, code, *args, **kwargs)
                request = c.canonical({'kind':'shadow_write_request','id':'local.p.fixture'})
                watched = set()
                def observe(leaf, kind, site, value, *args, **kwargs):
                    if case == 'close-observer' and site == 'held-close' and not fired:
                        fired.append(site);raise MemoryError('controlled local P close observation')
                    return original_observe(leaf,kind,site,value,*args,**kwargs)
                def closing(fd):
                    result = original_close(fd)
                    if fd in watched:
                        closed.append(fd)
                        if case == 'close-error' and not fired:
                            fired.append('close');raise OSError(errno.EIO,'controlled actual P close')
                        if case == 'close-cancel' and not events:
                            try:callbacks['cancel'](signal.SIGTERM,None)
                            except InterruptedError as error:events.append(error);raise
                    return result
                class Reject(list):
                    def append(self, value):
                        rejected.append(value)
                        raise MemoryError('controlled local P caller registration')
                rejected = []
                try:
                    c._open_held = fixed_open
                    if case == 'registration':holder.runtime_copies = Reject()
                    if case == 'sudo':holder._retain_sudo(anchor,native,request)
                    else:holder._retain_runtime(anchor,'python',original,raw,request)
                    if case == 'registration':
                        assert len(rejected) == 1 and rejected[0].closed and not rejected[0].owned
                        assert anchor.private_observations.get('unusable') is True
                        output.append({'case':case,'P_work':anchor.recording_work});continue
                    assert len(holder.runtime_copies) == 1
                    copied = holder.runtime_copies[0]
                    assert copied.local_parent and not copied.closed and len(copied.members) == 1
                    name, held = next(iter(copied.members.items()))
                    assert held.fd != original.fd and held.before.st_ino != original.before.st_ino
                    assert copied.runtime_sha256[name] == c.digest(raw)
                    if case == 'two-runtime':
                        holder._retain_runtime(anchor,'jq',original,raw,request)
                        assert len(holder.runtime_copies) == 2
                    watched = {row.fd for owner in holder.runtime_copies for item in owner.owned for row in item.components}
                    if case in ('parent-mode', 'parent-inode'):
                        if case == 'parent-mode':work.chmod(0o750)
                        else:
                            work.rename(base/'original-recorder');work.mkdir(mode=0o700)
                        holder._retain_runtime(anchor,'jq',original,raw,request)
                        assert len(holder.runtime_copies) == 1 and anchor.private_observations.get('unusable') is True
                    if case == 'P-drift':
                        target = work/name;target.chmod(0o600)
                        with target.open('r+b') as stream:stream.write(b'!')
                        target.chmod(0o400)
                    elif case not in ('parent-mode', 'parent-inode'):
                        anchor.seal_local_runtime(holder._recording_parent())
                        original.close()
                        assert os.pread(held.fd,len(raw),0) == raw
                    c._capture_observe, os.close = observe, closing
                    caught = None
                    try:holder.close_runtime_copies()
                    except InterruptedError as error:caught = error
                    assert not holder.runtime_copies and copied.closed and not copied.owned
                    assert len(closed) == len(watched) and set(closed) == watched
                    holder.close_runtime_copies();assert len(closed) == len(watched)
                    for fd in watched:
                        try:os.fstat(fd)
                        except OSError as error:assert error.errno == errno.EBADF
                        else:raise AssertionError('local P fd leaked')
                    if case == 'close-cancel':assert len(events) == 1 and caught is events[0]
                    else:assert caught is None
                    assert bool(anchor.private_observations.get('unusable')) == (case in ('P-drift','parent-mode','parent-inode','close-observer','close-error','close-cancel'))
                    if case == 'sudo':assert requests == ['/usr/bin/sudo'] and os.fstat(native.fd)
                    output.append({'case':case,'P_work':anchor.recording_work,'P_leaf':copied.leaf,
                        'closed_once':len(closed),'extra_fixture_validation_read_bytes':0 if case in ('P-drift','parent-mode','parent-inode') else len(raw),
                        'system_runtime_read':False,'ACL_and_native_sudo_qualification':'fixture doubles'})
                finally:
                    c._open_held, c._capture_observe, os.close = original_open, original_observe, original_close
                    holder.close();original.close();anchor.close();native.close()
    finally:c._acl_state = original_acl
    print(json.dumps({'actual_StableDirectory_local_P':output},sort_keys=True))

def raw16_hp_registration_primary(root: Path) -> None:
    import ast
    import tempfile
    spec=importlib.util.spec_from_file_location('HP_registration_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    scope=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in scope.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-scope-handler>', 'exec'),callbacks)
    original_acl=c._acl_state
    c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    try:
        for marked in (True,False):
            with tempfile.TemporaryDirectory(prefix='ystack-P-register-') as temporary:
                base=Path(temporary).resolve();base.chmod(0o700)
                directory=base/'reproduction';directory.mkdir(mode=0o700)
                member=directory/'capture.json';member.write_bytes(b'ordinary P copied bytes');member.chmod(0o400)
                anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
                parent=c._open_held(str(base),True,c._store_rule(os.geteuid(),os.getegid(),0o700,True,None),'E_STORE')
                work=anchor.recording_work
                key=str(parent.before.st_dev)+':'+str(parent.before.st_ino)
                case_work=c._capture_work_values(work,key)
                copied=c._HeldCaptureCopy(anchor,work,case_work)
                events=[];closed=[];observed=[];first=[]
                def cancel():
                    try:callbacks['cancel'](signal.SIGTERM,None)
                    except InterruptedError as error:
                        events.append(error)
                        return error
                class Reject(list):
                    def append(self,held):
                        error=cancel() if marked else MemoryError('ordinary first registration failure')
                        first.append(error)
                        raise error
                copied.owned=Reject()
                close,observe=os.close,c._capture_observe
                def close_once(fd):
                    close(fd);closed.append(fd)
                    if len(closed)==1:raise OSError(errno.EBADF,'ordinary registration compensation close')
                def observer(work,kind,site,value,*args,**kwargs):
                    if site=='P-hold-registration-close':
                        observed.append({'site':site,'errno':value['errno'],'category':value['category']})
                        raise cancel()
                    return observe(work,kind,site,value,*args,**kwargs)
                caught=None
                try:
                    os.close=close_once;c._capture_observe=observer
                    try:copied.acquire(parent,'reproduction',{'capture.json':member.stat()}, {})
                    except BaseException as error:caught=error
                    assert len(first)==1 and len(observed)==1 and observed[0]['errno']==errno.EBADF
                    if marked:
                        assert len(events)==2 and events[0] is not events[1] and caught is first[0]
                    else:assert len(events)==1 and caught is events[0] and caught is not first[0]
                    assert copied.closed and not copied.owned
                    assert len(closed)==len(set(closed)) and closed
                    for fd in closed:
                        try:os.fstat(fd)
                        except OSError as error:assert error.errno==errno.EBADF
                        else:raise AssertionError('registration fd remained open')
                    before=len(closed);copied.close();assert len(closed)==before
                    print(json.dumps({'marked_registration_primary':marked,'actual_first_preserved':caught is first[0],
                        'first_marked_preserved':caught is events[0],'distinct_cancel_objects':len(events),
                        'closed_fd_count':len(closed),'once_close':True,'observer':observed,'actual_work':work,
                        'ordinary_private_P_only':True,'qualification':False},sort_keys=True))
                finally:
                    os.close=close;c._capture_observe=observe
                    copied.close();parent.close()
    finally:c._acl_state=original_acl


def raw16_hp_handoff(root: Path) -> None:
    import ast
    text = (root/'scripts/test/evals-malicious.test.sh').read_text()
    body = text.split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix = body.split('        copied_inventory.close();copied_inventory.close()\n',1)[0]
    footer = body[body.rfind('finally:\n    if copied_inventory'):]
    scope = ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main = next(node for node in scope.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler = next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks = {};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-scope-cancel>','exec'),callbacks)
    for case in ('stable','P-drift','close-observer-memory','transfer-memory','cancel-close-A-transfer-B','registration-memory'):
        setup = "        hp_case="+repr(case)+"\n"
        checks = """        import errno,signal
        source_states={name:item.before for name,item in copied_inventory.members.items()}
        original_observe=c._capture_observe;original_transfer=c._capture_transfer_work;original_close=os.close
        events=[];fired=[]
        def actual_cancel():
            try:hp_handler(signal.SIGTERM,None)
            except InterruptedError as error:
                events.append(error)
                return error
        def observe(work,kind,site,value,*args,**kwargs):
            if hp_case=='close-observer-memory' and work is copied_inventory.leaf and site=='held-close' and not fired:
                fired.append(site);raise MemoryError('controlled actual P close observer')
            return original_observe(work,kind,site,value,*args,**kwargs)
        def transfer(source,work,case):
            if source is copied_inventory.leaf and not fired and hp_case=='transfer-memory':
                fired.append('transfer');raise MemoryError('controlled P tail transfer')
            if source is copied_inventory.leaf and events and len(events)==1 and hp_case=='cancel-close-A-transfer-B':
                raise actual_cancel()
            return original_transfer(source,work,case)
        watched={component.fd for item in copied_inventory.owned for component in item.components}
        closed=[]
        def close(fd):
            original_close(fd)
            if fd in watched:
                closed.append(fd)
                if hp_case=='cancel-close-A-transfer-B' and not events:raise actual_cancel()
        caught=None
        try:
            c._capture_observe=observe;c._capture_transfer_work=transfer;os.close=close
            if hp_case=='P-drift':
                copied.chmod(0o600);copied.write_bytes(b'changed private bytes');copied.chmod(0o400)
                copied_inventory.recheck()
                assert anchor.private_observations.get('unusable') is True
            if hp_case=='registration-memory':
                class Reject(dict):
                    def __setitem__(self,*args):raise MemoryError('controlled P member registration')
                additional=c._HeldCaptureCopy(anchor,anchor.recording_work,c._capture_work_values(anchor.recording_work,'test-P'))
                additional.members=Reject()
                try:additional.acquire(parent,'reproduction',source_states,copied_inventory.runtime_sha256)
                except MemoryError:pass
                else:raise AssertionError('missing P registration refusal')
                assert additional.closed and not additional.owned
            try:copied_inventory.close()
            except BaseException as error:caught=error
            before_close=anchor.recording_work.get('held_close_calls',0)
            copied_inventory.close()
            assert anchor.recording_work.get('held_close_calls',0)==before_close
            assert copied_inventory.closed and not copied_inventory.owned
            assert set(closed)==watched and len(closed)==len(watched)
            if hp_case=='cancel-close-A-transfer-B':
                assert len(events)==2 and events[0] is not events[1] and caught is events[0]
            else:assert caught is None
            if hp_case in ('close-observer-memory','transfer-memory'):
                assert fired and anchor.private_observations.get('unusable') is True
                assert c._capture_work_incomplete(copied_inventory.leaf)
            print(json.dumps({'HP_case':hp_case,'P_members':sorted(source_states),'P_runtime_SHA':copied_inventory.runtime_sha256,
                'all_P_fd_closed_once':True,'same_first_cancel':caught is events[0] if events else None,
                'actual_work':anchor.recording_work,'runtime_readback_old_counts_unchanged':True,
                'extra_fixture_P_read':len(source_raw),'system_runtime_collection':False,'qualification':False},sort_keys=True))
        finally:
            c._capture_observe=original_observe;c._capture_transfer_work=original_transfer;os.close=original_close
"""
        namespace={'__name__':'hp_private_fixture','__file__':str(root/'scripts/test/evals-malicious.test.sh'),
                   'hp_handler':callbacks['cancel']}
        exec(compile(prefix+setup+checks+footer,'<existing-H-constructor-to-P-handoff>','exec'),namespace)


def raw16_D_sources(root: Path, *, selected=None, evidence_directory=None) -> None:
    import tempfile
    import shutil
    import datetime
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
    if evidence_directory is not None:
        evidence_directory.mkdir(mode=0o700, exist_ok=False)
    launcher = (root/'evals/v1/evals-launcher.sh').read_text()
    prefix = launcher.split('# run SEED-SET.json OBSERVED_AT', 1)[0]
    engine = prefix.split("<<'PY_SHADOW_SOURCE'\n", 1)[1].split('\nPY_SHADOW_SOURCE', 1)[0]
    generation = json.loads((root/'core/v2/generation-registry.json').read_bytes())[1]['generation_id']
    table_script = prefix + "\ngeneration=$1\nrecord_generation=$1\nshadow_source_rows\n"
    cases = ('actual-84', 'reuse-84', 'wrong-reused-bytes', 'same-changed-source-target',
        'missing-file', 'extra-control', 'duplicate-table', 'missing-table', 'extra-table',
        'source-parent-mode-drift', 'target-name-drift', 'short-write', 'write-error', 'fsync-error',
        'close-error', 'registration-memory', 'linux-acl-present', 'linux-acl-unknown',
        'darwin-acl-present', 'darwin-acl-free-error', 'cancel-A-close-B',
        'ordinary-A-close-cancel-B', 'wrong-generation', 'registry-extra-key',
        'per-file-at', 'per-file-over', 'total-at', 'total-over', 'core-record-shadow-overlap',
        'source-fifo', 'target-fifo', 'wrong-reused-size')
    if selected is not None:
        assert set(selected) <= set(cases)
        cases = selected
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='ystack-D84-matrix-') as temporary:
            base = Path(temporary).resolve();base.chmod(0o700)
            table_run = subprocess.run(['/bin/bash', '-c', table_script, 'D-table', generation],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            assert table_run.returncode == 0, table_run.stderr
            rows = table_run.stdout.decode().splitlines()
            assert len(rows) == 84
            entries = [row.split(' ') for row in rows]
            source, target = base/'source', base/'target'
            source.mkdir(mode=0o700);target.mkdir(mode=0o700)
            source_copied = 0
            for name, _digest, size, _mode in entries:
                path = source/name;path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(root/name, path);source_copied += int(size)
            first = entries[0][0]
            if case in ('reuse-84', 'wrong-reused-bytes', 'same-changed-source-target', 'wrong-reused-size'):
                for name, _digest, _size, _mode in entries:
                    path = target/name;path.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source/name, path);path.chmod(0o400)
                for path in target.rglob('*'):
                    if path.is_dir():path.chmod(0o700)
                if case not in ('reuse-84', 'wrong-reused-size'):
                    path = target/first;raw = path.read_bytes()
                    wrong = bytes([raw[0]^1])+raw[1:]
                    path.chmod(0o600);path.write_bytes(wrong);path.chmod(0o400)
                    if case == 'same-changed-source-target':
                        path = source/first;mode = path.stat().st_mode&0o777
                        path.write_bytes(wrong);path.chmod(mode)
            if case == 'wrong-reused-size':
                path=target/first;path.chmod(0o600);path.write_bytes(b'partial');path.chmod(0o400)
            if case == 'source-fifo':
                (source/first).unlink();os.mkfifo(source/first,0o600)
            if case == 'target-fifo':
                (target/first).parent.mkdir(parents=True,exist_ok=True)
                for path in target.rglob('*'):
                    if path.is_dir():path.chmod(0o700)
                os.mkfifo(target/first,0o600)
            overlap_before = None
            if case == 'core-record-shadow-overlap':
                import re
                schema = next(row for row in entries if row[0].endswith('/modules/schema.jq'))
                core_sha = re.search(r"'schema[.]jq ([0-9a-f]{64})'",launcher).group(1)
                record_sha = re.search(r'record_files="\$record_schema ([0-9a-f]{64})',launcher).group(1)
                assert core_sha == record_sha == schema[1]
                parent=(target/schema[0]).parent;parent.mkdir(parents=True,exist_ok=True)
                for path in target.rglob('*'):
                    if path.is_dir():path.chmod(0o700)
                common = prefix + '\nrepo=$1\nruntime=$2\nschema=$3\ncore_sha=$4\nrecord_sha=$5\n'
                core_command=['/bin/bash','-c',common+'snapshot_expected "$core_sha" "$repo/$schema" "$runtime/$schema" 0400\n',
                    'D-core-cache',str(source),str(target),schema[0],core_sha,record_sha]
                core_result=subprocess.run(core_command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=environment)
                assert core_result.returncode==0,core_result.stderr
                before=(target/schema[0]).stat()
                cache_command=['/bin/bash','-c',common+'stage_expected "$record_sha" "$repo/$schema" "$runtime/$schema" 0400 E_STALE\n',
                    'D-record-cache',str(source),str(target),schema[0],core_sha,record_sha]
                cache_result=subprocess.run(cache_command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=environment)
                assert cache_result.returncode==0,cache_result.stderr
                value=(target/schema[0]).stat()
                fields=lambda row:(row.st_dev,row.st_ino,row.st_mode,row.st_uid,row.st_gid,row.st_nlink,
                    row.st_size,row.st_mtime_ns,row.st_ctime_ns)
                assert fields(before)==fields(value)
                overlap_before={'path':schema[0],'dev':value.st_dev,'ino':value.st_ino,'size':value.st_size,
                    'after_core_identity':fields(before),'after_record_identity':fields(value),
                    'core_and_record_declared_sha':core_sha,'core_cache_argv':core_command,'cache_argv':cache_command,
                    'core_cache_stdout':core_result.stdout.decode(),'core_cache_stderr':core_result.stderr.decode(),
                    'cache_stdout':cache_result.stdout.decode(),'cache_stderr':cache_result.stderr.decode()}
            if case == 'missing-file':(source/first).unlink()
            if case == 'extra-control':(source/'control/v1/unexpected.py').write_bytes(b'not accepted source')
            if case == 'duplicate-table':rows[-1] = rows[0]
            if case == 'missing-table':rows.pop()
            if case == 'extra-table':rows.append(rows[0])
            if case in ('wrong-generation', 'registry-extra-key'):
                path = source/'core/v2/generation-registry.json'
                value = json.loads(path.read_bytes())
                if case == 'wrong-generation':value[1]['generation_id'] = 'g-'+'f'*64
                else:value[1]['unaccepted'] = True
                raw = canonical_json(value);path.write_bytes(raw)
                rows = [name+' '+hashlib.sha256(raw).hexdigest()+' '+str(len(raw))+' '+mode
                    if name == 'core/v2/generation-registry.json' else ' '.join((name,digest,size,mode))
                    for name,digest,size,mode in entries]
            source_fill_bytes = 0
            if case in ('per-file-at', 'total-at'):
                sizes = [16*1024*1024]
                if case == 'total-at':
                    sizes.append(32*1024*1024-sum(int(row[2]) for row in entries[2:])-sizes[0])
                for index, size in enumerate(sizes):
                    path = source/entries[index][0]
                    measured = hashlib.sha256()
                    with path.open('wb') as output:
                        remaining = size
                        while remaining:
                            chunk = b'S'*min(65536,remaining)
                            assert output.write(chunk)==len(chunk)
                            source_fill_bytes += len(chunk)
                            measured.update(chunk);remaining -= len(chunk)
                    entries[index][1:3] = [measured.hexdigest(),str(size)]
                rows = [' '.join(row) for row in entries]
            if case in ('per-file-over', 'total-over'):
                entries[0][2] = str(16*1024*1024+(1 if case == 'per-file-over' else 0))
                if case == 'total-over':entries[1][2]=str(16*1024*1024)
                rows = [' '.join(row) for row in entries]
            body = engine
            injected = ''
            if case == 'source-parent-mode-drift':
                body = body.replace('    copy_inputs(rows)\n', '    os.chmod(source_root+"/control",0o777)\n    copy_inputs(rows)\n')
            if case == 'target-name-drift':
                body = body.replace('    final_checks(rows)\n', '    item=targets[next(iter(rows))]\n    os.rename(item["name"],item["name"]+".retained-failed",src_dir_fd=item["parent"]["fd"],dst_dir_fd=item["parent"]["fd"])\n    fd=os.open(item["name"],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o400,dir_fd=item["parent"]["fd"])\n    os.close(fd)\n    final_checks(rows)\n')
            if case in ('short-write', 'write-error'):
                injected += "_write=os.write\n_events=[]\ndef injected_write(fd,data):\n    if not _events:\n        _events.append(True)\n"
                injected += ("        return _write(fd,data[:3])\n" if case == 'short-write' else "        raise OSError(errno.ENOSPC,'controlled source write')\n")
                injected += "    return _write(fd,data)\nos.write=injected_write\n"
            if case == 'fsync-error':
                injected += "def injected_sync(fd):\n    raise OSError(errno.EIO,'controlled source fsync')\nos.fsync=injected_sync\n"
            if case == 'close-error':
                injected += "_close=os.close\n_events=[]\ndef injected_close(fd):\n    _close(fd)\n    if not _events:\n        _events.append(True)\n        raise OSError(errno.EBADF,'controlled post-close failure')\nos.close=injected_close\n"
            if case == 'registration-memory':
                injected += "class RejectOwned(list):\n    def append(self,row):\n        raise MemoryError('controlled source fd registration')\nowned=RejectOwned()\n"
            if case.startswith('linux-acl-'):
                injected += "sys.platform='linux'\n"
                injected += ("os.getxattr=lambda *args:b'present'\n" if case.endswith('present') else "def denied_xattr(*args):\n    raise OSError(errno.EPERM,'controlled fd ACL')\nos.getxattr=denied_xattr\n")
            if case.startswith('darwin-acl-'):
                injected += "import types\nsys.platform='darwin'\ndef fake_free(pointer):\n    work['fixture_free_calls']=work.get('fixture_free_calls',0)+1\n"
                injected += ("    ctypes.set_errno(errno.EBADF)\n    return -1\n" if case.endswith('free-error') else "    return 0\n")
                injected += "library=types.SimpleNamespace(acl_get_fd_np=lambda *args:1,acl_free=fake_free)\n"
            if case in ('cancel-A-close-B', 'ordinary-A-close-cancel-B'):
                injected += "_close=os.close\n_cancel_events=[]\n_close_events=[]\ndef event():\n    try:interrupt(signal.SIGTERM,None)\n    except InterruptedError as error:\n        _cancel_events.append(error)\n        return error\ndef stop_write(fd,data):\n"
                injected += ("    raise event()\n" if case.startswith('cancel-A') else "    raise ValueError('controlled first source failure')\n")
                injected += "def cancel_close(fd):\n    _close(fd)\n    if not _close_events:\n        _close_events.append(True)\n        raise event()\nos.write=stop_write\nos.close=cancel_close\n"
                body = body.replace('print(json.dumps(work,', "work['fixture_same_first_marked']=failure is _cancel_events[0]\nwork['fixture_distinct_cancels']=len({id(error) for error in _cancel_events})\nprint(json.dumps(work,")
            body = body.replace('failure = None\ntry:\n', injected+'\nfailure = None\ntry:\n')
            command = ['/usr/bin/python3','-I','-S','-B','-',str(source),str(target),'\n'.join(rows)]
            started = datetime.datetime.now(datetime.timezone.utc).isoformat()
            if evidence_directory is not None:
                case_output = evidence_directory/case;case_output.mkdir(mode=0o700)
                (case_output/'inline.py').write_bytes(body.encode())
                (case_output/'command.json').write_text(json.dumps({'argv':command,'cwd':str(Path.cwd()),
                    'environment':environment,'started':started},indent=2)+'\n')
            result = subprocess.run(command, input=body.encode(),stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,env=environment)
            finished = datetime.datetime.now(datetime.timezone.utc).isoformat()
            if evidence_directory is not None:
                (case_output/'stdout.raw').write_bytes(result.stdout)
                (case_output/'stderr.raw').write_bytes(result.stderr)
                (case_output/'receipt.json').write_text(json.dumps({'argv':command,'environment':environment,
                    'started':started,'finished':finished,'exit':result.returncode,
                    'inline_sha256':hashlib.sha256(body.encode()).hexdigest()},indent=2)+'\n')
            assert result.stdout, (case,result.returncode,result.stderr)
            work = json.loads(result.stdout)
            positive = case in ('actual-84','reuse-84','short-write','per-file-at','total-at','core-record-shadow-overlap')
            assert result.returncode == (0 if positive else 1), (case,result.returncode,work.get('failures'),result.stderr)
            assert work['data_and_close_complete'] is positive, case
            if positive:
                assert work['logical_occurrences'] == 84
                for name,digest,size,_mode in entries:
                    measured=hashlib.sha256();actual_size=0
                    with (target/name).open('rb') as input_file:
                        while True:
                            raw=input_file.read(65536)
                            if not raw:break
                            actual_size+=len(raw);measured.update(raw)
                    assert actual_size==int(size) and measured.hexdigest()==digest
                    assert target.joinpath(name).stat().st_mode&0o777==0o400
            if case == 'reuse-84':
                assert work['created_files'] == work['write_bytes'] == work['physical_bytes'] == 0
                assert work['reused_files']==84 and work['prior_physical_bytes']==source_copied
            if case in ('duplicate-table','missing-table','extra-table','per-file-over','total-over'):
                assert work['created_files']==work['read_bytes']==work['close_calls']==0
            if case == 'core-record-shadow-overlap':
                assert overlap_before is not None
                after=(target/overlap_before['path']).stat()
                assert (after.st_dev,after.st_ino,after.st_size)==(overlap_before['dev'],overlap_before['ino'],overlap_before['size'])
                assert work['reused_files']==1 and work['created_files']==83
                assert work['prior_physical_bytes']==overlap_before['size']
                assert work['physical_bytes']+work['prior_physical_bytes']==work['logical_bytes']
                overlap_before['logical_memberships']={'core':1,'record':1,'shadow':1}
                overlap_before['native_Q_and_other_old_closure_costs']='UNKNOWN; original cache hashes are not fully metered'
            if case == 'wrong-reused-size':assert work['prior_physical_bytes'] >= 7
            if case == 'registration-memory':assert work['close_calls']==1 and work['accounting_incomplete'] is True
            if case.startswith('darwin-acl-'):assert work['fixture_free_calls']==1
            if case == 'cancel-A-close-B':
                assert work['fixture_same_first_marked'] is True and work['fixture_distinct_cancels']==2
            if case == 'ordinary-A-close-cancel-B':
                assert work['fixture_same_first_marked'] is True and work['fixture_distinct_cancels']==1
            if case == 'target-name-drift':assert (target/(first+'.retained-failed')).exists()
            if case == 'write-error':assert (target/first).exists() and (target/first).stat().st_size==0
            print(json.dumps({'D_case':case,'exit':result.returncode,'actual_D_work':work,'actual_cross_closure_cache':overlap_before,
                'injected_private_inline_only': bool(injected) or case in ('source-parent-mode-drift','target-name-drift'),
                'fixture_source_copy_logical_file_bytes':source_copied,'fixture_source_fill_actual_write_bytes':source_fill_bytes,
                'synthetic_source_and_private_pin_override_for_boundary':case in ('per-file-at','total-at','per-file-over','total-over'),
                'fixture_source_copy_backend_R_W_C':'UNKNOWN: shutil.copy2 backend not measured',
                'fixture_target_prefill_logical_file_bytes':source_copied if case in ('reuse-84','wrong-reused-bytes','same-changed-source-target','wrong-reused-size') else 0,
                'boundary_argv':command,'boundary_environment':environment,'started':started,'finished':finished,
                'executed_inline_sha256':hashlib.sha256(body.encode()).hexdigest(),
                'positive_validation_extra_target_read_sha_bytes':sum(int(row[2]) for row in entries) if positive else 0,
                'full_cli_pinned_jq_route':'NOTRUN','whole_B_qualification':False,
                'real_system_runtime_retention':False},sort_keys=True))


def raw16_scope_sudo_source(root: Path, *, observer_cancel_only=False) -> None:
    import tempfile
    import ast
    spec = importlib.util.spec_from_file_location('raw16_scope_sudo_reader', root/'scope/v1/read-shadow-evidence.py')
    scope = importlib.util.module_from_spec(spec);sys.modules[spec.name] = scope;spec.loader.exec_module(scope)
    c, results = scope.c, []
    main = next(node for node in ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text()).body
        if isinstance(node, ast.FunctionDef) and node.name == 'main')
    cancel = next(node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == 'cancel')
    namespace = {};exec(compile(ast.Module(body=[cancel], type_ignores=[]), '<actual-scope-handler>', 'exec'), namespace)
    handler = namespace['cancel']
    original_acl = c._acl_state
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    try:
        cases = ('stable', 'kill-stable', 'dup-ancestor', 'dup-target', 'dup-observer-memory',
                     'companion-close-observer', 'cancel-A-native-close-B', 'native-error-close-error',
                     'dup-fstat', 'dup-row-allocation', 'companion-registration', 'native-error-close-cancel', 'native-error-close-observer-cancel')
        if observer_cancel_only:cases = ('native-error-close-observer-cancel',)
        for case in cases:
            with tempfile.TemporaryDirectory(prefix='ystack-scope-sudo-') as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                captures = base/'captures';captures.mkdir(mode=0o700)
                paths = {}
                for role in ('sudo', 'python', 'jq', 'bash', 'git', 'supervisor'):
                    path = base/role;path.write_bytes(b'never executed synthetic scope '+role.encode());path.chmod(0o400)
                    paths[role] = path
                reader = object.__new__(scope._Reader)
                reader.source_copies = [];reader.owned = [];reader.inputs = [];reader.commands = [];reader.gate_commands = []
                reader.commands_open = True;reader.store_session = None;reader.capture_completion_owner = None
                reader.captures = captures;reader.darwin = None
                anchor = c.Anchor({'principal_uid': os.geteuid()}, b'', [], {}, ('', []), ('', []), None)
                reader.anchor = anchor
                reader.python = reader.hold(paths['python'], c.EXECUTABLE_LIMIT)
                reader.jq = reader.hold(paths['jq'], c.EXECUTABLE_LIMIT)
                reader.bash = reader.hold(paths['bash'], c.EXECUTABLE_LIMIT)
                reader.git_binary = reader.hold(paths['git'], c.EXECUTABLE_LIMIT)
                supervisor = reader.hold(paths['supervisor'], c.EXECUTABLE_LIMIT)
                supervisor.held.path = c.ANCHOR+'/host-supervisor.py'
                anchor.held.append(supervisor.held)
                configuration = object.__new__(c._CoverageConfiguration)
                configuration.normalizer = types.SimpleNamespace(request=lambda _raw: None)
                configuration.recheck = lambda: None
                reader.coverage_configuration = configuration;reader.kill_configuration = configuration
                owner = object.__new__(c._DarwinChildOwner)
                owner.ledger = reader;owner.python = reader.python;owner.deadline = time.monotonic()+120
                owner.recheck = lambda: None
                request = c.canonical({'kind': 'kill_register_source_request' if case == 'kill-stable' else 'coverage_source_request',
                    'id': 'coverage.sudo.fixture'})
                foreground, original_holds, cancels, duplicated, closed, injections, source_chain = [], [], [], [], [], [], []
                first = c.Refusal('E_RUNTIME')
                def foreground_fixture(*_args):
                    foreground.append(True)
                    if case in ('native-error-close-error', 'native-error-close-cancel', 'native-error-close-observer-cancel'):raise first
                    return b''
                owner._foreground = foreground_fixture
                hold_bytes, dup, close, observe = c._hold_bytes, os.dup, os.close, c._capture_observe
                fstat, replace = os.fstat, c.dataclasses.replace
                class RegistrationFailure(list):
                    def append(self, _row):
                        injections.append("registration");raise MemoryError("controlled companion registration")
                if case == "companion-registration":anchor.runtime_companions = RegistrationFailure()
                def held_fixture(path, *args, **kwargs):
                    assert path == '/usr/bin/sudo'
                    item = hold_bytes(str(paths['sudo']), *args, **kwargs)
                    item.held.path = '/usr/bin/sudo'
                    original_holds.append((item, item.held.fd, len(item.held.components)))
                    return item
                def handler_error():
                    try:handler(signal.SIGTERM, None)
                    except InterruptedError as error:
                        cancels.append(error)
                        return error
                def dup_fixture(fd):
                    ordinal = len(duplicated)
                    if ((case == 'dup-ancestor' and ordinal == 0)
                            or (case == 'dup-target' and ordinal == original_holds[0][2]-1)):
                        injections.append('dup');raise OSError(errno.EMFILE, 'controlled dup failure')
                    value = dup(fd);duplicated.append(value);return value
                def close_fixture(fd):
                    close(fd)
                    if fd in duplicated:closed.append(fd)
                    if original_holds and fd == original_holds[0][1] and 'native-close' not in injections:
                        if case in ('cancel-A-native-close-B', 'native-error-close-cancel'):
                            injections.append('native-close');raise handler_error()
                        if case in ('native-error-close-error', 'native-error-close-observer-cancel'):
                            injections.append('native-close');raise OSError(errno.EBADF, 'controlled secondary native close')
                def fstat_fixture(fd):
                    if case == 'dup-fstat' and fd in source_chain and not injections:
                        injections.append('fstat');raise OSError(errno.EIO, 'controlled duplicated hold fstat')
                    return fstat(fd)
                def replace_fixture(component, **kwargs):
                    if case == 'dup-row-allocation' and not injections:
                        injections.append('row-allocation');raise MemoryError('controlled duplicated row allocation')
                    return replace(component, **kwargs)
                def observed(work, kind, site, value, *args, **kwargs):
                    if site == 'scope-sudo-dup' and value['return'] >= 0:source_chain.append(value['return'])
                    if case == 'native-error-close-observer-cancel' and site == 'scope-native-sudo-close':
                        injections.append('close-observer-cancel');raise handler_error()
                    if site == 'scope-sudo-dup' and not injections:
                        if case == 'dup-observer-memory':
                            injections.append('observer');raise MemoryError('controlled dup observer')
                        if case == 'cancel-A-native-close-B':
                            injections.append('cancel-A');raise handler_error()
                    if (case == 'companion-close-observer' and site == 'held-close' and closed and not injections):
                        injections.append('companion-close');raise MemoryError('controlled companion close observer')
                    return observe(work, kind, site, value, *args, **kwargs)
                c._hold_bytes, os.dup, os.close, c._capture_observe = held_fixture, dup_fixture, close_fixture, observed
                os.fstat, c.dataclasses.replace = fstat_fixture, replace_fixture
                caught = None
                try:
                    try:
                        if case == 'kill-stable':owner.kill_register_source(request)
                        else:owner.coverage_source(request)
                    except BaseException as error:caught = error
                    if case == 'cancel-A-native-close-B':
                        assert len(cancels) == 2 and cancels[0] is not cancels[1] and caught is cancels[0]
                        assert not foreground
                    elif case == 'native-error-close-error':assert caught is first and foreground == [True]
                    elif case in ('native-error-close-cancel', 'native-error-close-observer-cancel'):
                        assert len(cancels) == 1 and caught is cancels[0] and foreground == [True]
                    else:assert caught is None and foreground == [True]
                    assert len(original_holds) == 1 and original_holds[0][0].held.components == []
                    retained_chain = [component.fd for item, _work, _key in anchor.runtime_companions for component in item.components]
                    assert retained_chain == source_chain, (case, retained_chain, source_chain)
                    if case in ('stable', 'kill-stable', 'companion-close-observer', 'native-error-close-error', 'native-error-close-cancel', 'native-error-close-observer-cancel'):
                        assert len(retained_chain) == original_holds[0][2]
                    for fd in retained_chain:os.fstat(fd)
                    parent = c._open_held(str(captures), True,
                        c._store_rule(os.geteuid(), os.getegid(), 0o700, True, None), 'E_STORE')
                    try:anchor.seal_local_runtime(parent)
                    finally:parent.close()
                    assert sorted(closed) == sorted(duplicated)
                    assert all(closed.count(fd) == 1 for fd in source_chain)
                    if case in ('stable', 'kill-stable'):
                        assert not anchor.private_observations.get('unusable', False)
                        row = next(row for row in anchor.private_observations['local_runtime'] if row['slot'] == 'sudo')
                        if case == 'kill-stable':
                            assert {row['slot'] for row in anchor.private_observations['local_runtime']} == {'python', 'jq', 'bash', 'git', 'sudo'}
                        assert row['slot'] == 'sudo' and row['request_sha256'] == c.digest(request)
                        assert (captures/row['file']).read_bytes() == paths['sudo'].read_bytes()
                    else:assert anchor.private_observations.get('unusable') is True
                    if case == 'native-error-close-observer-cancel':
                        assert injections == ['native-close', 'close-observer-cancel']
                        assert anchor.recording_work['metadata_failure']['errno'] == errno.EBADF
                        assert anchor.recording_work['accounting_incomplete'] is True
                    results.append({'case': case, 'native_foreground_calls': len(foreground), 'native_original_closed_at_source_return': True,
                        'first_cancel_same_object': caught is cancels[0] if cancels else None,
                        'observed_dup_fds_including_P_reader': duplicated, 'retained_full_source_chain_dup_fds': source_chain,
                        'once_closed_dup_fds': closed, 'injections': injections,
                        'work': anchor.recording_work, 'validation_extra_read_bytes': 2*paths['sudo'].stat().st_size if case in ('stable', 'kill-stable') else 0})
                finally:
                    c._hold_bytes, os.dup, os.close, c._capture_observe = hold_bytes, dup, close, observe
                    os.fstat, c.dataclasses.replace = fstat, replace
                    anchor.held = []
                    anchor.close();reader.close()
    finally:c._acl_state = original_acl
    print(json.dumps({'scope_actual_source_read_sudo_to_P_and_post_native_close_seal': results,
        'fixed_sudo_and_supervisor_paths_mapped_to_TMP': True,
        'native_foreground_normalizer_recheck_and_ACL_are_fixture_substitutes': True,
        'system_runtime_read_or_execution': False, 'real_source_qualification': False}, sort_keys=True))


def raw16_scope_acquisitions(root: Path) -> None:
    import tempfile
    spec = importlib.util.spec_from_file_location('raw16_scope_actual_reader', root/'scope/v1/read-shadow-evidence.py')
    scope = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = scope
    spec.loader.exec_module(scope)
    c = scope.c
    acl, results = c._acl_state, []
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    try:
        for case in ('stable', 'source-drift', 'P-drift', 'occupied-P', 'parent-close-observer', 'invalid-caller'):
            with tempfile.TemporaryDirectory(prefix='ystack-scope-P-') as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                captures = base/'captures';captures.mkdir(mode=0o700)
                sources = base/'sources';sources.mkdir(mode=0o700)
                reader = object.__new__(scope._Reader)
                reader.source_copies = [];reader.owned = [];reader.inputs = [];reader.captures = captures;reader.darwin = None
                anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
                reader.anchor = anchor;reader.capture_completion_owner = None
                paths, acquired = {}, {}
                for role, attribute in (('python', 'python'), ('jq', 'jq'), ('bash', 'bash'), ('git', 'git_binary')):
                    path = sources/role
                    raw = (b'never executed scope original bytes ' + role.encode()) * 7
                    path.write_bytes(raw);path.chmod(0o400)
                    paths[role] = path;acquired[role] = raw
                reference = {'sha256': 'a'*64}
                stage = {'request_ref': reference, 'resolved_profile_ref': reference, 'result_ref': reference}
                for name in ('risk', 'duty', 'scope'):
                    path = base/(name+'.json')
                    path.write_bytes(c.canonical({'schema_version': 1, 'kind': name, 'id': 'scope.fixture', 'body': {'stage': stage}}))
                    path.chmod(0o400)
                normalizer = types.SimpleNamespace(DOCUMENT_NAMES=('risk', 'duty', 'scope'),
                    doc_ref=scope.ref, request=lambda raw: None)
                configuration = types.SimpleNamespace(normalizer=normalizer, close=lambda: None,
                    package_raw=c.canonical({'schema_version': 1, 'kind': 'package', 'id': 'scope.fixture'}),
                    accepted_raw=c.canonical({'schema_version': 1, 'kind': 'accepted', 'id': 'scope.fixture'}))
                reader.scope_body = {'required_shadow_environments': [], 'target_repository_id': 'repository.fixture',
                    'qualified_identity': {'target_revision': {'commit_id': 'a'*40}, 'stage_request_ref': reference,
                        'resolved_profile_ref': reference},
                    'coverage': {'coverage_base': {'commit_id': 'b'*40}, 'qualifying_shadow_record_refs': []},
                    'shadow_evidence_refs': []}
                reader.document_paths = {name: base/(name+'.json') for name in ('risk', 'duty', 'scope')}
                reader.scratch = base;reader.store_session = None;reader.git = types.SimpleNamespace(config=b'synthetic native config')
                reader.commit = lambda _oid: ('c'*40, [])
                reader._coverage_nonce = 'd'*64;reader._coverage_prepare_only = True
                for role, attribute in (('python', 'python'), ('jq', 'jq'), ('bash', 'bash'), ('git', 'git_binary')):
                    setattr(reader, attribute, reader.hold(paths[role], c.EXECUTABLE_LIMIT))
                if case == 'source-drift':
                    paths['python'].chmod(0o600);paths['python'].write_bytes(b'changed bytes');paths['python'].chmod(0o400)
                if case == 'occupied-P':
                    (captures/'runtime-0000-python-0000.bin').write_bytes(b'preserved partial')
                load_configuration, observe = c.load_coverage_configuration, c._capture_observe
                fired = []
                def close_observer(work, kind, site, value, *args, **kwargs):
                    if case == 'parent-close-observer' and site == 'held-close' and any(work is leaf for leaf in anchor.recording_work.get('scope_runtime_parent_work', [])) and not fired:
                        fired.append(site)
                        raise MemoryError('controlled real scope parent close observation')
                    return observe(work, kind, site, value, *args, **kwargs)
                c.load_coverage_configuration = lambda *_: configuration
                c._capture_observe = close_observer
                try:
                    if case == 'invalid-caller':
                        request = c.canonical({'kind': 'unrelated_request', 'id': 'scope.fixture'})
                        reader.retain_source_runtime(request)
                    else:
                        request = reader.source_coverage({}, {}, [[], []])
                        assert c._json(request, c.DOCUMENT_LIMIT, 'E_STORE')['kind'] == 'coverage_source_request'
                    values = anchor.private_observations.get('local_runtime', [])
                    if case in ('stable', 'P-drift', 'parent-close-observer'):
                        assert [row['slot'] for row in values] == ['python', 'jq', 'bash', 'git'], (anchor.private_observations, anchor.recording_work)
                        for row in values:
                            assert row['request_sha256'] == c.digest(request)
                            assert row['attempt_id'] == 'coverage.'+'d'*64
                            assert (captures/row['file']).read_bytes() == acquired[row['slot']]
                            assert stat.S_IMODE((captures/row['file']).stat().st_mode) == 0o400
                        if case == 'P-drift':
                            target = captures/values[0]['file']
                            target.chmod(0o600);target.write_bytes(b'changed P bytes');target.chmod(0o400)
                        parent = c._open_held(str(captures), True,
                            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, None), 'E_STORE')
                        try:anchor.seal_local_runtime(parent)
                        finally:parent.close()
                        if case == 'stable':
                            assert not anchor.private_observations.get('unusable', False)
                            reader.source_capture_work = []
                            def unresolved_capture_seal(current, _parent):
                                current.private_observations['recording_sealed'] = False
                                c._capture_accounting_receipt(current)
                            reader.enforced = types.SimpleNamespace(_seal_capture_recording=unresolved_capture_seal)
                            reader.seal_source_captures()
                            assert anchor.private_observations['recording_sealed'] is False
                        else:assert anchor.private_observations.get('unusable') is True
                        if case == 'parent-close-observer':
                            assert fired == ['held-close'] and anchor.recording_work['accounting_incomplete'] is True
                    else:
                        assert anchor.private_observations.get('unusable') is True
                        if case == 'occupied-P':assert (captures/'runtime-0000-python-0000.bin').read_bytes() == b'preserved partial'
                        if case == 'invalid-caller':assert not list(captures.iterdir())
                    assert anchor.private_observations['accounting']['complete'] is False
                    results.append({'case': case, 'work': anchor.recording_work,
                        'actual_original_hold_bytes': {role: len(raw) for role, raw in acquired.items()},
                        'validation_extra_read_bytes': sum(len(raw) for raw in acquired.values()) if values else 0,
                        'physical_P_positive': case == 'stable', 'fixture_normalizer_and_git_values': True,
                        'full_runtime_Q_and_host_work': 'UNKNOWN', 'system_runtime_read_or_execution': False})
                finally:
                    c.load_coverage_configuration, c._capture_observe = load_configuration, observe
                    reader.close()
    finally:c._acl_state = acl
    print(json.dumps({'scope_actual_hold_and_source_coverage_to_P': results,
        'ACL_prerequisite_is_fixture_substitute': True, 'full_scope_route_and_qualification': False}, sort_keys=True))


def raw16_p_acquisitions(root: Path) -> None:
    import tempfile
    spec = importlib.util.spec_from_file_location('raw16_P_actual_reader', root/'shadow/v1/enforced-reproduction.py')
    e = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = e
    spec.loader.exec_module(e)
    c = e.c
    acl = c._acl_state
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    results = []
    try:
        for scenario in ('stable', 'source-drift', 'P-drift', 'occupied-P', 'case-carry-over', 'close-observer-memory'):
            with tempfile.TemporaryDirectory(prefix='ystack-raw16-P-') as temporary:
                base = Path(temporary).resolve()
                base.chmod(0o700)
                work, dependencies, source = base/'work', base/'dependencies', base/'synthetic-helper'
                work.mkdir(mode=0o700);dependencies.mkdir(mode=0o700)
                raw = b'synthetic never executed helper acquisition' * 1751
                source.write_bytes(raw);source.chmod(0o400)
                aux = base/'native-fixture-values'
                aux.mkdir(mode=0o700)
                aux_paths = {}
                for role in ('compiler', 'native_release', 'native_build_record'):
                    path = aux/role
                    path.write_bytes(b'never executed original native owner ' + role.encode())
                    path.chmod(0o400)
                    aux_paths[role] = path
                native_values = {role: e.stable_file(path) for role, path in aux_paths.items()}
                native = c.snapshot_dependency(str(source), c.digest(raw), len(raw), str(dependencies/'helper'), 'object-closure')
                holder = e.stable_directory(work)
                anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
                request = c.canonical({'kind': 'shadow_enforced_request', 'id': 'p.original.read.fixture'})
                pread, events = os.pread, []
                def observed_read(fd, size, offset):
                    value = pread(fd, size, offset)
                    events.append({'fd': fd, 'count': size, 'offset': offset, 'return': len(value)})
                    return value
                try:
                    assert native.acquisition_raw == raw
                    if scenario == 'occupied-P':
                        (work/'runtime-0000-object_closure-0000.bin').write_bytes(b'preserved occupancy')
                    if scenario == 'case-carry-over':
                        key = str(holder.held.before.st_dev) + ':' + str(holder.held.before.st_ino)
                        carry = c._capture_work_values(anchor.recording_work, key)
                        carry['runtime'] = {'read_bytes': c._RUNTIME_FIELDS['read_bytes']-len(raw)+1}
                    os.pread = observed_read
                    holder._retain_runtime(anchor, 'object_closure', native.original, native.acquisition_raw, request)
                    native.acquisition_raw = None
                    target = work/'runtime-0000-object_closure-0000.bin'
                    if scenario == 'case-carry-over':
                        assert anchor.private_observations.get('unusable') is True and not events and not target.exists()
                        results.append({'case': scenario, 'actual_new_runtime_reads': 0, 'actual_native_acquisition_bytes': len(raw),
                            'carry_counter_is_synthetic_boundary_input_not_actual_104GiB_work': True,
                            'work': anchor.recording_work})
                        continue
                    if scenario == 'occupied-P':
                        assert anchor.private_observations.get('unusable') is True
                        assert target.read_bytes() == b'preserved occupancy'
                        results.append({'case': scenario, 'actual_pread_trace': events,
                            'work': anchor.recording_work, 'preserved_occupied_bytes': 19})
                        continue
                    assert not anchor.private_observations.get('unusable', False)
                    previous_active = e.CancellationSignals.active
                    raw_owner = object.__new__(e._NativeRelease)
                    raw_owner.compiler = native_values['compiler']
                    raw_owner.binary = native_values['native_release']
                    raw_owner.record = native_values['native_build_record']
                    raw_owner.runtime_values = {'fixture_only': 'no native loader or compiler was executed'}
                    e.CancellationSignals.active = types.SimpleNamespace(native=raw_owner)
                    try:
                        e._retain_native_runtime(anchor, holder, request)
                    finally:
                        e.CancellationSignals.active = previous_active
                    assert {row['slot'] for row in anchor.private_observations['local_runtime']} == {
                        'object_closure', 'compiler', 'native_release', 'native_build_record'}
                    assert target.read_bytes() == raw and target.stat().st_mode & 0o777 == 0o400
                    assert native.snapshot.read(len(raw), 'E_DEPENDENCY') == raw
                    row = anchor.private_observations['local_runtime'][0]
                    assert row['request_sha256'] == c.digest(request) and row['attempt_id'] == 'p.original.read.fixture'
                    if scenario in ('source-drift', 'P-drift'):
                        changed = source if scenario == 'source-drift' else target
                        changed.chmod(0o600);changed.write_bytes(b'changed fixture bytes');changed.chmod(0o400)
                    observe, receipt_owner = c._capture_observe, c._capture_accounting_receipt
                    fired, tail_flags = [], []
                    def close_observation(work, kind, site, value, *args, **kwargs):
                        if scenario == 'close-observer-memory' and site == 'held-close' and not fired:
                            fired.append(site)
                            raise MemoryError('controlled real HeldPath.close observation failure')
                        return observe(work, kind, site, value, *args, **kwargs)
                    def actual_tail_receipt(current):
                        if fired:
                            tail_flags.append(current.private_observations.get('unusable', False))
                        return receipt_owner(current)
                    owner_work = {}
                    c._capture_work_values(owner_work, 'completion-fixture')
                    owner = types.SimpleNamespace(source=types.SimpleNamespace(recheck=lambda *_: None, close=lambda: None),
                        source_closed=False, work=owner_work,
                        transfer=lambda work, case: c._capture_transfer_work(owner_work, work, case))
                    anchor.capture_completion_owner = owner
                    try:
                        c._capture_observe, c._capture_accounting_receipt = close_observation, actual_tail_receipt
                        e._seal_capture_recording(anchor, holder._recording_parent())
                    finally:
                        c._capture_observe, c._capture_accounting_receipt = observe, receipt_owner
                    if scenario == 'close-observer-memory':
                        assert fired == ['held-close'] and tail_flags and all(tail_flags)
                        assert anchor.recording_work['accounting_incomplete'] is True
                    elif scenario == 'stable':
                        assert not c._capture_work_incomplete(anchor.recording_work)
                        assert all('final_failure' not in leaf for leaf in anchor.recording_work['local_runtime_leaves'])
                    else:
                        assert any('final_failure' in leaf for leaf in anchor.recording_work['local_runtime_leaves'])
                    assert anchor.private_observations['recording_sealed'] is False
                    assert anchor.private_observations['accounting']['complete'] is False
                    assert native.snapshot.read(len(raw), 'E_DEPENDENCY') == raw
                    if scenario == 'stable':
                        assert sum(row['return'] for row in events) == 7*(len(raw)+sum(len(item.raw) for item in native_values.values()))
                    results.append({'case': scenario, 'actual_pread_trace': events,
                        'runtime_fees': anchor.recording_work['runtime'],
                        'actual_M_fees': anchor.recording_work.get('accounting'),
                        'native_snapshot_original_read_copy_version_qualification_Q': 'NOT_COMPLETE_OR_QUALIFIED',
                        'validation_extra_reads': 3*len(raw), 'source_bytes': len(raw)})
                finally:
                    os.pread = pread
                    holder.close();native.close()
                    for item in native_values.values():item.close()
    finally:
        c._acl_state = acl
    print(json.dumps({'P_original_snapshot_to_recorder': results, 'ordinary_synthetic_runtime_only': True}, sort_keys=True))

def _synthetic_parent_P_context(c, path):
    import struct
    helper=c.canonical(['synthetic helper metadata'])
    dependency=c.canonical({'synthetic dependency metadata':True})
    native={key:'a'*64 for key in ('source_sha256','build_script_sha256','build_record_sha256',
        'binary_sha256','python_sha256','dependency_record_sha256')}
    native.update(binary_path='/fixture/native',binary_size=1,python_path='/fixture/python',
        python_abi='fixture-abi',loader_mode='rtld-now-local.v1',dependency_record_sha256=c.digest(dependency))
    body={'helper_source_sha256':c.HELPER_SOURCE_SHA256,'helper_build_record_sha256':c.digest(helper),
        'helper_executable_sha256':'b'*64,'helper_executable_size':1,'helper_path':'/fixture/helper','native_release':native}
    raw=c.canonical({'schema_version':2,'kind':'shadow_consumer_parent_context','id':'shadow.parent','body':body})
    frame=c.PARENT_FRAME_MAGIC+struct.pack('!III',len(raw),len(helper),len(dependency))+raw+helper+dependency
    path.write_bytes(frame);path.chmod(0o400)
    return c.capture_parent_context(os.open(path,os.O_RDONLY)),{
        'parent-frame.bin':frame,'helper-build-record.json':helper,'native-dependency-record.json':dependency}


def raw16_T_enforced_chain(root: Path) -> None:
    body=(root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix=body.split('        copied_inventory.close();copied_inventory.close()\n',1)[0]
    footer=body[body.rfind('finally:\n    if copied_inventory'):]
    before="        parent=c._open_held(str(private),True,c._store_rule(uid,gid,0o700,True),'E_STORE')\n"
    prefix=prefix.replace(before,"        (private/'preparation-scratch').mkdir(mode=0o700)\n"+before)
    edge="        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)\n"
    head,tail=prefix.split(edge,1)
    setup='''        import textwrap,shutil
        holder=e.StableDirectory(parent)
        input_raw,response_raw=b'synthetic enforced input',b'synthetic enforced response'
        caller=c.canonical({'kind':'shadow_enforced_request','id':'t.enforced.chain'})
        calls=[];snapshots=[];old=[]
        snapshot_init=c._RuntimeSnapshot.__init__;retain=holder._retain_preparation
        def snapshot(self,*args,**kwargs):snapshots.append(args[0].path);return snapshot_init(self,*args,**kwargs)
        def retaining(*args,**kwargs):
            result=retain(*args,**kwargs)
            assert result is not None, ('actual enforced T retention',anchor.private_observations.get('unusable'),
                [leaf.get('failure') for leaf in anchor.recording_work.get('preparation_leaves',[])])
            if args[2]=='prepare':
                T=result.T_companions[0];old.append((T,T.binding['root_before'],dict(T.binding['target_states'])))
            else:
                assert len(result.T_companions)==2 and holder.T_native_context is None
                assert old[0][0].closed and old[0][0].close_complete
                assert any(T.previous_source is old[0][0] for T in result.T_companions)
            return result
        def execute(role,argv,component,**options):
            operation=argv[5]
            assert role=='candidate-'+('preparation' if operation=='prepare' else 'inspection')
            assert options=={'timeout':300,'env':{'fixture':'unchanged'},'deadline':123}
            assert argv[argv.index('--input-sha256')+1]==c.digest(input_raw)
            scratch=Path(argv[argv.index('--scratch')+1])
            if operation=='inspect':assert not (scratch/'candidate-preparation-0000000000000001').exists()
            make_T(c,scratch,operation,input_raw,response_raw)
            (scratch/('candidate-preparation-'+('0000000000000001' if operation=='prepare' else '0000000000000002'))).mkdir(mode=0o700)
            calls.append(operation)
        source_text=(root/'shadow/v1/enforced-reproduction.py').read_text()
        begin=source_text.index('        prep = work / "preparation-parent/preparation";')
        end=source_text.index('        record_raw = read_regular(',begin)
        segment=textwrap.dedent(source_text[begin:end])
        holder._retain_preparation=retaining;c._RuntimeSnapshot.__init__=snapshot
        env={'work':private,'SOURCE':root,'sys':sys,'sha':e.sha,'mapped':{'materialization_input':private/'input'},
            'response_path':private/'response','candidate':private/'candidate',
            'jq':types.SimpleNamespace(snapshot=types.SimpleNamespace(path=str(private/'synthetic-jq'))),
            'execute':execute,'env':{'fixture':'unchanged'},'deadline':123,'work_hold':holder,'anchor':anchor,
            'input_raw':input_raw,'response_raw':response_raw,'request_raw':caller,'shutil':shutil,'c':c}
        exec(compile(segment,'<actual-enforced-T-sequence>','exec'),env)
        assert calls==['prepare','inspect'] and len(snapshots)==9
        assert not anchor.private_observations.get('unusable'), 'enforced T original inspect full acquisition must succeed'
        assert old[0][0].binding['root_before']==old[0][1] and old[0][0].binding['target_states']==old[0][2]
        current=[T for carrier in holder.runtime_copies for T in carrier.T_companions]
        assert len(current)==2 and all(T.stable and not T.closed for T in current)
        assert all(T.binding['root_before']!=old[0][1] for T in current)
        T_transition=holder._begin_T_parent(anchor,parent)
'''
    checks='''        holder._refresh_runtime_parents()
        holder._finish_T_parent(anchor,parent,T_transition,{'reproduction'})
        current=[T for carrier in holder.runtime_copies for T in carrier.T_companions]
        assert len(current)==2 and all(T.stable and not T.closed for T in current)
        assert not anchor.private_observations.get('unusable'), 'enforced current T after Hcopy must remain valid'
        c._RuntimeSnapshot.__init__=snapshot_init
        e._seal_capture_recording(anchor,parent,None,copied_inventory,holder)
        assert all(T.closed for T in current) and not holder.runtime_copies
        assert anchor.private_observations.get('recording_sealed') is not True
        print(json.dumps({'actual_enforced_prepare_cleanup_inspect_Hcopy_T_chain':True,'original_T_snapshots':len(snapshots),
            'actual_cleanup_removed_old_native_directory':True,'old_T_before_binding_preserved':True,
            'work':anchor.recording_work,'native_execute_is_synthetic_T_construction':calls,
            'qualification':'NOT_ACCEPTED / original T outcome M Q host parent debt'}))
'''
    namespace={'make_T':_synthetic_T_live_files};argv=sys.argv;sys.argv=['enforced-T-chain',str(root)]
    try:exec(compile(head+setup+edge+tail+checks+footer,'<actual-enforced-T-chain>','exec'),namespace)
    finally:
        sys.argv=argv
        if namespace.get('snapshot_init') is not None:namespace['c']._RuntimeSnapshot.__init__=namespace['snapshot_init']
        if namespace.get('holder') is not None:namespace['holder'].close()


def raw16_T_writer_chain(root: Path) -> None:
    import textwrap
    body=(root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix=body.split('        copied_inventory.close();copied_inventory.close()\n',1)[0]
    footer=body[body.rfind('finally:\n    if copied_inventory'):]
    before="        parent=c._open_held(str(private),True,c._store_rule(uid,gid,0o700,True),'E_STORE')\n"
    prefix=prefix.replace(before,"        (private/'preparation-scratch').mkdir(mode=0o700);(private/'inspection-scratch').mkdir(mode=0o700)\n"+before)
    edge="        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)\n"
    head,tail=prefix.split(edge,1)
    setup='''        import textwrap
        holder=e.StableDirectory(parent)
        input_raw,response_raw=b'synthetic writer input',b'synthetic writer response'
        caller=c.canonical({'kind':'shadow_write_request','id':'t.writer.chain'})
        renewed=[];snapshot_calls=[];native_calls=[]
        source_continue=c._HeldPreparationSources.continue_parent_chain
        snapshot_init=c._RuntimeSnapshot.__init__
        def continuation(self,*args,**kwargs):
            read,pread=os.read,os.pread
            def no_bytepass(*_args,**_kwargs):raise AssertionError('metadata continuation added a content read')
            try:
                os.read=os.pread=no_bytepass
                result=source_continue(self,*args,**kwargs)
            finally:os.read,os.pread=read,pread
            renewed.append((self,result))
            return result
        def snapshot(self,*args,**kwargs):
            snapshot_calls.append(args[0].path);return snapshot_init(self,*args,**kwargs)
        def execute(role,argv,component,**options):
            operation=argv[5]
            assert role=='candidate-'+('preparation' if operation=='prepare' else 'inspection')
            assert argv[:5]==[sys.executable,'-I','-S','-B',str(root/'preparation/v1/prepare-candidate.py')]
            assert options=={'timeout':300}
            scratch=Path(argv[argv.index('--scratch')+1])
            assert scratch==private/('preparation-scratch' if operation=='prepare' else 'inspection-scratch')
            make_T(c,scratch,operation,input_raw,response_raw);native_calls.append(operation)
        ws=types.SimpleNamespace(execute=execute,work_hold=holder,anchor=anchor,request=types.SimpleNamespace(raw=caller))
        writer=(root/'shadow/v1/write-shadow.py').read_text()
        begin=writer.index('    for operation, scratch in (("prepare", "preparation-scratch"),')
        end=writer.index('    prep_raw = ws.hold(',begin)
        segment=textwrap.dedent(writer[begin:end])
        c._HeldPreparationSources.continue_parent_chain,c._RuntimeSnapshot.__init__=continuation,snapshot
        exec(compile(segment,'<actual-writer-T-caller>','exec'),{'ws':ws,'work':private,'sys':sys,
            'preparation':root/'preparation/v1/prepare-candidate.py','common':[],'input_raw':input_raw,'response_raw':response_raw})
        assert native_calls==['prepare','inspect'] and len(snapshot_calls)==6 and len(renewed)==1
        assert not anchor.private_observations.get('unusable'), 'writer T metadata continuation must succeed'
        old_states=[(old,old.binding['root_before'],dict(old.binding['target_states'])) for old,fresh in renewed]
        assert all(old.closed and old.close_complete and not fresh.closed and fresh.stable for old,fresh in renewed)
        T_transition=holder._begin_T_parent(anchor,parent)
'''
    checks='''        holder._refresh_runtime_parents()
        holder._finish_T_parent(anchor,parent,T_transition,{'reproduction'})
        assert len(renewed)==3 and len(snapshot_calls)==6
        current=[source for carrier in holder.runtime_copies for source in carrier.T_companions]
        assert len(current)==2 and all(not source.closed and source.stable for source in current)
        assert {source.binding['operation'] for source in current}=={'prepare','inspect'}
        assert not anchor.private_observations.get('unusable'), 'writer T after H copy must remain current'
        for old,before,targets in old_states:
            assert old.binding['root_before']==before and old.binding['target_states']==targets
        c._HeldPreparationSources.continue_parent_chain,c._RuntimeSnapshot.__init__=source_continue,snapshot_init
        e._seal_capture_recording(anchor,parent,None,copied_inventory,holder)
        assert all(source.closed for source in current) and not holder.runtime_copies
        assert anchor.private_observations.get('recording_sealed') is not True
        print(json.dumps({'actual_writer_prepare_inspect_Hcopy_T_chain':True,'metadata_renewals':len(renewed),
            'original_T_runtime_snapshots':len(snapshot_calls),'no_python_content_reads_during_metadata_renewal':True,
            'work':anchor.recording_work,'native_calls_are_synthetic_T_construction':native_calls,
            'qualification':'NOT_ACCEPTED / original T outcome and M/Q/host/parent debt remain'}))
'''
    namespace={'make_T':_synthetic_T_live_files};argv=sys.argv;sys.argv=['writer-T-chain',str(root)]
    try:exec(compile(head+setup+edge+tail+checks+footer,'<actual-writer-T-chain>','exec'),namespace)
    finally:
        sys.argv=argv
        if namespace.get('c') is not None and namespace.get('source_continue') is not None:
            namespace['c']._HeldPreparationSources.continue_parent_chain=namespace['source_continue']
            namespace['c']._RuntimeSnapshot.__init__=namespace['snapshot_init']
        if namespace.get('holder') is not None:namespace['holder'].close()


def _synthetic_T_live_files(c, scratch, operation, input_raw, response_raw):
    rows=[];files={}
    for ordinal,role in enumerate(('python','git','jq')):
        name='raw16-t-v1-'+operation+'-runtime-'+role+'-'+str(ordinal).zfill(2)+'.bin'
        raw=(b'never executed synthetic T '+role.encode())*103
        path=scratch/name;path.write_bytes(raw);path.chmod(0o400);files[name]=raw
        rows.append({'slot':role,'index':0,'ordinal':ordinal,'locator':str(path),'file':name,
            'size_bytes':len(raw),'sha256':c.digest(raw),'errno':None})
    value={'operation':operation,'binding':{'input_sha256':c.digest(input_raw),'response_sha256':c.digest(response_raw)},
        'entropy':[],'clocks':[],'storage':[],'commands':[],'runtime':{'files':rows},'complete':True}
    raw=c.canonical(value);name='raw16-t-v1-'+operation+'-capture.json'
    path=scratch/name;path.write_bytes(raw);path.chmod(0o400);files[name]=raw
    marker='raw16-t-v1-'+operation+'-complete-'+c.digest(raw);(scratch/marker).mkdir(mode=0o700)
    return value,files,marker


def raw16_T_transition_refusals(root: Path) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('T_transition_refusals',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    results=[]
    try:
        for case in ('namespace-extra','target-drift'):
            with tempfile.TemporaryDirectory(prefix='ystack-T-transition-refusal-') as temporary:
                base=Path(temporary).resolve();base.chmod(0o700);work=base/'work';work.mkdir(mode=0o700)
                scratch=work/'preparation-scratch';scratch.mkdir(mode=0o700)
                input_raw,response_raw=b'synthetic input',b'synthetic response'
                value,files,marker=_synthetic_T_live_files(c,scratch,'prepare',input_raw,response_raw)
                holder=e.stable_directory(work);anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
                init=c._HeldPreparationSources.__init__;constructed=[]
                def initialize(self,*args,**kwargs):init(self,*args,**kwargs);constructed.append(self)
                c._HeldPreparationSources.__init__=initialize
                try:
                    copied=holder._retain_preparation(anchor,'preparation-scratch','prepare',input_raw,response_raw,
                        c.canonical({'kind':'shadow_write_request','id':'t.refusal.fixture'}))
                    assert copied is not None and not anchor.private_observations.get('unusable')
                    old=constructed[0];before=old.binding['root_before'];states=dict(old.binding['target_states'])
                    parent=holder._recording_parent();transition=holder._begin_T_parent(anchor,parent)
                    parent_before=parent.before
                    os.mkdir('reproduction',0o700,dir_fd=parent.fd)
                    if case=='namespace-extra':os.mkdir('preparation-runtime-inspect',0o700,dir_fd=parent.fd)
                    c._refresh_recording_directory(parent,parent_before,old.leaf)
                    validation = {"read_bytes": 0, "sha_bytes": 0, "equality_bytes": 0}
                    if case=='target-drift':
                        name='raw16-t-v1-prepare-runtime-python-00.bin'
                        target=scratch/name;target.chmod(0o600);target.chmod(0o400)
                        require_before=old.binding['target_states'][name]
                        assert c._identity(target.stat())!=c._identity(require_before)
                        assert c._identity(os.fstat(old.directory.fd))==c._identity(old.binding['root_before'])
                        current=os.pread(old.members[name].fd,len(files[name]),0)
                        assert current==files[name] and c.digest(current)==c.digest(files[name])
                        validation={"read_bytes": len(current), "sha_bytes": 2*len(current), "equality_bytes": 2*len(current)}
                    caught=None
                    try:holder._finish_T_parent(anchor,parent,transition,{'reproduction'})
                    except (e.Refusal,c.Refusal) as error:caught=error
                    assert caught is not None, 'T transition must reject unproved namespace or old target drift'
                    assert anchor.private_observations.get('unusable') is True
                    assert all(source.closed and not source.owned for source in constructed)
                    assert old.binding['root_before']==before and old.binding['target_states']==states
                    assert all(os.fstat(item.fd) for item in holder.held.components)
                    results.append({'case':case,'work':anchor.recording_work,'old_before_preserved':True,
                        'all_private_T_acquisitions_released':len(constructed),'extra_fixture_validation':validation,
                        'same_runtime_bytes_and_SHA':case=='target-drift','grammar_valid_extra_other_stage_name':case=='namespace-extra',
                        'source_operation':'synthetic fixed H directory creation, consumer transition owner only',
                        'qualification':'NOT_ACCEPTED'})
                finally:c._HeldPreparationSources.__init__=init;holder.close();anchor.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_T_transition_refusals':results},sort_keys=True))


def raw16_open_child_pending(root: Path) -> None:
    import ast
    import inspect
    import tempfile
    spec=importlib.util.spec_from_file_location('open_child_pending',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),callbacks)
    results=[]
    try:
        for recorded in (False,True):
            for case in ('stable','leaf-fstat','leaf-component','leaf-registered-cancel'):
                with tempfile.TemporaryDirectory(prefix='ystack-open-child-pending-') as temporary:
                    base=Path(temporary).resolve();base.chmod(0o700);target=base/'fixed-leaf';target.write_bytes(b'synthetic');target.chmod(0o400)
                    parent=c._open_held(str(base),True,c._store_rule(os.geteuid(),os.getegid(),0o700,True),'E_STORE')
                    opened,duplicate,metadata,component,closing=os.open,os.dup,c._metadata,c.HeldComponent,os.close
                    new,leaf_fds,attempts,events=[],[],[],[];primary=MemoryError('controlled child component allocation')
                    work={} if recorded else None
                    if work is not None:c._capture_work_values(work,'child-acquisition')
                    def opening(path,*args,**kwargs):
                        fd=opened(path,*args,**kwargs)
                        if path=='fixed-leaf':new.append(fd);leaf_fds.append(fd)
                        return fd
                    def duplicating(fd):
                        value=duplicate(fd);new.append(value);return value
                    def state(fd):
                        if case=='leaf-fstat' and fd in leaf_fds:raise OSError(errno.EIO,'controlled acquired leaf fstat failure')
                        return metadata(fd)
                    def constructing(*args,**kwargs):
                        if case=='leaf-component' and args[0] in leaf_fds:raise primary
                        return component(*args,**kwargs)
                    def close(fd):
                        if fd in new:attempts.append(fd)
                        return closing(fd)
                    lines,start=inspect.getsourcelines(c._open_child)
                    location=start+next(index for index,line in enumerate(lines) if line.startswith('        pending = None'))
                    previous_trace=sys.gettrace()
                    def trace(frame,event,arg):
                        if frame.f_code is not c._open_child.__code__:return None
                        if event=='line' and frame.f_lineno==location:
                            assert frame.f_locals['rows'][-1].fd==frame.f_locals['pending']==leaf_fds[0]
                            sys.settrace(previous_trace)
                            try:callbacks['cancel'](15,None)
                            except InterruptedError as error:events.append(error);raise
                        return trace
                    held=caught=None
                    try:
                        os.open,os.dup,c._metadata,c.HeldComponent,os.close=opening,duplicating,state,constructing,close
                        if case=='leaf-registered-cancel':sys.settrace(trace)
                        try:held=c._open_child(parent,'fixed-leaf',False,c._store_rule(os.geteuid(),os.getegid(),0o400,False),'E_STORE',recording_work=work,accounting_kind='M' if recorded else None)
                        except BaseException as error:caught=error
                        if case=='stable':assert caught is None;held.close()
                        elif case=='leaf-fstat':assert isinstance(caught,c.Refusal) and caught.os_errno==errno.EIO
                        elif case=='leaf-component':assert caught is primary
                        else:assert len(events)==1 and caught is events[0]
                        assert len(leaf_fds)==1 and set(attempts)==set(new) and len(attempts)==len(new), 'all open_child acquisitions must close once'
                        assert all(os.fstat(item.fd) for item in parent.components)
                        for fd in new:
                            try:os.fstat(fd)
                            except OSError as error:assert error.errno==errno.EBADF
                            else:raise AssertionError('open_child left an acquired FD live')
                        results.append({'recorded':recorded,'case':case,'actual_acquired_FDs_closed_once':len(attempts),
                            'work':work,'no_recording_owner_cost':'UNKNOWN' if not recorded else None})
                    finally:
                        sys.settrace(previous_trace)
                        os.open,os.dup,c._metadata,c.HeldComponent,os.close=opened,duplicate,metadata,component,closing;parent.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_open_child_pending_acquisition':results},sort_keys=True))


def raw16_adopt_registered_cancel(root: Path) -> None:
    import ast
    import tempfile
    spec=importlib.util.spec_from_file_location('adopt_registered',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),callbacks)
    results=[]
    try:
        for kind in ('P','T'):
            with tempfile.TemporaryDirectory(prefix='ystack-adopt-registered-') as temporary:
                base=Path(temporary).resolve();base.chmod(0o700);work=base/'work';work.mkdir(mode=0o700)
                context,metadata=_synthetic_parent_P_context(c,base/'frame')
                scratch=work/'preparation-scratch';scratch.mkdir(mode=0o700)
                input_raw,response_raw=b'synthetic input',b'synthetic response'
                _synthetic_T_live_files(c,scratch,'prepare',input_raw,response_raw)
                holder=e.stable_directory(work);anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
                request=c.canonical({'kind':'shadow_write_request','id':'adopt.registered.fixture'})
                init,T_init,closing=c._HeldCaptureCopy.__init__,c._HeldPreparationSources.__init__,os.close
                events,owners,close_methods,attempts=[],[],[],[];watched=set()
                def cancel():
                    try:callbacks['cancel'](15,None)
                    except InterruptedError as error:events.append(error);return error
                class AppendThenCancel(list):
                    def append(self,held):
                        super().append(held)
                        watched.update(component.fd for component in held.components)
                        actual=held.close
                        def close():
                            close_methods.append(held)
                            return actual()
                        held.close=close
                        raise cancel()
                def construct(self,*args,**kwargs):
                    init(self,*args,**kwargs)
                    if kind=='P':self.owned=AppendThenCancel();owners.append(self)
                def construct_T(self,*args,**kwargs):
                    T_init(self,*args,**kwargs)
                    if kind=='T':self.owned=AppendThenCancel();owners.append(self)
                def close(fd):
                    if fd in watched:attempts.append(fd)
                    result=closing(fd)
                    if fd in watched and len(events)==1:raise cancel()
                    return result
                caught=None
                try:
                    c._HeldCaptureCopy.__init__,c._HeldPreparationSources.__init__,os.close=construct,construct_T,close
                    try:
                        if kind=='P':holder._retain_parent_inputs(anchor,context,request)
                        else:holder._retain_preparation(anchor,'preparation-scratch','prepare',input_raw,response_raw,request)
                    except InterruptedError as error:caught=error
                    assert len(owners)==1 and owners[0].closed and not owners[0].owned
                    assert len(events)==2 and events[0] is not events[1] and caught is events[0]
                    assert len(close_methods)==1, 'registered owner must be released by its sole owner once'
                    assert watched and len(attempts)==len(watched) and set(attempts)==watched
                    assert not holder.runtime_copies and all(os.fstat(item.fd) for item in holder.held.components)
                    results.append({'kind':kind,'append_completed_before_handler':True,'first_cancel_same_object':True,
                        'HeldPath_close_calls':len(close_methods),'actual_FD_close_attempts':len(attempts),
                        'work':anchor.recording_work,'producer_and_qualification':'UNKNOWN / not executed'})
                finally:
                    c._HeldCaptureCopy.__init__,c._HeldPreparationSources.__init__,os.close=init,T_init,closing
                    holder.close();anchor.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_adopt_registered_cancel':results},sort_keys=True))


def raw16_clone_pending_allocation(root: Path) -> None:
    import ast
    import tempfile
    spec=importlib.util.spec_from_file_location('clone_pending',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),callbacks)
    results=[]
    try:
        for recorded in (False,True):
            for case in ('stable','component-allocation','secondary-ordinary','first-cancel','close-first-cancel','append-success-cancel'):
                with tempfile.TemporaryDirectory(prefix='ystack-clone-pending-') as temporary:
                    base=Path(temporary).resolve();base.chmod(0o700)
                    parent=c._open_held(str(base),True,c._store_rule(os.geteuid(),os.getegid(),0o700,True),'E_STORE')
                    dup,component,closing=os.dup,c.HeldComponent,os.close
                    duplicates,closed,events,attempts=[],[],[],[];primary=MemoryError('controlled component construction after successful dup')
                    leaf={} if recorded else None
                    if leaf is not None:c._capture_work_values(leaf,'pending-clone')
                    def cancellation():
                        try:callbacks['cancel'](15,None)
                        except InterruptedError as error:events.append(error);return error
                    def duplicate(fd):
                        result=dup(fd);duplicates.append(result);return result
                    def construct(*args,**kwargs):
                        if case!='stable' and len(duplicates)==2:
                            if case=='first-cancel':raise cancellation()
                            raise primary
                        return component(*args,**kwargs)
                    def close(fd):
                        if fd in duplicates:attempts.append(fd)
                        result=closing(fd)
                        if fd in duplicates:
                            closed.append(fd)
                            if len(duplicates)==2 and fd==duplicates[-1]:
                                if case=='secondary-ordinary':raise OSError(errno.EIO,'controlled pending FD close error')
                                if case in ('first-cancel','close-first-cancel'):raise cancellation()
                        return result
                    caught=None;rows=None
                    import inspect
                    lines,start=inspect.getsourcelines(c._clone)
                    append_done=start+next(index for index,line in enumerate(lines) if line.strip()=='pending = None')
                    previous_trace=sys.gettrace()
                    def trace(frame,event,arg):
                        if frame.f_code is not c._clone.__code__:return None
                        if event=='line' and frame.f_lineno==append_done:
                            assert frame.f_locals['rows'][-1].fd==frame.f_locals['pending'] and duplicates[-1]==frame.f_locals['pending']
                            sys.settrace(previous_trace)
                            raise cancellation()
                        return trace
                    try:
                        os.dup,c.HeldComponent,os.close=duplicate,construct,close
                        if case=='append-success-cancel':sys.settrace(trace)
                        try:rows=c._clone(parent,'E_STORE',leaf,'M' if recorded else None)
                        except BaseException as error:caught=error
                        if case=='stable':
                            assert caught is None and len(rows)==len(parent.components)
                            c._close_components(rows)
                        elif case=='first-cancel':assert len(events)==2 and events[0] is not events[1] and caught is events[0]
                        elif case in ('close-first-cancel','append-success-cancel'):assert len(events)==1 and caught is events[0]
                        else:assert caught is primary
                        assert len(closed)==len(duplicates) and set(closed)==set(duplicates), 'pending dup must close before row registration completes'
                        assert len(attempts)==len(duplicates) and set(attempts)==set(duplicates), 'registered pending FD must have one close attempt'
                        for fd in duplicates:
                            try:os.fstat(fd)
                            except OSError as error:assert error.errno==errno.EBADF
                            else:raise AssertionError('pending clone FD leaked')
                        assert all(os.fstat(item.fd) for item in parent.components)
                        results.append({'recorded':recorded,'case':case,'new_FDs_closed_once':len(closed),
                            'parent_still_live':True,'work':leaf,'no_recording_owner_cost':'UNKNOWN' if not recorded else None,
                            'allocation_control':('actual append success before pending clear; real handler at line event' if case=='append-success-cancel' else 'actual HeldComponent construction failure after second successful dup; list allocation not separately injected')})
                    finally:
                        sys.settrace(previous_trace)
                        os.dup,c.HeldComponent,os.close=dup,component,closing;parent.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_pending_clone_allocation':results},sort_keys=True))


def raw16_T_live_stable(root: Path) -> None:
    import ast
    import tempfile
    spec=importlib.util.spec_from_file_location('T_live_stable',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),callbacks)
    results=[]
    try:
        for case in ('stable','runtime-target-drift','capture-target-drift','root-mode','clone-failure','allocation-failure','registration-failure','transfer-failure','close-cancel'):
            with tempfile.TemporaryDirectory(prefix='ystack-T-live-') as temporary:
                base=Path(temporary).resolve();base.chmod(0o700);work=base/'work';work.mkdir(mode=0o700)
                scratch=work/'preparation-scratch';scratch.mkdir(mode=0o700)
                input_raw,response_raw=b'synthetic T input',b'synthetic T response'
                value,files,marker=_synthetic_T_live_files(c,scratch,'prepare',input_raw,response_raw)
                holder=e.stable_directory(work);anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
                request=c.canonical({'kind':'shadow_write_request','id':'t.live.fixture'})
                dup,init,source_init,transfer,close_paths,closing=os.dup,c.HeldPath.__init__,c._HeldPreparationSources.__init__,c._capture_transfer_work,c._close_paths,os.close
                originals,closed,fired,events,sources,T_duplicates=[],[],[],[],[],[];watched=set()
                class Reject(list):
                    def append(self,*args):raise MemoryError('controlled T source ownership registration')
                def construct(self,*args,**kwargs):
                    source_init(self,*args,**kwargs);sources.append(self)
                    if case=='registration-failure':self.owned=Reject()
                def duplicate(fd):
                    if case=='clone-failure' and sources and not fired:
                        fired.append(case);raise OSError(errno.EMFILE,'controlled T fullchain duplicate')
                    value=dup(fd)
                    if sources and not anchor.recording_work.get('P_hold_leaves'):T_duplicates.append(value)
                    return value
                def initialize(self,*args,**kwargs):
                    if case=='allocation-failure' and sources and kwargs.get('recording_work') is sources[0].leaf and not fired:
                        fired.append(case);raise MemoryError('controlled T HeldPath construction')
                    return init(self,*args,**kwargs)
                def transferring(leaf,*args,**kwargs):
                    if case=='transfer-failure' and sources and leaf is sources[0].leaf and not fired:
                        fired.append(case);raise MemoryError('controlled T transfer')
                    return transfer(leaf,*args,**kwargs)
                def original_close(items):
                    originals.extend(component.fd for held in items for component in held.components)
                    return close_paths(items)
                def closing_T(fd):
                    result=closing(fd)
                    if fd in watched or fd in T_duplicates:
                        closed.append(fd)
                        if case=='close-cancel' and not events:
                            try:callbacks['cancel'](15,None)
                            except InterruptedError as error:events.append(error);raise
                    return result
                try:
                    os.dup,c.HeldPath.__init__,c._HeldPreparationSources.__init__,c._capture_transfer_work,c._close_paths,os.close=duplicate,initialize,construct,transferring,original_close,closing_T
                    copied=holder._retain_preparation(anchor,'preparation-scratch','prepare',input_raw,response_raw,request)
                    os.dup,c.HeldPath.__init__,c._HeldPreparationSources.__init__,c._capture_transfer_work,c._close_paths=dup,init,source_init,transfer,close_paths
                    assert len(sources)==1
                    T=sources[0]
                    if case.endswith('failure'):
                        assert copied is None and T.closed and not T.owned and not holder.runtime_copies
                        assert anchor.private_observations.get('unusable') is True
                        assert len(closed)==len(T_duplicates) and set(closed)==set(T_duplicates), 'failed T acquisition must close each duplicate once'
                        for fd in T_duplicates:
                            try:os.fstat(fd)
                            except OSError as error:assert error.errno==errno.EBADF
                            else:raise AssertionError('failed T acquisition leaked an FD')
                        results.append({'case':case,'T_leaf':T.leaf,'work':anchor.recording_work,'failed_T_new_FDs_closed_once':len(closed)});continue
                    assert copied is holder.runtime_copies[0] and copied.T_companions==[T]
                    assert T.stable and not T.closed and set(T.members)==set(files)|{marker}
                    assert T.binding['capture_raw']==files['raw16-t-v1-prepare-capture.json']
                    watched={component.fd for item in T.owned for component in item.components}
                    assert watched.isdisjoint(originals)
                    for fd in originals:
                        try:os.fstat(fd)
                        except OSError as error:assert error.errno==errno.EBADF
                        else:raise AssertionError('original T close point moved')
                    assert all(os.fstat(fd) for fd in watched)
                    if case in ('runtime-target-drift','capture-target-drift'):
                        name=('raw16-t-v1-prepare-runtime-python-00.bin' if case.startswith('runtime') else 'raw16-t-v1-prepare-capture.json')
                        target=scratch/name;target.chmod(0o600)
                        with target.open('r+b') as stream:stream.write(b'!')
                        target.chmod(0o400)
                    if case=='root-mode':scratch.chmod(0o750)
                    copied.recheck()
                    assert bool(anchor.private_observations.get('unusable'))==(case in ('runtime-target-drift','capture-target-drift','root-mode'))
                    os.close=closing_T;caught=None
                    try:holder.close_runtime_copies()
                    except InterruptedError as error:caught=error
                    assert T.closed and not T.owned and copied.closed
                    T.close();assert len(closed)==len(watched) and set(closed)==watched
                    if case=='close-cancel':assert len(events)==1 and caught is events[0]
                    else:assert caught is None
                    results.append({'case':case,'T_leaf':T.leaf,'P_leaf':copied.leaf,'work':anchor.recording_work,
                        'original_T_FDs_closed_at_original_point':len(originals),'independent_T_FDs_closed_once':len(closed),
                        'T_raw_binding':value['binding'],'producer_and_qualification':'synthetic / UNKNOWN'})
                finally:
                    os.dup,c.HeldPath.__init__,c._HeldPreparationSources.__init__,c._capture_transfer_work,c._close_paths,os.close=dup,init,source_init,transfer,close_paths,closing
                    holder.close();anchor.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_stable_T_companions':results},sort_keys=True))


def raw16_P_handoff_accounting(root: Path) -> None:
    import ast
    import tempfile
    spec=importlib.util.spec_from_file_location('P_handoff_accounting',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),callbacks)
    output=[]
    try:
        for case in ('stable','P-transfer-error','P-transfer-cancel','P-receipt-error','P-receipt-cancel','nested-stable'):
            with tempfile.TemporaryDirectory(prefix='ystack-P-handoff-accounting-') as temporary:
                base=Path(temporary).resolve();base.chmod(0o700);work=base/'work';work.mkdir(mode=0o700)
                context,values=_synthetic_parent_P_context(c,base/'synthetic-frame')
                holder=e.stable_directory(work);anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
                request=c.canonical({'kind':'shadow_write_request','id':'p.accounting.fixture'})
                transfer,receipt,adopt,closing=c._capture_transfer_work,c._capture_accounting_receipt,c._HeldCaptureCopy._adopt,os.close
                owners,fired,cancellations,closed=[],[],[],[];watched=set();caught=None
                def fault():
                    fired.append(case)
                    if case.endswith('cancel'):
                        try:callbacks['cancel'](15,None)
                        except InterruptedError as error:cancellations.append(error);raise
                    raise MemoryError('controlled actual P_hold '+case)
                def adopting(self,item):
                    if self not in owners:owners.append(self)
                    watched.update(component.fd for component in item.components)
                    return adopt(self,item)
                def transferring(leaf,*args,**kwargs):
                    if case.startswith('P-transfer-') and owners and leaf is owners[0].leaf and not fired:fault()
                    return transfer(leaf,*args,**kwargs)
                def receipting(target):
                    if case.startswith('P-receipt-') and owners and target is anchor and not fired:fault()
                    return receipt(target)
                def close(fd):
                    result=closing(fd)
                    if fd in watched:closed.append(fd)
                    return result
                try:
                    c._capture_transfer_work,c._capture_accounting_receipt,c._HeldCaptureCopy._adopt,os.close=transferring,receipting,adopting,close
                    if case=='nested-stable':
                        c._capture_work_values(anchor.recording_work,'nested')
                        os.mkdir('fixed-copy',0o700,dir_fd=holder.held.fd)
                        c._refresh_recording_directory(holder.held,holder.held.before,anchor.recording_work)
                        destination=c._open_child(holder.held,'fixed-copy',True,c._store_rule(os.geteuid(),os.getegid(),0o700,True),'E_STORE')
                        try:
                            state=c._copy_preparation_document(destination.fd,b'synthetic document\n',anchor.recording_work,None)
                            c._refresh_recording_directory(destination,destination.before,anchor.recording_work)
                        finally:destination.close()
                        copied=c._HeldCaptureCopy(anchor,anchor.recording_work,c._capture_work_values(anchor.recording_work,'nested'))
                        copied.acquire(holder.held,'fixed-copy',{'capture.json':state},{})
                        holder._own_runtime(anchor,copied)
                    else:
                        try:copied=holder._retain_parent_inputs(anchor,context,request)
                        except InterruptedError as error:copied=None;caught=error
                    assert len(owners)==1
                    owner=owners[0]
                    if case.startswith('P-'):
                        assert fired==[case] and copied is None and owner.closed and not owner.owned and not holder.runtime_copies, 'P-hold incomplete cannot return a live owner'
                        assert owner.leaf.get('transfer_incomplete') is True
                        assert anchor.private_observations.get('unusable') is True
                        if case.endswith('cancel'):assert len(cancellations)==1 and caught is cancellations[0]
                        else:assert caught is None
                    else:
                        assert copied is owner and not owner.closed and not c._capture_work_incomplete(owner.leaf)
                        holder.close_runtime_copies()
                    owner.close();owner.close()
                    assert watched and len(closed)==len(watched) and set(closed)==watched
                    for fd in watched:
                        try:os.fstat(fd)
                        except OSError as error:assert error.errno==errno.EBADF
                        else:raise AssertionError('P accounting handoff leaked an FD')
                    output.append({'case':case,'all_new_P_FDs_closed_once':len(closed),'P_leaf':owner.leaf,
                        'P_work':anchor.recording_work,'native_frame_unchanged':dict(context)==dict(c._parent_context_values(context.context_raw,context.frame_raw,context.runtime_records)),
                        'parent_semantics_and_full_qualification':'UNKNOWN / NOT_ACCEPTED'})
                finally:
                    c._capture_transfer_work,c._capture_accounting_receipt,c._HeldCaptureCopy._adopt,os.close=transfer,receipt,adopt,closing
                    holder.close();anchor.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_P_hold_accounting_handoff':output},sort_keys=True))


def raw16_parent_P_handoff(root: Path) -> None:
    import ast
    import tempfile
    spec=importlib.util.spec_from_file_location('parent_P_handoff',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    acl=c._acl_state;c._acl_state=lambda *_:([],None) if sys.platform=='darwin' else (None,None)
    syntax=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
    main=next(node for node in syntax.body if isinstance(node,ast.FunctionDef) and node.name=='main')
    handler=next(node for node in main.body if isinstance(node,ast.FunctionDef) and node.name=='cancel')
    callbacks={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-cancel>','exec'),callbacks)
    results=[]
    try:
        for case in ('stable','runtime-append','target-drift','parent-mode','parent-inode','transfer-failure','transfer-cancel','close-observer'):
            with tempfile.TemporaryDirectory(prefix='ystack-parent-P-holds-') as temporary:
                base=Path(temporary).resolve();base.chmod(0o700);work=base/'work';work.mkdir(mode=0o700)
                source=base/'synthetic-runtime';raw=b'never executed runtime';source.write_bytes(raw);source.chmod(0o400)
                context,values=_synthetic_parent_P_context(c,base/'synthetic-frame')
                holder=e.stable_directory(work);anchor=c.Anchor({},b'',[],{},('',[]),('',[]),None)
                request=c.canonical({'kind':'shadow_write_request','id':'parent.held.fixture'})
                transfer,acquire,observe=c._capture_transfer_work,c._HeldCaptureCopy.acquire,c._capture_observe
                acquired,fired,cancellations=[],[],[]
                def acquiring(self,*args,**kwargs):
                    value=acquire(self,*args,**kwargs);acquired.append(self);return value
                def transferring(leaf,*args,**kwargs):
                    if case.startswith('transfer-') and anchor.recording_work.get('parent_input_leaves') and leaf is anchor.recording_work['parent_input_leaves'][-1] and not fired:
                        fired.append(case)
                        if case=='transfer-cancel':
                            try:callbacks['cancel'](15,None)
                            except InterruptedError as error:cancellations.append(error);raise
                        raise MemoryError('controlled parent original final transfer')
                    return transfer(leaf,*args,**kwargs)
                def observing(leaf,kind,site,value,*args,**kwargs):
                    if case=='close-observer' and site=='held-close' and not fired:
                        fired.append(site);raise MemoryError('controlled metadata P close observer')
                    return observe(leaf,kind,site,value,*args,**kwargs)
                runtime_source=None;caught=None
                try:
                    c._capture_transfer_work,c._HeldCaptureCopy.acquire=transferring,acquiring
                    try:copied=holder._retain_parent_inputs(anchor,context,request)
                    except InterruptedError as error:copied=None;caught=error
                    finally:c._capture_transfer_work,c._HeldCaptureCopy.acquire=transfer,acquire
                    assert len(acquired)==1
                    owner=acquired[0]
                    if case.startswith('transfer-'):
                        assert copied is None and owner.closed and not owner.owned and not holder.runtime_copies, 'parent-P failed tail must close owner'
                        if case=='transfer-cancel':assert len(cancellations)==1 and caught is cancellations[0]
                        results.append({'case':case,'P_work':anchor.recording_work});continue
                    assert copied is owner is holder.runtime_copies[0] and not copied.closed
                    assert copied.runtime_sha256=={} and set(copied.members)==set(values)
                    assert not anchor.recording_work['parent_input_leaves'][0].get('runtime')
                    assert anchor.private_observations['parent_inputs']['parent_producer_and_record_semantics']=='UNKNOWN'
                    extra=0
                    for name,item in copied.members.items():
                        assert os.pread(item.fd,len(values[name]),0)==values[name];extra+=len(values[name])
                    if case=='runtime-append':
                        runtime_source=c._open_held(str(source),False,c._store_rule(os.geteuid(),os.getegid(),0o400,False),'E_STORE')
                        holder._retain_runtime(anchor,'python',runtime_source,raw,request)
                        anchor.seal_local_runtime(holder._recording_parent());runtime_source.close()
                    if case=='target-drift':
                        target=work/'helper-build-record.json';target.chmod(0o600)
                        with target.open('r+b') as stream:stream.write(b'!')
                        target.chmod(0o400)
                    if case=='parent-mode':work.chmod(0o750)
                    if case=='parent-inode':work.rename(base/'original-work');work.mkdir(mode=0o700)
                    c._capture_observe=observing
                    holder.close_runtime_copies();holder.close_runtime_copies()
                    assert copied.closed and not holder.runtime_copies
                    assert bool(anchor.private_observations.get('unusable'))==(case in ('target-drift','parent-mode','parent-inode','close-observer'))
                    results.append({'case':case,'P_work':anchor.recording_work,'P_leaf':copied.leaf,
                        'extra_fixture_P_read_bytes':extra,'real_parent_or_record_semantics':'UNKNOWN'})
                finally:
                    c._capture_transfer_work,c._HeldCaptureCopy.acquire,c._capture_observe=transfer,acquire,observe
                    holder.close();anchor.close()
                    if runtime_source is not None:runtime_source.close()
    finally:c._acl_state=acl
    print(json.dumps({'actual_parent_metadata_P_handoff':results},sort_keys=True))


def raw16_parent_P_Hcopy(root: Path) -> None:
    body=(root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix=body.split('        copied_inventory.close();copied_inventory.close()\n',1)[0]
    footer=body[body.rfind('finally:\n    if copied_inventory'):]
    line="        source=base/'kernel';source_raw=b'ordinary immutable runtime bytes'*4097;source.write_bytes(source_raw);source.chmod(0o400)\n"
    assert prefix.count(line)==1;prefix=prefix.replace(line,line+"        context,metadata=make_context(c,base/'synthetic-parent-frame')\n")
    edge="        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)\n"
    setup="""        holder=e.StableDirectory(parent)
        result=holder._retain_parent_inputs(anchor,context,c.canonical({'kind':'shadow_write_request','id':'parent.hcopy.fixture'}))
        assert result is holder.runtime_copies[0] and result.runtime_sha256=={}
"""
    prefix=prefix.replace(edge,setup+edge+'        holder._refresh_runtime_parents()\n')
    checks="""        result.recheck()
        assert not anchor.private_observations.get('unusable'), 'parent-P after Hcopy must stay valid'
        e._seal_capture_recording(anchor,parent,None,copied_inventory,holder)
        assert result.closed and not holder.runtime_copies
        assert anchor.private_observations.get('recording_sealed') is not True
        print(json.dumps({'actual_parent_P_Hcopy_seal':True,'P_work':anchor.recording_work,
            'runtime_metadata_not_conflated':result.runtime_sha256=={},'real_parent_semantics':'UNKNOWN'}))
"""
    namespace={'make_context':_synthetic_parent_P_context};argv=sys.argv;sys.argv=['parent-P-Hcopy',str(root)]
    try:exec(compile(prefix+checks+footer,'<actual-parent-P-Hcopy>','exec'),namespace)
    finally:
        sys.argv=argv
        if namespace.get('holder') is not None:namespace['holder'].close()


def raw16_parent_carrier(root: Path) -> None:
    import struct
    import tempfile
    spec = importlib.util.spec_from_file_location('raw16_parent_P_owner', root/'shadow/v1/enforced-reproduction.py')
    e = importlib.util.module_from_spec(spec);sys.modules[spec.name] = e;spec.loader.exec_module(e)
    c = e.c
    acl = c._acl_state
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    output = []
    try:
        for case in ('complete', 'record-at-limit', 'legacy', 'frame-drift', 'occupied-P'):
            helper = c.canonical('h' * (c.DOCUMENT_LIMIT-3)) if case == 'record-at-limit' else c.canonical(['fixture helper record'])
            dependency = c.canonical('d' * (c.DOCUMENT_LIMIT-3)) if case == 'record-at-limit' else c.canonical({'opaque fixture': True})
            native = {key: 'a'*64 for key in ('source_sha256', 'build_script_sha256', 'build_record_sha256',
                'binary_sha256', 'python_sha256', 'dependency_record_sha256')}
            native.update(binary_path='/fixture/native', binary_size=1, python_path='/fixture/python',
                python_abi='fixture-abi', loader_mode='rtld-now-local.v1', dependency_record_sha256=c.digest(dependency))
            body = {'helper_source_sha256': c.HELPER_SOURCE_SHA256, 'helper_build_record_sha256': c.digest(helper),
                'helper_executable_sha256': 'b'*64, 'helper_executable_size': 1, 'helper_path': '/fixture/helper',
                'native_release': native}
            context_raw = c.canonical({'schema_version': 2, 'kind': 'shadow_consumer_parent_context',
                                      'id': 'shadow.parent', 'body': body})
            frame = c.PARENT_FRAME_MAGIC + struct.pack('!III', len(context_raw), len(helper), len(dependency)) + context_raw+helper+dependency
            with tempfile.TemporaryDirectory(prefix='ystack-parent-P-') as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                path, work = base/'synthetic-inherited-file', base/'work'
                path.write_bytes(context_raw if case == 'legacy' else frame);path.chmod(0o400)
                work.mkdir(mode=0o700)
                context = c.capture_parent_context(os.open(path, os.O_RDONLY))
                assert dict(context) == body
                if case == 'frame-drift':context.frame_raw = frame[:-1]+b'!'
                holder = e.stable_directory(work)
                anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
                request = c.canonical({'kind': 'shadow_write_request', 'id': 'parent.fixture'})
                if case == 'occupied-P':(work/'parent-frame.bin').write_bytes(b'preserved partial')
                try:
                    holder._retain_parent_inputs(anchor, context, request)
                    assert dict(context) == body
                    if case in ('complete', 'record-at-limit'):
                        assert not anchor.private_observations.get('unusable', False)
                        assert (work/'parent-frame.bin').read_bytes() == frame
                        assert (work/'helper-build-record.json').read_bytes() == helper
                        assert (work/'native-dependency-record.json').read_bytes() == dependency
                        assert all((work/name).stat().st_mode & 0o777 == 0o400 for name in
                            ('parent-frame.bin', 'helper-build-record.json', 'native-dependency-record.json'))
                        assert anchor.private_observations['parent_inputs']['parent_producer_and_record_semantics'] == 'UNKNOWN'
                    else:
                        assert anchor.private_observations.get('unusable') is True
                    output.append({'case': case, 'frame_bytes': len(frame), 'record_bytes': [len(helper), len(dependency)],
                        'P_work': anchor.recording_work, 'actual_parent_and_record_semantics': 'UNKNOWN',
                        'validation_extra_read_bytes': len(frame)+len(helper)+len(dependency) if case in ('complete','record-at-limit') else 0})
                finally:holder.close()
    finally:c._acl_state = acl
    print(json.dumps({'actual_v3_fd_receiver_to_private_P': output, 'real_parent_producer': False}, sort_keys=True))

def raw16_sudo_companion(root: Path) -> None:
    import tempfile
    spec = importlib.util.spec_from_file_location('raw16_sudo_P_fixture', root/'shadow/v1/enforced-reproduction.py')
    e = importlib.util.module_from_spec(spec);sys.modules[spec.name] = e;spec.loader.exec_module(e)
    c = e.c
    opened, read, pread, acl, observe = c._open_held, os.read, os.pread, c._acl_state, c._capture_observe
    c._acl_state = lambda *_: ([], None) if sys.platform == 'darwin' else (None, None)
    scope_spec = importlib.util.spec_from_file_location('raw16_sudo_cancel_source', root/'scope/v1/read-shadow-evidence.py')
    scope = importlib.util.module_from_spec(scope_spec);sys.modules[scope_spec.name] = scope;scope_spec.loader.exec_module(scope)
    cancel_code = next(value for value in scope.main.__code__.co_consts
                       if isinstance(value, types.CodeType) and value.co_name == 'cancel')
    cancel = types.FunctionType(cancel_code, {'InterruptedError': InterruptedError})
    results = []
    try:
        for case in ('stable', 'inode-mismatch', 'source-drift', 'companion-close-observer', 'read-A-close-B'):
            with tempfile.TemporaryDirectory(prefix='ystack-sudo-companion-') as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                work, source, other = base/'work', base/'synthetic-executable', base/'different-inode'
                work.mkdir(mode=0o700)
                raw = b'synthetic sudo bytes never executed' * 2037
                source.write_bytes(raw);source.chmod(0o400)
                other.write_bytes(raw);other.chmod(0o400)
                native = e.FixedSudo(os.open(source, os.O_RDONLY), source.stat())
                before_native_sha = native.sha256
                def native_fixture_recheck():
                    assert c._identity(os.fstat(native.fd)) == c._identity(native.before)
                native.recheck = native_fixture_recheck
                holder = e.stable_directory(work)
                anchor = c.Anchor({}, b'', [], {}, ('', []), ('', []), None)
                requests, fired, cancellations, companion_fds, target_closes = [], [], [], set(), []
                previous_signal, os_close = signal.getsignal(signal.SIGTERM), os.close
                def handler(number, frame):
                    try:cancel(number, frame)
                    except InterruptedError as error:
                        cancellations.append(error)
                        raise
                signal.signal(signal.SIGTERM, handler)
                def closing(fd):
                    if fd in companion_fds:
                        target_closes.append(fd)
                        os_close(fd)
                        if case == 'read-A-close-B' and len(cancellations) == 1:
                            os.kill(os.getpid(), signal.SIGTERM)
                        return None
                    return os_close(fd)
                def fixed_open(path, directory, rule, code, *args, **kwargs):
                    if path == '/usr/bin/sudo':
                        requests.append(path)
                        held = opened(str(other if case == 'inode-mismatch' else source), False,
                            c._store_rule(os.geteuid(), os.getegid(), 0o400, False), code, *args, **kwargs)
                        companion_fds.add(held.fd)
                        return held
                    return opened(path, directory, rule, code, *args, **kwargs)
                def read_only(fd, count, *args):
                    assert fd != native.fd, 'the original execution fd must not become a byte reader'
                    return read(fd, count, *args)
                def pread_only(fd, count, offset):
                    assert fd != native.fd, 'the original execution fd must not become a byte reader'
                    if case == 'read-A-close-B' and fd in companion_fds and not cancellations:
                        os.kill(os.getpid(), signal.SIGTERM)
                    return pread(fd, count, offset)
                try:
                    c._open_held, os.read, os.pread, os.close = fixed_open, read_only, pread_only, closing
                    request = c.canonical({'kind': 'shadow_write_request', 'id': 'sudo.fixture'})
                    if case == 'read-A-close-B':
                        caught = None
                        try:holder._retain_sudo(anchor, native, request)
                        except InterruptedError as error:caught = error
                        assert len(cancellations) == 2 and cancellations[0] is not cancellations[1]
                        assert caught is cancellations[0] and all(error._scope_signal_cancel for error in cancellations)
                        assert len(target_closes) == 1 and not anchor.runtime_companions
                        assert os.fstat(native.fd) and native.sha256 == before_native_sha
                        results.append({'case': case, 'first_cancel_same_object': True, 'different_real_handler_objects': True,
                            'target_close_calls': len(target_closes), 'P_work': anchor.recording_work})
                        continue
                    holder._retain_sudo(anchor, native, request)
                    assert requests == ['/usr/bin/sudo'] and native.sha256 == before_native_sha
                    if case == 'inode-mismatch':
                        assert not anchor.runtime_companions and not list(work.glob('runtime-*.bin'))
                        assert not anchor.recording_work.get('runtime', {}).get('read_bytes', 0)
                        assert anchor.private_observations.get('unusable') is True
                        assert os.fstat(native.fd) and native.sha256 == before_native_sha
                        results.append({'case': case, 'P_work': anchor.recording_work,
                            'no_runtime_body_read_before_inode_rejection': True})
                        continue
                    companion = anchor.runtime_companions[0][0]
                    if case == 'source-drift':
                        source.chmod(0o600)
                        with source.open('r+b') as stream:stream.write(b'!')
                        source.chmod(0o400)
                    if case == 'companion-close-observer':
                        real_close = companion.close
                        during = [False]
                        def companion_close():
                            during[0] = True
                            try:real_close()
                            finally:during[0] = False
                        companion.close = companion_close
                        def observer(work, kind, site, value, *args, **kwargs):
                            if during[0] and site == 'held-close' and not fired:
                                fired.append(site)
                                raise MemoryError('controlled companion close observation failure')
                            return observe(work, kind, site, value, *args, **kwargs)
                        c._capture_observe = observer
                    anchor.seal_local_runtime(holder._recording_parent())
                    assert not anchor.runtime_companions and not companion.components
                    assert bool(anchor.private_observations.get('unusable')) == (case != 'stable')
                    if case == 'stable':
                        row = anchor.private_observations['local_runtime'][0]
                        assert row['slot'] == 'sudo' and row['sha256'] == c.digest(raw) != before_native_sha
                        assert (work/row['file']).read_bytes() == raw
                    if case != 'source-drift':assert native.sha256 == before_native_sha
                    assert os.fstat(native.fd)
                    if case == 'companion-close-observer':assert fired == ['held-close']
                    results.append({'case': case, 'P_work': anchor.recording_work,
                        'native_fd_still_open': True, 'actual_fixed_companion_path': requests,
                        'native_root_uid_qualification_and_fixed_sudo_recheck_are_fixture_substitutions': True,
                        'no_actual_system_sudo_read_or_execution': True})
                finally:
                    c._open_held, os.read, os.pread, c._capture_observe, os.close = opened, read, pread, observe, os_close
                    signal.signal(signal.SIGTERM, previous_signal)
                    anchor.close();holder.close();native.close()
    finally:c._acl_state = acl
    print(json.dumps({'fixed_sudo_companion_controls': results}, sort_keys=True))

def raw16_scope_P_ownership(root: Path) -> None:
    import ast
    import tempfile
    loaded = {}
    for name, path in (("scope", "scope/v1/read-shadow-evidence.py"),
                       ("host", "sandbox/v1/host-supervisor.py"),
                       ("enforced", "shadow/v1/enforced-reproduction.py")):
        spec = importlib.util.spec_from_file_location("scope_P_" + name, root / path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        loaded[name] = module
    scope, host, enforced = (loaded[name] for name in ("scope", "host", "enforced"))
    c = scope.c
    main = next(node for node in ast.parse((root / "scope/v1/read-shadow-evidence.py").read_text()).body
                if isinstance(node, ast.FunctionDef) and node.name == "main")
    cancel = next(node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == "cancel")
    namespace = {}
    exec(compile(ast.Module(body=[cancel], type_ignores=[]), "<scope-original-handler>", "exec"), namespace)
    handler = namespace["cancel"]
    acl, results = c._acl_state, []
    c._acl_state = lambda *_: ([], None) if sys.platform == "darwin" else (None, None)
    try:
        for case in ("release", "seal", "close", "target-drift", "parent-mode",
                     "register-memory", "register-A-close-B", "register-memory-close-B", "registered-cancel"):
            with tempfile.TemporaryDirectory(prefix="ystack-reader-owned-P-") as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                captures = base / "captures";captures.mkdir(mode=0o700)
                reader = object.__new__(scope._Reader)
                reader.source_copies = [];reader.source_capture_work = [];reader.source_capture_ordinal = 0
                reader.owned = [];reader.inputs = [];reader.captures = captures;reader.darwin = None
                reader.store_session = None;reader.capture_completion_owner = None;reader.enforced = enforced
                anchor = c.Anchor({}, b"", [], {}, ("", []), ("", []), None)
                reader.anchor = anchor
                roles = (("python", "python"), ("jq", "jq"), ("bash", "bash"), ("git", "git_binary"))
                for role, _attribute in roles:
                    path = base / role;path.write_bytes(b"synthetic never executed runtime " + role.encode());path.chmod(0o400)
                for role, attribute in roles:
                    setattr(reader, attribute, reader.hold(base / role, c.EXECUTABLE_LIMIT))
                request = c.canonical({"kind": "coverage_source_request", "id": "source.p.fixture"})
                acquired, cancels, closes, active_P = [], [], {}, []
                acquire, observe, close_fd = c._HeldCaptureCopy.acquire, c._capture_observe, os.close
                def marked():
                    try:handler(15, None)
                    except InterruptedError as error:cancels.append(error);raise
                class Registration(list):
                    def append(self, value):
                        if case == "registered-cancel":
                            super().append(value)
                            marked()
                        if case == "register-A-close-B":marked()
                        if case.startswith("register-memory"):raise MemoryError("controlled Reader registration")
                        super().append(value)
                reader.source_copies = Registration()
                def acquisition(current, *args):
                    result = acquire(current, *args)
                    acquired.append(result)
                    for held in result.owned:
                        for row in held.components:closes[row.fd] = 0
                    actual_close = result.close
                    def close_P():
                        active_P.append({row.fd for held in result.owned for row in held.components})
                        try:actual_close()
                        finally:active_P.pop()
                    result.close = close_P
                    return result
                def observation(work, kind, site, value, *args, **kwargs):
                    result = observe(work, kind, site, value, *args, **kwargs)
                    if case in {"register-A-close-B", "register-memory-close-B"} and site == "held-close" and acquired and work is acquired[0].leaf and len(cancels) < (2 if case == "register-A-close-B" else 1):marked()
                    return result
                def closing(fd):
                    if active_P and fd in active_P[-1]:closes[fd] += 1
                    return close_fd(fd)
                c._HeldCaptureCopy.acquire, c._capture_observe, os.close = acquisition, observation, closing
                caught = None
                try:
                    try:reader.retain_source_runtime(request)
                    except InterruptedError as error:caught = error
                    if case.startswith("register"):
                        assert len(acquired) == 1 and acquired[0].closed and not reader.source_copies
                        assert anchor.private_observations.get("unusable") is True
                        assert closes and all(count == 1 for count in closes.values()), "registration P once close"
                        if case == "register-memory":assert caught is None
                        else:assert cancels and caught is cancels[0]
                    else:
                        assert len(reader.source_copies) == 4 and all(not item.closed for item in reader.source_copies), (case, anchor.private_observations.get("unusable"), [leaf.get("failure") for leaf in anchor.recording_work.get("local_runtime_leaves", [])], [leaf.get("metadata_failure") for leaf in anchor.recording_work.get("scope_runtime_parent_work", [])])
                        native = c._open_held(str(base), True, lambda *_: True, "E_STORE")
                        captured = host._capture_values("source.p.fixture", request, {"source_pages": {"coverage": []}}, True)
                        source = object.__new__(c._HeldCoverageRead)
                        source.anchor = anchor;source.attempt_id = "source.p.fixture";source.held = [native]
                        source.snapshots = {"payload/request.json": request};source.observation = b"{}\n"
                        source.capture_origin = b"{}\n";source.storage_rows = [];source.capture_work = {}
                        source.capture = object.__new__(c._HeldCaptureRead)
                        source.capture.snapshots = {"capture.json": captured,
                            "complete.json": host._capture_completion_values(source.attempt_id, request, captured)}
                        source.capture.work = {};c._capture_work_values(source.capture.work, "synthetic-source-H-input")
                        source.capture.transferred = 0;source.capture.anchor = anchor
                        anchor.identity_context = {}
                        anchor.capture_completion_owner = types.SimpleNamespace(transfer=lambda *_: None)
                        source.capture.completion_owner = anchor.capture_completion_owner
                        try:
                            reader.retain_source_capture(source)
                            reader.retain_source_capture(source)
                            assert len(reader.source_copies) == 6 and not anchor.private_observations.get("unusable")
                            for copied in reader.source_copies:
                                copied.recheck()
                                assert not copied.leaf.get("metadata_failure") and not copied.closed
                            assert set(reader.source_copies[4].members) == {"capture.json", "complete.json", "origin-observation.json", "consumer-observations.json"}
                            if case == "target-drift":
                                target = Path(next(iter(reader.source_copies[0].members.values())).path)
                                target.chmod(0o600);target.write_bytes(b"drift");target.chmod(0o400)
                            if case == "parent-mode":captures.chmod(0o750)
                            expected = {row.fd for copied in reader.source_copies for held in copied.owned for row in held.components}
                            os.close = closing
                            if case == "seal":
                                anchor.capture_completion_owner = None
                                reader.seal_source_captures()
                                assert anchor.private_observations.get("recording_sealed") is not True
                            elif case == "release":reader.release_stores()
                            elif case == "close":reader.close()
                            else:reader._close_source_copies()
                            assert not reader.source_copies and all(item.closed and not item.owned for item in acquired)
                            assert all(closes.get(fd) == 1 for fd in expected), ("Reader P once close", case, [(fd, closes.get(fd)) for fd in expected if closes.get(fd) != 1])
                            if case in {"target-drift", "parent-mode"}:assert anchor.private_observations.get("unusable") is True
                            assert os.fstat(native.fd)
                        finally:
                            os.close = close_fd
                            native.close()
                    results.append({"case": case, "P_acquisitions": len(acquired),
                        "all_P_closed": all(item.closed for item in acquired), "work": anchor.recording_work,
                        "completion_transport_and_qualification": "UNKNOWN fixture H input; not native production",
                        "all_runtime_inputs": "TMP synthetic; none executed"})
                finally:
                    c._HeldCaptureCopy.acquire, c._capture_observe, os.close = acquire, observe, close_fd
                    reader.close();anchor.close()
    finally:c._acl_state = acl
    print(json.dumps({"scope_actual_runtime_and_source_P_ownership": results}, sort_keys=True))


def raw16_noexport_projection_values(root: Path) -> None:
    owners = {}
    paths = {"host": "sandbox/v1/host-supervisor.py", "consumer": "shadow/v1/_consumer.py",
             "replay": "evals/v1/replay-malicious.py"}
    for name, path in paths.items():
        spec = importlib.util.spec_from_file_location("noexport_" + name, root / path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        owners[name] = module
    host, consumer, replay = (owners[name] for name in ("host", "consumer", "replay"))
    results = []
    for operation, kind, wrapper in (
        ("reproduction", "shadow_enforced_request", replay._reproduction_capture_values),
        ("write", "shadow_write_request", replay._write_capture_values),
    ):
        attempt_id = "attempt.noexport." + operation
        attempt = {"attempt_id": attempt_id, "attempt_number": 1}
        body = {"attempt": attempt, "store_id": "store.ordinary",
                "control": {"ordinary": "control"}, "subject": {"ordinary": "subject"}}
        launch = host.canonical({"schema_version": 1, "kind": "sandbox_launch_request",
                                 "id": attempt_id, "body": body})
        bound = attempt | {"launch_request_sha256": host.sha256_hex(launch)}
        outer = host.canonical({"schema_version": 1, "kind": kind, "id": attempt_id,
                                "body": {"attempt_id": attempt_id}})
        expectation = host.canonical({"schema_version": 1, "kind": "sandbox_receipt_expectation",
                                      "id": attempt_id, "body": body | {"attempt": bound}})
        receipt = host.canonical({"schema_version": 1, "kind": "sandbox_enforcement_receipt",
            "id": "receipt." + host.sha256_hex(launch), "body": {"attempt": bound,
            "control": body["control"], "subject": body["subject"],
            "origin": {"store_id": body["store_id"]}}})
        groups = {"host": {"process": [], "driver_rest": [], "signals": []},
                  "clocks": {"wall": [], "monotonic": []}}
        capture = host._capture_values(attempt_id, launch, groups, True)
        assert consumer._capture_export_reference(groups) is None
        assert consumer._capture_envelope_values(attempt_id, launch, groups) == capture
        assert consumer._launch_capture_values(capture, outer, launch, expectation, receipt, kind) == groups
        rebuilt, projected = wrapper(root, capture, groups, outer, launch, expectation, receipt)
        assert rebuilt == capture
        assert projected == groups
        results.append({"operation": operation, "rebuilt_equals_capture": True,
            "projected_equals_groups": True, "no_export_reference": True,
            "input_bytes": {"capture": len(capture), "outer": len(outer), "launch": len(launch),
                            "expectation": len(expectation), "receipt": len(receipt)},
            "capture_sha256": host.sha256_hex(capture), "rebuilt_bytes": len(rebuilt),
            "projected_canonical_bytes": len(host.canonical(projected))})
    print(json.dumps({"noexport_value_positives": results,
        "full_recording_costs_and_qualification": "NOT_PROVEN"}, sort_keys=True))


def raw16_C1_case_values(replay, host, assembly=None):
    import copy
    ids = {role: 'ordinary.' + role for role in ('reproduction', 'write', 'gate')}
    raw_requests = {role: host.canonical({'original': role}) for role in ids}
    hashes = {role: host.sha256_hex(raw) for role, raw in raw_requests.items()}
    incident = {'observed_at': '2026-10-26T00:00:00Z'}
    rows = []
    for index, role in enumerate(replay._CASE_ROLES):
        local = {'entropy': {'preparation_names': []},
            'clocks': {'wall': [], 'monotonic': [{'site': 'ordinary.' + role,
                'value': struct.pack('>d', float(index)).hex()}]},
            'storage': {'entries': [], 'identity_context': {'platform': sys.platform}},
            'commands': {'runtime_values': []}, 'runtime': {'files': []}}
        if '.' in role:
            local['storage'] = []
            launch, operation = role.split('.')
            binding = {'attempt_id': ids[launch], 'outer_request_sha256': hashes[launch],
                'input_sha256': host.sha256_hex(b'input' + role.encode()),
                'response_sha256': host.sha256_hex(b'response' + role.encode()), 'operation': operation}
            raw = {'preparation': local}
        elif role in ('reproduction', 'write'):
            binding = {'attempt_id': ids[role], 'outer_request_sha256': hashes[role],
                'request_sha256': host.sha256_hex(b'launch' + role.encode()), 'operation': 'launch'}
            capture = {'host': {'process': [{'site': 'run_driver.state', 'ordinal': 0,
                'return': index, 'errno': None, 'bytes': ('reply-' + role).encode().hex(), 'timeout': None}],
                'driver_rest': [{'call': 0, 'reply': {'status': 200, 'body_hex': role.encode().hex()},
                    'error': None, 'operation': 'state'}], 'signals': []},
                'guest': {'setup': {'page_size': {'bytes': '', 'errno': None, 'return': 4096 + index}},
                    'control': [{'tag': 'launch', 'pid': 700 + index}], 'counters': {}},
                'clocks': copy.deepcopy(local['clocks'])}
            raw = {'local': local, 'capture': capture}
        elif role == 'gate':
            binding = {'request_id': ids['gate'], 'request_sha256': hashes['gate']}
            raw = {'generator': local, 'scope_reader': copy.deepcopy(local)}
            raw['scope_reader']['clocks']['monotonic'][0]['value'] = struct.pack('>d', 99.0).hex()
        else:
            binding = {'gate_request_sha256': hashes['gate'], 'attempt_id': 'ordinary.' + role,
                'request_sha256': host.sha256_hex(role.encode()),
                'operation': 'kill-register-read' if role == 'kill' else 'coverage-read'}
            del local['entropy']
            raw = {'local': local, 'capture': {'source_pages': {role: []},
                'clocks': {'wall': [], 'monotonic': []}}}
        rows.append({'role': role, 'binding': binding, 'raw': raw})
    locators = {role: {'request': '/ordinary/' + role} for role in replay._CASE_ROLES}
    if assembly is None:
        canonical = replay._case_v2_values(incident, ids, locators, rows)
        assert replay._case_v2_validate(canonical, incident, ids, locators, rows)['body']['occurrences'] == rows
    else:
        assembly.incident=incident;assembly.identifiers=ids;assembly.locators=locators
        assembly.occurrences={row['role']:row for row in rows};assembly.coverage_required=True
        assembly.original_raw=(b'composition incident',raw_requests['reproduction'],raw_requests['write'],raw_requests['gate'])
        assembly.bindings={role:{'caller_raw':raw_requests[role]} for role in ('reproduction','write')}
        canonical=assembly.document()
        assert assembly.raw==canonical and assembly.files['raw-observations.json']['size_bytes']==len(canonical)
    assert rows[2]['raw']['capture']['guest'] != rows[5]['raw']['capture']['guest']
    assert rows[6]['raw']['generator']['clocks'] != rows[6]['raw']['scope_reader']['clocks']
    negatives = []
    for label in ('missing', 'duplicate', 'order', 'unknown', 'versioned-operation', 'cross-outer', 'cross-gate', 'null-coverage'):
        changed = copy.deepcopy(rows)
        if label == 'missing':changed.pop(1)
        elif label == 'duplicate':changed[1] = copy.deepcopy(changed[0])
        elif label == 'order':changed[0], changed[1] = changed[1], changed[0]
        elif label == 'unknown':changed[0]['raw']['extra'] = {}
        elif label == 'versioned-operation':changed[7]['binding']['operation'] = 'kill-register-read.v1'
        elif label == 'cross-outer':changed[0]['binding']['outer_request_sha256'] = hashes['write']
        elif label == 'cross-gate':changed[7]['binding']['gate_request_sha256'] = hashes['write']
        else:changed[8] = None
        try:replay._case_v2_values(incident, ids, locators, changed)
        except (ValueError, TypeError):negatives.append(label)
        else:raise AssertionError('case v2 construction admitted ' + label)
    for label in ('guest-setup', 'host-reply', 'controller-order', 'rest-call', 'clock', 'cross-role'):
        value = json.loads(canonical)
        occurrences = value['body']['occurrences']
        if label == 'guest-setup':occurrences[2]['raw']['capture']['guest']['setup']['page_size']['return'] += 1
        elif label == 'host-reply':occurrences[5]['raw']['capture']['host']['process'][0]['bytes'] = 'ff'
        elif label == 'controller-order':occurrences[2]['raw']['capture']['host']['process'][0]['ordinal'] = 1
        elif label == 'rest-call':occurrences[5]['raw']['capture']['host']['driver_rest'][0]['call'] = 1
        elif label == 'clock':occurrences[6]['raw']['scope_reader']['clocks'] = occurrences[6]['raw']['generator']['clocks']
        else:occurrences[0]['binding'] = occurrences[3]['binding']
        try:replay._case_v2_validate(host.canonical(value), incident, ids, locators, rows)
        except ValueError:negatives.append(label)
        else:raise AssertionError('case v2 projection admitted ' + label)
    return {'full_v2_value_roundtrip': True, 'separate_launches_and_four_T': True,
        'bytes': len(canonical), 'negatives': negatives,
        'primitive_shapes_and_inputs': 'composition values only, not collection/qualification or native guest proof',
        'valid_absence_branch': 'NOTRUN here; no missing-capture inference'}


def raw16_C1_copy(root: Path, selected_cases=None, mutation=None) -> None:
    body = (root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n", 1)[1].split('\nPY_RUNTIME_CONSUMER', 1)[0]
    prefix = body.split('        native.recheck();native.close();native=None\n', 1)[0]
    footer = body[body.rfind('finally:\n    if copied_inventory'):]
    prefix = prefix.replace("        store=base/'store';", "        seed=base/'pending-S';seed.mkdir(mode=0o700)\n        store=base/'store';", 1)
    prefix = prefix.replace("anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),None)",
        "anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),c._DarwinUUIDResolver() if sys.platform=='darwin' else None)")
    prefix = prefix.replace("c._store_rule(uid,gid,0o700,True),'E_STORE')", "c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')")
    cases = ('stable', 'initial-sha', 'tail', 'hash-allocation', 'write-limit', 'physical-limit',
             'partial-budget', 'register-memory', 'register-A-close-B', 'ordinary-A-close-B', 'registered-cancel',
             'S-extra', 'S-close-A-B', 'write-accounting', 'export', 'S-document', 'both-changed')
    if selected_cases is not None:cases = selected_cases
    extra = '''        import ast,inspect,struct
        replay=load('C1_actual_replay',root/'evals/v1/replay-malicious.py')
        if C1_mutation is not None:
            import textwrap
            method,old=(' _copy_file','_seed_require(installed.before.st_size == size)') if C1_mutation=='S-size' else (' _namespace_check','_seed_require(set(self.root.listdir()) == names)')
            method=method.strip();source=textwrap.dedent(inspect.getsource(getattr(replay._SeedAssembly,method)))
            assert source.count(old)==1;source=source.replace(old,'pass')
            changed={};exec(compile(source,'<C1-narrow-rule-deletion>','exec'),replay.__dict__,changed)
            setattr(replay._SeedAssembly,method,changed[method])
        c._acl_state=original_acl
        seed_parent=c._open_held(str(seed),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        assembly=replay._SeedAssembly(seed_parent,anchor,'malicious.incident-symptom-text',anchor.recording_work,copied_inventory.case_work)
        original_open,original_write,original_close=os.open,os.write,os.close
        original_hash,original_held_close,original_child=replay.hashlib.sha256,c.HeldPath.close,c._open_child
        original_runtime,original_recheck=c._runtime_account,c.HeldPath.recheck
        fds,writes,closes,cancels,writer_live=[],[],{},[],set()
        main=next(n for n in ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text()).body if isinstance(n,ast.FunctionDef) and n.name=='main')
        cancel=next(n for n in main.body if isinstance(n,ast.FunctionDef) and n.name=='cancel')
        ns={};exec(compile(ast.Module(body=[cancel],type_ignores=[]),'<original-handler>', 'exec'),ns)
        def marked():
            try:ns['cancel'](15,None)
            except InterruptedError as error:cancels.append(error);raise
        def opening(path,flags,*args,**kwargs):
            result=original_open(path,flags,*args,**kwargs)
            if path=='runtime-copy.bin' and flags & os.O_CREAT:fds.append(result);writer_live.add(result)
            return result
        def writing(fd,raw):
            result=original_write(fd,raw)
            if fd in fds:writes.append(result)
            return result
        def closing(fd):
            if fd in writer_live:
                closes[fd]=closes.get(fd,0)+1;writer_live.remove(fd)
            return original_close(fd)
        def hashing(*args,**kwargs):
            if C1_case=='hash-allocation' and inspect.currentframe().f_back.f_code is replay._SeedAssembly._copy_file.__code__:
                raise MemoryError('controlled pre-open hash allocation')
            return original_hash(*args,**kwargs)
        source_member=copied_inventory.members[name]
        def child(parent,name,*args,**kwargs):
            if C1_case=='tail' and parent is assembly.root and name=='runtime-copy.bin':
                os.chmod(name,0o600,dir_fd=parent.fd,follow_symlinks=False)
                fd=original_open(name,os.O_WRONLY|os.O_APPEND,dir_fd=parent.fd)
                try:assert original_write(fd,b'tail')==4
                finally:
                    original_close(fd)
                    os.chmod(name,0o400,dir_fd=parent.fd,follow_symlinks=False)
            if C1_case=='both-changed' and parent is assembly.root and name=='runtime-copy.bin':
                for directory,filename in ((parent.fd,name),(copied_inventory.directory.fd,source_member.components[-1].name)):
                    os.chmod(filename,0o600,dir_fd=directory,follow_symlinks=False)
                    fd=original_open(filename,os.O_WRONLY,dir_fd=directory)
                    try:assert original_write(fd,b'X')==1
                    finally:
                        original_close(fd)
                        os.chmod(filename,0o400,dir_fd=directory,follow_symlinks=False)
            return original_child(parent,name,*args,**kwargs)
        class Registration(list):
            def append(self,item):
                if C1_case=='registered-cancel':super().append(item);marked()
                if C1_case=='register-A-close-B':marked()
                if C1_case in ('register-memory','ordinary-A-close-B'):raise MemoryError('controlled S registration')
                super().append(item)
        def held_close(item):
            result=original_held_close(item)
            if item.path==str(seed/'runtime-copy.bin') and C1_case in ('register-A-close-B','ordinary-A-close-B'):marked()
            return result
        def runtime_account(work,field,amount,*,window=False,commit=True):
            if C1_case=='write-accounting' and work is assembly.work and field=='write_bytes' and commit:
                raise MemoryError('actual written accounting')
            return original_runtime(work,field,amount,window=window,commit=commit)
        c._runtime_account=runtime_account
        if C1_case.startswith('register') or C1_case=='ordinary-A-close-B':assembly.output_holds=Registration()
        if C1_case in ('write-limit','partial-budget'):
            assembly.case_work['runtime']['write_bytes']=c._RUNTIME_FIELDS['write_bytes']-(65536 if C1_case=='partial-budget' else 0)
        if C1_case=='physical-limit':assembly.case_work['runtime']['physical_bytes']=c._RUNTIME_FIELDS['physical_bytes']
        os.open,os.write,os.close,replay.hashlib.sha256,c.HeldPath.close,c._open_child=opening,writing,closing,hashing,held_close,child
        caught=None
        try:
            try:assembly._copy(anchor,copied_inventory.members[name],('exports/reproduction.bin' if C1_case=='export' else 'runtime-copy.bin'),('f'*64 if C1_case=='initial-sha' else native_digest),('export' if C1_case=='export' else 'runtime'))
            except BaseException as error:caught=error
        finally:os.open,os.write,os.close,replay.hashlib.sha256,c.HeldPath.close,c._open_child=original_open,original_write,original_close,original_hash,original_held_close,original_child
        c._runtime_account=original_runtime
        if C1_case=='export':
            assert caught is None and assembly.exports is not None
            assert (seed/'exports/reproduction.bin').read_bytes()==source_raw
            case_values=None
        elif C1_case in ('stable','S-extra','S-close-A-B','S-document'):
            assert caught is None, (type(caught).__name__, str(caught), getattr(caught,'code',None))
            assert assembly.work['runtime']['read_bytes']==assembly.work['runtime']['sha_bytes']==3*len(source_raw)
            assert assembly.work['runtime']['write_bytes']==assembly.work['runtime']['copy_bytes']==len(source_raw)
            assert assembly.work['runtime']['equality_bytes']==2*len(source_raw)
            assert (seed/'runtime-copy.bin').read_bytes()==source_raw
            case_values=raw16_C1_case_values(replay,h) if C1_case=='stable' else None
        else:
            assert caught is not None and assembly.failure is not None,C1_case
            if C1_case=='write-accounting':
                assert writes==[65536] and assembly.work['observed_write_failures'][0]['return']==65536
                assert assembly.work['write_accounting_incomplete'] and (seed/'runtime-copy.bin').stat().st_size==65536
            if C1_case=='hash-allocation':assert not fds and not (seed/'runtime-copy.bin').exists()
            if C1_case in ('write-limit','physical-limit'):assert not writes and (seed/'runtime-copy.bin').stat().st_size==0
            if C1_case=='partial-budget':
                assert writes==[65536] and (seed/'runtime-copy.bin').stat().st_size==65536
                assert assembly.work['runtime']['write_bytes']==assembly.work['runtime']['physical_bytes']==65536
            if C1_case in ('register-A-close-B','ordinary-A-close-B','registered-cancel'):assert caught is cancels[0]
            case_values=None
        if C1_case=='S-document':
            document=b'{"physical_document_control":1}\\n'
            assembly._write_document(document)
            assert (seed/'raw-observations.json').read_bytes()==document
        if C1_case=='S-extra':
            before=assembly.root.before;(seed/'undeclared.bin').write_bytes(b'unknown');assembly._refresh_S(before)
        if C1_case=='S-close-A-B':
            def rechecking(item,*args,**kwargs):
                if item.path==str(seed/'runtime-copy.bin'):marked()
                return original_recheck(item,*args,**kwargs)
            def closing_held(item):
                result=original_held_close(item)
                if item.path==str(seed/'runtime-copy.bin'):marked()
                return result
            c.HeldPath.recheck,c.HeldPath.close=rechecking,closing_held
        closing_error=None
        try:assembly.close(caught)
        except BaseException as error:
            closing_error=error
            assert caught is None or error is caught
        finally:c.HeldPath.recheck,c.HeldPath.close=original_recheck,original_held_close
        if C1_case=='S-extra':assert closing_error is not None and assembly.failure is not None,'S-namespace-deletion'
        if C1_case=='S-close-A-B':assert len(cancels)==2 and closing_error is cancels[0]
        assert assembly.closed and assembly.root is None and not assembly.output_holds
        assert all(closes.get(fd)==1 for fd in fds), (C1_case,fds,closes)
        seed_parent.close()
        assert copied_inventory.closed is False and os.fstat(copied_inventory.directory.fd)
        partial=(seed/'runtime-copy.bin').read_bytes() if (seed/'runtime-copy.bin').exists() else None
        print(json.dumps({'C1_copy_case':C1_case,'writes':writes,'new_writer_FD_count':len(fds),
            'S_bytes_before_fixture_cleanup':None if partial is None else partial.hex(),
            'S_work':assembly.work,'case_work':assembly.case_work,'window_work':anchor.recording_work,
            'case_values':case_values,'real_Darwin_ACL':sys.platform=='darwin',
            'no_native_qualification_or_final_seed':True},sort_keys=True))
'''
    for case in cases:
        namespace = {'C1_case': case, 'C1_mutation': mutation, 'raw16_C1_case_values': raw16_C1_case_values}
        argv = sys.argv;sys.argv = ['C1-copy-fixture', str(root)]
        try:exec(compile(prefix + extra + footer, '<actual-held-C1-copy>', 'exec'), namespace)
        finally:sys.argv = argv


def raw16_C1_deletions(root: Path) -> None:
    for case, mutation, marker in (('tail', 'S-size', 'tail'),
                                   ('S-extra', 'S-namespace', 'S-namespace-deletion')):
        try:raw16_C1_copy(root, (case,), mutation)
        except AssertionError as error:assert str(error) == marker
        else:raise AssertionError('C1 deletion was not detected: ' + mutation)
    print(json.dumps({'C1_narrow_deletions_detected': ['S-size', 'S-namespace']}))


def _synthetic_C1_T(c, scratch, operation, input_raw, response_raw):
    rows = []
    for ordinal, role in enumerate(('python', 'git', 'jq')):
        name = 'raw16-t-v1-' + operation + '-runtime-' + role + '-' + str(ordinal).zfill(2) + '.bin'
        raw = (b'C1 synthetic never executed ' + role.encode()) * 31
        path = scratch/name;path.write_bytes(raw);path.chmod(0o400)
        rows.append({'slot': role, 'index': 0, 'ordinal': ordinal, 'locator': str(path),
            'file': name, 'size_bytes': len(raw), 'sha256': c.digest(raw), 'errno': None})
    value = {'operation': operation, 'binding': {'input_sha256': c.digest(input_raw),
        'response_sha256': c.digest(response_raw)},
        'entropy': {'preparation_names': [[{'entropy': '01'*8, 'errno': None}]]},
        'clocks': {'wall': [], 'monotonic': []}, 'storage': [],
        'commands': {'runtime_values': [{'git_version': b'git version fixture\n'.hex(),
            'python_version': '3.11.fixture', 'unicode_version': '14.0.0'}]},
        'runtime': {'files': rows}, 'complete': True}
    raw = c.canonical(value)
    path = scratch/('raw16-t-v1-' + operation + '-capture.json');path.write_bytes(raw);path.chmod(0o400)
    (scratch/('raw16-t-v1-' + operation + '-complete-' + c.digest(raw))).mkdir(mode=0o700)
    return value


def raw16_C1_T_windows(root: Path) -> None:
    body = (root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n", 1)[1].split('\nPY_RUNTIME_CONSUMER', 1)[0]
    prefix = body.split("        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)\n", 1)[0]
    footer = body[body.rfind('finally:\n    if copied_inventory'):]
    prefix = prefix.replace("        store=base/'store';", "        seed=base/'pending-S';seed.mkdir(mode=0o700)\n        writer_private=base/'writer-private';writer_private.mkdir(mode=0o700)\n        parent_context,parent_values=make_parent(c,base/'parent.frame')\n        store=base/'store';", 1)
    prefix = prefix.replace("        install=base/'installed';", "        for directory in (private,writer_private):\n            for item in ('preparation-scratch','inspection-scratch'):(directory/item).mkdir(mode=0o700)\n        install=base/'installed';", 1)
    original = "uid,gid=os.getuid(),os.getgid();attempt='attempt.runtime';request=b'ordinary original request'"
    replacement = """uid,gid=os.getuid(),os.getgid();attempt='attempt.runtime'
        launch_body={'attempt':{'attempt_id':attempt,'attempt_number':1},'store_id':'store.runtime','control':{},'subject':{}}
        request=h.canonical({'schema_version':1,'kind':'sandbox_launch_request','id':attempt,'body':launch_body})
        bound=launch_body['attempt']|{'launch_request_sha256':h.sha256_hex(request)}
        outer=h.canonical({'schema_version':1,'kind':'shadow_enforced_request','id':attempt,'body':{'attempt_id':attempt}})
        expectation=h.canonical({'schema_version':1,'kind':'sandbox_receipt_expectation','id':attempt,'body':launch_body|{'attempt':bound}})
        receipt=h.canonical({'schema_version':1,'kind':'sandbox_enforcement_receipt','id':'receipt.'+h.sha256_hex(request),
            'body':{'attempt':bound,'control':{},'subject':{},'origin':{'store_id':'store.runtime'}}})"""
    assert original in prefix;prefix = prefix.replace(original, replacement)
    old_receipt = "h.canonical({'body':{'attempt':{'attempt_id':attempt,'launch_request_sha256':h.sha256_hex(request)}}})"
    assert old_receipt in prefix;prefix = prefix.replace(old_receipt, 'receipt')
    prefix = prefix.replace("groups={'runtime':{'files':h._capture_process['runtime_inventory']}}", "groups={'runtime':{'files':h._capture_process['runtime_inventory']},'host':{'process':[],'driver_rest':[],'signals':[]},'clocks':{'wall':[],'monotonic':[]}}")
    prefix = prefix.replace("anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),None)", "anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),c._DarwinUUIDResolver() if sys.platform=='darwin' else None)")
    prefix = prefix.replace("c._store_rule(uid,gid,0o700,True),'E_STORE')", "c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')")
    extra = '''        import shutil
        replay=load('C1_T_replay',root/'evals/v1/replay-malicious.py')
        c._acl_state=original_acl
        seed_parent=c._open_held(str(seed),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        key=str(parent.before.st_dev)+':'+str(parent.before.st_ino)
        case_work=c._capture_work_values(anchor.recording_work,key)
        assembly=replay._SeedAssembly(seed_parent,anchor,'malicious.checked-file-bytes',anchor.recording_work,case_work)
        holder=e.StableDirectory(parent)
        input_raw,response_raw=b'ordinary C1 materialization input',b'ordinary C1 materialization response'
        prep=private/'preparation-scratch'
        make_T(c,prep,'prepare',input_raw,response_raw)
        (prep/'candidate-preparation-0101010101010101').mkdir(mode=0o700)
        prepared=holder._retain_preparation(anchor,'preparation-scratch','prepare',input_raw,response_raw,outer)
        assert prepared is not None
        early=prepared.T_companions[0]
        assembly.reproduction_prepare(prepared,early,outer,input_raw,response_raw)
        assert len(assembly.occurrences)==1 and not early.closed
        holder._T_cleanup_begin(anchor,'preparation-scratch')
        child=prep/'candidate-preparation-0101010101010101';shutil.rmtree(child)
        holder._T_cleanup_removed(anchor,child.name);holder._T_cleanup_done(anchor)
        make_T(c,prep,'inspect',input_raw,response_raw)
        holder._T_inspection_returned(anchor)
        inspected=holder._retain_preparation(anchor,'preparation-scratch','inspect',input_raw,response_raw,outer)
        assert inspected is not None and early.closed and early.close_complete
        current=next(item for item in inspected.T_companions if item.binding['operation']=='inspect')
        assembly.reproduction_inspect(inspected,current,outer,input_raw,response_raw)
        try:assembly.reproduction_prepare(prepared,early,outer,input_raw,response_raw)
        except ValueError:pass
        else:raise AssertionError('duplicate/closed prepare admitted')
        record={'values':{'platform':sys.platform,'architecture':'fixture','python_implementation':'cpython',
            'python_version':'fixture3.11','soabi':'fixture','ext_suffix':'.so',
            'configuration':{name:None for name in e._NATIVE_CONFIGURATION_KEYS}},
            'locators':{name:'/fixture/'+name for name in ('compiler','include','config_include','source','binary')}}
        e._native_runtime_values(record['values'],record['locators'])
        anchor.private_observations['commands']={'runtime_values':[record]}
        anchor.retain_entropy('reproduction',bytes(32))
        parent_P=holder._retain_parent_inputs(anchor,parent_context,outer)
        runtime_source=c._open_held(str(source),False,c._store_rule(uid,gid,0o400,False,anchor.resolver),'E_STORE')
        holder._retain_runtime(anchor,'python',runtime_source,source_raw,outer)
        local=next((item for item in holder.runtime_copies if item.runtime_sha256 and all(name.endswith('-python-0000.bin') for name in item.runtime_sha256)),None)
        assert parent_P is not None and local is not None
        native.record_reproduction(outer,request,expectation)
        transition=holder._begin_T_parent(anchor,parent)
        copied_inventory=native.copy_capture(parent,request,'reproduction',anchor.recording_work)
        holder._refresh_runtime_parents();holder._finish_T_parent(anchor,parent,transition,{'reproduction'})
        assembly.reproduction(native,copied_inventory,list(holder.runtime_copies),outer,expectation)
        assert 'reproduction' in assembly.occurrences
        writer_anchor=c.Anchor(config,config_raw,[],{},('',[]),('',[]),anchor.resolver,recording_work=anchor.recording_work)
        writer_parent=c._open_held(str(writer_private),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        writer_holder=e.StableDirectory(writer_parent)
        writer_outer=c.canonical({'schema_version':1,'kind':'shadow_write_request','id':'attempt.write','body':{'attempt_id':'attempt.write'}})
        for operation,scratch in (('prepare','preparation-scratch'),('inspect','inspection-scratch')):
            make_T(c,writer_private/scratch,operation,input_raw,response_raw)
            retained=writer_holder._retain_preparation(writer_anchor,scratch,operation,input_raw,response_raw,writer_outer)
            assert retained is not None
            T=next(item for item in retained.T_companions if item.binding['operation']==operation)
            method=assembly.write_prepare if operation=='prepare' else assembly.write_inspect
            method(retained,T,writer_outer,input_raw,response_raw)
        assert set(assembly.occurrences)==set(replay._CASE_ROLES[:5])
        assert len(assembly.case_sources)==2 and assembly.case_sources[0] is case_work
        assert all(any(source is item for item in anchor.recording_work['cases'].values()) for source in assembly.case_sources)
        assert assembly.raw is None and anchor.private_observations.get('accounting',{}).get('complete') is False
        assembly.close();seed_parent.close()
        writer_holder.close();holder.close();runtime_source.close()
        assert all(item.closed for item in assembly.bindings['reproduction.prepare']['T'])
        print(json.dumps({'four_actual_T_early_consumptions':True,'actual_original_enforced_cleanup_inspect_transition':True,
            'prepare_closed_before_later_launch_consumption':early.closed,'pending_S_only':True,
            'actual_reproduction_held_stage':True,'S_work':assembly.work,
            'qualification':'NOT_ACCEPTED; synthetic runtime/version inputs and parent semantics UNKNOWN; no actual native release'},sort_keys=True))
'''
    namespace = {'make_T': _synthetic_C1_T, 'make_parent': _synthetic_parent_P_context}
    argv = sys.argv;sys.argv = ['C1-T-fixture', str(root)]
    try:exec(compile(prefix + extra + footer, '<actual-C1-T-windows>', 'exec'), namespace)
    finally:
        sys.argv = argv
        for name in ('assembly', 'writer_holder', 'holder', 'seed_parent'):
            value = namespace.get(name)
            if value is not None:
                try:value.close()
                except Exception:pass


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


def raw16_C1_scope_runtime_values(root: Path, mutation=False) -> None:
    import ast, copy, inspect, textwrap, types
    module = load_component(root/"scope/v1/read-shadow-evidence.py")
    if mutation:
        source = textwrap.dedent(inspect.getsource(module._scope_runtime_value_values))
        assert source.count('type(row["ordinal"]) is int') == 1
        source = source.replace('type(row["ordinal"]) is int', 'isinstance(row["ordinal"], int)')
        changed = {};exec(compile(source, '<scope-ordinal-rule-deletion>', 'exec'), module.__dict__, changed)
        module._scope_runtime_value_values = changed['_scope_runtime_value_values']
    tree = ast.parse((root/"scope/v1/read-shadow-evidence.py").read_text())
    owner = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "_Reader")
    constructor = next(n for n in owner.body if isinstance(n, ast.FunctionDef) and n.name == "__init__")
    prologue = []
    for statement in constructor.body:
        if isinstance(statement, ast.Try):break
        prologue.append(statement)
    def reader():
        value = module._Reader.__new__(module._Reader)
        local = dict(self=value, scope_path=Path('/fixture/scope'), set_path=Path('/fixture/set'),
            bundle_root=Path('/fixture/bundle'), git_root=Path('/fixture/git'), output=Path('/fixture/private/result'),
            store_session=None, deadline=None, document_paths=None)
        exec(compile(ast.Module(body=prologue, type_ignores=[]), '<original-Reader-initialization>', 'exec'), module.__dict__, local)
        value.capture_completion_owner = None
        value.darwin = module.c._DarwinUUIDResolver() if sys.platform == 'darwin' else None
        return value
    calls = []
    class Versions:
        def get_config_var(self, name):
            assert name == 'SOABI';calls.append(name);return self.value
    versions = Versions();versions.value = 'fixture.abi'
    module.sysconfig = versions
    module.sys = types.SimpleNamespace(version='fixture Python', executable='/fixture/python', platform=sys.platform)
    module.unicodedata = types.SimpleNamespace(unidata_version='fixture.unicode')
    first, second = reader(), reader()
    anchors = [module.c.Anchor({}, b'{}\n', [], {}, ('', []), ('', []), None) for _ in range(2)]
    pending = iter(anchors);original_load = module.c.load_anchor
    module.c.load_anchor = lambda *args:next(pending)
    try:
        for item in (first, second):item.anchor_for()
    finally:module.c.load_anchor = original_load
    # Completion-owner admission is deliberately unavailable in this scalar fixture.
    assert all(item.private_observations['unusable'] for item in anchors)
    def block(name, marker):
        method = next(n for n in owner.body if isinstance(n, ast.FunctionDef) and n.name == name)
        return next(n for n in ast.walk(method) if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
            and isinstance(n.value.func, ast.Name) and n.value.func.id == 'require'
            and marker in ast.get_source_segment((root/'scope/v1/read-shadow-evidence.py').read_text(), n))
    abi = block('provenance', 'scope.soabi')
    language = block('preparation', 'scope.python-version')
    native = {key:'a'*64 for key in ('source_sha256','build_script_sha256','build_record_sha256',
        'binary_locator_sha256','binary_sha256','python_locator_sha256','python_sha256','dependency_record_sha256')}
    native.update(context_version=2,binary_size=1,python_abi='fixture.abi',loader_mode='rtld-now-local.v1')
    native['python_locator_sha256'] = module.c.digest(b'/fixture/python')
    producer = dict(source_sha256='a'*64,protocol_sha256='b'*64,jq={'version':'jq-1.6'},
        python={'version':'fixture Python'},git={'version':'git version fixture'},unicode_version='fixture.unicode')
    def execute(statement, item, native_value=native, producer_value=producer):
        item.package_sources = {'adapters/local-git-materializer/v1/protocol.jq':types.SimpleNamespace(sha256='b'*64)}
        local = dict(self=item, native=native_value, body={'python_sha256':'a'*64},
            producer=producer_value, source=types.SimpleNamespace(sha256='a'*64),
            hashes=set(native)-{'context_version','binary_size','python_abi','loader_mode'})
        environment = dict(module.__dict__, **local)
        exec(compile(ast.Module(body=[statement],type_ignores=[]),'<original-scope-runtime-check>', 'exec'),environment,environment)
    execute(abi,first);execute(language,first)
    observed = first.anchor.private_observations['commands']['runtime_values']
    assert not first.anchor.recording_work.get('scope_runtime_incomplete')
    assert first.anchor.recording_work['accounting']['M']['occurrences']==3
    assert [row['site'] for row in observed] == list(module._SCOPE_RUNTIME_SITES)
    assert calls == ['SOABI'] and all(row['ordinal']==0 for row in observed)
    snapshot = copy.deepcopy(observed)
    bad = copy.deepcopy(producer);bad['git']['version'] = 'wrong prefix'
    try:execute(language,first,producer_value=bad)
    except module.c.Refusal:pass
    else:raise AssertionError('original Git prefix failure lost')
    assert observed[-1] == dict(site='scope.python-version',ordinal=1,value='fixture Python')
    before = len(observed);bad = copy.deepcopy(producer);bad['jq']['version'] = 'wrong'
    try:execute(language,first,producer_value=bad)
    except module.c.Refusal:pass
    else:raise AssertionError('original early rejection lost')
    assert len(observed)==before
    wrong = dict(native,context_version=True)
    try:execute(abi,first,native_value=wrong)
    except module.c.Refusal:pass
    else:raise AssertionError('original before-ABI rejection lost')
    assert calls == ['SOABI']
    versions.value = None
    try:execute(abi,first)
    except module.c.Refusal:pass
    else:raise AssertionError('None ABI admitted')
    assert observed[-1] == dict(site='scope.soabi',ordinal=1,value=None)
    module._scope_runtime_prefix_values(snapshot,observed)
    assert not second.anchor.private_observations['entropy']
    second._runtime_equal('scope.python-version','other','other')
    rejected = []
    for label in ('cross-context','order','ordinal-bool','gap','extra','value'):
        changed = copy.deepcopy(snapshot)
        if label=='cross-context':target=second.anchor.private_observations['commands']['runtime_values']
        else:target=observed
        if label=='order':changed.reverse()
        elif label=='ordinal-bool':changed[0]['ordinal']=False
        elif label=='gap':changed[0]['ordinal']=1
        elif label=='extra':changed[0]['extra']=0
        elif label=='value':changed[0]['value']='foreign'
        try:module._scope_runtime_prefix_values(changed,target)
        except module.c.Refusal:rejected.append(label)
        else:raise AssertionError('scope row accepted '+label)
    class Broken(list):
        def append(self,item):raise MemoryError('ordinary scope recording failure')
    second.anchor.private_observations['commands']['runtime_values']=Broken()
    assert second._runtime_equal('scope.unicode-version','same','same') is True
    assert second.anchor.recording_work['scope_runtime_incomplete']
    main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'main')
    cancel = next(n for n in main.body if isinstance(n, ast.FunctionDef) and n.name == 'cancel')
    handlers = {};exec(compile(ast.Module(body=[cancel],type_ignores=[]),'<actual-scope-handler>','exec'),handlers)
    cancellations = []
    def marked():
        try:handlers['cancel'](15,None)
        except InterruptedError as error:cancellations.append(error);raise
    original_error = module.c._capture_observation_error
    class Cancelled(list):
        def append(self,item):marked()
    try:
        second.anchor.private_observations['commands']['runtime_values']=Cancelled()
        module.c._capture_observation_error=lambda *args:marked()
        try:second._runtime_equal('scope.soabi','same','same')
        except InterruptedError as error:assert error is cancellations[0] and len(cancellations)==2
        else:raise AssertionError('first scope recording cancellation lost')
        second.anchor.private_observations['commands']['runtime_values']=Broken()
        try:second._runtime_equal('scope.soabi','same','same')
        except InterruptedError as error:assert error is cancellations[2] and len(cancellations)==3
        else:raise AssertionError('later scope recording cancellation lost')
    finally:module.c._capture_observation_error=original_error
    print(json.dumps({'C1_scope_runtime_actual_original_check_blocks':True,'SOABI_actual_calls':calls,
        'snapshot':snapshot,'later_actual_rows':observed,'negatives':rejected,
        'no_coverage_entropy_container':first.anchor.private_observations['entropy'],
        'M_actual':[item.recording_work.get('accounting') for item in anchors],
        'real_handler_cancel_priority':len(cancellations),
        'limits':'scalar original blocks and producer only; synthetic version/source inputs; admission unavailable, full Reader/native/gate qualification NOTRUN'},sort_keys=True))


def raw16_C1_scope_runtime_deletion(root: Path) -> None:
    try:raw16_C1_scope_runtime_values(root, mutation=True)
    except AssertionError as error:assert str(error)=='scope row accepted ordinal-bool'
    else:raise AssertionError('scope ordinal deletion not detected')
    print(json.dumps({'scope_ordinal_bool_rule_deletion_detected':True}))


def raw16_C1_revision_wrapper(root: Path, mutation=False) -> None:
    body = (root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n", 1)[1].split('\nPY_RUNTIME_CONSUMER', 1)[0]
    prefix = body.split('        native.recheck();native.close();native=None\n', 1)[0]
    footer = body[body.rfind('finally:\n    if copied_inventory'):]
    prefix = prefix.replace("        store=base/'store';", "        seed=base/'pending-S';seed.mkdir(mode=0o700)\n        store=base/'store';", 1)
    prefix = prefix.replace("anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),None)", "anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),c._DarwinUUIDResolver() if sys.platform=='darwin' else None)")
    prefix = prefix.replace("c._store_rule(uid,gid,0o700,True),'E_STORE')", "c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')")
    extra = '''        import inspect
        replay=load('C1_revision_replay',root/'evals/v1/replay-malicious.py')
        c._acl_state=original_acl
        seed_parent=c._open_held(str(seed),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        assembly=replay._SeedAssembly(seed_parent,anchor,'malicious.checked-file-bytes',anchor.recording_work,copied_inventory.case_work)
        actual_processed=assembly._wrapper_processed
        encoder=c.json.JSONEncoder;loads=replay.json.loads
        caught=None;fault=MemoryError('bounded wrapper '+case);attempts=[];armed=[True]
        def process(site,amount):
            attempts.append({'site':site,'input_bytes':amount})
            if wrapper_mutation and site=='compare':return
            if case==site and armed[0]:armed[0]=False;raise fault
            return actual_processed(site,amount)
        class Partial(encoder):
            def iterencode(self,value,*args,**kwargs):
                iterator=super().iterencode(value,*args,**kwargs)
                for index,piece in enumerate(iterator):
                    yield piece
                    if case=='partial-encode' and armed[0] and index==4:
                        armed[0]=False;raise fault
        def parsing(*args,**kwargs):
            if case=='parse' and armed[0] and inspect.currentframe().f_back.f_code is replay._case_v2_validate.__code__:
                armed[0]=False;attempts.append({'site':'parse-attempt','input_bytes':len(args[0])});raise fault
            return loads(*args,**kwargs)
        assembly._wrapper_processed=process
        assembly.work['wrapper_incomplete']=True
        c.json.JSONEncoder=Partial;replay.json.loads=parsing
        try:
            try:result=values(replay,h,assembly)
            except BaseException as error:
                caught=error;assembly._failed(error,'ordinary-fixed-wrapper-caller')
        finally:c.json.JSONEncoder=encoder;replay.json.loads=loads
        if case=='normal':
            assert caught is None
            steps=assembly.work['wrapper_steps'];assert [row['site'] for row in steps]==['shape','size','encode','shape','size','encode','compare','parse'], 'wrapper compare accounting omitted'
            assert assembly.work['accounting']['M']['occurrences']>=2
            assert assembly.work['accounting']['M']['logical_bytes']>=2*result['bytes']
            assembly.work['wrapper_incomplete']=False
            assembly._transfer();before=anchor.recording_work['read_bytes'];assembly._transfer()
            assert anchor.recording_work['read_bytes']==before
        else:
            assert caught is fault and assembly.failure is fault
            assert assembly.work['wrapper_incomplete'] and not (seed/'raw-observations.json').exists()
            if case=='partial-encode':assert assembly.work['read_bytes']>0
        try:assembly.close(caught)
        except BaseException as error:assert caught is None or error is caught
        seed_parent.close()
        print(json.dumps({'C1_wrapper_case':case,'attempts':attempts,'completed_steps':assembly.work.get('wrapper_steps',[]),
            'actual_read_bytes':assembly.work['read_bytes'],'M':assembly.work.get('accounting',{}).get('M'),
            'failure':None if caught is None else type(caught).__name__,'incomplete':assembly.work.get('wrapper_incomplete'),
            'qualification':'NOT_ACCEPTED; actual S/ledger owner with composition input, not full case/native/seed'},sort_keys=True))
'''
    for case in ('normal','shape','size','partial-encode','compare','parse'):
        namespace = {'case':case,'values':raw16_C1_case_values,'wrapper_mutation':mutation}
        argv=sys.argv;sys.argv=['C1-wrapper-fixture',str(root)]
        try:exec(compile(prefix+extra+footer,'<actual-C1-wrapper>','exec'),namespace)
        finally:sys.argv=argv


def raw16_C1_gate_revision(root: Path, case='normal', mutation=False) -> None:
    body = (root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n", 1)[1].split('\nPY_RUNTIME_CONSUMER', 1)[0]
    prefix = body.split('        native.recheck();native.close();native=None\n', 1)[0]
    footer = body[body.rfind('finally:\n    if copied_inventory'):]
    setup = '''        seed=base/'pending-S';seed.mkdir(mode=0o700)
        originals_dir=base/'original-inputs';originals_dir.mkdir(mode=0o700)
        terminal_dir=base/'terminal';terminal_dir.mkdir(mode=0o700)
        snapshot_dir=base/'scope-P';snapshot_dir.mkdir(mode=0o700)
        original_values=[{'schema_version':1,'kind':kind,'id':identity,'body':value} for kind,identity,value in (
            ('shadow_incident_record','incident.fixture',{'observed_at':'2026-10-26T00:00:00Z'}),
            ('shadow_enforced_request','reproduction.fixture',{}),('shadow_write_request','write.fixture',{}),
            ('scope_gate_generation_request','generation.fixture',{'scope_basis':{'body':{'workflow_id':'workflow.other','task_class':'task.other'}},'risk_claim':{}}))]
        original_paths=[]
        for index,value in enumerate(original_values):
            path=originals_dir/str(index);path.write_bytes(h.canonical(value));path.chmod(0o400);original_paths.append(path)
        store=base/'store';'''
    prefix = prefix.replace("        store=base/'store';", setup, 1)
    prefix = prefix.replace("anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),None)", "anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),c._DarwinUUIDResolver() if sys.platform=='darwin' else None)")
    prefix = prefix.replace("c._store_rule(uid,gid,0o700,True),'E_STORE')", "c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')")
    extra = '''        import ast,socket,time,types
        replay=load('C1_gate_revision_replay',root/'evals/v1/replay-malicious.py')
        g=load('C1_revision_generator',root/'scope/v1/generate-gate-evidence.py')
        g.c=c;g.r.c=c
        c._acl_state=original_acl
        seed_parent=c._open_held(str(seed),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        assembly=replay._SeedAssembly(seed_parent,anchor,'malicious.unread-forge-text',anchor.recording_work,copied_inventory.case_work)
        original_holds=[c._hold_bytes(str(path),c.DOCUMENT_LIMIT) for path in original_paths]
        assembly.original_inputs(*original_holds)
        def init_prefix(module,cls,instance,arguments):
            tree=ast.parse((root/('scope/v1/generate-gate-evidence.py' if cls=='_Generator' else 'scope/v1/read-shadow-evidence.py')).read_text())
            node=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name==cls)
            init=next(n for n in node.body if isinstance(n,ast.FunctionDef) and n.name=='__init__')
            statements=[]
            for item in init.body:
                if isinstance(item,ast.Try if cls=='_Reader' else ast.For):break
                statements.append(item)
            environment=dict(module.__dict__,self=instance,**arguments)
            exec(compile(ast.Module(body=statements,type_ignores=[]),'<original-owner-initialization>','exec'),environment,environment)
        generator=g._Generator.__new__(g._Generator)
        init_prefix(g,'_Generator',generator,{'arguments':['generate']+[str(path) for path in original_paths]+[str(base/'a'),str(base/'b'),str(base/'c')]})
        generator.request=g.generation_request(original_holds[3].raw)
        session=g._GateStoreSession(generator.request['id'],c.digest(original_holds[3].raw),time.monotonic()+30)
        generator.session=session;session.generator=generator
        reader=g.r._Reader.__new__(g.r._Reader)
        init_prefix(g.r,'_Reader',reader,dict(scope_path=original_paths[3],set_path=original_paths[3],bundle_root=store,git_root=store,
            output=terminal_dir/'result',store_session=session,deadline=None,document_paths=None))
        reader.scope_body=generator.request['body']['scope_basis']['body'];reader.enforced=e
        session.reader=reader;generator.reader=reader
        assembly._bind_gate(generator)
        reader.anchor=anchor;anchor.scope_runtime_owner=reader
        anchor.private_observations['commands']={'runtime_values':[]}
        anchor.private_observations['entropy']={}
        for site,value in [('scope.soabi','fixture-soabi'),('scope.python-version','fixture-python'),('scope.unicode-version','fixture-unicode')]:
            assert reader._runtime_equal(site,value,value)
        snapshot_parent=c._open_held(str(snapshot_dir),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        scope_P=native.copy_capture(snapshot_parent,request,'reproduction',anchor.recording_work)
        frozen=scope_P.consumer_snapshot
        assert reader._runtime_equal('scope.python-version','later-python','later-python')
        actual_snapshot=assembly._consumer_snapshot(c,anchor,scope_P,'kill')
        assert len(actual_snapshot['commands']['runtime_values'])==3
        assert len(anchor.private_observations['commands']['runtime_values'])==4
        scope_P.consumer_snapshot=frozen+b' '
        try:assembly._consumer_snapshot(c,anchor,scope_P,'kill')
        except ValueError:pass
        else:raise AssertionError('changed P snapshot accepted')
        scope_P.consumer_snapshot=frozen
        scope_P.close();snapshot_parent.close()
        if gate_mutation=='phase':
            import inspect,textwrap
            source=textwrap.dedent(inspect.getsource(replay._SeedAssembly._closed_gate))
            assert source.count('self.gate_session.phase == "COMPLETE"')==1
            source=source.replace('self.gate_session.phase == "COMPLETE"','self.gate_session.phase == "FINAL_OWNER"')
            changed={};exec(compile(source,'<old-gate-phase-rule>','exec'),replay.__dict__,changed)
            replay._SeedAssembly._closed_gate=changed['_closed_gate']
        assert assembly._gate_request()['id']=='generation.fixture'
        reader.owned.append(native);native=None
        native_tree=ast.parse((root/'scope/v1/generate-gate-evidence.py').read_text())
        gen_class=next(n for n in native_tree.body if isinstance(n,ast.ClassDef) and n.name=='_Generator')
        kill=next(n for n in gen_class.body if isinstance(n,ast.FunctionDef) and n.name=='kill_source')
        changed_id=next(n for n in kill.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Attribute) and t.attr=='call_id' for t in n.targets))
        changed_request=kill.body[kill.body.index(changed_id)+1]
        source_id='kill-register.'+'11'*32
        source_raw=c.canonical({'schema_version':1,'kind':'kill_register_source_request','id':source_id,
            'body':{'operation':'kill-register-read.v1','nonce':'11'*32}})
        environment=dict(g.__dict__,session=session,call_id=source_id,raw=source_raw)
        exec(compile(ast.Module(body=[changed_id,changed_request],type_ignores=[]),'<original-kill-id-assignment>','exec'),environment,environment)
        assert session.call_id!='generation.fixture' and assembly._gate_request()['id']=='generation.fixture'
        gate_fn=next(n for n in ast.parse((root/'evals/v1/replay-malicious.py').read_text()).body if isinstance(n,ast.ClassDef) and n.name=='_SeedAssembly')
        gate=next(n for n in gate_fn.body if isinstance(n,ast.FunctionDef) and n.name=='gate')
        binding=[n for n in gate.body if isinstance(n,ast.Assign) and
            (any(isinstance(t,ast.Name) and t.id=='original' for t in n.targets) or
             any(isinstance(t,ast.Subscript) and isinstance(t.value,ast.Attribute) and t.value.attr=='occurrences' for t in n.targets))]
        if gate_mutation=='request-id':
            class OldID(ast.NodeTransformer):
                def visit_Subscript(self,node):
                    if isinstance(node.value,ast.Name) and node.value.id=='original' and isinstance(node.slice,ast.Constant) and node.slice.value=='id':
                        return ast.copy_location(ast.Attribute(value=ast.Name(id='session',ctx=ast.Load()),attr='call_id',ctx=ast.Load()),node)
                    return self.generic_visit(node)
            binding=[ast.fix_missing_locations(OldID().visit(node)) for node in binding]
        environment=dict(replay.__dict__,self=assembly,session=session,contexts=object())
        exec(compile(ast.Module(body=binding,type_ignores=[]),'<actual-gate-binding-assignment>','exec'),environment,environment)
        assert assembly.occurrences['gate']['binding']=={'request_id':'generation.fixture','request_sha256':session.binding}, 'mutable kill id reused as generation id'
        actual_request=generator.request
        generator.request=dict(actual_request,id=session.call_id)
        try:assembly._gate_request()
        except ValueError:pass
        else:raise AssertionError('cross gate id admitted')
        generator.request=actual_request
        original_binding=session.binding;session.binding='f'*64
        try:assembly._gate_request()
        except ValueError:pass
        else:raise AssertionError('cross gate SHA admitted')
        session.binding=original_binding
        collecting=[]
        reader.darwin=types.SimpleNamespace(kill_register_source=lambda raw:collecting.append(raw))
        raw=b'synthetic collector boundary input'
        begin=next(i for i,n in enumerate(kill.body) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Attribute) and t.attr=='phase' for t in n.targets))
        end=next(i for i,n in enumerate(kill.body) if isinstance(n,ast.Assign) and isinstance(n.value,ast.Constant) and n.value.value=='K_DONE')
        environment=dict(g.__dict__,session=session,reader=reader,raw=raw)
        exec(compile(ast.Module(body=kill.body[begin:end+1],type_ignores=[]),'<original-returned-collector-transition>','exec'),environment,environment)
        assert session.phase=='K_DONE' and not session.local and collecting==[raw]
        second_native=c._HeldStoreRead(anchor,attempt);reader.owned.append(second_native)
        session.start_scope();peer=c._GateWire(session.child_socket,session.deadline)
        assert peer.receive()[0]=='INIT';peer.send('INIT_ACK',{});session.pump()
        binding=c._gate_store_binding(second_native)
        for phase,payload in [('ACQUIRE',{'acquisition':'inner.1','binding':binding}),
            ('FINAL_OWNER',{'acquisitions':['inner.1']}),('RELEASE',{'acquisition':'inner.1'}),('CLOSED',{})]:
            peer.send(phase,payload);session.pump();assert peer.receive()==(phase+'_ACK',{})
        assert session.closed and session.phase=='FINAL_OWNER'
        session.complete();assert session.phase=='COMPLETE'
        closing_input=generator.hold(original_paths[3])
        inner=g.r._Reader.__new__(g.r._Reader)
        init_prefix(g.r,'_Reader',inner,dict(scope_path=original_paths[3],set_path=original_paths[3],bundle_root=store,git_root=store,
            output=terminal_dir/'result',store_session=None,deadline=None,document_paths=None))
        inner.scope={'id':'scope.fixture'};inner.darwin=anchor.resolver
        inner.terminal(c.canonical({'synthetic_observation':True}));inner.close()
        assembly.scope_reader=inner
        target_fd=second_native.held[-1].fd if gate_case=='reader-failure' else closing_input.held.fd
        original_close=os.close;transfer=assembly._transfer;close_count=[0]
        closing_failure=OSError(5,'controlled original gate close');primary=None;caught=None
        def closing(fd):
            if fd==target_fd:
                close_count[0]+=1
                result=original_close(fd)
                if gate_case in ('held-failure','reader-failure','prior-cancel'):raise closing_failure
                return result
            return original_close(fd)
        if gate_case=='prior-failure':
            primary=ValueError('earlier data failure');assembly._failed(primary,'fixture-earlier-failure')
        if gate_case=='post-transfer':
            closing_failure=MemoryError('actual close returned; transfer failed')
            def broken_transfer():raise closing_failure
            assembly._transfer=broken_transfer
        os.close=closing
        try:
            try:
                if gate_case=='prior-cancel':
                    reader_tree=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
                    main=next(n for n in reader_tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
                    handler=next(n for n in main.body if isinstance(n,ast.FunctionDef) and n.name=='cancel')
                    actual={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<original-scope-cancel>','exec'),actual)
                    try:actual['cancel'](15,None)
                    except InterruptedError as error:
                        primary=error;assembly.close_gate()
                else:assembly.close_gate()
            except BaseException as error:caught=error
        finally:os.close=original_close;assembly._transfer=transfer
        assert close_count==[1] and assembly.gate_close_attempted
        if gate_case=='normal':
            assert caught is None and not generator.active and not reader.owned and not session.local
            try:assembly._closed_gate()
            except ValueError as error:raise AssertionError('actual COMPLETE condition refused') from error
        else:
            if gate_case in ('held-failure','reader-failure','post-transfer'):assert caught is closing_failure
            if gate_case=='prior-cancel':assert caught is primary and assembly.failure is primary
            if gate_case=='prior-failure':assert caught is None and assembly.failure is primary
            try:assembly._closed_gate()
            except ValueError:pass
            else:raise AssertionError('failed original gate close accepted')
        try:assembly.close_gate()
        except ValueError:pass
        else:raise AssertionError('original gate close repeated')
        try:session.complete()
        except c.Refusal:pass
        else:raise AssertionError('complete accepted after original reader release')
        try:assembly.close(caught)
        except BaseException as error:assert caught is None or error is caught
        seed_parent.close()
        for item in original_holds:item.close()
        print(json.dumps({'gate_case':gate_case,'gate_original_request_id_after_actual_assignment':'generation.fixture',
            'mutable_kill_id':session.call_id,'original_wire_phase':session.phase,'original_Generator_close_returned':assembly.gate_close_returned,
            'original_close_attempts':close_count,'caught':None if caught is None else type(caught).__name__,
            'data_failure':None if assembly.failure is None else type(assembly.failure).__name__,
            'P_snapshot_rows':3,'later_owner_rows':4,'changed_P_snapshot_refused':True,'pending_only':True,'limits':'original binding assignment and real local wire/complete/close; constructor prologues only; collector stub, no source/native qualification'},sort_keys=True))
'''
    namespace = {'gate_case':case,'gate_mutation':mutation};argv=sys.argv;sys.argv=['C1-gate-revision',str(root)]
    try:exec(compile(prefix+extra+footer,'<actual-C1-gate-revision>','exec'),namespace)
    finally:sys.argv=argv


def raw16_C1_gate_revision_controls(root: Path) -> None:
    for case in ('normal','held-failure','reader-failure','prior-cancel','prior-failure','post-transfer'):
        raw16_C1_gate_revision(root,case)
    try:raw16_C1_gate_revision(root,mutation='phase')
    except AssertionError as error:assert str(error)=='actual COMPLETE condition refused'
    else:raise AssertionError('old FINAL_OWNER rule not detected')
    print(json.dumps({'old_gate_phase_rule_detected':True}))


def raw16_C1_revision_deletions(root: Path) -> None:
    try:raw16_C1_revision_wrapper(root,mutation=True)
    except AssertionError as error:assert str(error)=='wrapper compare accounting omitted'
    else:raise AssertionError('wrapper accounting deletion not detected')
    try:raw16_C1_gate_revision(root,mutation='request-id')
    except AssertionError as error:assert str(error)=='mutable kill id reused as generation id'
    else:raise AssertionError('original request id deletion not detected')
    print(json.dumps({'wrapper_compare_charge_deletion_detected':True,'mutable_gate_id_deletion_detected':True}))


def raw16_C2_inventory_inputs(root: Path, selected=None, mutation=False, window=False) -> None:
    body=(root/'scripts/test/evals-malicious.test.sh').read_text().split("<<'PY_RUNTIME_CONSUMER'\n",1)[1].split('\nPY_RUNTIME_CONSUMER',1)[0]
    prefix=body.split('        native.recheck();native.close();native=None\n',1)[0]
    footer=body[body.rfind('finally:\n    if copied_inventory'):]
    setup="""        seed=base/'pending-S';seed.mkdir(mode=0o700)
        if C2_window:
            import hashlib,tempfile
            ephemeral=Path(tempfile.gettempdir())/('ystack-C2-ephemeral-'+hashlib.sha256(os.fsencode(str(seed))).hexdigest())
            ephemeral.mkdir(mode=0o700)
        inputs=base/'original-inputs';inputs.mkdir(mode=0o700)
        input_values=[{'schema_version':1,'kind':kind,'id':identity,'body':value} for kind,identity,value in (
            ('shadow_incident_record','incident.fixture',{'observed_at':'2026-10-26T00:00:00Z'}),
            ('shadow_enforced_request','reproduction.fixture',{}),('shadow_write_request','write.fixture',{}),
            ('scope_gate_generation_request','generation.fixture',{}))]
        input_paths=[]
        for index,value in enumerate(input_values):
            path=inputs/str(index);path.write_bytes(h.canonical(value));path.chmod(0o400 if index%2==0 else 0o644);input_paths.append(path)
        store=base/'store';"""
    prefix=prefix.replace("        store=base/'store';",setup,1)
    prefix=prefix.replace("anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),None)","anchor=c.Anchor(config,config_raw,[installed_hold],{},('',[]),('',[]),c._DarwinUUIDResolver() if sys.platform=='darwin' else None)")
    prefix=prefix.replace("c._store_rule(uid,gid,0o700,True),'E_STORE')","c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')")
    extra='''        import ast,copy,inspect,textwrap
        replay=load('C2_inventory_replay',root/'evals/v1/replay-malicious.py');c._acl_state=original_acl
        if C2_mutation=='copy':
            source=textwrap.dedent(inspect.getsource(replay._SeedAssembly.original_inputs))
            calls=[node for node in ast.walk(ast.parse(source)) if isinstance(node,ast.Call)
                and isinstance(node.func,ast.Attribute) and node.func.attr=='_copy_file']
            assert len(calls)==1;call=ast.get_source_segment(source,calls[0])
            assert source.count(call)==1
            source=source.replace(call,'None')
            changed={};exec(compile(source,'<remove-original-input-copy>','exec'),replay.__dict__,changed)
            replay._SeedAssembly.original_inputs=changed['original_inputs']
        if C2_mutation in {'source-seal','kind-seal'}:
            source=textwrap.dedent(inspect.getsource(replay._S_inventory_core_values))
            check='source == (row["occurrence"], row["role"], row["member"], row["size_bytes"], row["sha256"], row["kind"])'
            assert source.count(check)==1
            replacement='True' if C2_mutation=='source-seal' else 'source[:5] == (row["occurrence"], row["role"], row["member"], row["size_bytes"], row["sha256"])'
            source=source.replace(check,replacement)
            changed={};exec(compile(source,'<remove-semantic-source-seal>','exec'),replay.__dict__,changed)
            replay._S_inventory_core_values=changed['_S_inventory_core_values']
        window_custody=window_caller=None
        if C2_window:
            window_held=c._open_held(str(seed),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
            window_caller=C2_caller_class(root,window_held,anchor.recording_work,copied_inventory.case_work)
            window_caller.work['files']+=1;c._capture_account(window_caller.work,'M','files',1)
            window_caller.work['seed_processing']['H']+=len(os.fsencode(str(base/'pending-S')))
            window_caller.observe('C2.ephemeral-parent-created-before-holds',{'path':str(ephemeral),'return':0})
            window_caller.work['runtime_case_carry_in']=copied_inventory.case_work.setdefault('runtime',{})
            window_caller.work['runtime_window_carry_in']=anchor.recording_work.setdefault('runtime',{})
            window_custody=window_caller.fixed['C2Root'](window_held,window_caller.work,anchor.resolver)
            S_destinations,window_operations=window_custody.layout()
            seed_parent=S_destinations['malicious.checked-file-bytes'];seed=Path(seed_parent.path)
        else:seed_parent=c._open_held(str(seed),True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE')
        assembly=replay._SeedAssembly(seed_parent,anchor,'malicious.checked-file-bytes',anchor.recording_work,copied_inventory.case_work)
        if C2_window:window_custody.release_destination(seed_parent);seed_parent=None
        inputs_held=[c._hold_bytes(str(path),c.DOCUMENT_LIMIT) for path in input_paths]
        fault=MemoryError('controlled semantic registration');caught=None;close_attempts=[];cancellations=[]
        observe=c._capture_observe;closing=os.close;opening=os.open;writer=[None];armed=[True]
        def opened(*args,**kwargs):
            fd=opening(*args,**kwargs)
            if args[0]=='incident.json' and kwargs.get('dir_fd')==assembly.root.fd:writer[0]=fd
            return fd
        def close(fd):
            if C2_case=='copy-close' and fd==writer[0] and armed[0]:
                armed[0]=False;close_attempts.append(fd);closing(fd);raise OSError(5,'controlled input writer close')
            return closing(fd)
        scope_tree=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
        main=next(n for n in scope_tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
        handler=next(n for n in main.body if isinstance(n,ast.FunctionDef) and n.name=='cancel')
        actual_handler={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<original-scope-cancel>','exec'),actual_handler)
        def observed(work,kind,site,value):
            if C2_case=='register-cancel-close' and site=='seed-semantic-member':
                try:actual_handler['cancel'](15,None)
                except InterruptedError as error:cancellations.append(error);raise
            if C2_case=='registration' and site=='seed-semantic-member':raise fault
            return observe(work,kind,site,value)
        if C2_case=='source-drift':input_paths[2].chmod(0o600)
        c._capture_observe=observed;os.open=opened;os.close=close
        try:
            try:assembly.original_inputs(*inputs_held)
            except BaseException as error:caught=error
        finally:c._capture_observe=observe;os.open=opening;os.close=closing
        names=('incident.json','reproduction-request.json','write-request.json','gate-request.json')
        if C2_case in ('source-drift','registration','copy-close','register-cancel-close'):
            assert caught is not None and assembly.failure is caught
            if C2_case=='registration':assert caught is fault and (seed/'incident.json').exists() and not assembly.semantic
            if C2_case=='copy-close':assert isinstance(caught,OSError) and close_attempts==[writer[0]] and not assembly.semantic
            if C2_case=='source-drift':assert isinstance(caught,c.Refusal) and not assembly.files
            if C2_case=='register-cancel-close':
                assert caught is cancellations[0] and len(cancellations)==1
                target=assembly.output_holds[0].fd;once=[False]
                def close_after_cancel(fd):
                    if fd==target and not once[0]:
                        once[0]=True;close_attempts.append(fd);closing(fd);raise OSError(5,'secondary after real cancellation')
                    return closing(fd)
                os.close=close_after_cancel
            try:
                try:assembly.close(caught)
                except BaseException as error:assert error is caught
            finally:os.close=closing
            if C2_case=='register-cancel-close':assert close_attempts==[target] and assembly.failure is caught
            for item in inputs_held:item.close()
            if seed_parent is not None:seed_parent.close()
            print(json.dumps({'C2_case':C2_case,'failure':type(caught).__name__,'partial_files':list(assembly.files),
                'writer_close_attempts':close_attempts,'same_first_cancel':bool(cancellations) and caught is cancellations[0],'work':assembly.work,'full_seed':False},sort_keys=True))
        else:
            assert caught is None, 'four original input copies failed'
            assert set(assembly.files)==set(names) and set(assembly.semantic)==set(names)
            for name,item in zip(names,inputs_held):assert (seed/name).read_bytes()==item.raw
            binding={'attempt_id':input_values[1]['id'],'outer_request_sha256':c.digest(inputs_held[1].raw)}
            assembly.occurrences['reproduction']={'role':'reproduction','binding':binding,'raw':{}}
            runtime_name=next(iter(copied_inventory.runtime_sha256))
            member=copied_inventory.members[runtime_name]
            assembly._semantic_copy(anchor,member,'reproduction-runtime.bin',native_digest,'runtime',
                'reproduction','capture',copied_inventory.directory.components[-1].name+'/'+runtime_name)
            for item in inputs_held:item.close()
            assembly.close()
            assert assembly.root is None and not assembly.output_holds
            loads=replay.json.loads;processed=assembly._wrapper_processed;encoder=c.json.JSONEncoder
            transfer=c._capture_transfer_work;account=c._capture_account
            baseline={key:copy.deepcopy(value) for key,value in assembly.work.items() if key in ('read_bytes','seed_processing','accounting','accounting_rows')}
            original_window=assembly.window;original_case=assembly.case_work
            target_before=[copy.deepcopy({key:value for key,value in target.items() if key in ('read_bytes','seed_processing','accounting','accounting_rows')}) for target in (original_window,original_case)]
            transfer_entries=[]
            def transferring(source,window,case):
                if source is assembly.work:
                    transfer_entries.append({'read_bytes':source['read_bytes'],'watermark':source.get('transferred_read_bytes',0)})
                    if C2_case=='cancel-transfer':
                        try:actual_handler['cancel'](15,None)
                        except InterruptedError as error:cancellations.append(error);raise
                return transfer(source,window,case)
            secondary=OSError(5,'controlled partial category transfer')
            def accounted(target,kind,field,amount):
                if C2_case=='partial-transfer' and target is original_case and kind=='M' and field=='read_bytes' and amount:
                    raise secondary
                return account(target,kind,field,amount)
            def parsed(raw,*args,**kwargs):
                if inspect.currentframe().f_back.f_code is replay._SeedAssembly._closed_inventory_core_data.__code__:
                    if C2_case in ('parse','partial-transfer'):raise fault
                    value=loads(raw,*args,**kwargs)
                    if C2_case=='compare':value['case_id']='changed'
                    return value
                return loads(raw,*args,**kwargs)
            cancel_armed=[True]
            class Partial(encoder):
                def iterencode(self,value,*args,**kwargs):
                    for index,piece in enumerate(super().iterencode(value,*args,**kwargs)):
                        yield piece
                        if C2_case=='encode' and index==4:raise fault
                        if C2_case=='cancel-transfer' and index==4 and cancel_armed[0]:
                            cancel_armed[0]=False
                            try:actual_handler['cancel'](15,None)
                            except InterruptedError as error:cancellations.append(error);raise
            replay.json.loads=parsed;c.json.JSONEncoder=Partial
            c._capture_transfer_work=transferring;c._capture_account=accounted
            try:
                try:result=assembly._closed_inventory_core_data()
                except BaseException as error:caught=error
            finally:
                replay.json.loads=loads;c.json.JSONEncoder=encoder
                c._capture_transfer_work=transfer;c._capture_account=account
            if C2_case in ('normal','encode','parse','compare'):
                for target,target_previous in zip((original_window,original_case),target_before):
                    assert target['read_bytes']-target_previous['read_bytes']==assembly.work['read_bytes']-baseline['read_bytes'], 'postclose delta absent from original target'
                    for key,value in assembly.work.get('seed_processing',{}).items():
                        assert target.get('seed_processing',{}).get(key,0)-target_previous.get('seed_processing',{}).get(key,0)==value-baseline.get('seed_processing',{}).get(key,0)
                    for kind,values in assembly.work.get('accounting',{}).items():
                        for key,value in values.items():
                            assert target.get('accounting',{}).get(kind,{}).get(key,0)-target_previous.get('accounting',{}).get(kind,{}).get(key,0)==value-baseline.get('accounting',{}).get(kind,{}).get(key,0)
                    assert target.get('accounting_rows',[])[len(target_previous.get('accounting_rows',[])):]==assembly.work.get('accounting_rows',[])[len(baseline.get('accounting_rows',[])):]
                    if C2_case!='normal':
                        assert target['inventory_incomplete'] and target['seed_incomplete']
                        assert any(row['field']=='metadata_failure' for row in target['leaf_failures'])
                    if C2_case=='parse':assert target['inventory_parse_incomplete']
                assert assembly.work['transferred_read_bytes']==assembly.work['read_bytes']
                transferred=copy.deepcopy([(target.get('read_bytes'),target.get('seed_processing'),target.get('accounting'),len(target.get('accounting_rows',[]))) for target in (original_window,original_case)])
                if C2_case=='normal':assembly._transfer()
                else:assembly.close()
                assert transferred==[(target.get('read_bytes'),target.get('seed_processing'),target.get('accounting'),len(target.get('accounting_rows',[]))) for target in (original_window,original_case)]
            if C2_case in ('cancel-transfer','partial-transfer'):
                assert len(transfer_entries)==1 and assembly.work['transfer_incomplete']
                assert all(target['transfer_incomplete'] for target in (original_window,original_case))
                if C2_case=='cancel-transfer':
                    assert len(cancellations)==2 and cancellations[0] is not cancellations[1]
                    assert caught is cancellations[0] and assembly.failure is caught
                    assert all(target['read_bytes']==target_previous['read_bytes'] for target,target_previous in zip((original_window,original_case),target_before))
                    assert assembly.work['transferred_read_bytes']==baseline['read_bytes']
                else:
                    assert caught is fault and assembly.failure is fault
                    entry=transfer_entries[0]
                    assert all(target['read_bytes']-target_previous['read_bytes']==entry['read_bytes']-entry['watermark'] for target,target_previous in zip((original_window,original_case),target_before))
                    assert assembly.work['transferred_read_bytes']==entry['read_bytes']<assembly.work['read_bytes']
                    assert any(row['site']=='seed-transfer' and row['value'].get('errno')==5 for row in assembly.work['accounting_rows'])
            if C2_case=='normal':
                assert caught is None and len(result['inventory_core']['entries'])==5
                assert c.digest(c.canonical(result['inventory_core']))==result['sha256']
                failures=[]
                labels=('both-sha',) if C2_mutation=='source-seal' else ('both-kind',) if C2_mutation=='kind-seal' else ('missing','unused','member','role','size-bool','both-size','both-sha','both-kind','original-kind','cross-binding','cap')
                for label in labels:
                    files,semantic,expected,originals,occurrences=copy.deepcopy((assembly.files,assembly.semantic,assembly.semantic_expected,assembly.original_bindings,assembly.occurrences))
                    if label=='missing':semantic.pop('incident.json')
                    elif label=='unused':files['unused.bin']=dict(files['incident.json'])
                    elif label=='member':semantic['incident.json']['member']='gate-request.json'
                    elif label=='role':semantic['incident.json']['role']=files['incident.json']['kind']
                    elif label=='size-bool':semantic['incident.json']['size_bytes']=True
                    elif label=='both-size':files['incident.json']['size_bytes']+=1;semantic['incident.json']['size_bytes']+=1
                    elif label=='both-sha':files['reproduction-runtime.bin']['sha256']='f'*64;semantic['reproduction-runtime.bin']['sha256']='f'*64
                    elif label=='both-kind':files['reproduction-runtime.bin']['kind']='M';semantic['reproduction-runtime.bin']['kind']='M'
                    elif label=='original-kind':originals['incident.json']['kind']='shadow_write_request'
                    elif label=='cross-binding':occurrences['reproduction']['binding']['outer_request_sha256']='f'*64
                    else:
                        for index in range(257):files['extra'+str(index)]=dict(files['incident.json'])
                    try:replay._S_inventory_core_values(assembly.case_id,files,semantic,expected,originals,occurrences)
                    except (ValueError,TypeError,KeyError):failures.append(label)
                    else:raise AssertionError('semantic inventory admitted '+label)
                try:assembly.closed_inventory_core()
                except ValueError:pass
                else:raise AssertionError('partial data accepted as closed qualified case')
                if C2_window:
                    try:
                        operation=window_custody.mkdir(window_operations,'0')
                        installed=window_custody.mkdir(operation,'I')
                        target=window_custody.mkdir(installed,assembly.case_id)
                        parent=next(item for item in window_custody.owned if item.components and item.path==str(seed.parent))
                        current=window_custody.adopt(c._open_child(parent,'S',True,c._store_rule(uid,gid,0o700,True,anchor.resolver),'E_STORE',recording_work=window_caller.work,accounting_kind='M'))
                        before_scope=window_caller.fixed['c2_counters'](anchor.recording_work)
                        total=window_caller.fixed['c2_fresh_work']('C2-case-total-fixture')
                        leaf=window_caller.fixed['c2_fresh_work']('C2-case-copy-fixture')
                        window_caller.work['C2_case_totals']={assembly.case_id:total}
                        window_caller.work['C2_case_leaves']={assembly.case_id:leaf}
                        copied=window_caller.fixed['C2Copies'](window_custody,leaf,total,before_scope['window'],before_scope['cases'][assembly.case_id])
                        for entry in result['inventory_core']['entries']:
                            source=window_custody.adopt(c._open_child(current,entry['file'],False,c._store_rule(uid,gid,0o400,False,anchor.resolver),'E_STORE',recording_work=window_caller.work,accounting_kind='M'))
                            copied.copy(source,target,entry['file'],entry['size_bytes'],entry['sha256'],entry['kind'])
                        copied.final_checks();copied.transfer_cases()
                        window_caller.transfer()
                    finally:
                        window_custody.close();copied.transfer_cases();window_caller.transfer()
                    assert not window_caller.held.components and len(copied.pairs)==5
                    print(json.dumps({'C2_original_C1_caller_window':True,'full_seed':False,'no_window_descriptor_fabricated':True,
                        'original_S_closed_before_reacquisition':assembly.root is None,'actual_S_to_I_files':len(copied.pairs),
                        'work':window_caller.fixed['c2_counters'](window_caller.work)},sort_keys=True))
                print(json.dumps({'C2_case':C2_case,'entries':result['inventory_core']['entries'],'binding_negatives':failures,
                    'post_close_no_root':True,'actual_four_input_copies':True,'actual_one_P_runtime_copy':True,
                    'composition_occurrence_only':True,'full_seed':False,'work':assembly.work},sort_keys=True))
            else:
                assert caught is not None and assembly.failure is caught and assembly.work['inventory_incomplete']
                if C2_case in ('encode','parse','partial-transfer'):assert caught is fault
                if C2_case=='parse':assert assembly.work['inventory_parse_attempt_bytes']>0 and assembly.work['inventory_parse_unknown']
                print(json.dumps({'C2_case':C2_case,'failure':type(caught).__name__,'incomplete':True,'work':assembly.work,
                    'original_targets':[{key:target[key] for key in ('read_bytes','write_bytes','physical_bytes','files','seed_processing','accounting','leaf_failures','transfer_incomplete','inventory_incomplete','seed_incomplete','inventory_parse_incomplete') if key in target} for target in (original_window,original_case)],
                    'target_before':[{key:value for key,value in row.items() if key!='accounting_rows'} for row in target_before],
                    'leaf_before':{key:value for key,value in baseline.items() if key!='accounting_rows'},
                    'target_new_rows':[target.get('accounting_rows',[])[len(prior.get('accounting_rows',[])):] for target,prior in zip((original_window,original_case),target_before)],
                    'transfer_entries':transfer_entries,'same_first_cancel':bool(cancellations) and caught is cancellations[0],'full_seed':False},sort_keys=True))
            if seed_parent is not None:seed_parent.close()
'''
    for case in (selected or ('normal','source-drift','registration','copy-close','register-cancel-close','encode','parse','compare','cancel-transfer','partial-transfer')):
        namespace={'C2_case':case,'C2_mutation':mutation,'C2_window':window,'C2_caller_class':_C2FixtureCaller};argv=sys.argv;sys.argv=['C2-inventory-fixture',str(root)];primary=None
        try:exec(compile(prefix+extra+footer,'<actual-C2-inventory>','exec'),namespace)
        except BaseException as error:
            primary=error
            if mutation and 'assembly' in namespace:
                print(json.dumps({'C2_mutation':mutation,'actual_work':namespace['assembly'].work,'full_seed':False},sort_keys=True))
            raise
        finally:
            sys.argv=argv
            ephemeral=namespace.get('ephemeral')
            if ephemeral is not None:
                try:
                    ephemeral.rmdir()
                    caller=namespace.get('window_caller')
                    if caller is not None:
                        caller.observe('C2.ephemeral-parent-remove-after-holds',{'path':str(ephemeral),'return':0})
                        caller.transfer()
                except BaseException as closing:
                    if primary is None or getattr(closing,'_scope_signal_cancel',False) and not getattr(primary,'_scope_signal_cancel',False):raise
                    namespace.setdefault('C2_ephemeral_close_errors',[]).append(closing)


def raw16_C2_inventory_deletion(root: Path) -> None:
    for mutation,marker in (('copy','four original input copies failed'),('source-seal','semantic inventory admitted both-sha'),('kind-seal','semantic inventory admitted both-kind')):
        try:raw16_C2_inventory_inputs(root,('normal',),mutation=mutation)
        except AssertionError as error:assert str(error)==marker
        else:raise AssertionError('C2 deletion not detected: '+mutation)
    print(json.dumps({'C2_actual_original_copy_deletion_detected':True,'C2_initial_source_seal_deletion_detected':True,'C2_initial_kind_seal_deletion_detected':True}))


class _C2FixtureCaller:
    """Fixed ordinary caller; the root and its original ledger remain live here."""
    def __init__(self, root: Path, held, window_work, case_work):
        import shlex
        owner = sys.modules[type(held).__module__]
        assert type(held) is owner.HeldPath
        assert Path(owner.__file__) == root/'shadow/v1/_consumer.py'
        launcher = (root/'evals/v1/evals-launcher.sh').read_text()
        literal = shlex.split(launcher.split('c2_program=', 1)[1].split('\nc2_fd9=', 1)[0])[0]
        self.fixed = {'__name__': '_C2_fixture_fixed_launcher', '__file__': str(root/'evals/v1/evals-launcher.sh'), 'c': owner}
        exec(compile(literal, self.fixed['__file__']+':fixed-C2', 'exec'), self.fixed)
        self.owner, self.root, self.held = owner, root, held
        self.window_work, self.case_work = window_work, case_work
        self.bindings = window_work.setdefault('C2_case_bindings',{})
        new_common='C2/session' not in window_work.get('cases',{})
        self.common_case = owner._capture_work_values(window_work,'C2/session')
        if new_common:
            for key,value in self.fixed['c2_fresh_work']('C2/session').items():self.common_case.setdefault(key,value)
        window_work['C2_common_case']=self.common_case
        self.caller_state, self.child_state = {}, {}
        self.work = self.fixed['c2_fresh_work']('C2-caller')
        self.ordinal, self.head, self.window_sha = 0, None, None
        self.pending, self.failed = False, False
        self.receipts = []
        self.child_work = None
        self.reconstructed = []
    def transfer(self):
        self._settle_scoped(self.fixed['c2_counters'](self.work),self.caller_state)
        assert not self.work.get('C2_calls_transfer_incomplete')
        previous=self.work.setdefault('C2_transferred_calls',{})
        try:
            for name,amount in self.work.get('calls',{}).items():
                prior=previous.get(name,0);assert type(amount) is int and 0<=prior<=amount
                for target in (self.window_work,self.common_case):
                    counts=target.setdefault('calls',{});counts[name]=counts.get(name,0)+amount-prior
                previous[name]=amount
        except BaseException:
            for target in (self.work,self.window_work,self.common_case):target['C2_calls_transfer_incomplete']=True
            raise
    def observe(self, site, value):
        self.owner._capture_observe(self.work,'M',site,value)
    def _transfer_view(self, value, state, key, target):
        if key not in state:state[key]=self.fixed['c2_fresh_work']('C2-transfer-'+key)
        leaf=state[key]
        for field in self.fixed['_C2_SCALARS']:
            amount=value[field]
            assert type(amount) is int and amount>=leaf[field]
            leaf[field]=amount
        for name in ('runtime','accounting','seed_processing'):leaf[name]=value[name]
        for flag in value['incomplete']:leaf[flag]=True
        if 'ledgers' in value:
            ledgers=value['ledgers']
            assert type(ledgers) is list
            for ledger in ledgers:self.owner._c3_ledger_check(ledger)
            if ledgers:
                named=self.owner._c3_values_sum([row['values'] for row in ledgers])
                assert all(named[field]==value[field] for field in self.fixed['_C2_SCALARS'])
                assert all(named[group]==value[group] for group in ('runtime','accounting','seed_processing'))
            leaf['accounting_rows']=[row for ledger in ledgers for row in ledger['observations']]
            leaf['calls']={}
            for ledger in ledgers:
                for name,amount in ledger['calls'].items():leaf['calls'][name]=leaf['calls'].get(name,0)+amount
            previous=leaf.setdefault('C2_transferred_ledger_calls',{})
            for name,amount in leaf['calls'].items():
                prior=previous.get(name,0);assert type(prior) is int and 0<=prior<=amount
                for counter in (self.window_work,target):
                    counts=counter.setdefault('calls',{});counts[name]=counts.get(name,0)+amount-prior
                previous[name]=amount
            for counter in (self.window_work,target):
                counter.setdefault('C2_scope_ledger_cutoffs',{})[key]=ledgers
        self.owner._capture_transfer_work(leaf,self.window_work,target)
        previous=leaf.setdefault('transferred_seed_processing',{})
        for field,amount in leaf['seed_processing'].items():
            prior=previous.get(field,0);assert type(amount) is int and 0<=prior<=amount
            for counter in (self.window_work,target):
                values=counter.setdefault('seed_processing',{});values[field]=values.get(field,0)+amount-prior
            previous[field]=amount
        if value['unknown']:
            for counter in (self.window_work,target):
                counter['C2_work_unknown']=value['unknown'];counter['C2_accounting_incomplete']=True
    def _settle_scoped(self, value, state):
        assert set(value)=={'window','cases','common'} and set(value['cases'])<=set(self.bindings)
        self.window_work['C2_observed_child_window']=value['window']
        for identity,view in value['cases'].items():
            primary,rows=self.bindings[identity]
            assert any(primary is row for row in rows)
            assert any(primary is row for row in self.window_work['cases'].values())
            self._transfer_view(view,state,identity,primary)
        self._transfer_view(value['common'],state,'session',self.common_case)
        if 'source' in value['window']:
            self.window_work.setdefault('C2_source_counter_cutoffs',[]).append(value['window']['source'])
            self.common_case.setdefault('C2_source_counter_cutoffs',[]).append(value['window']['source'])
    def settle_child(self, value):
        self._settle_scoped(value,self.child_state)
    def reconstruct_tail(self, end, done):
        values=done[4:-1]
        assert len(values)==50 and all(value==0 for value in values[11:20]) and all(value==0 for value in values[-6:])
        tail=self.fixed['c2_fresh_work']('C2-terminal')
        for target in (self.window_work,self.common_case):
            counts=target.setdefault('calls',{});counts['consumer-json-buffer']=counts.get('consumer-json-buffer',0)+3
        cursor=iter(values)
        for field in self.fixed['_C2_SCALARS']:tail[field]=next(cursor)
        for field in self.owner._RUNTIME_FIELDS:tail['runtime'][field]=next(cursor)
        for kind in self.fixed['_C2_CLASSES']:
            for field in self.fixed['_C2_ACCOUNT_FIELDS']:tail['accounting'][kind][field]=next(cursor)
        tail['accounting']['M']['logical_bytes']+=512;tail['accounting']['M']['occurrences']+=1
        tail['write_bytes']+=512;tail['accounting']['M']['write_bytes']+=512
        tail['seed_processing']['W']=tail['seed_processing']['C']=values[1]+512
        ordinal=end['child_delta']['window']['observation_calls']+values[10]
        for index,site in enumerate(('C2.stdout','C2.stderr','C2.control'),1):
            row={'owner':'C2-terminal','ordinal':ordinal+index,'kind':'M','site':'close',
                'value':{'site':site,'return':0,'errno':None}}
            raw=self.fixed['C2Channel'](None,self.work).encode(row)
            size=len(raw)
            tail['read_bytes']+=3*size-2;tail['accounting']['M']['read_bytes']+=3*size-2
            tail['accounting']['M']['logical_bytes']+=size;tail['accounting']['M']['occurrences']+=1
            tail['close_calls']+=1;tail['observation_calls']+=1
            self.reconstructed.append({'basis':'fixed END/DONE/EOF/wait=0 schedule','row':row,'raw':raw})
        return tail
    def _receive_charge(self, raw):
        self.work['read_bytes'] += len(raw)
        self.owner._capture_account(self.work, 'M', 'read_bytes', len(raw))
        self.work['seed_processing']['R'] += len(raw)
    def _parse(self, raw, kind):
        self.work['C2_parse_unknown'] = True
        value = json.loads(raw)
        self._receive_charge(raw)
        self.work['C2_parse_unknown'] = False
        channel = self.fixed['C2Channel'](None, self.work)
        rebuilt = channel.encode(value)
        equal = raw == rebuilt
        self._receive_charge(raw);self._receive_charge(rebuilt)
        assert equal
        return self.fixed['c2_message'](value, kind)
    def bind_window(self, custody, descriptor):
        assert custody.root is self.held and not self.pending and self.head is None
        self.window_sha = self.fixed['c2_write_document'](custody, self.held, 'window.json', descriptor)
        self.head = self.window_sha
        self.transfer()
    def invoke(self, arguments, case_ids, reservation):
        import fcntl, socket
        assert not self.pending and not self.failed and self.head is not None
        mode, parent, paths = self.fixed['c2_cli'](arguments)
        assert parent == self.held.path and self.ordinal < 4
        self.transfer()
        before = self.fixed['c2_counters'](self.window_work, ledger=True, codec_work=self.work)
        budget_before={key:dict(before[key]) for key in ('window','common')}
        previous=self.caller_state.get('session',{})
        for scope in budget_before.values():
            for field in ('read_bytes','write_bytes','physical_bytes','files','export_read_bytes','export_write_bytes','export_physical_bytes','export_files'):
                prior=previous.get('transferred_'+field,0)
                assert type(scope[field]) is int and type(prior) is int and 0<=prior<=scope[field]
                scope[field]-=prior
        budget_before['cases']=before['cases']
        self.work['C2_admitted_before']=budget_before
        self.work['C2_tail_reservation']=reservation
        self.fixed['c2_nonruntime_room'](self.work,0,False)
        self.held.recheck('E_STALE', self.work, 'M')
        assert set(case_ids)<=set(before['cases'])
        self.child_state={}
        caller_before = self.fixed['c2_counters'](self.work, ledger=True)
        hashes = []
        resolver = self.owner._DarwinUUIDResolver() if sys.platform == 'darwin' else None
        custody = self.fixed['c2_clone_root'](self.held, self.work, resolver)
        input_failure=None
        try:
            for path in paths:
                _value, _raw, digest, _item = self.fixed['c2_document'](custody, custody.root, Path(path).name)
                hashes.append(digest)
        except BaseException as error:input_failure=error
        finally:
            try:custody.close(input_failure)
            except BaseException as error:input_failure=self.fixed['c2_first'](input_failure,error)
        if input_failure is not None:raise input_failure
        start = {'kind':'START','version':1,'ordinal':self.ordinal,'window_sha256':self.window_sha,
            'predecessor_sha256':self.head,'mode':mode,'case_ids':list(case_ids),
            'seed_sha256s':hashes if mode=='run' else hashes[::2],
            'result_sha256s':[] if mode=='run' else hashes[1::2],
            'root_identity':list(self.owner._identity(self.held.before)), 'before':before, 'tail_reservation':reservation}
        self.fixed['c2_message'](start, 'START')
        self.fixed['c2_reserve'](before,reservation)
        owned, sockets, child, first = [], [], None, None
        pending,pending_pair=None,None
        caller_socket=child_socket=None
        stdout, stderr, control = [], [], []
        received = [];phase = 'READY';remaining = 4;pieces = [];end = done = candidate = None
        self.last_attempt={'stdout':stdout,'stderr':stderr,'control':control,'messages':received,'end':None,'done':None,'wait':None}
        self.pending = True
        def close_fd(fd, site):
            owned.remove(fd)
            self.owner._close_capture_copy(fd, self.work, self.work, site, first)
        try:
            caller_socket, child_socket = socket.socketpair();sockets.extend((caller_socket, child_socket))
            pending=fcntl.fcntl(child_socket.fileno(),fcntl.F_DUPFD_CLOEXEC,11)
            owned.append(pending);prepared_control=pending;pending=None
            pending=fcntl.fcntl(self.held.fd,fcntl.F_DUPFD_CLOEXEC,11)
            owned.append(pending);prepared_root=pending;pending=None
            pending=os.open('/dev/null',os.O_RDONLY)
            owned.append(pending);null=pending;pending=None
            pending_pair=os.pipe()
            for fd in pending_pair:owned.append(fd)
            out_r,out_w=pending_pair;pending_pair=None
            pending_pair=os.pipe()
            for fd in pending_pair:owned.append(fd)
            err_r,err_w=pending_pair;pending_pair=None
            known = {item.fd for item in self.held.components} | set(owned) | {caller_socket.fileno(), child_socket.fileno()}
            actions = [(os.POSIX_SPAWN_DUP2,null,0),(os.POSIX_SPAWN_DUP2,out_w,1),(os.POSIX_SPAWN_DUP2,err_w,2),
                (os.POSIX_SPAWN_DUP2,prepared_control,9),(os.POSIX_SPAWN_DUP2,prepared_root,10)]
            actions.extend((os.POSIX_SPAWN_CLOSE,fd) for fd in sorted(known) if fd not in {0,1,2,9,10})
            argv = ['/bin/bash',str(self.root/'evals/v1/run-evals.sh'),*arguments]
            child = os.posix_spawn('/bin/bash',argv,{'LC_ALL':'C','PATH':'/usr/bin:/bin','TMPDIR':os.environ['TMPDIR']},file_actions=actions)
            self.observe('C2.caller-spawn',{'pid':child,'actions':actions})
            child_socket.close();sockets.remove(child_socket)
            self.observe('C2.caller-child-socket-close',{'return':0})
            for fd in (prepared_control,prepared_root,null,out_w,err_w):close_fd(fd,'C2.caller-prepared-close')
            channel = self.fixed['C2Channel'](caller_socket.fileno(),self.work)
            start_raw,_sent = channel.send(start)
            with selectors.DefaultSelector() as selected:
                selected.register(caller_socket,selectors.EVENT_READ,'control')
                selected.register(out_r,selectors.EVENT_READ,'stdout');selected.register(err_r,selectors.EVENT_READ,'stderr')
                lengths = {'stdout':0,'stderr':0,'control':0}
                while selected.get_map():
                    for key,_events in selected.select():
                        stream = key.data
                        amount = min(CHUNK,remaining) if stream=='control' else min(CHUNK,1048577-lengths[stream])
                        assert amount > 0
                        self.owner._capture_copy_room(self.work,amount,False,read_only=True)
                        raw = os.read(key.fd,amount)
                        self._receive_charge(raw);lengths[stream] += len(raw)
                        if not raw:
                            selected.unregister(key.fileobj)
                            if stream=='control':assert phase=='EOF'
                            continue
                        if stream!='control':
                            assert lengths[stream]<=1048576
                            (stdout if stream=='stdout' else stderr).append(raw)
                            continue
                        control.append(raw);pieces.append(raw);remaining -= len(raw)
                        if remaining:continue
                        value_raw = b''.join(pieces);self._receive_charge(value_raw);pieces=[]
                        if phase in {'READY','END'}:
                            size = struct.unpack('>I',value_raw)[0]
                            assert 0<size<=1048576
                            remaining=size;phase+='-body';continue
                        if phase=='READY-body':
                            ready=self._parse(value_raw,'READY');received.append(('READY',value_raw))
                            assert ready['ordinal']==self.ordinal and ready['start_sha256']==self.fixed['c2_sha'](start_raw,self.work)
                            assert ready['leaf_pid']==child and ready['leaf_ppid']==os.getpid()
                            assert ready['input_sha256s']==hashes and ready['observed_predecessor_sha256']==self.head
                            self.held.recheck('E_STALE',self.work,'M')
                            self.settle_child(ready['acquisition_delta'])
                            self.transfer()
                            self.fixed['c2_reserve'](self.fixed['c2_counters'](self.window_work),reservation)
                            go={'kind':'GO','version':1,'ordinal':self.ordinal,'start_sha256':self.fixed['c2_sha'](start_raw,self.work),
                                'ready_sha256':self.fixed['c2_sha'](value_raw,self.work),'caller_delta':self.fixed['c2_delta'](self.fixed['c2_counters'](self.work, ledger=True),caller_before),
                                'tail_reservation':reservation}
                            channel.send(go)
                            phase='END';remaining=4
                        elif phase=='END-body':
                            end=self._parse(value_raw,'END');received.append(('END',value_raw));self.last_attempt['end']=end
                            assert end['ordinal']==self.ordinal and end['start_sha256']==self.fixed['c2_sha'](start_raw,self.work)
                            self.settle_child(end['child_delta'])
                            phase='DONE';remaining=512
                        elif phase=='DONE':
                            done=struct.unpack('>8s53Q80s',value_raw);self.last_attempt['done']=done
                            assert done[0]==b'YC2DONE1' and done[1]==self.ordinal and done[-1]==bytes(80)
                            assert done[2]==len(received[-1][1]) and done[3]==done[2]+4
                            phase='EOF';remaining=1
                        else:raise AssertionError('C2 trailing control bytes')
            waited,status=os.waitpid(child,0);expected_child=child;child=None
            self.last_attempt['wait']=status
            self.observe('C2.caller-wait',{'pid':waited,'status':status})
            assert waited==expected_child
            output,error=b''.join(stdout),b''.join(stderr)
            self._receive_charge(output);self._receive_charge(error)
            assert status==0 and end is not None and done is not None and phase=='EOF'
            assert (end['outcome']=='refused')==(end['result_sha256'] is None)
            assert end['outcome']!='completed' or not error and self.fixed['c2_sha'](output,self.work)==end['result_sha256']
            receipt={'end':end,'done':done,'stdout':output,'stderr':error,'control':control,'wait':status}
            self.receipts.append(receipt)
            tail=self.reconstruct_tail(end,done)
            combined_raw=self.fixed['C2Channel'](None,self.work).encode(end['child_delta'])
            self.work['C2_merge_parse_incomplete']=True
            combined=json.loads(combined_raw);self._receive_charge(combined_raw)
            self.work['C2_merge_parse_incomplete']=False
            for field in self.fixed['_C2_SCALARS']:
                combined['window'][field]+=tail[field];combined['common'][field]+=tail[field]
            for kind in self.fixed['_C2_CLASSES']:
                for field in self.fixed['_C2_ACCOUNT_FIELDS']:
                    combined['window']['accounting'][kind][field]+=tail['accounting'][kind][field]
                    combined['common']['accounting'][kind][field]+=tail['accounting'][kind][field]
            for field,amount in tail['seed_processing'].items():
                combined['window']['seed_processing'][field]+=amount;combined['common']['seed_processing'][field]+=amount
            self.settle_child(combined)
            candidate=receipt
        except BaseException as error:
            first=error;self.failed=True
            for target in (self.window_work,self.common_case):
                target['C2_child_tail_unknown']=True
                target['C2_accounting_incomplete']=True
        finally:
            if child is not None:
                try:
                    os.kill(child,signal.SIGTERM)
                    waited,status=os.waitpid(child,0);child=None
                    self.last_attempt['wait']=status
                    self.observe('C2.caller-failed-wait',{'pid':waited,'status':status})
                except BaseException as error:first=self.fixed['c2_first'](first,error)
            for fd in ((pending,) if pending is not None else ())+(pending_pair or ()):
                if fd not in owned:
                    try:self.owner._close_capture_copy(fd,self.work,self.work,'C2.caller-pending-close',first)
                    except BaseException as error:first=self.fixed['c2_first'](first,error)
            for fd in reversed(owned[:]):
                try:close_fd(fd,'C2.caller-tail-close')
                except BaseException as error:first=self.fixed['c2_first'](first,error)
            for value in (child_socket,caller_socket):
                if value is None or value._closed:continue
                try:
                    value.close();self.observe('C2.caller-control-close',{'return':0})
                except BaseException as error:first=self.fixed['c2_first'](first,error)
            try:self.transfer()
            except BaseException as error:first=self.fixed['c2_first'](first,error)
            if first is not None:raise first
        assert candidate is not None
        self.held.recheck('E_STALE',self.work,'M')
        self.transfer()
        end=candidate['end']
        assert end['outcome']=='completed' and not end['errors'] and not end['unknown']
        assert not self.owner._capture_work_incomplete(self.window_work)
        self.head=end['receipt_sha256'];self.ordinal+=1;self.pending=False
        return candidate


def raw16_C2_lifecycle_core(root: Path, selected=None, mutation=None) -> None:
    import ast, copy, inspect, shlex, socket, tempfile, textwrap
    consumer_path=root/'shadow/v1/_consumer.py'
    spec=importlib.util.spec_from_file_location('_raw16_C2_core_consumer',consumer_path)
    consumer=importlib.util.module_from_spec(spec);sys.modules[spec.name]=consumer;spec.loader.exec_module(consumer)
    launcher=(root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(launcher.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_raw16_C2_core','c':consumer};exec(compile(literal,str(root/'evals/v1/evals-launcher.sh')+':C2','exec'),fixed)
    if mutation=='length':
        tree=ast.parse(literal)
        cls=next(node for node in tree.body if isinstance(node,ast.ClassDef) and node.name=='C2Copies')
        method=next(node for node in cls.body if isinstance(node,ast.FunctionDef) and node.name=='copy')
        source=textwrap.dedent(ast.get_source_segment(literal,method))
        guard='c2_require(installed.before.st_size == size, "E_STALE")'
        assert source.count(guard)==1;source=source.replace(guard,'None')
        changed={};exec(compile(source,'<C2-installed-length-deletion>','exec'),fixed,changed)
        fixed['C2Copies'].copy=changed['copy']
    cases=selected or ('normal','extra-name','target-drift','same-bytes-drift','tail-before-acquire','close-observer','ordinary-eintr')
    for label in cases:
        with tempfile.TemporaryDirectory(prefix='raw16-C2-held.') as temp:
            base=Path(temp);window=base/'window';window.mkdir(mode=0o700)
            raw=b'synthetic-runtime\0'*8192;source_path=base/'source';source_path.write_bytes(raw);source_path.chmod(0o400)
            resolver=consumer._DarwinUUIDResolver() if sys.platform=='darwin' else None
            work=fixed['c2_fresh_work']('C2-core-fixture')
            held=consumer._open_held(str(window),True,consumer._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STORE',recording_work=work,accounting_kind='M')
            custody=fixed['C2Root'](held,work,resolver)
            source=consumer._open_held(str(source_path),False,consumer._store_rule(os.geteuid(),os.getegid(),0o400,False,resolver),'E_STORE',recording_work=work,accounting_kind='M')
            copied=None;error=None;closed=[];original_close=os.close;original_open=consumer._open_child;original_observe=consumer._capture_observe
            copy=fixed['C2Copies'](custody)
            def target_open(parent,name,directory,*args,**kwargs):
                if label=='tail-before-acquire' and name=='runtime.bin' and not directory:
                    path=Path(parent.path)/name;path.chmod(0o600)
                    with path.open('ab') as output:assert output.write(b'TAIL')==4
                    path.chmod(0o400)
                return original_open(parent,name,directory,*args,**kwargs)
            try:
                destinations,operations=custody.layout()
                assert set(destinations)==fixed['_C2_CASES'] and all(not custody.namespace(row) for row in destinations.values())
                operation=custody.mkdir(operations,'0');installed=custody.mkdir(operation,'I')
                case=custody.mkdir(installed,'malicious.checked-file-bytes')
                consumer._open_child=target_open
                if label=='ordinary-eintr':
                    def read_error(*_args):raise InterruptedError(errno.EINTR,'controlled ordinary byte read failure')
                    original_pread=os.pread;os.pread=read_error
                try:copied=copy.copy(source,case,'runtime.bin',len(raw),hashlib.sha256(raw).hexdigest(),'runtime')
                finally:
                    consumer._open_child=original_open
                    if label=='ordinary-eintr':os.pread=original_pread
                if label=='tail-before-acquire':raise AssertionError('C2 copy accepted installed tail')
                if label=='extra-name':os.mkdir('1',mode=0o700,dir_fd=operations.fd)
                if label in {'target-drift','same-bytes-drift'}:
                    Path(copied.path).chmod(0o600)
                    if label=='same-bytes-drift':
                        for path in (Path(source.path),Path(copied.path)):
                            path.chmod(0o600)
                            with path.open('r+b') as output:assert output.write(b'changed')==7
                            path.chmod(0o400)
                    else:Path(copied.path).chmod(0o400)
                copy.final_checks()
                if label not in {'normal','close-observer'}:raise AssertionError('C2 held identity drift admitted')
                if label=='normal':
                    amount=len(raw);counts=work['runtime']
                    assert (counts['read_bytes'],counts['write_bytes'],counts['sha_bytes'],counts['equality_bytes'],counts['copy_bytes'])==(6*amount,amount,3*amount,4*amount,amount)
                    # Coordinator acquisition/origin add the remaining two reads/hashes later; they were not executed here.
                    assert counts['physical_files']==1 and counts['physical_bytes']==amount
                if label=='close-observer':
                    def failing_observer(counter,kind,site,*args,**kwargs):
                        if site=='held-close':raise MemoryError('controlled final close accounting')
                        return original_observe(counter,kind,site,*args,**kwargs)
                    consumer._capture_observe=failing_observer
            except BaseException as caught:
                error=caught
            finally:
                watched={component.fd for item in custody.owned for component in item.components}
                def close_fd(fd):
                    if fd in watched:closed.append(fd)
                    return original_close(fd)
                os.close=close_fd
                try:
                    try:custody.close(error)
                    except BaseException as closing:error=fixed['c2_first'](error,closing)
                finally:
                    os.close=original_close;consumer._capture_observe=original_observe;consumer._open_child=original_open
                    source.close()
            assert len(closed)==len(set(closed))==len(watched)
            if label=='normal':assert error is None
            elif label=='close-observer':assert error is not None and consumer._capture_work_incomplete(work)
            elif label=='ordinary-eintr':assert isinstance(error,InterruptedError) and not fixed['c2_cancelled'](error)
            else:assert error is not None and not isinstance(error,AssertionError)
            print(json.dumps({'case':label,'error':None if error is None else {'category':type(error).__name__,'errno':getattr(error,'errno',None)},
                'once_closed':len(closed),'read_bytes':work['read_bytes'],'metadata':work['accounting']['M'],
                'runtime':work['runtime'],'seed_processing':work['seed_processing'],
                'incomplete':{key:value for key,value in work.items() if key.endswith('incomplete') and value}},sort_keys=True))
    if mutation is not None:return
    # Fixed codec operates on actual socket bytes. No driver or expected result is substituted.
    work=fixed['c2_fresh_work']('C2-codec-fixture')
    left,right=socket.socketpair()
    try:
        message={'kind':'GO','version':1,'ordinal':0,'start_sha256':'a'*64,'ready_sha256':'b'*64,
            'caller_delta':fixed['c2_counters'](work),'tail_reservation':fixed['c2_counters'](work)}
        sender=fixed['C2Channel'](left.fileno(),work)
        sent,count=sender.send(message)
        received,actual=fixed['C2Channel'](right.fileno(),work).receive('GO')
        assert received==message and actual==sent and count==len(sent)+4
        failures=[]
        for field,value in (('version',True),('ordinal',-1),('kind','END')):
            damaged=dict(message);damaged[field]=value
            try:fixed['c2_message'](damaged,'GO')
            except fixed['C2Refusal']:failures.append(field)
            else:raise AssertionError('C2 closed codec accepted '+field)
        for size in (0,1048577):
            assert os.write(left.fileno(),struct.pack('>I',size))==4
            original_read=os.read;calls=[]
            def traced_read(fd,amount):
                raw=original_read(fd,amount)
                if fd==right.fileno():calls.append((amount,len(raw)))
                return raw
            os.read=traced_read
            try:
                try:fixed['C2Channel'](right.fileno(),work).receive('GO')
                except fixed['C2Refusal'] as error:assert error.code=='E_LIMIT'
                else:raise AssertionError('C2 frame limit bypassed')
            finally:os.read=original_read
            assert calls==[(4,4)]
            failures.append('length-'+str(size))
        print(json.dumps({'case':'codec','failures':failures,'work':fixed['c2_counters'](work)},sort_keys=True))
    finally:left.close();right.close()
    cap=256<<20
    values=[]
    for amount in (cap-5,3,3,0):
        counter=fixed['c2_counters'](fixed['c2_fresh_work']('C2-bounded-counter-only'))
        counter['window']['write_bytes']=amount;counter['window']['accounting']['M']['write_bytes']=amount
        counter['window']['seed_processing']['W']=counter['window']['seed_processing']['C']=amount;values.append(counter)
    admitted=fixed['c2_combine'](values[0],values[1],values[3])
    fixed['c2_reserve'](admitted,values[3])
    assert admitted['window']['write_bytes']==cap-2
    try:fixed['c2_reserve'](fixed['c2_combine'](*values[:3]),values[3])
    except consumer.Refusal as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('C2 combined carry-in/admission exceeded original write cap')
    print(json.dumps({'case':'bounded-carry-in','admitted':cap-2,'refused':cap+1,'actual_large_bytes_written':0}))
    # One descriptor must refuse before platform queries, source acquisition or scratch creation.
    left,right=socket.socketpair();out_r,out_w=os.pipe();err_r,err_w=os.pipe();null=os.open('/dev/null',os.O_RDONLY)
    descriptors=(left.fileno(),right.fileno(),out_r,out_w,err_r,err_w,null)
    actions=[(os.POSIX_SPAWN_DUP2,null,0),(os.POSIX_SPAWN_DUP2,out_w,1),(os.POSIX_SPAWN_DUP2,err_w,2),
        (os.POSIX_SPAWN_DUP2,right.fileno(),9),(os.POSIX_SPAWN_DUP2,null,10),(os.POSIX_SPAWN_CLOSE,10)]
    actions.extend((os.POSIX_SPAWN_CLOSE,fd) for fd in sorted(set(descriptors)) if fd not in {0,1,2,9,10})
    pid=os.posix_spawn('/bin/bash',['/bin/bash',str(root/'evals/v1/run-evals.sh'),'run'],
        {'LC_ALL':'C','PATH':'/usr/bin:/bin','TMPDIR':os.environ['TMPDIR']},file_actions=actions)
    right.close();os.close(out_w);os.close(err_w);os.close(null)
    try:
        output,error=os.read(out_r,1048576),os.read(err_r,1048576)
        waited,status=os.waitpid(pid,0)
        assert waited==pid and status==256 and output==b'' and error==b'E_RUNTIME\n'
        assert left.recv(1)==b''
        print(json.dumps({'case':'one-FD-bootstrap-refusal','pid':pid,'wait':status,'stdout_bytes':len(output),'stderr_hex':error.hex(),'actions':actions},sort_keys=True))
    finally:left.close();os.close(out_r);os.close(err_r)


def raw16_C2_source_tail(root: Path, mutation=False) -> None:
    import shlex, tempfile
    launcher=(root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(launcher.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_raw16_C2_source_tail'};exec(compile(literal,str(root/'evals/v1/evals-launcher.sh')+':C2','exec'),fixed)
    if mutation:
        target='work[target] += delta'
        assert literal.count(target)==1
        altered=literal.replace(target,'None')
        fixed={'__name__':'_raw16_C2_source_tail_deleted'};exec(compile(altered,'<C2-D-transfer-deletion>','exec'),fixed)
    handlers={number:signal.getsignal(number) for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP)}
    sources=None;first=None
    try:
        with tempfile.TemporaryDirectory(prefix='raw16-C2-source-tail.') as area:
            sources=fixed['C2Sources'](str(root/'evals/v1/evals-launcher.sh'),area+'/runtime')
            consumer=sources.load_consumer();work=fixed['c2_fresh_work']('C2-source-tail-fixture')
            sources.reconcile(work)
            before=dict(fixed['c2_counters'](work)['window']['source']);before_scalar=work['close_calls']
            try:os.kill(os.getpid(),signal.SIGTERM)
            except InterruptedError as error:first=error
            else:raise AssertionError('original D handler did not cancel')
            assert first._D_source_cancel and first._scope_signal_cancel
            original_close=os.close;watched={row['fd'] for row in sources.namespace['owned']};closed=[];fault=[]
            def close_fd(fd):
                if fd in watched:
                    closed.append(fd)
                    original_close(fd)
                    if not fault:
                        fault.append(fd);raise OSError(errno.EIO,'controlled D secondary close error')
                    return
                return original_close(fd)
            os.close=close_fd
            try:
                try:sources.close(first)
                except BaseException as error:assert error is first
                else:raise AssertionError('D primary cancellation lost')
            finally:os.close=original_close
            sources.reconcile(work)
            final=fixed['c2_counters'](work)
            assert final['window']['source']['close_calls']-before['close_calls']==len(watched)
            assert work['close_calls']-before_scalar==len(watched)
            assert len(closed)==len(set(closed))==len(watched)
            assert work['read_bytes']==sources.work['read_bytes'] and work['seed_processing']['H']==sources.work['sha_bytes']
            assert any(row[0]=='close' and row[-2:]==[-1,errno.EIO] for row in sources.work['rows'])
            assert any(row.get('site')=='close' and row.get('errno')==errno.EIO for row in final['window']['source']['failures'] if type(row) is dict)
            # The exact source cutoff is what END projects; another original window/case receives its delta once.
            window,case=fixed['c2_fresh_work']('C2-window-fixture'),fixed['c2_fresh_work']('C2-case-fixture')
            caller_path=Path(area)/'caller';caller_path.mkdir(mode=0o700)
            resolver=consumer._DarwinUUIDResolver() if sys.platform=='darwin' else None
            caller_held=consumer._open_held(str(caller_path),True,consumer._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STORE')
            caller=_C2FixtureCaller(root,caller_held,window,case)
            try:
                caller.settle_child(final)
                for field in fixed['_C2_SCALARS']:assert window[field]==caller.common_case.get(field,0)==work[field]
                previous=window['read_bytes'];caller.settle_child(final);assert window['read_bytes']==previous
                assert window['C2_source_counter_cutoffs'][-1]['close_calls']==sources.work['close_calls']
                assert any(row.get('errno')==errno.EIO for row in window['C2_source_counter_cutoffs'][-1]['failures'] if type(row) is dict)
            finally:
                original_observe=consumer._capture_observe;second=[];holder_closed=[]
                holder_fds={component.fd for component in caller_held.components}
                caller_held.recording_work=caller.work;caller_held.accounting_kind='M'
                def observing(counter,kind,site,*args,**kwargs):
                    if site=='held-close' and not second:
                        try:os.kill(os.getpid(),signal.SIGTERM)
                        except InterruptedError as later:
                            second.append(later);raise
                    return original_observe(counter,kind,site,*args,**kwargs)
                def close_holder(fd):
                    if fd in holder_fds:holder_closed.append(fd)
                    return original_close(fd)
                consumer._capture_observe=observing;os.close=close_holder
                try:
                    try:caller_held.close()
                    except BaseException as later:
                        assert second and later is second[0] and later is not first
                        assert later._D_source_cancel and later._scope_signal_cancel
                        assert fixed['c2_first'](first,later) is first
                    else:raise AssertionError('second real consumer close cancellation not observed')
                    assert len(holder_closed)==len(set(holder_closed))==len(holder_fds)
                finally:consumer._capture_observe=original_observe;os.close=original_close
                caller.transfer()
            print(json.dumps({'case':'D-real-signal-tail','first_same_object':True,'consumer_later_cancel_preserved_first':True,'once_closed':len(closed),
                'before_close_calls':before['close_calls'],'after_close_calls':final['window']['source']['close_calls'],
                'source':final['window']['source'],'window_read_bytes':window['read_bytes'],'case_read_bytes':caller.common_case['read_bytes'],
                'source_unknown':work['source_processing_unknown'],'setup_runtime_collection':False},sort_keys=True))
    finally:
        if sources is not None and not sources.closed:
            try:sources.close(first)
            except BaseException:pass
        for number,handler in handlers.items():signal.signal(number,handler)


def raw16_C2_terminal(root: Path, short=False, mutation=False) -> None:
    import shlex,socket
    launcher=(root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(launcher.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    if mutation:
        guard='if result != 512:os._exit(1)'
        assert literal.count(guard)==1;literal=literal.replace(guard,'if False:os._exit(1)')
    # This is a terminal-only real child, not START/READY/GO, driver success, or a valid session.
    suffix='''
import importlib.util
spec=importlib.util.spec_from_file_location("_C2_terminal_consumer",sys.argv[1])
c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
work=c2_fresh_work("C2-terminal")
os.close(0)
'''
    if short:
        suffix+='''original=os.write
def short_write(fd,raw):
    if fd==9:return original(fd,memoryview(raw)[:511])
    return original(fd,raw)
os.write=short_write
'''
    suffix+='c2_terminal(work,0,0,0,c2_vector(work))\n'
    code='__name__="_C2_terminal_only"\n'+literal+suffix
    left,right=socket.socketpair();out_r,out_w=os.pipe();err_r,err_w=os.pipe();null=os.open('/dev/null',os.O_RDONLY)
    descriptors=(left.fileno(),right.fileno(),out_r,out_w,err_r,err_w,null)
    actions=[(os.POSIX_SPAWN_DUP2,null,0),(os.POSIX_SPAWN_DUP2,out_w,1),(os.POSIX_SPAWN_DUP2,err_w,2),(os.POSIX_SPAWN_DUP2,right.fileno(),9)]
    actions.extend((os.POSIX_SPAWN_CLOSE,fd) for fd in sorted(set(descriptors)) if fd not in {0,1,2,9})
    pid=os.posix_spawn('/usr/bin/python3',['/usr/bin/python3','-I','-S','-B','-c',code,str(root/'shadow/v1/_consumer.py')],
        {'LC_ALL':'C','PATH':'/usr/bin:/bin','TMPDIR':os.environ['TMPDIR']},file_actions=actions)
    right.close();os.close(out_w);os.close(err_w);os.close(null)
    try:
        chunks=[]
        while True:
            raw=left.recv(513)
            if not raw:break
            chunks.append(raw)
        observed=b''.join(chunks);output,error=os.read(out_r,1024),os.read(err_r,1024)
        waited,status=os.waitpid(pid,0)
        assert waited==pid and not output and not error
        if short:assert status==256 and len(observed)==511
        else:
            assert status==0 and len(observed)==512
            parsed=struct.unpack('>8s53Q80s',observed)
            assert parsed[0]==b'YC2DONE1' and parsed[1:54]==(0,)*53 and parsed[54]==bytes(80)
        print(json.dumps({'case':'terminal-short' if short else 'terminal-only','wait':status,'actual_control_bytes':len(observed),
            'stdout_bytes':len(output),'stderr_bytes':len(error),'full_session':False,'short_fault_shim':short,'actions':actions},sort_keys=True))
    finally:left.close();os.close(out_r);os.close(err_r)


def raw16_C2_lifecycle_deletion(root: Path) -> None:
    try:raw16_C2_lifecycle_core(root,('tail-before-acquire',),mutation='length')
    except AssertionError as error:
        frame=error.__traceback__
        while frame.tb_next is not None:frame=frame.tb_next
        assert frame.tb_frame.f_code.co_name=='raw16_C2_lifecycle_core'
        actual=frame.tb_frame.f_locals
        assert isinstance(actual.get('error'),AssertionError) and str(actual['error'])=='C2 copy accepted installed tail'
    else:raise AssertionError('C2 installed-length deletion undetected')
    try:raw16_C2_source_tail(root,mutation=True)
    except AssertionError as error:
        frame=error.__traceback__
        while frame.tb_next is not None:frame=frame.tb_next
        actual=frame.tb_frame.f_locals
        assert frame.tb_frame.f_code.co_name=='raw16_C2_source_tail'
        assert actual['work']['close_calls']==actual['before_scalar']==0 and len(actual['closed'])==len(actual['watched'])>0
    else:raise AssertionError('C2 D-transfer deletion undetected')
    try:raw16_C2_terminal(root,short=True,mutation=True)
    except AssertionError as error:
        frame=error.__traceback__
        while frame.tb_next is not None:frame=frame.tb_next
        actual=frame.tb_frame.f_locals
        assert frame.tb_frame.f_code.co_name=='raw16_C2_terminal'
        assert actual['status']==0 and len(actual['observed'])==511
    else:raise AssertionError('C2 short-DONE deletion undetected')
    print(json.dumps({'C2_installed_length_deletion_detected':True,'C2_D_actual_tail_transfer_deletion_detected':True,
        'C2_short_DONE_retry_gate_deletion_detected':True}))


def raw16_C2_scoped_runtime(root: Path) -> None:
    import copy,shlex,tempfile
    spec=importlib.util.spec_from_file_location('_C2_scoped_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    launcher=(root/'evals/v1/evals-launcher.sh').read_text();literal=shlex.split(launcher.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_C2_scoped_runtime','c':c};exec(compile(literal,'<fixed-C2-scoped>','exec'),fixed)
    first,second=sorted(fixed['_C2_CASES'])[:2]
    # Counter-only occupancy vectors exercise original caps without claiming large bytes were produced.
    model=fixed['c2_fresh_work']('C2-bounded-model')
    model['C2_common_case']=fixed['c2_fresh_work']('C2-new-unacted-model-common')
    a=c._capture_work_values(model,'a');b=c._capture_work_values(model,'b');shared=c._capture_work_values(model,'shared')
    a['runtime']={'write_bytes':3};b['runtime']={'write_bytes':2};shared['runtime']={'write_bytes':7}
    model['runtime']['write_bytes']=12
    model['C2_case_bindings']={first:(a,[a,shared,shared]),second:(b,[b,shared])}
    views=fixed['c2_counters'](model)
    assert views['window']['runtime']['write_bytes']==12
    assert views['cases'][first]['runtime']['write_bytes']==10 and views['cases'][second]['runtime']['write_bytes']==9
    limit=c._RUNTIME_FIELDS['write_bytes']
    before=copy.deepcopy(views);before['cases'][first]['runtime']['write_bytes']=limit-1
    reserve={'window':fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-reservation')),'common':fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-common-reservation')),'cases':{identity:fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-case-reservation')) for identity in views['cases']}}
    reserve['window']['runtime']['write_bytes']=2;reserve['cases'][first]['runtime']['write_bytes']=2
    try:fixed['c2_reserve'](before,reserve)
    except fixed['C2Refusal'] as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('over case/below window accepted')
    before['cases'][first]['runtime']['write_bytes']=limit-2;fixed['c2_reserve'](before,reserve)
    for variant in ('missing','foreign'):
        damaged=copy.deepcopy(reserve)
        if variant=='missing':damaged['cases'].pop(first)
        else:damaged['cases']['foreign.case']=damaged['cases'].pop(first)
        try:fixed['c2_reserve'](before,damaged)
        except fixed['C2Refusal']:pass
        else:raise AssertionError('invalid case reservation accepted')
    # Real small writes are separate per-case leaves under the same retained root/window.
    with tempfile.TemporaryDirectory(prefix='C2-scoped-held.') as area:
        base=Path(area);window_path=base/'window';window_path.mkdir(mode=0o700)
        source_path=base/'source';source_path.write_bytes(b'abc');source_path.chmod(0o400)
        resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
        child=fixed['c2_fresh_work']('C2-terminal');original=fixed['c2_fresh_work']('C2-original-window')
        p=c._capture_work_values(original,'actual-a');q=c._capture_work_values(original,'actual-b')
        original['C2_case_bindings']={first:(p,[p]),second:(q,[q])}
        held=c._open_held(str(window_path),True,c._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STORE')
        custody=fixed['C2Root'](held,child,resolver)
        src=c._open_held(str(source_path),False,c._store_rule(os.geteuid(),os.getegid(),0o400,False,resolver),'E_STORE')
        caller=_C2FixtureCaller(root,held,original,p)
        totals={identity:fixed['c2_fresh_work']('C2-total-'+identity) for identity in (first,second)}
        child['C2_case_totals']=totals;child['C2_case_leaves']={}
        copies=[]
        before=fixed['c2_counters'](original)
        try:
            _destinations,operations=custody.layout()
            operation=custody.mkdir(operations,'0');installed=custody.mkdir(operation,'I')
            # READY is an actual zero-copy acquisition cutoff of these newly declared case leaves.
            caller.settle_child(fixed['c2_counters'](child))
            for identity in (first,second):
                target=custody.mkdir(installed,identity)
                leaf=fixed['c2_fresh_work']('C2-I-'+identity);child['C2_case_leaves'][identity]=leaf
                current=fixed['C2Copies'](custody,leaf,totals[identity],before['window'],before['cases'][identity])
                current.copy(src,target,'runtime.bin',3,hashlib.sha256(b'abc').hexdigest(),'runtime')
                if identity==second:assert leaf['runtime_window_carry_in']['write_bytes']==3
                current.transfer_cases();copies.append(current)
            assert child['runtime']['write_bytes']==6 and all(row.work['runtime']['write_bytes']==3 for row in copies)
            for current in copies:current.final_checks();current.transfer_cases()
            custody.close()
            for current in copies:current.transfer_cases()
            end=fixed['c2_counters'](child)
            caller.settle_child(end)
            assert original['runtime']['write_bytes']==6 and p['runtime']['write_bytes']==q['runtime']['write_bytes']==3
            old=original['read_bytes'];caller.settle_child(end);assert original['read_bytes']==old
            wrong=copy.deepcopy(end);wrong['cases']['foreign.case']=wrong['cases'].pop(first)
            try:caller.settle_child(wrong)
            except AssertionError:pass
            else:raise AssertionError('foreign case transfer admitted')
            assert original['read_bytes']==old
            print(json.dumps({'case':'scoped-real-copy','actual_runtime_written':6,'case_write_bytes':[p['runtime']['write_bytes'],q['runtime']['write_bytes']],
                'window_write_bytes':original['runtime']['write_bytes'],'common_runtime_write_bytes':caller.common_case.get('runtime',{}).get('write_bytes',0),
                'READY_END_monotonic_once':True,'window_case_shared_view':[12,10,9], 'counter_only_case_cap':limit,
                'counter_only_large_bytes_executed':0,'missing_foreign_rejected':True},sort_keys=True))
        finally:
            if not custody.closed:custody.close()
            src.close()


def raw16_C2_six_fixes(root: Path, original=None) -> None:
    import shlex, types, tempfile
    spec=importlib.util.spec_from_file_location('_C2_six_consumer',root/'shadow/v1/_consumer.py')
    owner=importlib.util.module_from_spec(spec);sys.modules[spec.name]=owner;spec.loader.exec_module(owner)
    text=(Path(original) if original else root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(text.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_C2_six_fixed','c':owner};exec(compile(literal,'<actual-fixed-C2>','exec'),fixed)
    resolver=owner._DarwinUUIDResolver() if sys.platform=='darwin' else None
    # The helper is stopped at its real spawn boundary. No shell, runtime or jq is executed.
    work=fixed['c2_fresh_work']('C2-six-env');spawn=os.posix_spawn;seen=[]
    sentinel=OSError(5,'controlled before helper execution')
    def intercept(path,argv,env,**kwargs):seen.append(dict(env));raise sentinel
    os.posix_spawn=intercept
    try:
        sources=types.SimpleNamespace(helpers='',launcher=str(root/'evals/v1/evals-launcher.sh'),namespace={'owned':[]})
        helper=fixed['C2Helpers'](sources,'/synthetic/scratch',work,())
        try:helper.build([])
        except BaseException as error:assert error is sentinel
        else:raise AssertionError('helper unexpectedly executed')
    finally:os.posix_spawn=spawn
    assert seen[0].get('TMPDIR')==os.environ.get('TMPDIR'), 'helper original TMPDIR lost'
    print(json.dumps({'C2_fix':'helper-env','spawn_intercepted':True,'runtime_executed':False,'work':work},sort_keys=True))
    with tempfile.TemporaryDirectory(prefix='C2-six-fixed.') as area:
        base=Path(area);window=base/'window';ephemeral=base/'ephemeral';window.mkdir(mode=0o700);ephemeral.mkdir(mode=0o700)
        source_path=base/'source';source_path.write_bytes(b'abcdef');source_path.chmod(0o400)
        def acquire(work):return owner._open_held(str(window),True,owner._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M')
        work=fixed['c2_fresh_work']('C2-six-root');held=acquire(work)
        child=Path(tempfile.mkdtemp(dir=ephemeral));child.rmdir();held.recheck('E_STALE',work,'M')
        # An unrelated creation in the held ancestor remains forbidden.
        unexpected=base/'unexpected';unexpected.mkdir()
        try:held.recheck('E_STALE',work,'M')
        except owner.Refusal as error:assert error.code=='E_STALE'
        else:raise AssertionError('external ancestor drift accepted')
        held.close();unexpected.rmdir()
        print(json.dumps({'C2_fix':'scratch-parent','stable_child_create_delete':True,'external_drift_refused':True,'work':work},sort_keys=True))
        work=fixed['c2_fresh_work']('C2-six-root-failure');held=acquire(work);watched=[row.fd for row in held.components]
        original_check=owner.HeldPath.recheck;original_close=os.close;closed=[];fault=MemoryError('controlled root admission')
        def reject(self,*args,**kwargs):
            if self is held:raise fault
            return original_check(self,*args,**kwargs)
        def closing(fd):
            if fd in watched:closed.append(fd)
            return original_close(fd)
        owner.HeldPath.recheck=reject;os.close=closing
        try:
            try:fixed['C2Root'](held,work,resolver)
            except BaseException as error:assert error is fault
            else:raise AssertionError('root fault accepted')
        finally:owner.HeldPath.recheck=original_check;os.close=original_close
        assert sorted(closed)==sorted(watched),'root constructor leaked held chain'
        print(json.dumps({'C2_fix':'root-failure','onceclose':len(closed),'same_primary':True,'work':work},sort_keys=True))
        work=fixed['c2_fresh_work']('C2-six-copy');custody=fixed['C2Root'](acquire(work),work,resolver)
        source=owner._open_held(str(source_path),False,owner._store_rule(os.geteuid(),os.getegid(),0o400,False,resolver),'E_STALE',recording_work=work,accounting_kind='M')
        try:
            target=custody.mkdir(custody.root,'target')
            copies=fixed['C2Copies'](custody)
            installed=copies.copy(source,target,'bytes',6,hashlib.sha256(b'abcdef').hexdigest(),'runtime')
            baseline=work['runtime']['read_bytes'];pread=os.pread;calls=[];fault=OSError(5,'second paired read failed')
            def paired(fd,count,offset):
                calls.append((fd,count,offset))
                if len(calls)==2:raise fault
                return pread(fd,count,offset)
            os.pread=paired
            try:
                try:copies.final_checks()
                except BaseException as error:assert error is fault
                else:raise AssertionError('paired read error swallowed')
            finally:os.pread=pread
            assert work['runtime']['read_bytes']-baseline==6,'first successful pread lost'
            print(json.dumps({'C2_fix':'paired-read','actual_first_read_bytes':6,'second_failed':True,'work':work},sort_keys=True))
        finally:source.close();custody.close()
    # A real stage fails after its first physical copy. The pre-registered owner still transfers that delta.
    with tempfile.TemporaryDirectory(prefix='C2-six-stage.') as area:
        base=Path(area);window=base/'window';window.mkdir(mode=0o700)
        cases=window/'cases';cases.mkdir(mode=0o700);identity=sorted(fixed['_C2_CASES'])[0]
        casepath=cases/identity;casepath.mkdir(mode=0o700);sourcepath=casepath/'S';sourcepath.mkdir(mode=0o700)
        (sourcepath/'one').write_bytes(b'123');(sourcepath/'one').chmod(0o400)
        targetpath=window/'I';targetpath.mkdir(mode=0o700)
        work=fixed['c2_fresh_work']('C2-six-stage');held=owner._open_held(str(window),True,owner._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M')
        custody=fixed['C2Root'](held,work,resolver)
        target=custody.adopt(owner._open_child(held,'I',True,owner._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M'))
        total=fixed['c2_fresh_work']('C2-six-total');work['C2_case_totals']={identity:total}
        before={'window':fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-stage-before')), 'cases':{identity:fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-case-before'))}}
        core={'case_id':identity,'entries':[{'occurrence':'reproduction','role':'runtime','member':'one','file':'one','size_bytes':3,'sha256':hashlib.sha256(b'123').hexdigest(),'kind':'runtime'}],'originals':{},'occurrences':{}}
        raw=fixed['C2Channel'](None,work).encode(core)
        descriptor={'carry_in':{},'cases':{key:({'inventory_core':core,'sha256':hashlib.sha256(raw).hexdigest()} if key==identity else None) for key in fixed['_C2_CASES']}}
        copies=fixed['C2Copies'](custody);copy_method=fixed['C2Copies'].copy;fault=OSError(5,'after real staged copy')
        def stop_after(self,*args):
            result=copy_method(self,*args)
            raise fault
        fixed['C2Copies'].copy=stop_after
        caught=None
        try:
            try:fixed['c2_stage'](custody,descriptor,[identity],target,before,copies)
            except BaseException as error:caught=error
            assert caught is fault
        finally:
            fixed['C2Copies'].copy=copy_method
            copies.transfer_cases()
            try:custody.close(caught)
            except BaseException as error:assert error is caught
        assert work['runtime']['write_bytes']==total['runtime']['write_bytes']==3
        assert work['runtime']['read_bytes']==total['runtime']['read_bytes']>0
        print(json.dumps({'C2_fix':'failed-stage-delta','same_primary':caught is fault,'window':work,'case':total},sort_keys=True))
    window_work=fixed['c2_fresh_work']('C2-six-window');case=fixed['c2_fresh_work']('C2-six-case');leaf=fixed['c2_fresh_work']('C2-six-leaf')
    before_window=fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-before-window'))
    before_case=fixed['c2_counter_values'](fixed['c2_fresh_work']('C2-before-case'))
    before_case['read_bytes']=128*owner.DOCUMENT_LIMIT
    custody=types.SimpleNamespace(work=window_work)
    copies=fixed['C2Copies'](custody,leaf,case,before_window,before_case)
    try:copies.room('R',1,'raw')
    except owner.Refusal as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('case carry-in cap bypassed')
    assert leaf['read_bytes']==0
    leaf['read_bytes']=7;leaf['write_bytes']=3;leaf['physical_bytes']=3
    copies.transfer_cases();copies.transfer_cases()
    assert window_work['read_bytes']==case['read_bytes']==7 and window_work['write_bytes']==case['write_bytes']==3
    print(json.dumps({'C2_fix':'carry-and-transfer','nearcase_refused_before_read':True,'repeat_delta_zero':True,'window':window_work,'case':case},sort_keys=True))


def raw16_C2_failure_accounting(root: Path, original=None) -> None:
    import ast,shlex,socket,copy,tempfile
    spec=importlib.util.spec_from_file_location('_C2_failure_consumer',root/'shadow/v1/_consumer.py')
    owner=importlib.util.module_from_spec(spec);sys.modules[spec.name]=owner;spec.loader.exec_module(owner)
    source=(Path(original) if original else root/'evals/v1/evals-launcher.sh').read_text();literal=shlex.split(source.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_C2_failure_fixed','c':owner};exec(compile(literal,'<actual-C2-fixed>','exec'),fixed)
    fresh=fixed['c2_fresh_work'];view=fixed['c2_counter_values']
    work=fresh('C2-common-nearcap');before={'window':view(fresh('C2-old-window')),'cases':{},'common':view(fresh('C2-old-common'))}
    reservation={'window':view(fresh('C2-reserved-window')),'cases':{},'common':view(fresh('C2-reserved-common'))}
    before['common']['read_bytes']=128*owner.DOCUMENT_LIMIT-1;reservation['common']['read_bytes']=1
    work['C2_admitted_before']=before;work['C2_tail_reservation']=reservation
    try:fixed['c2_wire_room'](work,1,'R')
    except owner.Refusal as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('common carry plus reservation ignored')
    assert work['read_bytes']==0
    pending_window=fresh('C2-pending-window');pending_leaf=fresh('C2-pending-leaf');pending_case=fresh('C2-pending-case')
    pending_before={'window':view(fresh('C2-pending-before')),'cases':{},'common':view(fresh('C2-pending-common'))}
    pending_before['window']['read_bytes']=512*owner.DOCUMENT_LIMIT-4
    pending_window['C2_admitted_before']=pending_before
    pending_window['C2_tail_reservation']={'window':view(fresh('C2-pending-window-reserve')),'cases':{},'common':view(fresh('C2-pending-common-reserve'))}
    pending_leaf['read_bytes']=4
    pending_window['C2_case_leaves']={'malicious.checked-file-bytes':pending_leaf}
    pending_window['C2_case_totals']={'malicious.checked-file-bytes':pending_case}
    try:fixed['c2_wire_room'](pending_window,1,'R')
    except owner.Refusal as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('pending case delta omitted from window admission')
    owner._capture_transfer_work(pending_leaf,pending_window,pending_case)
    fixed['c2_wire_room'](pending_window,0,'R')
    assert pending_window['read_bytes']==pending_case['read_bytes']==4
    window=fresh('C2-partial-window')
    class FailWrite(dict):
        def __setitem__(self,key,value):
            if key=='write_bytes':raise MemoryError('controlled case target write counter')
            return super().__setitem__(key,value)
    total=FailWrite(fresh('C2-partial-case'));leaf=fresh('C2-partial-leaf')
    window['C2_case_totals']={'malicious.checked-file-bytes':total}
    leaf['read_bytes']=7;leaf['write_bytes']=3;leaf['physical_bytes']=3
    copies=fixed['C2Copies'](type('Custody',(),{'work':window})(),leaf,total,view(fresh('C2-old-window')),view(fresh('C2-old-case')))
    try:copies.transfer_cases()
    except MemoryError:pass
    else:raise AssertionError('partial transfer fault missed')
    assert window['read_bytes']==total['read_bytes']==7 and leaf['transferred_read_bytes']==7
    assert window['write_bytes']==3 and total['write_bytes']==0 and leaf['write_bytes']==3
    cutoff=fixed['c2_counters'](window)
    assert cutoff['common']['unknown']['C2_common_transfer_unknown']
    assert cutoff['common']['read_bytes']==cutoff['common']['write_bytes']==0
    try:copies.transfer_cases()
    except fixed['C2Refusal']:pass
    else:raise AssertionError('partial transfer retried')
    assert window['read_bytes']==7 and window['write_bytes']==3
    print(json.dumps({'C2_fix':'common-and-partial-transfer','common_before_plus_tail_refused':True,'same_actual_delta_retained':True,'no_retry':True,'window':window,'case':total,'leaf':leaf,'cutoff':cutoff},sort_keys=True))
    work=fresh('C2-canonical-failure');left,right=socket.socketpair()
    try:
        message={'kind':'GO','version':1,'ordinal':0,'start_sha256':'a'*64,'ready_sha256':'b'*64,
            'caller_delta':fixed['c2_counters'](fresh('C2-delta')),'tail_reservation':fixed['c2_counters'](fresh('C2-reservation'))}
        raw=json.dumps(message,sort_keys=True).encode()+b'\n';left.sendall(struct.pack('>I',len(raw))+raw)
        try:fixed['C2Channel'](right.fileno(),work).receive('GO')
        except fixed['C2Refusal'] as error:assert error.code=='E_CANONICAL'
        else:raise AssertionError('noncanonical frame accepted')
        assert work['read_bytes']>=4+4*len(raw),'failed canonical comparison lost known processing'
        print(json.dumps({'C2_fix':'canonical-failure','actual_compare_charged':True,'work':work},sort_keys=True))
    finally:left.close();right.close()
    body=source.split("<<'PY_SHADOW_SOURCE'\n",1)[1].split('\nPY_SHADOW_SOURCE',1)[0]
    interrupt=next(node for node in ast.parse(body).body if isinstance(node,ast.FunctionDef) and node.name=='interrupt')
    handler={};exec(compile(ast.Module(body=[interrupt],type_ignores=[]),'<original-D-interrupt>','exec'),handler)
    def cancelled():
        try:handler['interrupt'](signal.SIGTERM,None)
        except InterruptedError as error:return error
    resolver=owner._DarwinUUIDResolver() if sys.platform=='darwin' else None
    for first_marked in (False,True):
        with tempfile.TemporaryDirectory(prefix='C2-root-primary.') as area:
            work=fresh('C2-root-primary');held=owner._open_held(area,True,owner._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M')
            watched=[row.fd for row in held.components];closed=[];primary=cancelled() if first_marked else MemoryError('ordinary root admission')
            secondary=OSError(5,'secondary actual close') if first_marked else cancelled()
            checking=owner.HeldPath.recheck;closing=os.close
            def failcheck(self,*args,**kwargs):
                if self is held:raise primary
                return checking(self,*args,**kwargs)
            def failclose(fd):
                result=closing(fd)
                if fd in watched:
                    closed.append(fd)
                    if len(closed)==1:raise secondary
                return result
            owner.HeldPath.recheck=failcheck;os.close=failclose
            try:
                try:fixed['C2Root'](held,work,resolver)
                except BaseException as error:assert error is (primary if first_marked else secondary)
                else:raise AssertionError('root admission fault disappeared')
            finally:owner.HeldPath.recheck=checking;os.close=closing
            assert sorted(closed)==sorted(watched)
            print(json.dumps({'C2_fix':'root-cancel-onceclose','first_marked':first_marked,'same_primary_or_first_marked':True,'onceclose':len(closed),'work':work},sort_keys=True))


def raw16_C2_refused_END_transfer(root: Path) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('_C2_END_consumer',root/'shadow/v1/_consumer.py')
    owner=importlib.util.module_from_spec(spec);sys.modules[spec.name]=owner;spec.loader.exec_module(owner)
    resolver=owner._DarwinUUIDResolver() if sys.platform=='darwin' else None
    with tempfile.TemporaryDirectory(prefix='C2-END-failure.') as area:
        base=Path(area);window=base/'window';window.mkdir(mode=0o700)
        (window/'seed-a.json').write_bytes(b'{}\n');(window/'seed-a.json').chmod(0o400)
        work={};owner._capture_work_values(work,'END-case')
        for key,value in {'runtime':{field:0 for field in owner._RUNTIME_FIELDS},'close_calls':0,'held_close_calls':0,'observation_calls':0,'seed_processing':{field:0 for field in ('R','W','H','E','C')},'accounting':{kind:{field:0 for field in ('read_bytes','write_bytes','logical_bytes','physical_bytes','files','occurrences')} for kind in ('L','W','M','raw','unresolved')}}.items():work[key]=value
        case=work['cases']['END-case']
        held=owner._open_held(str(window),True,owner._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE')
        caller=_C2FixtureCaller(root,held,work,case);fixed=caller.fixed;identity=sorted(fixed['_C2_CASES'])[0]
        work['C2_case_bindings'][identity]=(case,[case]);caller.window_sha=caller.head='a'*64
        reservation={'window':fixed['c2_counter_values'](fixed['c2_fresh_work']('END-window-reservation')),
            'common':fixed['c2_counter_values'](fixed['c2_fresh_work']('END-common-reservation')),
            'cases':{identity:fixed['c2_counter_values'](fixed['c2_fresh_work']('END-case-reservation'))}}
        # Failure-only protocol peer. It reports its real codec work, then exits nonzero without DONE.
        # It never invokes a driver, returns successful replay data or claims a qualified seed.
        child_code=r'''import importlib.util,sys,os,shlex
from pathlib import Path
root=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('ENDpeerconsumer',root/'shadow/v1/_consumer.py');c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
s=(root/'evals/v1/evals-launcher.sh').read_text();literal=shlex.split(s.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0];ns={'__name__':'ENDpeer','c':c};exec(compile(literal,'<actual-fixed-codec>','exec'),ns)
w=ns['c2_fresh_work']('END-failure-peer');ch=ns['C2Channel'](9,w);start,raw=ch.receive('START')
ready={'kind':'READY','version':1,'ordinal':start['ordinal'],'start_sha256':ns['c2_sha'](raw,w),'input_sha256s':start['seed_sha256s'],'observed_predecessor_sha256':start['predecessor_sha256'],'acquisition_delta':ns['c2_counters'](w),'leaf_pid':os.getpid(),'leaf_ppid':os.getppid()}
ch.send(ready);ch.receive('GO')
end={'kind':'END','version':1,'ordinal':start['ordinal'],'start_sha256':ns['c2_sha'](raw,w),'receipt_sha256':None,'result_sha256':None,'outcome':'refused','child_delta':ns['c2_counters'](w),'retained':[],'errors':[{'category':'controlled-refusal'}],'unknown':['missing-DONE-tail']}
ch.send(end);os.close(9);os.close(10);os._exit(3)
'''
        spawn=os.posix_spawn
        def refused_peer(path,argv,env,**kwargs):
            return spawn('/usr/bin/python3',['/usr/bin/python3','-I','-S','-B','-c',child_code,str(root)],env,**kwargs)
        before=work['read_bytes'];os.posix_spawn=refused_peer;caught=None
        try:
            try:caller.invoke(['run',str(window/'seed-a.json'),'2026-10-27T00:00:00Z'],[identity],reservation)
            except BaseException as error:caught=error
        finally:os.posix_spawn=spawn;held.close()
        if not hasattr(caller,'last_attempt'):raise caught
        end=caller.last_attempt['end']
        assert caught is not None and end is not None,'refusal peer did not reach actual END'
        assert caller.child_state['session']['read_bytes']==end['child_delta']['common']['read_bytes']>0
        assert work['read_bytes']>before and caller.common_case['read_bytes']>=end['child_delta']['common']['read_bytes']
        assert work['C2_child_tail_unknown'] and caller.common_case['C2_child_tail_unknown']
        assert caller.last_attempt['wait']==3<<8
        assert caller.ordinal==0 and caller.head=='a'*64
        assert caller.work['seed_processing']['H']>0
        print(json.dumps({'C2_fix':'refused-END-transfer','actual_END_seen':True,'wait':caller.last_attempt['wait'],'no_DONE':caller.last_attempt['done'] is None,
            'no_driver_executed':True,'no_success_result':True,'unadvanced':True,'window':work,'common':caller.common_case,'child_END':end,'caller':caller.work},sort_keys=True))


def raw16_C2_six_fix_deletions(root: Path) -> None:
    import tempfile
    original=(root/'evals/v1/evals-launcher.sh').read_text()
    cases=(('common', '        scopes.append((admitted["common"], c2_counters(work)["common"], True, reservation["common"]))',
        '        pass', raw16_C2_failure_accounting, 'common carry plus reservation ignored'),
        ('first-read', '                self.charge("R", len(left), kind)', '                pass', raw16_C2_six_fixes, 'first successful pread lost'))
    for label,check,replacement,run,expected in cases:
        count=1 if label=='common' else 2
        assert original.count(check)==count
        with tempfile.TemporaryDirectory(prefix='C2-six-source-deletion.') as area:
            path=Path(area)/'launcher.sh';path.write_text(original.replace(check,replacement))
            try:run(root,path)
            except AssertionError as error:assert str(error)==expected
            else:raise AssertionError('six-fix deletion not detected: '+label)
        print(json.dumps({'C2_fix_deletion':label,'matched_assertion':expected,'detected':True}))


def raw16_C2_numeric_budget(root: Path, legacy_path=None) -> None:
    import shlex,tempfile,copy,ast
    spec=importlib.util.spec_from_file_location('_C2_budget_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    source=(root/'evals/v1/evals-launcher.sh').read_text();literal=shlex.split(source.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_C2_budget_fixed','c':c};exec(compile(literal,'<C2-fixed-budget>','exec'),fixed)
    fresh=fixed['c2_fresh_work'];value={'message':'ordinary small \u00e9 document'}
    unbound=fresh('C2-legacy');raw=c._private_capture_observations(value,unbound,unbound)
    if legacy_path is not None:
        spec=importlib.util.spec_from_file_location('_C2_budget_original',legacy_path)
        old=importlib.util.module_from_spec(spec);sys.modules[spec.name]=old;spec.loader.exec_module(old)
        original=fresh('C2-legacy');prior=old._private_capture_observations(value,original,original)
        assert prior==raw and original==unbound,'unbound original encoder semantics changed'
        old_window,old_case=fresh('C2-old-window'),fresh('C2-old-case')
        new_window,new_case=fresh('C2-old-window'),fresh('C2-old-case')
        assert old._private_capture_observations(value,old_window,old_case)==c._private_capture_observations(value,new_window,new_case)
        assert old_window==new_window and old_case==new_case
        for exported in (False,True):
            for read_only in (False,True):
                old._capture_copy_room(original,17,exported,read_only=read_only)
                c._capture_copy_room(unbound,17,exported,read_only=read_only)
    measured=unbound['read_bytes']
    for common_limited in (False,True):
        work=fresh('C2-bound');window=fresh('C2-window-carry');common=fresh('C2-common-carry')
        maximum=(128 if common_limited else 512)*c.DOCUMENT_LIMIT
        selected=common if common_limited else window
        # Numeric occupancy only. No large payload is allocated or claimed as produced.
        selected['read_bytes']=maximum-measured-1
        work['_capture_copy_budget']=c._capture_copy_budget_values(work,((window,False),(common,True)))
        encoded=c._private_capture_observations(value,work,work)
        assert encoded==raw and work['read_bytes']==measured
        try:c._capture_copy_room(work,2,False,read_only=True)
        except c.Refusal as error:assert error.code=='E_LIMIT'
        else:raise AssertionError('bound scope allowed exhausted room')
        print(json.dumps({'C2_budget':'near-common' if common_limited else 'near-window','small_document_passed':True,'actual_processing_bytes':measured,'work':work},sort_keys=True))
    work=fresh('C2-partial-encoding');window=fresh('C2-window');common=fresh('C2-common')
    common['read_bytes']=128*c.DOCUMENT_LIMIT-8
    work['_capture_copy_budget']=c._capture_copy_budget_values(work,((window,False),(common,True)))
    try:c._capture_observe(work,'M','bounded-row',value)
    except c.Refusal as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('bound encoder chunk bypassed carry')
    assert work['read_bytes']==1 and work['accounting_incomplete']
    for invalid in (None,((0,)*8,('UNKNOWN',)*11),((-1,)*8,(1,)*11),((1,)*8,(100,)*11)):
        bad=fresh('C2-invalid-budget');bad['_capture_copy_budget']=invalid
        try:c._capture_copy_room(bad,0,False)
        except c.Refusal:pass
        else:raise AssertionError('unknown or negative budget became credit')
        assert bad['read_bytes']==0
    body=source.split("<<'PY_SHADOW_SOURCE'\n",1)[1].split('\nPY_SHADOW_SOURCE',1)[0]
    handler={};node=next(node for node in ast.parse(body).body if isinstance(node,ast.FunctionDef) and node.name=='interrupt')
    exec(compile(ast.Module(body=[node],type_ignores=[]),'<original-D-interrupt>','exec'),handler)
    work_cancel=fresh('C2-encoding-cancel');work_cancel['_capture_copy_budget']=c._capture_copy_budget_values(work_cancel,((fresh('C2-w'),False),(fresh('C2-c'),True)))
    iterator=json.JSONEncoder.iterencode;events=[]
    def cancel_after_first(self,*args,**kwargs):
        for piece in iterator(self,*args,**kwargs):
            yield piece
            try:handler['interrupt'](signal.SIGTERM,None)
            except InterruptedError as error:events.append(error);raise
    json.JSONEncoder.iterencode=cancel_after_first
    try:
        try:c._capture_observe(work_cancel,'M','cancel-row',value)
        except BaseException as error:assert error is events[0]
        else:raise AssertionError('encoding cancellation lost')
    finally:json.JSONEncoder.iterencode=iterator
    assert work_cancel['read_bytes']==1 and work_cancel['accounting_incomplete']
    with tempfile.TemporaryDirectory(prefix='C2-budget-metadata.') as area:
        work_meta=fresh('C2-held-metadata');resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
        held=c._open_held(area,True,c._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work_meta,accounting_kind='M')
        window=fresh('C2-window');common=fresh('C2-common');common['read_bytes']=128*c.DOCUMENT_LIMIT-8
        work_meta['_capture_copy_budget']=c._capture_copy_budget_values(work_meta,((window,False),(common,True)))
        before=work_meta['read_bytes'];caught=None
        try:held.recheck('E_STALE',work_meta,'M')
        except c.Refusal as error:caught=error
        finally:held.close()
        assert caught is not None and work_meta['accounting_incomplete'] and not held.components
        assert work_meta['read_bytes']>before
    print(json.dumps({'C2_budget':'chunk-failure-cancel-metadata','unbound_legacy_compared':legacy_path is not None,
        'partial_encoding':work,'same_cancel_object':True,'cancel_work':work_cancel,'metadata_work':work_meta,'invalid_budgets_refused':4},sort_keys=True))


def raw16_C2_residual_custody(root: Path, original=None) -> None:
    import ast,shlex,tempfile
    spec=importlib.util.spec_from_file_location('_C2_residual_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    source=(Path(original) if original else root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(source.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_C2_residual_fixed','c':c};exec(compile(literal,'<actual-C2-residual>','exec'),fixed)
    body=source.split("<<'PY_SHADOW_SOURCE'\n",1)[1].split('\nPY_SHADOW_SOURCE',1)[0]
    handlers={};node=next(node for node in ast.parse(body).body if isinstance(node,ast.FunctionDef) and node.name=='interrupt')
    exec(compile(ast.Module(body=[node],type_ignores=[]),'<original-D-handler>','exec'),handlers)
    adapter=next(node for node in ast.walk(ast.parse(literal)) if isinstance(node,ast.FunctionDef) and node.name=='interrupted')
    adapted={'namespace':handlers};exec(compile(ast.Module(body=[adapter],type_ignores=[]),'<actual-C2-signal-adapter>','exec'),adapted)
    def cancellation():
        try:adapted['interrupted'](signal.SIGTERM,None)
        except InterruptedError as error:return error
    resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
    for label in ('allocation','initial-owned','internal-recheck','first-marked','later-marked'):
        with tempfile.TemporaryDirectory(prefix='C2-root-pending.') as area:
            work=fixed['c2_fresh_work']('C2-root-pending')
            parent=c._open_held(area,True,c._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M')
            Root=fixed['C2Root'];primary=cancellation() if label=='first-marked' else MemoryError('controlled '+label)
            secondary=cancellation() if label in ('first-marked','later-marked') else OSError(5,'secondary pending close')
            duplicate=os.dup;closing=os.close;checking=c.HeldPath.recheck;watched=[];closed=[];compensated=[];caught=None
            class AllocatingRoot(Root):
                def __new__(cls,*args,**kwargs):raise primary
            class InitializingRoot(Root):
                def __setattr__(self,key,value):
                    if key=='owned':raise primary
                    return super().__setattr__(key,value)
            if label=='initial-owned':fixed['C2Root']=InitializingRoot
            elif label!='internal-recheck':fixed['C2Root']=AllocatingRoot
            def dup(fd):
                result=duplicate(fd);watched.append(result);return result
            def close(fd):
                result=closing(fd)
                if fd in watched:
                    closed.append(fd)
                    if len(closed)==1 and label!='internal-recheck':raise secondary
                return result
            def check(self,*args,**kwargs):
                if self is not parent:raise primary
                return checking(self,*args,**kwargs)
            os.dup=dup;os.close=close
            if label=='internal-recheck':c.HeldPath.recheck=check
            try:
                try:fixed['c2_clone_root'](parent,work,resolver)
                except BaseException as error:caught=error
            finally:
                os.dup=duplicate;os.close=closing;c.HeldPath.recheck=checking;fixed['C2Root']=Root
                # Test compensation is separate from the observed production close attempts.
                for fd in watched:
                    if fd not in closed:closing(fd);compensated.append(fd)
                parent.recheck('E_STALE',work,'M');parent.close()
            print(json.dumps({'C2_residual':'pending-root','case':label,'clone_FDs':len(watched),'owner_close_attempts':closed,
                'fixture_compensation':compensated,'same_first_or_first_marked':caught is (secondary if label=='later-marked' else primary),'work':work},sort_keys=True))
            assert sorted(closed)==sorted(watched),'pre-handoff Root allocation leaked clone FDs'
            assert caught is (secondary if label=='later-marked' else primary),'pending Root replaced first cancellation'


def raw16_C2_tail_reserve(root: Path, original=None) -> None:
    import shlex,copy
    spec=importlib.util.spec_from_file_location('_C2_tail_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    source=(Path(original) if original else root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(source.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    fixed={'__name__':'_C2_tail_fixed','c':c};exec(compile(literal,'<actual-C2-tail>','exec'),fixed)
    fresh=fixed['c2_fresh_work'];view=fixed['c2_counter_values']
    def prepare(field,amount,spare=0,short=0):
        work=fresh('C2-tail-unit');before={'window':view(fresh('C2-tail-window')),'common':view(fresh('C2-tail-common')),'cases':{}}
        reserve={'window':view(fresh('C2-reserve-window')),'common':view(fresh('C2-reserve-common')),'cases':{}}
        for scope,multiplier in (('window',4),('common',1)):
            limit=(128 if field=='read_bytes' else 64)*multiplier*c.DOCUMENT_LIMIT
            before[scope][field]=limit-amount-spare+short;reserve[scope][field]=amount
        work['C2_admitted_before']=before;work['C2_tail_reservation']=reserve
        return work
    for field,axis in (('read_bytes','R'),('write_bytes','W')):
        for spare in (0,10):
            work=prepare(field,8,spare)
            if spare==0:
                try:fixed['c2_wire_room'](work,1,axis)
                except (c.Refusal,fixed['C2Refusal']):pass
                else:raise AssertionError('replay consumed tail reservation')
            # Binding made before the tail deliberately has less room than the tail itself.
            fixed['c2_nonruntime_room'](work,0,False)
            work['C2_tail_start']=fixed['c2_counters'](work)
            read_fd,write_fd=os.pipe();calls=[];offset=0
            if axis=='R':assert os.write(write_fd,b'abcdefgh')==8
            try:
                for amount in (2,3,3):
                    fixed['c2_wire_room'](work,amount,axis)
                    if axis=='R':actual=os.read(read_fd,amount);count=len(actual)
                    else:count=os.write(write_fd,b'abcdefgh'[offset:offset+amount])
                    assert count==amount;calls.append(count);offset+=count
                    fixed['C2Channel'](None,work).charge(axis,count)
                try:fixed['c2_wire_room'](work,1,axis)
                except (c.Refusal,fixed['C2Refusal']):pass
                else:raise AssertionError('tail spent more than its reservation')
                if axis=='W':assert os.read(read_fd,8)==b'abcdefgh'
                assert work[field]==8 and work['physical_bytes']==0
                assert work['C2_tail_reservation']['common'][field]==8
            finally:os.close(read_fd);os.close(write_fd)
            print(json.dumps({'C2_residual':'tail-consumption','axis':axis,'spare':spare,'actual_calls':calls,
                'fixture_other_pipe_bytes':8,'pre_tail_no_credit':spare==0,'excess_refused':True,'work':work},sort_keys=True))
        work=prepare(field,8,short=1);work['C2_tail_start']=fixed['c2_counters'](work)
        try:fixed['c2_wire_room'](work,1,axis)
        except (c.Refusal,fixed['C2Refusal']):pass
        else:raise AssertionError('insufficient reserved tail admitted')
        assert work[field]==0
    probe=fresh('C2-tail-metadata');value={'observed':'finite metadata'}
    row={'owner':'C2-tail-unit','ordinal':1,'kind':'M','site':'tail-metadata','value':value}
    expected=c._private_capture_observations(row,probe,probe);amount=probe['read_bytes']
    work=prepare('read_bytes',amount);fixed['c2_nonruntime_room'](work,0,False)
    work['C2_tail_start']=fixed['c2_counters'](work);fixed['c2_nonruntime_room'](work,0,False)
    c._capture_observe(work,'M','tail-metadata',value)
    assert work['read_bytes']==amount and c.canonical(work['accounting_rows'][0])==expected
    try:c._capture_observe(work,'M','one-extra-row',value)
    except c.Refusal as error:assert error.code=='E_LIMIT'
    else:raise AssertionError('inner metadata encoder spent beyond tail reserve')
    assert work['read_bytes']==amount and work['accounting_incomplete']
    print(json.dumps({'C2_residual':'tail-metadata','actual_owner_read_bytes':amount,'fixture_probe_read_bytes':probe['read_bytes'],
        'inner_chunk_refusal':True,'original_reserved_unchanged':True,'work':work},sort_keys=True))



def _C3_work_evidence(results, directory, label):
    for index,row in enumerate(results):
        work=row["work"]
        counters={key:work.get(key) for key in ("read_bytes","write_bytes","physical_bytes","files",
            "export_read_bytes","export_write_bytes","export_physical_bytes","export_files",
            "runtime","seed_processing","accounting","accounting_incomplete","transfer_incomplete","close_calls")}
        detail={"status":"NOT_SAVED; ordinary mechanism evidence only"}
        if directory is not None:
            raw=(json.dumps(work,sort_keys=True)+"\n").encode()
            path=directory/(label+"-%02d.json" % index)
            with path.open("xb") as stream:stream.write(raw)
            detail={"path":str(path),"bytes":len(raw),"sha256":hashlib.sha256(raw).hexdigest()}
        row["work"]={"actual_counters":counters,"complete_work":detail}


def raw16_C3_reader_retention(root: Path, evidence=None) -> None:
    spec = importlib.util.spec_from_file_location("C3_reader_retention", root / "scope/v1/read-shadow-evidence.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    results = []
    class AppendFailure(list):
        def __init__(self, error):
            super().__init__();self.error = error
        def append(self, value):raise self.error
    for label in ("multiplicity", "ordinary-index", "marked-index", "ledger"):
        reader = module._Reader.__new__(module._Reader)
        reader.anchor = types.SimpleNamespace(recording_work={}, private_observations={})
        reader._initialize_replay_outputs()
        first, second = object(), object()
        raw = b"same authenticated document\n"
        error = MemoryError("controlled new index allocation")
        if label == "marked-index":
            error = InterruptedError("controlled actual scope handler")
            import ast
            tree = ast.parse((root / "scope/v1/read-shadow-evidence.py").read_text())
            main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")
            handler = next(node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == "cancel")
            namespace = {}
            exec(compile(ast.Module(body=[handler], type_ignores=[]), "<original-scope-handler>", "exec"), namespace)
            try:namespace["cancel"](15, None)
            except InterruptedError as caught:error = caught
        if label in {"ordinary-index", "marked-index"}:reader.replay_outputs["bundles"] = AppendFailure(error)
        observe = module.c._capture_observe
        if label == "ledger":
            def failed(*args, **kwargs):raise error
            module.c._capture_observe = failed
        caught = None
        try:
            try:
                reader._retain_replay_output("bundles", raw, (first, "current", "environment.one"))
                if label == "multiplicity":
                    reader._retain_replay_output("bundles", raw, (second, "qualifying", "environment.two"))
            except BaseException as actual:caught = actual
        finally:module.c._capture_observe = observe
        if label == "multiplicity":
            assert caught is None and len(reader.replay_outputs["bundles"]) == 2
            assert reader.replay_outputs["bundles"][0][1][0] is first
            assert reader.replay_outputs["bundles"][1][1][0] is second
            assert not reader.replay_output_unusable
        else:
            assert reader.replay_output_unusable and reader.anchor.private_observations["unusable"]
            assert reader.replay_output_errors[0]["error"] is error
            assert (caught is error) if label == "marked-index" else caught is None
        results.append({"case": label, "observations": len(reader.replay_outputs["bundles"]),
            "unusable": reader.replay_output_unusable, "work": reader.replay_output_work})
    _C3_work_evidence(results,evidence,"reader")
    print(json.dumps({"C3_actual_reader_retention": results, "qualification": "NOT_PROVED"}, sort_keys=True))


def raw16_C3_value_file(root: Path, deletion=False, evidence=None) -> None:
    import tempfile
    spec = importlib.util.spec_from_file_location('scope_shadow_consumer', root/'shadow/v1/_consumer.py')
    c = importlib.util.module_from_spec(spec);sys.modules[spec.name] = c;spec.loader.exec_module(c)
    spec = importlib.util.spec_from_file_location('C3_value_file_replay', root/'evals/v1/replay-malicious.py')
    replay = importlib.util.module_from_spec(spec);sys.modules[spec.name] = replay;spec.loader.exec_module(replay)
    if deletion:
        import inspect,textwrap
        source = textwrap.dedent(inspect.getsource(replay._SeedAssembly._write_value_file))
        guard = '_seed_require(held.before.st_size == len(raw))'
        assert source.count(guard) == 1
        source = source.replace(guard, 'pass')
        changed = {};exec(compile(source, '<remove-value-file-length>', 'exec'), replay.__dict__, changed)
        replay._SeedAssembly._write_value_file = changed['_write_value_file']
    results = []
    for label in ('normal', 'tail', 'writer-close'):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-value-') as temporary:
            base = Path(temporary).resolve();destination = base/'S';destination.mkdir(mode=0o700)
            resolver = c._DarwinUUIDResolver() if sys.platform == 'darwin' else None
            held = c._open_held(str(destination), True, c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver), 'E_STORE')
            anchor = c.Anchor.__new__(c.Anchor);anchor.resolver = resolver
            window, case = {}, {};c._capture_work_values(window, 'C3-window');c._capture_work_values(case, 'C3-case')
            case_id = 'malicious.checked-file-bytes';window['cases'] = {case_id:case}
            anchor.recording_work = window;anchor.private_observations = {}
            assembly = replay._SeedAssembly(held, anchor, case_id, window, case)
            raw = b'actual authenticated Git blob bytes\n' * 16
            opening, closing, syncing = c._open_child, os.close, os.fsync
            writer, attempted = [None], []
            fault = OSError(5,'controlled new S writer close')
            def sync(fd):
                syncing(fd)
                if fd != assembly.root.fd:writer[0] = fd
            def close(fd):
                if label == 'writer-close' and fd == writer[0] and not attempted:
                    attempted.append(fd);closing(fd);raise fault
                return closing(fd)
            def child(parent, name, *args, **kwargs):
                if label == 'tail' and name == 'candidate-000':
                    os.chmod(name,0o600,dir_fd=parent.fd,follow_symlinks=False)
                    fd = os.open(name, os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW, dir_fd=parent.fd)
                    try:assert os.write(fd,b'tail') == 4
                    finally:os.close(fd)
                    os.chmod(name,0o400,dir_fd=parent.fd,follow_symlinks=False)
                return opening(parent,name,*args,**kwargs)
            c._open_child,os.close,os.fsync = child,close,sync
            caught = None
            try:
                try:assembly._write_value_file(raw, 'candidate-000', 'write','recorded',
                    'candidate/README.md', 'recorded', 8*c.DOCUMENT_LIMIT)
                except BaseException as error:caught = error
            finally:c._open_child,os.close,os.fsync = opening,closing,syncing
            try:
                if label == 'normal':
                    assert caught is None and (destination/'candidate-000').read_bytes() == raw
                    assert assembly.files['candidate-000']['sha256'] == c.digest(raw)
                    assert assembly.semantic['candidate-000']['member'] == 'candidate/README.md'
                elif label == 'tail':
                    assert caught is not None, 'appended S tail accepted'
                    assert (destination/'candidate-000').stat().st_size == len(raw)+4
                    assert 'candidate-000' not in assembly.files
                else:
                    assert caught is fault and attempted == [writer[0]]
                    assert assembly.failure is fault and 'candidate-000' not in assembly.files
                results.append({'case':label,'rejected':caught is not None,'work':assembly.work,
                    'observed_partial_size':(destination/'candidate-000').stat().st_size})
            finally:
                primary = sys.exc_info()[1] or caught
                try:assembly.close(primary)
                except BaseException as error:assert error is primary
                held.close()
    _C3_work_evidence(results,evidence,'value')
    print(json.dumps({'C3_actual_value_file':results,'qualification':'NOT_PROVED'},sort_keys=True))


def raw16_C3_bundle_outputs(root: Path, candidate=False, selected=None, evidence=None) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('C3_bundle_reader',root/'scope/v1/read-shadow-evidence.py')
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
    c=module.c
    spec=importlib.util.spec_from_file_location('C3_bundle_replay',root/'evals/v1/replay-malicious.py')
    replay=importlib.util.module_from_spec(spec);sys.modules[spec.name]=replay;spec.loader.exec_module(replay)
    results=[]
    for label in (selected or (('normal','wrong-row-sha','repeat-candidate-observation') if candidate else ('normal','source-mode-drift','unusable','duplicate-binding','unknown-role','default-repeat','repeat-observation','repeat-target-identity','repeat-source-swap'))):
        phase='write' if candidate else 'reproduction'
        form='withheld-write.v1' if candidate else 'enforced-reproduction.v1'
        with tempfile.TemporaryDirectory(prefix='ystack-C3-bundle-') as temporary:
            base=Path(temporary).resolve();source=base/'published';source.mkdir(mode=0o700)
            destination=base/'S';destination.mkdir(mode=0o700)
            incident=c.canonical({'schema_version':1,'kind':'shadow_incident_record','id':'incident.fixture',
                'body':{'git_revision_ref':{'hash_algorithm':'sha1','commit_id':'a'*40}}})
            request=c.canonical({'schema_version':1,'kind':'sandbox_launch_request','id':'launch.fixture','body':{}})
            files={name:(c.canonical({'synthetic':name}) if name.endswith('.json') else b'synthetic output\n')
                for name in c.SHADOW_EVIDENCE_NAMES}
            files.update({'incident.json':incident,'sandbox-request.json':request,
                'shadow-record.json':c.canonical({'schema_version':1,'kind':'shadow_reproduction_record',
                    'id':'incident.fixture','body':{'record_form':form}})})
            if candidate:
                files['publisher-body.txt']=b'withheld synthetic publication\n'
                candidate_files={'evidence/README.md':b'actual original Git README bytes\n',
                    'evidence/eval-seed.json':c.canonical({'actual_original_git_seed':1})}
                candidate_rows=[{'path':name,'mode':'100644','sha256':c.digest(raw),'git_blob_oid':'a'*40,'add_only':True}
                    for name,raw in sorted(candidate_files.items())]
                files['shadow-record.json']=c.canonical({'schema_version':1,'kind':'shadow_reproduction_record',
                    'id':'incident.fixture','body':{'record_form':form,'write':{'write_set':candidate_rows}}})
            files['bundle.json']=c.canonical({'schema_version':1,'kind':'shadow_consumer_bundle',
                'id':'bundle.'+c.digest(incident)[:32],'body':{'activation_state':'inactive',
                    'record_form':form,'incident_sha256':c.digest(incident),
                    'target_revision':json.loads(incident)['body']['git_revision_ref'],
                    'files':[{'name':name,'size_bytes':len(raw),'sha256':c.digest(raw)} for name,raw in sorted(files.items())]}})
            for name,raw in files.items():(source/name).write_bytes(raw);(source/name).chmod(0o400)
            if label=='repeat-source-swap':
                alternate=base/'other-published';alternate.mkdir(mode=0o700)
                for name,raw in files.items():(alternate/name).write_bytes(raw);(alternate/name).chmod(0o400)
            resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
            parent=c._open_held(str(base),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            bundle=c._HeldBundle(parent,'published',form)
            seed=c._open_child(parent,'S',True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            anchor=c.Anchor.__new__(c.Anchor);anchor.resolver=resolver;anchor.held=[]
            window,case={},{};c._capture_work_values(window,'C3-window');c._capture_work_values(case,'C3-case')
            window['cases']={'malicious.checked-file-bytes':case};anchor.recording_work=window;anchor.private_observations={}
            reader=module._Reader.__new__(module._Reader);reader.anchor=anchor;reader.commands_open=True
            reader.owned=[bundle];reader.inputs=[];reader._initialize_replay_outputs()
            reader._retain_replay_output('bundles',files['shadow-record.json'],(bundle,'current','environment.one'))
            reader._retain_replay_output('bundles',files['shadow-record.json'],(bundle,'qualifying','environment.one'))
            assembly=replay._SeedAssembly(seed,anchor,'malicious.checked-file-bytes',window,case)
            assembly.bindings[phase]={'request_raw':request};assembly.original_raw=(incident,)
            assembly.generator=types.SimpleNamespace(reader=reader)
            if label=='source-mode-drift':(source/'incident.json').chmod(0o600)
            if label=='unusable':reader.replay_output_state[0]=True
            if label=='unknown-role':reader.replay_outputs['bundles'][0]=(files['shadow-record.json'],(bundle,'invented','environment.one'))
            caught=None
            try:
                try:
                    assembly.bundle_outputs(phase,reader)
                    if label=='duplicate-binding':assembly.bundle_outputs(phase,reader)
                    if label in {'repeat-observation','repeat-target-identity','repeat-source-swap'}:
                        if label=='repeat-target-identity':
                            (source/'incident.json').chmod(0o600);(source/'incident.json').chmod(0o400)
                        repeated=c._HeldBundle(parent,'other-published' if label=='repeat-source-swap' else 'published',form)
                        reader.owned.append(repeated)
                        reader._retain_replay_output('bundles',files['shadow-record.json'],(repeated,'current','environment.one'))
                        before_copy=(assembly.work['physical_bytes'],assembly.work['files'])
                        assembly.bundle_outputs(phase,reader)
                        assert (assembly.work['physical_bytes'],assembly.work['files'])==before_copy
                    if label=='default-repeat':
                        source_leaf=next(item for item in bundle.held if item.path==str(source/'incident.json'))
                        assembly._copy(anchor,source_leaf,'default-repeat.bin',c.digest(incident),'recorded',source_mode=0o400)
                    if candidate:
                        git=c._ReadOnlyGit.__new__(c._ReadOnlyGit);git.held=[];git.ledger=reader;reader.git=git
                        rows=[dict(row) for row in candidate_rows]
                        if label=='wrong-row-sha':rows[0]['sha256']='f'*64
                        reader._retain_replay_output('git',files['shadow-record.json'],(candidate_files,rows,git,bundle.files))
                        assembly.candidate_outputs(reader)
                        if label=='repeat-candidate-observation':
                            before_copy=(assembly.work['physical_bytes'],assembly.work['files'])
                            reader._retain_replay_output('git',files['shadow-record.json'],
                                (dict(candidate_files),[dict(row) for row in rows],git,bundle.files))
                            assembly.candidate_outputs(reader)
                            assert (assembly.work['physical_bytes'],assembly.work['files'])==before_copy
                except BaseException as error:caught=error
                if label in {'normal','repeat-observation','repeat-candidate-observation'}:
                    assert caught is None and len(assembly.files)==2*len(files)+(4 if candidate else 0)
                    assert len(assembly.output_relations)==(3 if label=='repeat-observation' else 2) and assembly.output_relations[0][3:5]!=assembly.output_relations[1][3:5]
                    assert all((destination/assembly.derived_outputs[phase]['bundle/generator/'+role+'/environment.one/'+name]).read_bytes()==raw
                        for role in ('current','qualifying') for name,raw in files.items())
                else:assert caught is not None and assembly.failure is caught
                results.append({'case':label,'rejected':caught is not None,'output_files':len(assembly.files),
                    'actual_relations':len(assembly.output_relations),'work':assembly.work,
                    'native_authentication':'NOT_PROVED synthetic typed bundle/anchor; actual held/read/copy checks only'})
            finally:
                primary=sys.exc_info()[1] or caught
                try:assembly.close(primary)
                except BaseException as error:assert error is primary
                for owned_bundle in reader.owned:owned_bundle.close()
                seed.close();parent.close()
    _C3_work_evidence(results,evidence,'candidate' if candidate else 'bundle')
    print(json.dumps({'C3_actual_bundle_outputs':results},sort_keys=True))


def raw16_C3_gate_outputs(root: Path, evidence=None) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('C3_output_generator',root/'scope/v1/generate-gate-evidence.py')
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
    c=module.c
    spec=importlib.util.spec_from_file_location('C3_gate_output_replay',root/'evals/v1/replay-malicious.py')
    replay=importlib.util.module_from_spec(spec);sys.modules[spec.name]=replay;spec.loader.exec_module(replay)
    results=[]
    for label in ('normal','missing-output','wrong-size','unusable'):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-gate-output-') as temporary:
            base=Path(temporary).resolve();output=base/'gate';output.mkdir(mode=0o700)
            destination=base/'S';destination.mkdir(mode=0o700)
            names=('objects/request/value.json','private/reader-captures/captured.json','manifests/manifest.json','completion/COMPLETE.json')
            for name in names:(output/name).parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            raw={names[0]:c.canonical({'actual_synthetic_request':1}),names[1]:b'original reader capture\n'}
            rows=[{'name':name,'size_bytes':len(value),'sha256':c.digest(value)} for name,value in sorted(raw.items())]
            if label=='wrong-size':rows[0]['size_bytes']+=1
            identity='generation.fixture'
            manifest=module._manifest_values(identity,rows,[],{},c.canonical({'body':{'initial_origin_refs':[]}}),None)
            raw.update({names[2]:manifest,names[3]:module._completion_values(identity,manifest)})
            for name,value in raw.items():(output/name).write_bytes(value);(output/name).chmod(0o400)
            for path in (base, *base.rglob('*')):
                os.chown(path, os.getuid(), os.getgid())
            resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
            generator=module._Generator.__new__(module._Generator)
            generator.output=output;generator.active=True;generator.deadline=time.monotonic()+60
            generator.held=[];generator._init_output_capture()
            anchor=c.Anchor.__new__(c.Anchor);anchor.resolver=resolver;anchor.held=[];anchor.private_observations={}
            window,case={},{};c._capture_work_values(window,'C3-window');c._capture_work_values(case,'C3-case')
            window['cases']={'malicious.unread-forge-text':case};anchor.recording_work=window
            reader=module.r._Reader.__new__(module.r._Reader)
            reader.owned=[];reader.inputs=[];reader.anchor=anchor;reader.darwin=resolver
            reader.commands_open=True;reader.source_copies=[]
            generator.reader=reader;generator.session=types.SimpleNamespace(phase='FINAL_OWNER')
            owned=[]
            for name,value in raw.items():
                held=c._hold_bytes(str(output/name),c.DOCUMENT_LIMIT);owned.append(held)
                assert type(held) is c._HeldBytes and held.raw == value and held.raw is not value
                if name==names[1]:reader.owned.append(held)
                elif name != names[3]:generator.output_holds[name]=held;generator.held.append(held)
            if label=='missing-output':reader.owned=[]
            if label=='unusable':generator.capture_output_unusable=True
            parent=c._open_held(str(destination),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            assembly=replay._SeedAssembly(parent,anchor,'malicious.unread-forge-text',window,case)
            assembly.generator=assembly._gate_owner=generator;assembly.gate_session=generator.session
            assembly.identifiers['gate']=identity;assembly.occurrences['gate']={}
            caught=None
            try:
                try:
                    assembly.gate_output_members()
                    generator.session.phase='COMPLETE'
                    generator.output_holds[names[3]]=owned[-1]
                    assembly.gate_outputs()
                except BaseException as error:caught=error
                if label=='normal':
                    assert caught is None and set(assembly.derived_outputs['gate-output'])==set(raw)
                    assert len(assembly.files)==len(raw)
                    assert assembly.gate_manifest_pending is generator.output_holds['manifests/manifest.json'].raw
                    assert assembly.gate_manifest_pending == manifest and assembly.gate_manifest_pending is not manifest
                    assert all((destination/assembly.derived_outputs['gate-output'][name]).read_bytes()==value for name,value in raw.items())
                else:assert caught is not None and assembly.failure is caught
                results.append({'case':label,'rejected':caught is not None,'files':len(assembly.files),
                    'work':assembly.work,'scope':'partial actual held-output mechanism only; not complete 13 families or native'})
            finally:
                primary=sys.exc_info()[1] or caught
                try:assembly.close(primary)
                except BaseException as error:assert error is primary
                for item in owned:item.close()
                parent.close()
    _C3_work_evidence(results,evidence,'gate')
    print(json.dumps({'C3_actual_gate_output_copy':[{key:value for key,value in row.items() if key != 'work'} for row in results]},sort_keys=True))
    raw16_C3_gate_phase_seam(root,evidence)


def raw16_C3_I_inputs(root: Path, evidence=None) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('ystack_shadow_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    spec=importlib.util.spec_from_file_location('C3_I_replay',root/'evals/v1/replay-malicious.py')
    replay=importlib.util.module_from_spec(spec);sys.modules[spec.name]=replay;spec.loader.exec_module(replay)
    results=[]
    class Unregistered(list):
        def append(self,value):raise allocation
    for label in ('normal','wrong-sha','extra-file','owner-register','owner-register-cancel'):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-I-') as temporary:
            base=Path(temporary).resolve();case=base/'malicious.checked-file-bytes';case.mkdir(mode=0o700)
            data={'incident.json':b'{"primitive":"synthetic"}\n','slot.bin':b'qualified synthetic input\n'*4097}
            rows=[]
            for name,raw in data.items():
                (case/name).write_bytes(raw);(case/name).chmod(0o400)
                rows.append({'occurrence':'case' if name=='incident.json' else 'reproduction',
                    'role':'original-input' if name=='incident.json' else 'capture',
                    'member':name if name=='incident.json' else 'reproduction/runtime-0000-guest_kernel-0000.bin',
                    'file':name,'size_bytes':len(raw),'sha256':c.digest(raw),'kind':'raw' if name=='incident.json' else 'runtime'})
            if label=='wrong-sha':rows[1]['sha256']='f'*64
            if label=='extra-file':(case/'extra').write_bytes(b'extra');(case/'extra').chmod(0o400)
            core={'case_id':case.name,'entries':rows,'originals':{},'occurrences':[]}
            resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
            parent=c._open_held(str(case),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            work={};c._capture_work_values(work,'C3-I-control')
            clone,opened,closing=c._clone,c._open_child,os.close
            tracked=set();attempts={};allocation=MemoryError('controlled C3 owner append');cancelled=[]
            def cloned(*args,**kwargs):
                components=clone(*args,**kwargs);tracked.update(item.fd for item in components);return components
            def child(*args,**kwargs):
                item=opened(*args,**kwargs);tracked.update(component.fd for component in item.components);return item
            def close(fd):
                if fd in tracked:
                    attempts[fd]=attempts.get(fd,0)+1
                    closing(fd)
                    if label=='owner-register-cancel' and not cancelled:
                        import ast
                        tree=ast.parse((root/'scope/v1/read-shadow-evidence.py').read_text())
                        main=next(item for item in tree.body if isinstance(item,ast.FunctionDef) and item.name=='main')
                        handler=next(item for item in main.body if isinstance(item,ast.FunctionDef) and item.name=='cancel')
                        namespace={};exec(compile(ast.Module(body=[handler],type_ignores=[]),'<actual-scope-cancel>','exec'),namespace)
                        try:namespace['cancel'](15,None)
                        except InterruptedError as error:cancelled.append(error);raise
                    return
                return closing(fd)
            original_setattr=replay._ReplayInputs.__setattr__
            def assigned(self,name,value):
                if name=='owned' and label.startswith('owner-register'):value=Unregistered()
                return original_setattr(self,name,value)
            replay._ReplayInputs.__setattr__=assigned
            c._clone,c._open_child,os.close=cloned,child,close
            acquired=None;caught=None
            try:
                try:
                    acquired=replay._ReplayInputs(parent,core,work)
                    assert acquired.bytes('case','original-input','incident.json',c.DOCUMENT_LIMIT)==data['incident.json']
                    value=acquired.semantic('reproduction','capture','reproduction/runtime-0000-guest_kernel-0000.bin')
                    assert type(value) is tuple and b''.join(value)==data['slot.bin']
                except BaseException as error:caught=error
                if label=='normal':assert caught is None
                elif label=='owner-register':assert caught is allocation
                elif label=='owner-register-cancel':assert caught is cancelled[0]
                else:assert caught is not None
            finally:
                primary=sys.exc_info()[1] or caught
                if acquired is not None:
                    try:acquired.close(primary)
                    except BaseException as error:assert error is primary
                c._clone,c._open_child,os.close=clone,opened,closing
                replay._ReplayInputs.__setattr__=original_setattr
                assert set(attempts)==tracked and all(count==1 for count in attempts.values())
                parent.recheck('E_STORE');parent.close()
            results.append({'case':label,'rejected':caught is not None,'all_owned_FDs_closed_once':True,
                'real_first_cancel_preserved':bool(cancelled) and caught is cancelled[0],
                'work':work,'full_seed':False,'partial_inventory_only':True})
    _C3_work_evidence(results,evidence,'I')
    print(json.dumps({'C3_independent_I_input_owner':results},sort_keys=True))



def raw16_C3_git_inputs(root: Path, evidence=None) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('scope_shadow_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    spec=importlib.util.spec_from_file_location('C3_git_replay',root/'evals/v1/replay-malicious.py')
    replay=importlib.util.module_from_spec(spec);sys.modules[spec.name]=replay;spec.loader.exec_module(replay)
    results=[]
    for label in ('normal','wrong-sha','duplicate-path','unsafe-path','target-drift','files-full'):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-git-') as temporary:
            base=Path(temporary).resolve()
            for name in ('source','S','rebuilt','tools'):(base/name).mkdir(mode=0o700)
            source=base/'source'
            tree=write_loose(source,'sha1','tree',b'')
            commit_body=('tree '+tree+'\nauthor Fixture <fixture@example.invalid> 0 +0000\ncommitter Fixture <fixture@example.invalid> 0 +0000\n\nsynthetic\n').encode()
            commit=write_loose(source,'sha1','commit',commit_body)
            write_bytes(source/'HEAD', (commit+'\n').encode())
            write_bytes(source/'config',b'[core]\nrepositoryformatversion = 0\nbare = true\n')
            names=('incident.json','reproduction-request.json','write-request.json','gate-request.json')
            kinds=('shadow_incident_record','shadow_enforced_request','shadow_write_request','scope_gate_generation_request')
            original=[]
            for index,(name,kind) in enumerate(zip(names,kinds)):
                raw=c.canonical({'kind':kind,'id':'ordinary.'+str(index),'body':{'observed_at':'2026-10-27T00:00:00Z'}})
                write_bytes(base/'tools'/name,raw)
            for path in base.rglob('*'):
                if path.is_file():path.chmod(0o400)
            resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
            rule=c._store_rule(os.getuid(),os.getgid(),0o400,False,resolver)
            sources=[]
            for path in sorted(source.rglob('*')):
                if path.is_file():
                    held=c._open_held(str(path),False,rule,'E_STORE');sources.append(held)
            for name in names:
                held=c._open_held(str(base/'tools'/name),False,rule,'E_STORE')
                original.append(c._HeldBytes(held,(base/'tools'/name).read_bytes()))
            parent=c._open_held(str(base/'S'),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            target=c._open_held(str(base/'rebuilt'),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            anchor=c.Anchor.__new__(c.Anchor);anchor.resolver=resolver;anchor.private_observations={}
            window,case={},{};c._capture_work_values(window,'C3-window');c._capture_work_values(case,'C3-case')
            case_id='malicious.checked-file-bytes';window['cases']={case_id:case};anchor.recording_work=window
            assembly=replay._SeedAssembly(parent,anchor,case_id,window,case)
            entries=tuple({'path':str(Path(held.path).relative_to(source)),'sha256':c.digest(Path(held.path).read_bytes()),'held':held} for held in sources)
            if label=='wrong-sha':entries=({**entries[0],'sha256':'f'*64},)+entries[1:]
            if label=='duplicate-path':entries=entries+(entries[0],)
            if label=='unsafe-path':entries=({**entries[0],'path':'objects/info/alternates'},)+entries[1:]
            if label=='target-drift':
                os.chmod(sources[0].path,0o600)
            caught=None;incoming=None;work={}
            try:
                try:
                    assembly.original_inputs(*original)
                    assembly.original_git_inputs(anchor,entries)
                    assembly.close()
                    core=assembly._closed_inventory_core_data()['inventory_core']
                    current=c._open_held(str(base/'S'),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
                    try:incoming=replay._ReplayInputs(current,core,work)
                    finally:current.close()
                    if label=='files-full':work['files']=256
                    actual=incoming.git_repository(target)
                    assert set(actual)=={entry['path'] for entry in entries}
                    for path in actual:assert (base/'rebuilt'/path).read_bytes()==(source/path).read_bytes()
                    if label=='normal':
                        command=['/usr/bin/cc','-std=c11','-Wall','-Wextra','-Werror','-O2',str(root/'adapters/local-git-materializer/v1/object-closure.c'),'-o',str(base/'tools'/'object-closure')]
                        compiled=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={'PATH':'/usr/bin:/bin','LC_ALL':'C','TMPDIR':str(base/'tools')})
                        assert compiled.returncode==0,compiled.stderr
                        closure=base/'tools'/'closure'
                        command=[str(base/'tools'/'object-closure'),'walk',str(base/'rebuilt'),'sha1',commit,str(closure)]
                        walked=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={'PATH':'/usr/bin:/bin','LC_ALL':'C','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'})
                        assert walked.returncode==0,walked.stderr
                        assert commit.encode() in closure.read_bytes() and tree.encode() in closure.read_bytes()
                        work['offline_compile_and_closure_work_unknown']=True
                except BaseException as error:caught=error
                if label=='normal':assert caught is None,repr(caught)
                else:
                    assert caught is not None,label
                    if label=='files-full':
                        assert isinstance(caught,c.Refusal) and caught.code=='E_LIMIT'
                        assert not list((base/'rebuilt').iterdir())
            finally:
                primary=sys.exc_info()[1] or caught
                if incoming is not None:incoming.close(primary)
                assembly.close(primary)
                for held in sources:held.close()
                for item in original:item.close()
                target.close();parent.close()
            results.append({'case':label,'rejected':caught is not None,'error':None if caught is None else repr(caught),
                'files':len(assembly.files),'work':assembly.work,'I_and_rebuild_work':work,'full_seed':False,
                'original_materializer_jq16':'NOTRUN: local fixed jq1.6 absent','source_caller_qualification':'UNKNOWN'})
    details=[{'work':row['I_and_rebuild_work']} for row in results]
    _C3_work_evidence(details,evidence,'git-I')
    for row,detail in zip(results,details):row['I_and_rebuild_work']=detail['work']
    _C3_work_evidence(results,evidence,'git')
    print(json.dumps({'C3_actual_explicit_git_inputs':results},sort_keys=True))



def raw16_C3_trial_documents(root: Path, evidence=None) -> None:
    import tempfile
    spec=importlib.util.spec_from_file_location('scope_shadow_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    spec=importlib.util.spec_from_file_location('C3_trial_replay',root/'evals/v1/replay-malicious.py')
    replay=importlib.util.module_from_spec(spec);sys.modules[spec.name]=replay;spec.loader.exec_module(replay)
    spec=importlib.util.spec_from_file_location('C3_trial_original_enforced',root/'shadow/v1/enforced-reproduction.py')
    e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e);c=e.c
    results=[]
    for label in ('normal','InputSnapshot','duplicate','wrong-mode','qualified-not-input','wrong-request-source','gate-cross-binding'):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-documents-') as temporary:
            base=Path(temporary).resolve()
            for name in ('inputs','S'):(base/name).mkdir(mode=0o700)
            names=('incident.json','reproduction-request.json','write-request.json','gate-request.json')
            kinds=('shadow_incident_record','shadow_enforced_request','shadow_write_request','scope_gate_generation_request')
            gate_body={'scope_basis':{'basis':'actual request input'},'risk_claim':{'risk':'actual request input'}}
            documents={'reproduction/claim.json':c.canonical({'id':'claim.repro'}),
                'reproduction/duty-evaluation.json':c.canonical({'id':'duty.repro'}),
                'reproduction/qualified-identity.json':c.canonical({'id':'identity.original'}),
                'reproduction/materialization-input.json':c.canonical({'padding':'x'*(c.DOCUMENT_LIMIT+1)}),
                'gate/shadow-set.json':c.canonical({'actual':'shadow-set'}),
                'gate/dashboard.json':c.canonical({'actual':'dashboard'}),
                'gate/marker.json':c.canonical({'actual':'marker'}),
                'gate/basis.json':c.canonical(gate_body['scope_basis']),
                'gate/claim.json':c.canonical(gate_body['risk_claim'])}
            if label=='gate-cross-binding':documents['gate/basis.json']=c.canonical({'basis':'different input'})
            request_body={name.split('/',1)[1][:-5].replace('-','_'):str(base/'inputs'/str(index+4)) for index,name in enumerate(documents) if name.startswith('reproduction/')}
            originals={name:c.canonical({'kind':kind,'id':'ordinary.'+str(index),'body':gate_body if index==3 else request_body if index==1 else {'observed_at':'2026-10-27T00:00:00Z'}}) for index,(name,kind) in enumerate(zip(names,kinds))}
            all_raw=list(originals.values())+list(documents.values())
            for index,raw in enumerate(all_raw):
                path=base/'inputs'/str(index);path.write_bytes(raw);path.chmod(0o400)
                if label=='InputSnapshot' and index>=4:
                    target=base/'inputs'/('snapshot-'+str(index));target.write_bytes(raw);target.chmod(0o400)
            resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
            rule=c._store_rule(os.getuid(),os.getgid(),0o400,False,resolver)
            items=[c._HeldBytes(c._open_held(str(base/'inputs'/str(index)),False,rule,'E_STORE'),raw) for index,raw in enumerate(all_raw)]
            if label=='InputSnapshot':
                items[4:]=[e.InputSnapshot(item.held,base/'inputs'/('snapshot-'+str(index)),item.raw) for index,item in enumerate(items[4:],4)]
            parent=c._open_held(str(base/'S'),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
            anchor=c.Anchor.__new__(c.Anchor);anchor.resolver=resolver;anchor.private_observations={}
            window,case={},{};c._capture_work_values(window,'C3-window');c._capture_work_values(case,'C3-case')
            case_id='malicious.checked-file-bytes';window['cases']={case_id:case};anchor.recording_work=window
            assembly=replay._SeedAssembly(parent,anchor,case_id,window,case)
            entries=tuple({'member':name,'source':item} for name,item in zip(documents,items[4:]))
            if label=='duplicate':entries=entries+(entries[0],)
            if label=='wrong-mode':os.chmod(items[4].held.path,0o600)
            if label=='qualified-not-input':entries=({'member':'write/qualified-identity.json','source':items[4]},)
            if label=='wrong-request-source':entries=({'member':entries[0]['member'],'source':items[5]},)+entries[1:]
            incoming=None;work={};caught=None
            try:
                try:
                    assembly.original_inputs(*items[:4]);assembly.trial_documents(anchor,entries);assembly.close()
                    core=assembly._closed_inventory_core_data()['inventory_core']
                    current=c._open_held(str(base/'S'),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STORE')
                    try:incoming=replay._ReplayInputs(current,core,work)
                    finally:current.close()
                    values=replay._ReplayCase.__new__(replay._ReplayCase)
                    values.inputs=incoming;values.c=c;values.work=work;values.original={'gate-request.json':json.loads(originals['gate-request.json'])}
                    actual=values.trial('reproduction')
                    assert len(actual['materialization-input.json'])>c.DOCUMENT_LIMIT
                    for name,raw in actual.items():assert raw==documents['reproduction/'+name]
                    gate=values.trial('gate')
                    assert gate['basis.json']==c.canonical(gate_body['scope_basis'])
                except BaseException as error:caught=error
                if label in ('normal','InputSnapshot'):assert caught is None,repr(caught)
                else:assert caught is not None,label
            finally:
                primary=sys.exc_info()[1] or caught
                if incoming is not None:incoming.close(primary)
                assembly.close(primary)
                for item in items:item.close()
                parent.close()
            results.append({'case':label,'rejected':caught is not None,'error':None if caught is None else repr(caught),
                'work':assembly.work,'I_work':work,'full_seed':False,'original_schema_and_qualification':'NOT_PROVEN; private held copy/consumer only'})
    details=[{'work':row['I_work']} for row in results];_C3_work_evidence(details,evidence,'trial-I')
    for row,detail in zip(results,details):row['I_work']=detail['work']
    _C3_work_evidence(results,evidence,'trial')
    print(json.dumps({'C3_actual_trial_documents':results},sort_keys=True))



def raw16_C3_driver_input_owners(root: Path, evidence=None) -> None:
    from pathlib import Path
    import ast,contextlib,datetime,hashlib,importlib.util,json,os,shlex,stat,sys,traceback,tempfile
    repo=root;attempt="C3-driver-input"
    launcher=(repo/'evals/v1/evals-launcher.sh').read_bytes()
    consumer_path=repo/'shadow/v1/_consumer.py';consumer_raw=consumer_path.read_bytes()
    program=shlex.split(launcher.decode()[launcher.decode().index("c2_program='"):launcher.decode().index('\nc2_fd9=false')],posix=True)[0].split('=',1)[1]
    ast.parse(program)
    spec=importlib.util.spec_from_file_location('actual_C2_input_consumer',consumer_path)
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    ns={'__name__':'bounded_actual_C2_symbols','c':c};exec(compile(program,str(repo/'evals/v1/evals-launcher.sh')+':c2_program','exec'),ns)
    C2Root=ns['C2Root'];fresh=ns['c2_fresh_work'];sha=ns['c2_sha'];canonical=ns['c2_canonical'];check_input=ns['c2_driver_input_check'];build_input=ns['c2_driver_input']
    root_area=Path(tempfile.mkdtemp(prefix='ystack-driver-input-'+attempt+'-',dir=tempfile.gettempdir())).resolve();os.chown(root_area,-1,os.getegid())
    results=[]
    def check(value,label):
     if not value:raise AssertionError(label)
    def fds():
     result=set()
     for name in os.listdir('/dev/fd'):
      if name.isdigit():
       try:os.fstat(int(name));result.add(int(name))
       except OSError:pass
     return result
    def owned_fds(custody):return {row.fd for held in custody.owned for row in held.components}
    def error_value(error):return None if error is None else dict(category=type(error).__name__,errno=getattr(error,'errno',None),code=getattr(error,'code',None),message=str(error))
    def prepare(name,mode='run',malformed=False):
     base=root_area/name;base.mkdir(mode=0o700);scratch=base/'scratch';scratch.mkdir(mode=0o700);root=base/'root';root.mkdir(mode=0o700)
     manifest=None
     raws=[canonical(dict(schema_version=1,kind='synthetic_input',id='seed.'+str(index),body=dict(value=index))) for index in range(1 if mode=='run' else 4)]
     expected=[sha(raw) for raw in raws]
     if mode=='run':(scratch/'input.json').write_bytes(raws[0]);(scratch/'input.json').chmod(0o400)
     else:
      (scratch/'inputs').mkdir(mode=0o700)
      for label,raw in zip(('seed-0.json','result-0.json','seed-1.json','result-1.json'),raws):(scratch/'inputs'/label).write_bytes(raw);(scratch/'inputs'/label).chmod(0o400)
      manifest=b'{bad json\n' if malformed else canonical([dict(seed_sha256=expected[0],result_sha256=expected[1]),dict(seed_sha256=expected[2],result_sha256=expected[3])])
      (scratch/'inputs/manifest.json').write_bytes(manifest);(scratch/'inputs/manifest.json').chmod(0o400)
     if name=='positive-run':
      window=canonical({'cases':{},'carry_in':{}})
      (root/'window.json').write_bytes(window);(root/'window.json').chmod(0o400)
     return root,scratch,raws,expected,manifest
    scenarios=[('positive-run','run',False),('positive-dashboard','dashboard',False),('START-sha','run',False),('START-fullbytes','run',False),('registration-failure','run',False),('source-close-ordinary','run',False),('source-close-marked','run',False),('source-close-keyboard','run',False),('manifest-parse-failure','dashboard',True),('helper-unknown-refusal','run',False)]
    fixtures={name:prepare(name,mode,malformed) for name,mode,malformed in scenarios}
    @contextlib.contextmanager
    def setup(name,mode='run',malformed=False):
     root,scratch,raws,expected,_manifest=fixtures[name]
     work=fresh('bounded-driver-input-'+name)
     # Empty actual unit-scope counter owners declare no prior helper/native work.
     before=ns['c2_counters'](fresh('bounded-empty-before'))
     reservation=ns['c2_counters'](fresh('bounded-zero-tail'))
     ns['c2_reserve'](before,reservation)
     work['C2_admitted_before']=before;work['C2_tail_reservation']=reservation
     resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
     start_fds=fds();held=None;custody=None;entry=dict(name=name,mode=mode,started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),input_origin='synthetic static files; original builder/helper not executed')
     try:
      held=c._open_held(str(root),True,c._store_rule(os.geteuid(),os.getegid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M')
      custody=C2Root(held,work,resolver);operations=custody.mkdir(held,'operations');operation=custody.mkdir(operations,'0');installed=custody.mkdir(operation,'I');destination=custody.mkdir(installed,'driver-input')
      entry['synthetic_root']=str(root_area);entry['root_fd']=held.fd;entry['root_identity']=list(c._identity(held.before));entry['expected']=expected
      yield custody,destination,scratch,raws,expected,entry
      entry['passed']=True
     except BaseException as error:
      entry['passed']=False;entry['test_error']=error_value(error);entry['traceback']=traceback.format_exc()
      drift=[];tb=error.__traceback__
      while tb is not None:
       frame=tb.tb_frame
       if frame.f_code.co_name=='recheck' and frame.f_code.co_filename==str(consumer_path):
        values=frame.f_locals;row={}
        for key in ('current','expected','named','index','path'):
         if key in values:
          value=values[key]
          row[key]=list(value) if isinstance(value,(tuple,os.stat_result)) else value
        component=values.get('component')
        if component is not None:row['component']={'name':component.name,'before':list(component.before)}
        drift.append(row)
       tb=tb.tb_next
      entry['actual_traceback_locals']=drift
      raise
     finally:
      if custody is not None:
       try:custody.close()
       except BaseException as error:entry['cleanup_error']=error_value(error)
       entry['closed']=custody.closed;entry['remaining_owned']=len(custody.owned)
      elif held is not None:
       try:held.close()
       except BaseException as error:entry['cleanup_error']=error_value(error)
      entry['fd_set_restored']=fds()==start_fds
      entry['work']=work
      entry['completed_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
      if evidence is not None:
       target=evidence/(attempt+'-'+name+'.json')
       with target.open('x') as stream:stream.write(json.dumps(entry,sort_keys=True,indent=2)+'\n')
      results.append(dict(name=name,passed=entry.get('passed',False),fd_set_restored=entry['fd_set_restored']))
      check(entry['fd_set_restored'],'unit leaked actual descriptors')
    def expect_failure(fn,code=None,same=None):
     try:fn()
     except BaseException as error:
      if code is not None:check(getattr(error,'code',None)==code,'wrong refusal '+str(error))
      if same is not None:check(error is same,'lost exact original exception')
      return error
     raise AssertionError('negative input unexpectedly accepted')
    def root_live(custody,entry):
     check(not custody.closed and bool(custody.root.components),'root was closed by input boundary')
     check(c._identity(os.fstat(custody.root.fd))==c._identity(custody.root.before) and c._identity(custody.root.before)[:6]==custody.initial[:6],'root descriptor identity moved')
     entry['root_still_live']=True
    for mode in ('run','dashboard'):
     with setup('positive-'+mode,mode) as (custody,destination,scratch,raws,expected,entry):
      initial=fds();json_original=ns['json'].loads;encode_original=ns['C2Channel'].encode;phases=[]
      def measured_json(raw,*args,**kwargs):
       result=json_original(raw,*args,**kwargs)
       if mode=='dashboard' and raw==fixtures['positive-dashboard'][4]:phases.append(dict(read=custody.work['read_bytes'],R=custody.work['seed_processing']['R'],M=custody.work['accounting']['M']['read_bytes'],size=len(raw)))
       return result
      def measured_encode(self,value):
       if phases and 'parse_read_delta' not in phases[-1]:
        p=phases[-1];p['parse_read_delta']=custody.work['read_bytes']-p['read'];p['parse_R_delta']=custody.work['seed_processing']['R']-p['R'];p['parse_M_delta']=custody.work['accounting']['M']['read_bytes']-p['M']
       return encode_original(self,value)
      ns['json'].loads=measured_json;ns['C2Channel'].encode=measured_encode
      window_source=None
      if mode=='run':
       held=custody.adopt(c._open_child(custody.root,'window.json',False,
        c._store_rule(os.geteuid(),os.getegid(),0o400,False,custody.resolver),'E_STALE',
        recording_work=custody.work,accounting_kind='M'))
       window_raw=held.read(ns['_C2_LIMIT'],'E_STALE',custody.work)
       window_source=(held,window_raw,sha(window_raw))
      try:path,seals=build_input(custody,destination,str(scratch),mode,raws,expected,window_source)
      finally:ns['json'].loads=json_original;ns['C2Channel'].encode=encode_original
      check(path==destination.path+('/seed.json' if mode=='run' else ''),'wrong fixed path')
      check(len(seals)==(2 if mode=='run' else 5),'wrong original output count')
      for held,raw,digest in seals:
       check(type(held) is c.HeldPath and held.components,'fake holder type')
       check(stat.S_IMODE(os.fstat(held.fd).st_mode)==0o400,'wrong installed mode')
       check(Path(held.path).read_bytes()==raw and sha(raw)==digest,'actual bytes/hash differ')
      check(fds()-initial<=owned_fds(custody),'scratch source descriptors left live')
      check_input(custody,seals);custody.recheck();root_live(custody,entry)
      if mode=='dashboard':
       check(len(phases)==1 and all(phases[0][k]==phases[0]['size'] for k in ('parse_read_delta','parse_R_delta','parse_M_delta')),'actual parse fee not exact')
      entry['descriptor_copy']='mechanism-only; incomplete synthetic descriptor is not full manifest authority' if mode=='run' else 'not requested';entry['parse_phases']=phases;entry['installed']=[dict(path=h.path,sha256=digest,size=len(raw)) for h,raw,digest in seals]
      if mode=='run':
       old_H=custody.work['seed_processing']['H'];wrong=b'x'*len(seals[0][1])
       expect_failure(lambda:check_input(custody,[(seals[0][0],wrong,seals[0][2])]),code='E_STALE')
       check(custody.work['seed_processing']['H']==old_H,'equal-false reported unexecuted hash')
       entry['wrong_bytes_rejected_without_hash']=True;root_live(custody,entry)
    for variant in ('START-sha','START-fullbytes'):
     with setup(variant) as (custody,destination,scratch,raws,expected,entry):
      initial=fds();args_raw=list(raws);args_sha=list(expected)
      if variant=='START-sha':args_sha[0]='0'*64
      else:args_raw[0]=b'x'*len(args_raw[0])
      error=expect_failure(lambda:build_input(custody,destination,str(scratch),'run',args_raw,args_sha),code='E_RELATION')
      check(not os.listdir(destination.fd),'mismatched START produced installed file');check(fds()==initial,'mismatch leaked source fd')
      custody.recheck();root_live(custody,entry);entry['refusal']=error_value(error)
    with setup('registration-failure') as (custody,destination,scratch,raws,expected,entry):
     sentinel=MemoryError('actual holder ownership registration injection')
     class FailingOwned(list):
      def append(self,value):
       if value.path==destination.path+'/seed.json':raise sentinel
       return super().append(value)
     custody.owned=FailingOwned(custody.owned);initial=fds()
     error=expect_failure(lambda:build_input(custody,destination,str(scratch),'run',raws,expected),same=sentinel)
     check(fds()==initial,'registration failure leaked acquired fd');root_live(custody,entry)
     check((Path(destination.path)/'seed.json').read_bytes()==raws[0],'failed physical file lost')
     entry['refusal']=error_value(error);entry['retained_failed_file']=True
    for variant,sentinel in [('ordinary',OSError(5,'actual source close failure injection')),('marked',InterruptedError(4,'actual source close marked injection')),('keyboard',KeyboardInterrupt('actual source close keyboard injection'))]:
     if variant=='marked':sentinel._scope_signal_cancel=True
     with setup('source-close-'+variant) as (custody,destination,scratch,raws,expected,entry):
      initial=fds();original_helper=c._close_capture_copy;original_close=c.os.close;active=[None];fired=[]
      def measured_helper(fd,work,case_work,site,failure):
       previous=active[0];active[0]=fd if site=='C2.driver-input-source-close' else None
       try:return original_helper(fd,work,case_work,site,failure)
       finally:active[0]=previous
      def failed_close(fd):
       original_close(fd)
       if active[0]==fd and not fired:fired.append(fd);raise sentinel
      c._close_capture_copy=measured_helper;c.os.close=failed_close
      try:error=expect_failure(lambda:build_input(custody,destination,str(scratch),'run',raws,expected),same=sentinel)
      finally:c._close_capture_copy=original_helper;c.os.close=original_close
      check(fired and fds()-initial<=owned_fds(custody),'source close failed to drain real source chains')
      root_live(custody,entry);entry['refusal']=error_value(error);entry['injected_fd']=fired[0]
      check(custody.work.get('driver_input_close_unknown'),'close failure not UNKNOWN')
    with setup('manifest-parse-failure','dashboard',malformed=True) as (custody,destination,scratch,raws,expected,entry):
     initial=fds();error=expect_failure(lambda:build_input(custody,destination,str(scratch),'dashboard',raws,expected),code='E_RELATION')
     check(custody.work.get('driver_input_parse_unknown'),'failed actual parse not UNKNOWN')
     check(not os.listdir(destination.fd) and fds()==initial,'parse failure leaked source/installed fd')
     root_live(custody,entry);entry['refusal']=error_value(error)
    with setup('helper-unknown-refusal') as (custody,destination,scratch,raws,expected,entry):
     custody.work['helper_internal_work_unknown']='UNKNOWN: real original helper has no complete measured transfer'
     initial=fds();error=expect_failure(lambda:build_input(custody,destination,str(scratch),'run',raws,expected),code='E_LIMIT')
     check(not os.listdir(destination.fd) and fds()==initial,'UNKNOWN budget path performed copy')
     root_live(custody,entry);entry['refusal']=error_value(error)
    summary=dict(attempt=attempt,launcher_sha256=hashlib.sha256(launcher).hexdigest(),consumer_sha256=hashlib.sha256(consumer_raw).hexdigest(),results=results,complete=True,helper_builder_native_runtime='NOTRUN',cost='UNKNOWN')
    if evidence is not None:
     with (evidence/(attempt+'-summary.json')).open('x') as stream:stream.write(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(dict(actual_controls=len(results),all_passed=all(row['passed'] and row['fd_set_restored'] for row in results),summary=attempt+'-summary.json',helper_native='NOTRUN'),sort_keys=True))



def raw16_C3_export_stage(root: Path, deletion=False, evidence=None) -> None:
    import shlex,tempfile
    spec=importlib.util.spec_from_file_location('C3_export_consumer',root/'shadow/v1/_consumer.py')
    c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
    source=(root/'evals/v1/evals-launcher.sh').read_text()
    literal=shlex.split(source.split('c2_program=',1)[1].split('\nc2_fd9=',1)[0])[0]
    if deletion:
        begin=literal.index('            c2_require(type(name) is str and name not in')
        end=literal.index('\n            role = ',begin)
        literal=literal[:begin]+'            c2_require(type(name) is str and name not in {"", ".", ".."} and name not in entries, "E_SHAPE")'+literal[end:]
    fixed={'__name__':'C3_export_fixed','c':c};exec(compile(literal,'<actual-C3-export-stage>','exec'),fixed)
    results=[]
    for label in (('third-export',) if deletion else ('normal','third-export','extra-file','cross-occurrence')):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-export-') as temporary:
            base=Path(temporary).resolve();window=base/'window';window.mkdir(mode=0o700)
            cases=window/'cases';cases.mkdir(mode=0o700);identity='malicious.checked-file-bytes'
            casepath=cases/identity;casepath.mkdir(mode=0o700);S=casepath/'S';S.mkdir(mode=0o700)
            exports=S/'exports';exports.mkdir(mode=0o700);destination=window/'I';destination.mkdir(mode=0o700)
            data={'reproduction.bin':b'bounded synthetic reproduction export','write.bin':b'bounded synthetic write export'}
            if label=='third-export':data={'kill.bin':b'not one of the two fixed export roles'}
            entries=[]
            for name,raw in data.items():
                (exports/name).write_bytes(raw);(exports/name).chmod(0o400)
                phase=name[:-4]
                entries.append({'occurrence':phase,'role':'capture','member':'launch-0001/sandbox-export.bin',
                    'file':'exports/'+name,'size_bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'kind':'export'})
            if label=='extra-file':(exports/'extra').write_bytes(b'extra');(exports/'extra').chmod(0o400)
            if label=='cross-occurrence':entries[0]['occurrence']='write'
            work=fixed['c2_fresh_work']('C3-export-stage')
            resolver=c._DarwinUUIDResolver() if sys.platform=='darwin' else None
            held=c._open_held(str(window),True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M')
            custody=fixed['C2Root'](held,work,resolver)
            target=custody.adopt(c._open_child(held,'I',True,c._store_rule(os.getuid(),os.getgid(),0o700,True,resolver),'E_STALE',recording_work=work,accounting_kind='M'))
            total=fixed['c2_fresh_work']('C3-export-case');work['C2_case_totals']={identity:total}
            before={'window':fixed['c2_counter_values'](fixed['c2_fresh_work']('C3-export-before')),
                'cases':{identity:fixed['c2_counter_values'](fixed['c2_fresh_work']('C3-export-case-before'))}}
            core={'case_id':identity,'entries':entries,'originals':{},'occurrences':{}}
            raw=fixed['C2Channel'](None,work).encode(core)
            descriptor={'carry_in':{},'cases':{key:({'inventory_core':core,'sha256':hashlib.sha256(raw).hexdigest()} if key==identity else None) for key in fixed['_C2_CASES']}}
            copies=fixed['C2Copies'](custody);caught=None
            try:
                try:
                    fixed['c2_stage'](custody,descriptor,[identity],target,before,copies)
                    copies.final_checks();copies.transfer_cases()
                except BaseException as error:caught=error
                if label=='normal':
                    assert caught is None,repr(caught)
                    for name,value in data.items():assert (destination/identity/'exports'/name).read_bytes()==value
                    assert work['export_write_bytes']==total['export_write_bytes']==sum(map(len,data.values()))
                elif label=='third-export':assert caught is not None,'unexpected export pathname accepted'
                else:assert caught is not None,label
            finally:
                primary=sys.exc_info()[1] or caught
                copies.transfer_cases()
                custody.close(primary)
            results.append({'case':label,'rejected':caught is not None,'work':work,'case_work':total,
                'full_seed':False,'source_data':'synthetic bytes, no original binary export/native qualification'})
    details=[{'work':row['case_work']} for row in results];_C3_work_evidence(details,evidence,'export-case')
    for row,detail in zip(results,details):row['case_work']=detail['work']
    _C3_work_evidence(results,evidence,'export-window')
    print(json.dumps({'C3_fixed_export_stage':results},sort_keys=True))


def raw16_C3_payload_result_body(root: Path) -> list[dict]:
    import ast
    import copy

    spec = importlib.util.spec_from_file_location(
        'C3_payload_result_actual_enforced', root / 'shadow/v1/enforced-reproduction.py')
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    replay_source = (root / 'evals/v1/replay-malicious.py').read_text()
    reproduction = next(node for node in ast.parse(replay_source).body
                        if isinstance(node, ast.FunctionDef) and node.name == '_reproduction_values')
    payload_index = next(index for index, node in enumerate(reproduction.body)
                         if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call)
                         and isinstance(node.value.func, ast.Attribute)
                         and isinstance(node.value.func.value, ast.Name)
                         and node.value.func.value.id == 'owner' and node.value.func.attr == 'payload_result')
    payload_call = reproduction.body[payload_index]
    assert isinstance(payload_call.targets[0], ast.Tuple)
    assert [node.id for node in payload_call.targets[0].elts] == ['result_raw', 'result']
    byte_check, outcome, initialize_output = reproduction.body[payload_index + 1:payload_index + 4]
    assert isinstance(byte_check, ast.Expr) and isinstance(byte_check.value, ast.Call)
    assert isinstance(byte_check.value.func, ast.Attribute) and byte_check.value.func.attr == 'require'
    assert isinstance(outcome, ast.Assign) and outcome.targets[0].id == 'outcome'
    assert isinstance(initialize_output, ast.Assign) and initialize_output.targets[0].id == 'output'
    record_call = next(node for node in reproduction.body
                       if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call)
                       and isinstance(node.value.func, ast.Attribute)
                       and isinstance(node.value.func.value, ast.Name)
                       and node.value.func.value.id == 'owner'
                       and node.value.func.attr == '_reproduction_record_values')
    assert isinstance(record_call.value.args[9], ast.Name) and record_call.value.args[9].id == 'result'
    selected = ast.Module(body=[payload_call, byte_check, outcome, initialize_output, record_call],
                          type_ignores=[])
    binding = compile(selected, '<actual-reproduction-payload-to-record-binding>', 'exec')
    raw_file = b'finite ordinary checked file bytes\n'
    digest = owner.sha(raw_file)
    revision = {'hash_algorithm': 'sha1', 'commit_id': '1' * 40}
    incident = {'schema_version': 1, 'kind': 'shadow_incident_record', 'id': 'incident.payload-control',
        'body': {'observed_at': '2026-10-27T00:00:00Z', 'target_repository_id': 'repo.payload-control',
                 'git_revision_ref': revision,
                 'failing_check': {'kind': 'file-digest', 'path': 'checked.txt', 'expected_sha256': digest}}}
    instruction = owner.make_instruction(incident)
    body = {'check': {'path': 'checked.txt', 'expected_sha256': digest},
            'instruction_sha256': owner.sha(instruction),
            'observed': {'sha256': digest, 'size_bytes': len(raw_file)},
            'outcome': 'match', 'reason_id': 'file.match'}
    envelope = {'schema_version': 1, 'kind': 'file_digest_verifier_payload',
                'id': 'file-digest-payload', 'body': body}
    preparation = {'entries': [{'path': 'checked.txt', 'sha256': digest, 'size_bytes': len(raw_file)}]}

    def document(kind):
        return owner.canonical({'schema_version': 1, 'kind': kind, 'id': 'synthetic.' + kind, 'body': {}})

    identity = {'body': {'ordinary': 'identity-value-domain'}}
    evaluation = {'body': {'verdict': 'satisfied', 'reason_ids': ['synthetic.reason']}}
    materializer_receipt = {'source': {'repository_id': 'repo.payload-control',
        'hash_algorithm': 'sha1', 'commit_id': '1' * 40, 'tree_id': '2' * 40},
        'candidate': {'commit_id': '1' * 40, 'parent_commit_id': '1' * 40, 'tree_id': '2' * 40},
        'changed_paths': {'count': 0}}
    response = {'stage_result': {'schema_version': 2, 'kind': 'stage_result', 'id': 'stage.payload-control',
        'body': {'outcome': {'family': 'change', 'value': 'no-change'}}},
        'payloads': [{'data': owner.canonical(materializer_receipt).decode()}]}
    materialized = {'response_raw': owner.canonical(response),
        'evaluation_raw': owner.canonical(evaluation), 'qualified_identity_raw': owner.canonical(identity)}
    assert owner.require_no_change(materialized['response_raw'], incident) == materializer_receipt
    results = []
    for label in ('envelope', 'flat-body', 'manifest-row-digest', 'receipt-manifest-digest', 'preparation-observed'):
        payload_raw = owner.canonical(body if label == 'flat-body' else envelope)
        manifest = {'schema_version': 1, 'kind': 'sandbox_evidence_manifest', 'id': 'evidence-manifest',
            'body': {'files': [{'name_hex': b'file-digest-result.json'.hex(),
                              'size_bytes': len(payload_raw), 'sha256': owner.sha(payload_raw)}]}}
        if label == 'manifest-row-digest':
            manifest['body']['files'][0]['sha256'] = owner.sha(b'different payload bytes')
        manifest_raw = owner.canonical(manifest)
        sandbox_receipt = {'body': {'lifecycle': {'admission': 'admitted', 'runtime': 'completed',
            'control_deadline': 'met'}, 'teardown': {'state': 'confirmed'},
            'payload': {'exit_state': 'exited', 'exit_code': 0, 'stdout_sha256': owner.sha(b''),
                'stderr_sha256': owner.sha(b''), 'evidence_manifest_sha256': owner.sha(manifest_raw)}}}
        if label == 'receipt-manifest-digest':
            sandbox_receipt['body']['payload']['evidence_manifest_sha256'] = owner.sha(b'different manifest')
        sandbox_receipt.update(schema_version=1, kind='sandbox_receipt', id='receipt.payload-control')
        current_preparation = copy.deepcopy(preparation)
        if label == 'preparation-observed':
            current_preparation['entries'][0]['sha256'] = owner.sha(b'different prepared content')
        files = {'incident.json': owner.canonical(incident), 'claim.json': document('environment_claim'),
            'registry.json': document('environment_registry'), 'payload-stdout.txt': b'', 'payload-stderr.txt': b'',
            'file-digest-result.json': payload_raw, 'evidence-manifest.json': manifest_raw,
            'preparation-manifest.json': owner.canonical(current_preparation),
            'sandbox-receipt.json': owner.canonical(sandbox_receipt),
            'sandbox-request.json': document('sandbox_launch_request'),
            'sandbox-expectation.json': document('sandbox_receipt_expectation'),
            'sandbox-check.json': document('sandbox_check'), 'origin-observation.json': document('origin'),
            'trace-ledger.json': document('telemetry_trace_ledger')}
        namespace = {'owner': owner, 'files': files, 'materialized': materialized, 'incident': incident,
            'identity': identity, 'evaluation': evaluation, 'receipt': materializer_receipt,
            'instruction': instruction, 'context': {'store_id': 'synthetic.store'},
            'provenance': document('shadow_consumer_provenance')}
        caught = None
        try:
            exec(binding, namespace)
        except owner.Refusal as error:
            caught = error
        if label == 'envelope':
            assert caught is None, repr(caught)
            assert namespace['result_raw'] == payload_raw
            assert namespace['result'] == envelope['body'] and 'body' not in namespace['result']
            assert namespace['outcome'] == 'no-change'
            record = owner.parse(namespace['output']['shadow-record.json'])
            assert record['body']['check']['execution']['value'] == {
                'tool_id': 'tool.verifier', 'observed_sha256': digest, 'matches_expected': True}
            assert record['body']['sandbox']['payload_ref']['sha256'] == owner.sha(payload_raw)
        else:
            assert caught is not None and caught.code == 'E_RELATION', (label, repr(caught))
            assert 'result' not in namespace, 'invalid payload passed the original result owner'
            assert 'output' not in namespace, 'record construction ran after a rejected payload'
        results.append({'case': label, 'rejected': caught is not None,
            'input_payload_bytes': len(payload_raw), 'input_payload_sha256': owner.sha(payload_raw),
            'qualification': 'finite-payload-and-original-call-binding-only'})
    print(json.dumps({'C3_payload_result_body': results,
        'source_reproduction_function_sha256': owner.sha(ast.get_source_segment(replay_source, reproduction).encode()),
        'full_reproduction_input_chain': 'NOTRUN', 'native': 'NOTRUN'}, sort_keys=True))
    return results


def raw16_C3_write_builder_values(root: Path) -> dict:
    import importlib.util
    import sys
    spec = importlib.util.spec_from_file_location('C3_write_builder_owner', root / 'shadow/v1/write-shadow.py')
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    canonical, parse, sha = owner.canonical, owner.parse, owner.sha
    claim_raw = canonical({'id': 'environment.builder'})
    request = {'id': 'write.builder'}
    events = []
    def observed_sha(raw):
        events.append(('sha', raw))
        return sha(raw)
    def observed_parse(raw, *args):
        events.append(('parse', raw))
        return parse(raw, *args)
    owner.sha, owner.parse = observed_sha, observed_parse
    try:
        metadata = owner._write_builder_metadata_values(b'contract', b'patch', ['evidence/a'],
            request, claim_raw, 'withheld-write.v1')
        assert events == [('sha', b'contract'), ('sha', b'patch'), ('sha', b'write.builder'),
            ('parse', claim_raw), ('sha', claim_raw)]
        assert metadata == {'contract': sha(b'contract'), 'patch': sha(b'patch'),
            'allowed_paths': ['evidence/a'], 'attempt_id': request['id'],
            'suffix': sha(request['id'].encode())[:32], 'environment_id': 'environment.builder',
            'claim_sha256': sha(claim_raw), 'record_form': 'withheld-write.v1'}
    finally:
        owner.sha, owner.parse = sha, parse
    original = {'profile': {'id': 'p'}, 'resolved_profile': {'id': 'r'}, 'manifests': []}
    original_raw = canonical(original)
    first = {'original': original, 'stage_request': {'id': 'stage.builder'}}
    assert owner._write_builder_first_values(canonical(first), original_raw) == first
    stage_raw = canonical(first['stage_request'])
    final = dict(original, stage_request={'content': first['stage_request'], 'sha256': sha(stage_raw)})
    assert owner._write_builder_final_values(canonical(final), first, stage_raw, original_raw) == final
    rejected = []
    for label in ('original', 'stage-digest', 'profile', 'resolved_profile', 'manifests'):
        changed = json.loads(canonical(final))
        try:
            if label == 'original':
                owner._write_builder_first_values(canonical(first), original_raw + b' ')
            else:
                if label == 'stage-digest':changed['stage_request']['sha256'] = '0' * 64
                else:changed[label] = {'changed': True}
                owner._write_builder_final_values(canonical(changed), first, stage_raw, original_raw)
        except owner.e.Refusal as error:
            assert error.code == 'E_RELATION'
            rejected.append(label)
        else:raise AssertionError('write builder relationship accepted: ' + label)
    return {'normal': True, 'metadata_operation_order': True, 'rejected': rejected,
        'jq_builder_execution': 'NOTRUN', 'qualification': 'NOTACCEPTED'}


def raw16_C3_cleanup_decoder(root: Path) -> dict:
    import copy
    import tempfile
    import sys
    import importlib.util
    host_spec = importlib.util.spec_from_file_location('C3_cleanup_recording_host', root / 'sandbox/v1/host-supervisor.py')
    host = importlib.util.module_from_spec(host_spec);host_spec.loader.exec_module(host)
    replay_spec = importlib.util.spec_from_file_location('C3_cleanup_replay', root / 'evals/v1/replay-malicious.py')
    replay = importlib.util.module_from_spec(replay_spec);sys.modules[replay_spec.name] = replay
    replay_spec.loader.exec_module(replay)
    workspace = Path(tempfile.mkdtemp(prefix='ystack-c3-cleanup-'))
    results = []
    for label in ('empty', 'candidate-survivor', 'attempt-missing'):
        work = workspace / label;work.mkdir(mode=0o700)
        if label != 'attempt-missing':
            attempt = work / 'attempt.cleanup';attempt.mkdir(mode=0o700)
            frozen = attempt / 'frozen';frozen.mkdir(mode=0o700)
            candidate = frozen / 'candidate';candidate.mkdir(mode=0o700)
            for name in host.LAUNCH_FIXED_NAMES:(attempt / name).write_bytes(b'launch')
            for name in host.FROZEN_FIXED_NAMES:(frozen / name).write_bytes(b'frozen')
            (candidate / '00000').write_bytes(b'candidate')
            if label == 'candidate-survivor':
                survivor = b'unknown-\xff' if sys.platform.startswith('linux') else 'unknown-é'.encode()
                fd = os.open(os.fsencode(candidate) + b'/' + survivor, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o400)
                os.close(fd)
        capture = {'rows': [], 'ordinals': {}, 'bytes': 0, 'complete': True}
        host._capture_process = capture
        try:native = host.remove_frozen(str(work), 'attempt.cleanup', ['00000'])
        finally:host._capture_process = None
        assert capture['complete']
        calculated = replay._host_cleanup_values(root, capture['rows'], ['00000'])
        assert calculated is native and native is (label != 'candidate-survivor')
        rejected = []
        mutations = ('missing', 'extra', 'ordinal', 'wrong-site', 'wrong-type')
        for mutation in mutations:
            rows = copy.deepcopy(capture['rows'])
            if mutation == 'missing':rows.pop()
            elif mutation == 'extra':rows.append(copy.deepcopy(rows[-1]))
            elif mutation == 'ordinal':rows[0]['ordinal'] += 1
            elif mutation == 'wrong-site':rows[0]['site'] = 'remove_frozen.foreign.open'
            else:rows[0]['return'] = True
            try:replay._host_cleanup_values(root, rows, ['00000'])
            except (ValueError, replay._CalculationRefused):rejected.append(mutation)
            else:raise AssertionError('cleanup mutation accepted: ' + mutation)
        results.append({'label': label, 'native_result': native, 'rows': capture['rows'], 'rejected': rejected})
    return {'cases': results, 'retained_fixture_root': str(workspace), 'native_qualification': 'NOTRUN'}


def raw16_C3_accounted_io(root: Path, evidence=None, deletion=False, cancel_deletion=False) -> dict:
    import tempfile
    import sys
    import importlib.util
    spec = importlib.util.spec_from_file_location('ystack_shadow_consumer', root / 'shadow/v1/_consumer.py')
    c = importlib.util.module_from_spec(spec);sys.modules[spec.name] = c;spec.loader.exec_module(c)
    spec = importlib.util.spec_from_file_location('C3_io_replay', root / 'evals/v1/replay-malicious.py')
    replay = importlib.util.module_from_spec(spec);sys.modules[spec.name] = replay;spec.loader.exec_module(replay)
    if deletion:
        import ast,textwrap
        source_text = (root / 'evals/v1/replay-malicious.py').read_text()
        tree = ast.parse(source_text)
        cls = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == '_ReplayCase')
        function = next(node for node in cls.body if isinstance(node, ast.FunctionDef) and node.name == '_replay_write_bytes')
        text = textwrap.dedent(ast.get_source_segment(source_text, function))
        guard = '    self.c._capture_copy_room(self.work, len(raw), False, case=True)\n'
        assert text.count(guard) == 1
        namespace = dict(vars(replay))
        exec(compile(text.replace(guard, '', 1), '<actual-first-M-admission-deleted>', 'exec'), namespace)
        replay._ReplayCase._replay_write_bytes = namespace['_replay_write_bytes']
    if cancel_deletion:
        import ast
        text = (root / 'evals/v1/replay-malicious.py').read_text()
        function = next(node for node in ast.parse(text).body if isinstance(node, ast.FunctionDef) and node.name == '_seed_first')
        source = ast.get_source_segment(text, function)
        guard = 'isinstance(first, KeyboardInterrupt) or '
        assert source.count(guard) == 1
        namespace = dict(vars(replay))
        exec(compile(source.replace(guard, '', 1), '<actual-first-KB-rule-deleted>', 'exec'), namespace)
        replay._seed_first = namespace['_seed_first']
    results = []
    labels = (('keyboard-observer-cancel',) if cancel_deletion else ('case-room',) if deletion else
        ('normal', 'case-room', 'partial-account', 'first-cancel', 'keyboard-observer-cancel'))
    for label in labels:
        work = owner = inputs = source_hold = None
        error = None
        try:
            base = Path(tempfile.mkdtemp(prefix='ystack-C3-accounted-io-')).resolve()
            source, destination = base / 'I', base / 'work'
            source.mkdir(mode=0o700);destination.mkdir(mode=0o700)
            os.chown(source, os.getuid(), os.getgid());os.chown(destination, os.getuid(), os.getgid())
            raw = b'{"synthetic":"original"}\n'
            (source / 'incident.json').write_bytes(raw);(source / 'incident.json').chmod(0o400)
            os.chown(source / 'incident.json', os.getuid(), os.getgid())
            row = {'occurrence': 'case', 'role': 'original-input', 'member': 'incident.json',
                'file': 'incident.json', 'size_bytes': len(raw), 'sha256': c.digest(raw), 'kind': 'raw'}
            core = {'case_id': 'malicious.checked-file-bytes', 'entries': [row], 'originals': {}, 'occurrences': []}
            resolver = c._DarwinUUIDResolver() if sys.platform == 'darwin' else None
            source_hold = c._open_held(str(source), True,
                c._store_rule(os.getuid(), os.getgid(), 0o700, True, resolver), 'E_STORE')
            work = {};c._capture_work_values(work, 'C3-IO-ordinary')
            inputs = replay._ReplayInputs(source_hold, core, work)
            owner = object.__new__(replay._ReplayCase)
            owner.inputs, owner.c, owner.work, owner._replay_io_holds = inputs, c, work, []
            parent = c._open_held(str(destination), True,
                c._store_rule(os.getuid(), os.getgid(), 0o700, True, resolver), 'E_STORE',
                recording_work=work, accounting_kind='M')
            owner._replay_hold_work(parent)
            opened, written, closed = os.open, os.write, os.close
            account = c._capture_account
            observe_error = c._capture_observation_error
            target = [];writes = [];closes = []
            fault = MemoryError('actual write followed by accounting failure')
            keyboard = KeyboardInterrupt('first actual write accounting cancellation')
            observer_events = []
            cancelled = InterruptedError('actual owned close cancelled');cancelled._scope_signal_cancel = True
            def opening(name, flags, *args, **kwargs):
                fd = opened(name, flags, *args, **kwargs)
                if name == 'value.json' and flags & os.O_WRONLY:target.append(fd)
                return fd
            def writing(fd, value):
                count = written(fd, value[:2] if label == 'partial-account' else value)
                if fd in target:writes.append(count)
                return count
            def closing(fd):
                result = closed(fd)
                if fd in target:
                    closes.append(fd)
                    if label == 'first-cancel':raise cancelled
                return result
            def accounting(values, kind, field, amount):
                if label in {'partial-account', 'keyboard-observer-cancel'} and values is work and field == 'write_bytes' and target:
                    raise keyboard if label == 'keyboard-observer-cancel' else fault
                return account(values, kind, field, amount)
            def observation_error(values, kind, site, error, *args, **kwargs):
                if label == 'keyboard-observer-cancel' and values is work and error is keyboard:
                    observer_events.append(cancelled)
                    raise cancelled
                return observe_error(values, kind, site, error, *args, **kwargs)
            before = {key: work[key] for key in ('read_bytes', 'write_bytes', 'physical_bytes', 'files')}
            if label == 'case-room':work['write_bytes'] = 64 * c.DOCUMENT_LIMIT - 1
            os.open, os.write, os.close, c._capture_account = opening, writing, closing, accounting
            c._capture_observation_error = observation_error
            error = None
            try:
                if label == 'normal':
                    seed = owner._replay_mkdir(parent, 'seed')
                    assert seed.listdir() == []
                owner._replay_write_bytes(parent, 'value.json', b'abcd')
            except BaseException as caught:error = caught
            finally:
                os.open, os.write, os.close, c._capture_account = opened, written, closed, account
                c._capture_observation_error = observe_error
            if label == 'normal':
                assert error is None and (destination / 'value.json').read_bytes() == b'abcd'
                assert sum(writes) == 4 and work['write_bytes'] - before['write_bytes'] == 4
                assert work['physical_bytes'] - before['physical_bytes'] == 4
                assert len(closes) == 1
            elif label == 'case-room':
                assert error is not None and not target and not writes and not (destination / 'value.json').exists(), 'M pre-admission allowed a target open'
            elif label == 'partial-account':
                assert error is fault and writes == [2] and len(closes) == 1
                assert (destination / 'value.json').read_bytes() == b'ab'
                assert work['write_bytes'] - before['write_bytes'] == work['physical_bytes'] - before['physical_bytes'] == 2
                assert work['write_accounting_incomplete']
            elif label == 'keyboard-observer-cancel':
                assert error is keyboard and inputs.failure is keyboard and observer_events, 'first KeyboardInterrupt replaced by observer cancellation'
                assert all(event is cancelled for event in observer_events)
                assert len(closes) == 1 and writes == [4] and work['write_accounting_incomplete']
                assert work['write_bytes'] - before['write_bytes'] == work['physical_bytes'] - before['physical_bytes'] == 4
            else:
                assert error is cancelled and len(closes) == 1 and sum(writes) == 4
            results.append({'case': label, 'rejected': error is not None, 'actual_write_counts': writes,
                'writer_close_attempts': len(closes), 'retained_root': str(base),
                'known': {key: work[key] for key in ('read_bytes', 'write_bytes', 'physical_bytes', 'files')},
                'simulated_case_carry': label == 'case-room', 'full_case_constructor': 'NOTRUN'})
        finally:
            primary = sys.exc_info()[1] or error
            failure = primary
            if owner is not None:failure = owner._replay_close_io(failure)
            if inputs is not None:
                try:inputs.close(failure)
                except BaseException as later:failure = replay._ReplayCase._replay_io_first(failure, later)
            if source_hold is not None:
                try:source_hold.close()
                except BaseException as later:failure = replay._ReplayCase._replay_io_first(failure, later)
            if evidence is not None and work is not None:
                path = Path(evidence) / ("accounted-io-" + label + ".json")
                with path.open("x") as stream:json.dump(work, stream, sort_keys=True)
            if failure is not None and failure is not primary:raise failure
    return {'controls': results, 'native_qualification': 'NOTRUN'}


def raw16_C3_runtime_digest_and_held_close(root: Path, evidence=None) -> dict:
    import ast
    import collections
    import tempfile
    spec = importlib.util.spec_from_file_location('C3_stream_enforced', root / 'shadow/v1/enforced-reproduction.py')
    e = importlib.util.module_from_spec(spec);sys.modules[spec.name] = e;spec.loader.exec_module(e)
    c = e.c
    spec = importlib.util.spec_from_file_location('C3_stream_replay', root / 'evals/v1/replay-malicious.py')
    replay = importlib.util.module_from_spec(spec);sys.modules[spec.name] = replay;spec.loader.exec_module(replay)
    source = ast.parse((root / 'shadow/v1/_consumer.py').read_text())
    digest_node = next(node for node in source.body if isinstance(node, ast.FunctionDef) and node.name == 'digest')
    assert not any(isinstance(node, ast.Attribute) and node.attr == 'join' for node in ast.walk(digest_node))
    base = Path(tempfile.mkdtemp(prefix='ystack-C3-stream-close-')).resolve()
    os.chown(base, -1, os.getegid())
    resolver = c._DarwinUUIDResolver() if sys.platform == 'darwin' else None
    raw = b'A' * 65536 + b'B' * 17
    metrics = []
    def save(label, value):
        parent = Path(evidence) if evidence is not None else base
        with (parent / ('runtime-stream-' + label + '.json')).open('x') as stream:
            json.dump(value, stream, sort_keys=True)
    for label in ('normal', 'second-update-keyboard'):
        folder = base / label;folder.mkdir(mode=0o700);os.chown(folder, -1, os.getegid())
        path = folder / 'runtime.bin';path.write_bytes(raw);path.chmod(0o400);os.chown(path, -1, os.getegid())
        initial = inputs = None;primary = None
        work = c._c3_fresh_work(1)
        original_sha, original_error = c.hashlib.sha256, c._capture_observation_error
        try:
            initial = c._open_held(str(folder), True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver), 'E_STORE')
            row = {'occurrence': 'reproduction', 'role': 'local-runtime', 'member': 'runtime/runtime.bin',
                'file': 'runtime.bin', 'kind': 'runtime', 'size_bytes': len(raw), 'sha256': c.digest(raw)}
            core = {'case_id': 'malicious.checked-file-bytes', 'entries': [row], 'originals': {}, 'occurrences': []}
            inputs = replay._ReplayInputs(initial, core, work)
            chunks = inputs.semantic('reproduction', 'local-runtime', 'runtime/runtime.bin')
            assert type(chunks) is tuple and tuple(map(len, chunks)) == (65536, 17)
            assert chunks[0] == raw[:65536] and chunks[1] == raw[65536:]
            before = c._c3_values_vector(c._c3_work_values(work))
            native_calls = []
            def native_hash(data=b''):
                native_calls.append(len(data))
                return original_sha(data)
            c.hashlib.sha256 = native_hash
            expected = e.sha(raw)
            c.hashlib.sha256 = original_sha
            assert expected == original_sha(raw).hexdigest() and native_calls == [len(raw)]
            assert c._c3_values_vector(c._c3_work_values(work)) == before
            baseline_h, baseline_runtime_h = work['seed_processing']['H'], work['runtime']['sha_bytes']
            updates, constructors, observer_errors = [], [], []
            keyboard = KeyboardInterrupt('second real digest update cancelled')
            marked = InterruptedError('later digest failure observer cancelled');marked._scope_signal_cancel = True
            class HashUpdates:
                def __init__(self):self.real = original_sha()
                def update(self, chunk):
                    assert len(chunk) <= 65536, 'runtime digest formed a whole binary buffer'
                    updates.append(len(chunk))
                    if label == 'second-update-keyboard' and len(updates) == 2:raise keyboard
                    return self.real.update(chunk)
                def hexdigest(self):return self.real.hexdigest()
            def stream_hash(data=b''):
                constructors.append(len(data))
                assert data == b'', 'runtime digest hashed a joined binary'
                return HashUpdates()
            def observation_error(values, kind, site, error):
                result = original_error(values, kind, site, error)
                if values is work and error is keyboard:
                    observer_errors.append(marked)
                    raise marked
                return result
            c.hashlib.sha256 = stream_hash
            c._capture_observation_error = observation_error
            error = None
            try:measured = c.digest(chunks, runtime_work=work)
            except BaseException as caught:
                error = caught
                inputs._failed(caught)
            finally:
                c.hashlib.sha256, c._capture_observation_error = original_sha, original_error
            assert constructors == [0] and updates == [65536, 17]
            if label == 'normal':
                assert error is None and measured == expected and 'runtime_digest_incomplete' not in work
                assert work['seed_processing']['H'] - baseline_h == len(raw)
                assert work['runtime']['sha_bytes'] - baseline_runtime_h == len(raw)
            else:
                assert error is keyboard and inputs.failure is keyboard and observer_errors == [marked]
                assert work['runtime_digest_incomplete']
                assert work['seed_processing']['H'] - baseline_h == 65536
                assert work['runtime']['sha_bytes'] - baseline_runtime_h == 65536
                primary = keyboard
            metrics.append({'case': label, 'bytes': len(raw), 'chunks': len(chunks), 'update_sizes': updates,
                'runtime_H': work['runtime']['sha_bytes'] - baseline_runtime_h,
                'seed_H': work['seed_processing']['H'] - baseline_h, 'first_keyboard_preserved': error is keyboard})
        finally:
            c.hashlib.sha256, c._capture_observation_error = original_sha, original_error
            if inputs is not None:inputs.close(primary)
            if initial is not None:initial.close()
            save(label, work)
    for label in ('recording-keyboard-marked', 'native-none', 'native-none-keyboard'):
        folder = base / label;folder.mkdir(mode=0o700);os.chown(folder, -1, os.getegid())
        path = folder / 'value.json';path.write_bytes(b'{}\n');path.chmod(0o400);os.chown(path, -1, os.getegid())
        work = c._c3_fresh_work(1) if label == 'recording-keyboard-marked' else None
        held = c._open_held(str(path), False,
            c._store_rule(os.geteuid(), os.getegid(), 0o400, False, resolver), 'E_STORE',
            recording_work=work, accounting_kind='M' if work is not None else None)
        order = [item.fd for item in reversed(held.components)]
        assert len(order) > 1 and len(order) == len(set(order))
        original_close, original_observe = os.close, c._capture_observe
        closes, observed = [], []
        keyboard = KeyboardInterrupt('first actual held FD close cancelled')
        marked = InterruptedError('later held-close observation cancelled');marked._scope_signal_cancel = True
        def closing(fd):
            result = original_close(fd)
            if fd in order:
                closes.append(fd)
                if label != 'native-none' and fd == order[0]:raise keyboard
            return result
        def observing(values, kind, site, value, *args, **kwargs):
            result = original_observe(values, kind, site, value, *args, **kwargs)
            if site == 'held-close':
                observed.append(value)
                if label == 'recording-keyboard-marked' and len(observed) == 1:raise marked
            return result
        before_close = work['held_close_calls'] if work is not None else None
        os.close, c._capture_observe = closing, observing
        error = None
        try:held.close()
        except BaseException as caught:error = caught
        finally:os.close, c._capture_observe = original_close, original_observe
        try:
            if label == 'recording-keyboard-marked':
                assert error is keyboard and closes == order and held.components == []
                assert collections.Counter(closes) == collections.Counter(order)
                assert len(observed) == len(order) and work['held_close_calls'] - before_close == len(order)
                assert work['held_close_incomplete'] and work['accounting_incomplete']
            elif label == 'native-none':
                assert error is None and closes == order and not observed and held.components == []
            else:
                assert error is keyboard and closes == order[:1] and not observed
                assert [item.fd for item in reversed(held.components)] == order
            for fd in closes:
                try:os.fstat(fd)
                except OSError as caught:assert caught.errno == errno.EBADF
                else:raise AssertionError('actual held fd remained open')
            metrics.append({'case': label, 'owned_fds': len(order), 'actual_close_attempts': len(closes),
                'observations': len(observed), 'first_keyboard_preserved': error is keyboard})
        finally:
            # Native None cancellation leaves the original component list; avoid retrying its closed FD.
            held.components.clear()
            for fd in order:
                if fd not in closes:original_close(fd)
            save(label, work if work is not None else {'native_recording': None, 'close_order': closes})
    return {'controls': metrics, 'retained_root': str(base), 'cost': 'UNKNOWN', 'native_qualification': 'NOTRUN'}


def raw16_C3_gate_phase_seam(root: Path, evidence=None) -> None:
    import ast
    import tempfile
    spec = importlib.util.spec_from_file_location('C3_phase_generator', root/'scope/v1/generate-gate-evidence.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    c = module.c
    results = []
    # These controlled phase implementations test only the public sequencing seam.
    # They do not implement or qualify the native value-generation phase.
    for label in ('normal', 'values-ordinary', 'values-keyboard', 'tail-ordinary'):
        with tempfile.TemporaryDirectory(prefix='ystack-C3-phase-seam-') as temporary:
            output = Path(temporary).resolve()
            (output/'manifests').mkdir(mode=0o700)
            (output/'completion').mkdir(mode=0o700)
            raw = module._manifest_values('generation.phase-fixture', [], [], {},
                c.canonical({'body': {'initial_origin_refs': []}}), None)
            generator = object.__new__(module._Generator)
            generator.output = output
            for path in (output, *output.rglob('*')):
                os.chown(path, os.getuid(), os.getgid())
            generator.reader = types.SimpleNamespace(darwin=c._DarwinUUIDResolver() if sys.platform=='darwin' else None)
            generator.held = []
            generator._init_output_capture()
            events = []
            value_error = KeyboardInterrupt('original values cancellation') if label == 'values-keyboard' else OSError(5, 'original values failure')
            tail_error = OSError(5, 'original tail failure')
            caught = None
            try:
                path = output/'manifests/manifest.json'
                written = module.r.write_exclusive(path, raw, resolver=generator.reader.darwin)
                owner = generator.hold_written(path, raw, written)
                assert type(owner) is c._HeldBytes
                assert owner.raw == raw and owner.raw is not raw
                assert c._identity(owner.held.before) == written
                assert generator.output_holds['manifests/manifest.json'] is owner
                def values():
                    events.append('values')
                    if label.startswith('values-'): raise value_error
                    return owner
                def complete(actual):
                    events.append('complete')
                    assert actual is owner and any(item is actual for item in generator.held)
                    actual.recheck('E_STORE')
                    if label == 'tail-ordinary': raise tail_error
                generator._run_values = values
                generator._run_complete = complete
                try:
                    result = module._Generator.run(generator)
                    assert result is None
                except BaseException as error:
                    caught = error
                if label.startswith('values-'):
                    assert caught is value_error and events == ['values']
                    assert not (output/'completion/COMPLETE.json').exists()
                elif label == 'tail-ordinary':
                    assert caught is tail_error and events == ['values', 'complete']
                else:
                    assert caught is None and events == ['values', 'complete']
                if label == 'normal':
                    stop = OSError(5, 'stop after actual manifest-owner guard')
                    reached = []
                    def stop_at_complete():
                        reached.append('complete')
                        raise stop
                    generator.session = types.SimpleNamespace(phase='FINAL_OWNER', complete=stop_at_complete)
                    try:module._Generator._run_complete(generator, owner)
                    except BaseException as error:assert error is stop
                    else:raise AssertionError('actual tail did not reach stop sentinel')
                    assert reached == ['complete'] and owner.raw is not raw
                    other_path = output/'completion/wrong-manifest.json'
                    other_written = module.r.write_exclusive(other_path, raw, resolver=generator.reader.darwin)
                    other = generator.hold_written(other_path, raw, other_written)
                    for invalid in (object(), other):
                        try:module._Generator._run_complete(generator, invalid)
                        except BaseException as error:
                            assert error is not stop and str(error) == 'E_RUNTIME'
                        else:raise AssertionError('wrong actual owner/path passed guard')
                        assert reached == ['complete']
                results.append({'case': label, 'events': events,
                    'actual_complete_guard_stop': label == 'normal',
                    'independent_actual_HeldBytes_readback': owner.raw is not raw,
                    'caught': None if caught is None else type(caught).__name__,
                    'first_error_identity_preserved': caught is (value_error if label.startswith('values-') else tail_error) if caught is not None else None,
                    'scope': 'public run seam and actual manifest write/hold/readback only; native phases NOTRUN',
                    'work': generator.capture_output_work, 'full_fees': 'UNKNOWN'})
            finally:
                # Manifest owner remains in the original native held list.
                for held in reversed(generator.held): held.close()
                generator.held = []
    tree = ast.parse((root/'scope/v1/generate-gate-evidence.py').read_text())
    cls = next(node for node in tree.body if isinstance(node,ast.ClassDef) and node.name == '_Generator')
    complete = next(node for node in cls.body if isinstance(node,ast.FunctionDef) and node.name == '_run_complete')
    calls = [(node.lineno, ast.unparse(node.func)) for node in ast.walk(complete) if isinstance(node,ast.Call)]
    def line(name):
        matches = [number for number, actual in calls if actual == name]
        assert len(matches) == 1
        return matches[0]
    assert line('require') < line('self.session.complete') < line('self.reader.seal_source_captures') < line('_completion_values') < line('r.write_exclusive') < line('self._capture_completion')
    _C3_work_evidence(results,evidence,'gate-phase')
    print(json.dumps({'C3_public_run_phase_seam':results,'native_complete_body':'AST order only; NOTRUN'},sort_keys=True))


def raw16_C3_ledger_and_retained(root: Path, evidence=None) -> None:
    import tempfile
    spec = importlib.util.spec_from_file_location('C3_ledger_replay', root/'evals/v1/replay-malicious.py')
    replay = importlib.util.module_from_spec(spec);sys.modules[spec.name] = replay;spec.loader.exec_module(replay)
    spec = importlib.util.spec_from_file_location('ystack_shadow_consumer', root/'shadow/v1/_consumer.py')
    c = importlib.util.module_from_spec(spec);sys.modules[spec.name] = c;spec.loader.exec_module(c)
    work = c._c3_fresh_work(1);c._capture_work_values(work, 'C3-ledger-control')
    actual = c._capture_accounting_values(work, {})
    rejected = []
    for field in ('runtime_Q', 'host_publication_work'):
        for value in (None, {}, 0):
            changed = dict(actual);changed[field] = value;changed['complete'] = True
            try:c._c3_owner_receipt_values('Q', changed, complete=True)
            except c.Refusal:rejected.append(field + ':' + repr(value))
            else:raise AssertionError('untyped original Q accepted')
    try:c._c3_owner_receipt_values('raw', dict(actual, complete=True), complete=True)
    except c.Refusal:rejected.append('false-complete')
    else:raise AssertionError('sender complete accepted')
    c._c3_owner_receipt_values('Q', actual)
    spec = importlib.util.spec_from_file_location('C3_original_preparation_ledger', root/'preparation/v1/prepare-candidate.py')
    preparation = importlib.util.module_from_spec(spec);sys.modules[spec.name] = preparation;spec.loader.exec_module(preparation)
    original_preparation = preparation.Ledger()
    original_preparation.charge('scratch_bytes', 7, preparation.LIMITS['storage_bytes'])
    original_preparation.release('scratch_bytes', 3)
    gauges = dict(vars(original_preparation))
    assert c._c3_owner_receipt_values('preparation', gauges) is gauges and gauges['scratch_bytes'] == 4
    for changed in (dict(gauges, scratch_bytes=True), dict(gauges, extra=0)):
        try:c._c3_owner_receipt_values('preparation', changed)
        except c.Refusal:rejected.append('preparation-closed-original-shape')
        else:raise AssertionError('invalid preparation gauge accepted')
    current = c._c3_fresh_work(1)
    body = c._c3_fresh_work(1);terminal = c._c3_fresh_work(1)
    terminal['write_bytes'] = 64
    budget = {'grants':[{'actor':1, 'scopes':['case'], 'bootstrap':{'case':c._c3_work_values(current)},
        'body':{'case':c._c3_work_values(body)}, 'terminal':{'case':c._c3_work_values(terminal)}}]}
    increment = c._c3_fresh_work(1);increment['write_bytes'] = 1
    current, increment = c._c3_work_values(current), c._c3_work_values(increment)
    print(json.dumps({'C3_actual_receipt_mutations':rejected, 'original_preparation_gauges':gauges},sort_keys=True),flush=True)
    try:c._c3_grant_room(budget, 1, 'case', 'body', current, increment)
    except c.Refusal:rejected.append('body-cannot-borrow-terminal')
    else:raise AssertionError('body borrowed terminal')
    c._c3_grant_room(budget, 1, 'case', 'terminal', current, increment)
    print(json.dumps({'C3_body_refused_terminal_credit':True,'same_terminal_increment_admitted':True}),flush=True)
    base = Path(tempfile.mkdtemp(prefix='ystack-C3-retained-')).resolve()
    for name in ('I', 'work'):(base/name).mkdir(mode=0o700)
    for path in (base, *base.rglob('*')):os.chown(path, os.getuid(), os.getgid())
    resolver = c._DarwinUUIDResolver() if sys.platform == 'darwin' else None
    held = [c._open_held(str(base/name), True, c._store_rule(os.getuid(), os.getgid(), 0o700, True, resolver), 'E_STORE')
        for name in ('I','work')]
    inputs = object.__new__(replay._ReplayInputs)
    inputs.c, inputs.root, inputs.resolver, inputs.work, inputs.failure = c, held[0], resolver, work, None
    owner = object.__new__(replay._ReplayCase);owner.c, owner.inputs, owner.work = c, inputs, work
    owner._replay_io_holds = []
    try:
        parent = owner._replay_hold_work(held[1])
        directory = owner._replay_mkdir(parent, 'actual')
        path = owner._replay_write_bytes(directory, 'value', b'actual retained bytes\n')
        assert path.read_bytes() == b'actual retained bytes\n'
        assert owner._replay_close_io() is None
        rows = work['C3_retained']
        assert len(rows) == 3 and all(row['state'] == 'present' and row['last_identity'] is not None for row in rows)
        assert next(row for row in rows if bytes.fromhex(row['member']) == b'actual/value')['size_bytes'] == 22
    finally:
        failure = owner._replay_close_io(sys.exc_info()[1])
        held[0].close()
        if failure is not None and failure is not sys.exc_info()[1]:raise failure
    _C3_work_evidence([{'work':work, 'retained_root':str(base)}], evidence, 'ledger-retained')
    print(json.dumps({'C3_ledger_rejects':rejected, 'actual_retained':work['C3_retained'],
        'full_emit':'NOTRUN', 'complete_qualification':'UNKNOWN'}, sort_keys=True))
