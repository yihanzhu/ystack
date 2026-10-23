#!/usr/bin/env python3
"""build-guest.py -- guest build, VM launcher and supervisor (ystack #463),
PR 6 of 9. See work/vm-launcher-supervisor/plan.md ("PR 6") and spec.md
R2.5: the pinned Zig toolchain (`zig cc -target aarch64-linux-musl`), two
byte-identical builds required, and the deterministic two-file initramfs
(R2.3: `newc` cpio, exactly `init` and `supervisor`, uid/gid 0, mtime 0,
fixed inode numbers). Host code is stdlib Python 3.9-3.12 (R1.2). Inactive:
`compile` invokes no toolchain unless the caller names one, and neither
subcommand installs anything, uses the network or runs a built executable.

  compile <toolchain-dir> <out-dir>   builds init, supervisor and probe
                                       from this checkout's own sources plus
                                       the unchanged file-digest verifier,
                                       and writes <out-dir>/build-record.json.
  image <out-dir>                     assembles <out-dir>/initramfs.cpio
                                       from <out-dir>/init and
                                       <out-dir>/supervisor, deterministically.
"""
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SELF_DIR))
GUEST_DIR = os.path.join(SELF_DIR, "guest")
VERIFIER_SRC = os.path.join(REPO_ROOT, "verifiers", "file-digest", "v1", "verifier.c")
FLAGS = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-static"]
TARGET = "aarch64-linux-musl"


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                        separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    with open(path, "rb") as fh:
        return sha256_hex(fh.read())


_GUEST_TARGETS = [
    ("init", ["init.c"], True),
    ("supervisor", ["supervisor.c"], True),
    ("probe", ["probe.c"], True),
]


def _targets():
    """Return the closed set of mandatory guest and verifier targets."""
    out = []
    for name, extra, needs_common in _GUEST_TARGETS:
        src = os.path.join(GUEST_DIR, extra[0])
        sources = [src] + ([os.path.join(GUEST_DIR, "common.c")] if needs_common else [])
        headers = [os.path.join(GUEST_DIR, "common.h")] if needs_common else []
        out.append((name, sources, headers))
    out.append(("verifier", [VERIFIER_SRC], []))
    return out


class BuildError(Exception):
    pass


def _required_regular_files(targets):
    required = {os.path.abspath(__file__)}
    for _, sources, headers in targets:
        required.update(sources)
        required.update(headers)
    for path in required:
        if not os.path.isfile(path) or os.path.islink(path):
            raise BuildError("required input is missing or not a regular file")


def _copy_archive(source, destination):
    digest = hashlib.sha256()
    with open(source, "rb") as src, open(destination, "xb") as dst:
        while True:
            block = src.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            dst.write(block)
    return digest.hexdigest()


def _safe_members(archive):
    seen = set()
    files = set()
    roots = set()
    total_size = 0
    members = archive.getmembers()
    if not members or len(members) > 100000:
        raise BuildError("empty or oversized toolchain archive index")
    for member in members:
        pure = pathlib.PurePosixPath(member.name)
        if (not member.name or pure.is_absolute() or ".." in pure.parts or
                member.issym() or member.islnk() or not (member.isdir() or member.isfile())):
            raise BuildError("unsafe toolchain archive member")
        normalized = pure.as_posix().rstrip("/")
        if (not normalized or len(member.name.encode("utf-8")) > 4096 or
                normalized in seen or any(parent.as_posix() in files for parent in pure.parents)):
            raise BuildError("duplicate toolchain archive member")
        if member.size < 0 or total_size + member.size > 4 * 1024 * 1024 * 1024:
            raise BuildError("toolchain archive expands past its bound")
        total_size += member.size
        seen.add(normalized)
        roots.add(pure.parts[0])
        if member.isfile():
            files.add(normalized)
    if len(roots) != 1:
        raise BuildError("toolchain archive must have one root directory")
    return members


