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
            assert set(anchor.private_observations['preparation']) == {'prepare', 'inspect'}
            assert not anchor.private_observations.get('unusable', False)
            assert not native_paths[0].exists() and native_paths[1].is_dir()
            assert len(list((work/'preparation-scratch').glob('raw16-t-v1-*'))) == 10
            completed.append('actual prepare-retain-nativecleanup-inspect-retain sequence')
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

def raw16_scope_sudo_source(root: Path) -> None:
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
        for case in ('stable', 'kill-stable', 'dup-ancestor', 'dup-target', 'dup-observer-memory',
                     'companion-close-observer', 'cancel-A-native-close-B', 'native-error-close-error',
                     'dup-fstat', 'dup-row-allocation', 'companion-registration', 'native-error-close-cancel'):
            with tempfile.TemporaryDirectory(prefix='ystack-scope-sudo-') as temporary:
                base = Path(temporary).resolve();base.chmod(0o700)
                captures = base/'captures';captures.mkdir(mode=0o700)
                paths = {}
                for role in ('sudo', 'python', 'jq', 'bash', 'git', 'supervisor'):
                    path = base/role;path.write_bytes(b'never executed synthetic scope '+role.encode());path.chmod(0o400)
                    paths[role] = path
                reader = object.__new__(scope._Reader)
                reader.owned = [];reader.inputs = [];reader.commands = [];reader.gate_commands = []
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
                    if case in ('native-error-close-error', 'native-error-close-cancel'):raise first
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
                        if case == 'native-error-close-error':
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
                    elif case == 'native-error-close-cancel':
                        assert len(cancels) == 1 and caught is cancels[0] and foreground == [True]
                    else:assert caught is None and foreground == [True]
                    assert len(original_holds) == 1 and original_holds[0][0].held.components == []
                    retained_chain = [component.fd for item, _work, _key in anchor.runtime_companions for component in item.components]
                    assert retained_chain == source_chain, (case, retained_chain, source_chain)
                    if case in ('stable', 'kill-stable', 'companion-close-observer', 'native-error-close-error', 'native-error-close-cancel'):
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
                reader.owned = [];reader.inputs = [];reader.captures = captures;reader.darwin = None
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