def _extract_archive(archive_path, destination):
    zig_paths = []
    with tarfile.open(archive_path, "r:xz") as archive:
        members = _safe_members(archive)
        for member in members:
            pure = pathlib.PurePosixPath(member.name)
            target = os.path.join(destination, *pure.parts)
            if member.isdir():
                os.makedirs(target, mode=0o700, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise BuildError("unreadable toolchain archive member")
            with source, open(target, "xb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            os.chmod(target, member.mode & 0o777)
            if len(pure.parts) == 2 and pure.parts[1] == "zig":
                zig_paths.append(target)
    if len(zig_paths) != 1 or not os.access(zig_paths[0], os.X_OK):
        raise BuildError("toolchain archive must contain one executable <root>/zig")
    return zig_paths[0]


def _identity(path):
    return {"path": os.path.relpath(path, REPO_ROOT), "sha256": sha256_file(path)}


def cmd_compile(toolchain_dir, out_dir):
    if os.path.exists(out_dir):
        sys.stderr.write("E_BUILD_OUT_EXISTS\n")
        return 65
    targets = _targets()
    archive_source = os.path.join(toolchain_dir, "toolchain.tar.xz")
    parent = os.path.dirname(os.path.abspath(out_dir))
    os.makedirs(parent, exist_ok=True)
    private_dir = tempfile.mkdtemp(prefix=".ystack-toolchain-", dir=parent)
    stage_dir = tempfile.mkdtemp(prefix=".ystack-build-", dir=parent)
    os.chmod(private_dir, 0o700)
    os.chmod(stage_dir, 0o700)
    try:
        _required_regular_files(targets)
        if not os.path.isfile(archive_source) or os.path.islink(archive_source):
            raise BuildError("missing toolchain archive")
        private_archive = os.path.join(private_dir, "toolchain.tar.xz")
        archive_sha256 = _copy_archive(archive_source, private_archive)
        extract_dir = os.path.join(private_dir, "extract")
        os.mkdir(extract_dir, 0o700)
        zig = _extract_archive(private_archive, extract_dir)
        sources = {}
        headers = {}
        executables = []
        for name, target_sources, target_headers in targets:
            exe = os.path.join(stage_dir, name)
            argv = [zig, "cc", "-target", TARGET] + FLAGS + target_sources + ["-o", exe]
            subprocess.run(argv, check=True, cwd=SELF_DIR, env={})
            if not os.path.isfile(exe) or os.path.islink(exe):
                raise BuildError("compiler did not create target")
            os.chmod(exe, 0o555)
            executables.append({"name": name, "sha256": sha256_file(exe)})
            for path in target_sources:
                sources[path] = _identity(path)
            for path in target_headers:
                headers[path] = _identity(path)
        record = {
            "body": {
                "archive_sha256": archive_sha256,
                "executables": sorted(executables, key=lambda item: item["name"]),
                "flags": FLAGS + ["-target", TARGET],
                "headers": sorted(headers.values(), key=lambda item: item["path"]),
                "script_sha256": sha256_file(os.path.abspath(__file__)),
                "sources": sorted(sources.values(), key=lambda item: item["path"]),
            },
            "kind": "sandbox_guest_build",
            "schema_version": 1,
        }
        with open(os.path.join(stage_dir, "build-record.json"), "xb") as fh:
            fh.write(canonical(record))
        if os.path.exists(out_dir):
            raise BuildError("output appeared during build")
        os.rename(stage_dir, out_dir)
        stage_dir = None
        return 0
    except (BuildError, OSError, subprocess.CalledProcessError, tarfile.TarError) as exc:
        sys.stderr.write("E_BUILD_FAILED: %s\n" % exc)
        return 65
    finally:
        shutil.rmtree(private_dir, ignore_errors=True)
        if stage_dir is not None:
            shutil.rmtree(stage_dir, ignore_errors=True)


# --- R2.3/R2.5: the deterministic two-file "newc" cpio initramfs -----------
CPIO_MAGIC = b"070701"
INODES = {"init": 1, "supervisor": 2}


def _cpio_header(name, filesize, ino, mode):
    namesize = len(name) + 1
    fields = (ino, mode, 0, 0, 1, 0, filesize, 0, 0, 0, 0, namesize, 0)
    return CPIO_MAGIC + b"".join(b"%08X" % f for f in fields)


def _cpio_entry(name, data, ino, mode):
    name_b = name.encode("ascii") + b"\x00"
    header = _cpio_header(name, len(data), ino, mode)
    out = header + name_b
    out += b"\x00" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\x00" * ((4 - len(data) % 4) % 4)
    return out


def _cpio_trailer():
    return _cpio_entry("TRAILER!!!", b"", 0, 0)


def build_initramfs(init_bytes, supervisor_bytes):
    """Exactly two entries, in this order, `newc` cpio, uid/gid 0
    (baked into the header's own zero uid/gid fields), mtime 0 (the header
    carries no mtime field other than the zeroed one above), fixed inode
    numbers (R2.3): byte-identical for byte-identical inputs, nothing else
    varies (no padding beyond the format's own 4-byte alignment)."""
    body = _cpio_entry("init", init_bytes, INODES["init"], 0o100755)
    body += _cpio_entry("supervisor", supervisor_bytes, INODES["supervisor"], 0o100755)
    body += _cpio_trailer()
    # cpio archives are traditionally padded to a 512-byte multiple; this
    # frame's own two-entry contract cares only about the entries above,
    # but the pad itself must stay deterministic (zero bytes) too.
    body += b"\x00" * ((512 - len(body) % 512) % 512)
    return body


def cmd_image(out_dir):
    init_path = os.path.join(out_dir, "init")
    supervisor_path = os.path.join(out_dir, "supervisor")
    if not (os.path.isfile(init_path) and os.path.isfile(supervisor_path)):
        sys.stderr.write("E_BUILD_MISSING_INPUT\n")
        return 65
    out_path = os.path.join(out_dir, "initramfs.cpio")
    if os.path.exists(out_path):
        sys.stderr.write("E_BUILD_OUT_EXISTS\n")
        return 65
    with open(init_path, "rb") as fh:
        init_bytes = fh.read()
    with open(supervisor_path, "rb") as fh:
        supervisor_bytes = fh.read()
    image = build_initramfs(init_bytes, supervisor_bytes)
    with open(out_path, "xb") as fh:
        fh.write(image)
    return 0


def usage():
    sys.stderr.write("usage: build-guest.py compile <toolchain-dir> <out-dir>\n"
                      "       build-guest.py image <out-dir>\n")
    return 2


def main(argv):
    if len(argv) == 4 and argv[1] == "compile":
        return cmd_compile(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "image":
        return cmd_image(argv[2])
    return usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
