#!/usr/bin/env python3
"""build-guest.py -- guest build, VM launcher and supervisor (ystack #463),
PR 6 of 9. See work/vm-launcher-supervisor/plan.md ("PR 6") and spec.md
R2.5: the pinned Zig toolchain (`zig cc -target aarch64-linux-musl`), two
byte-identical builds required, and the deterministic two-file initramfs
(R2.3: `newc` cpio, exactly `init` and `supervisor`, uid/gid 0, mtime 0,
fixed inode numbers). Host code is stdlib Python 3.9-3.12 (R1.2). Inactive:
`compile` invokes no toolchain unless the caller names one, and neither
subcommand installs anything, uses the network or runs a built executable.

  compile <toolchain-dir> <out-dir>   builds init, supervisor and (once
                                       guest/probe.c exists, PR 7) probe
                                       from this checkout's own sources plus
                                       the unchanged file-digest verifier,
                                       and writes <out-dir>/build-record.json.
  image <out-dir>                     assembles <out-dir>/initramfs.cpio
                                       from <out-dir>/init and
                                       <out-dir>/supervisor, deterministically.
"""
import hashlib
import os
import subprocess
import sys

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
GUEST_DIR = os.path.join(SELF_DIR, "guest")
VERIFIER_SRC = os.path.join(
    os.path.dirname(SELF_DIR), "verifiers", "file-digest", "v1", "verifier.c")
FLAGS = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-static"]
TARGET = "aarch64-linux-musl"


def canonical(value):
    import json
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                        separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    with open(path, "rb") as fh:
        return sha256_hex(fh.read())


# (executable name, guest sources besides common.c, needs common.c)
_GUEST_TARGETS = [
    ("init", ["init.c"], True),
    ("supervisor", ["supervisor.c"], True),
    ("probe", ["probe.c"], True),  # only built once PR 7 adds guest/probe.c
]


def _targets():
    """Every guest executable this checkout can currently build: init and
    supervisor always (this PR), probe once guest/probe.c exists (PR 7),
    plus the unchanged verifier.c (already merged, concern 3)."""
    out = []
    for name, extra, needs_common in _GUEST_TARGETS:
        src = os.path.join(GUEST_DIR, extra[0])
        if os.path.exists(src):
            sources = [src] + ([os.path.join(GUEST_DIR, "common.c")] if needs_common else [])
            out.append((name, sources))
    if os.path.exists(VERIFIER_SRC):
        out.append(("verifier", [VERIFIER_SRC]))
    return out


def cmd_compile(toolchain_dir, out_dir):
    if os.path.exists(out_dir):
        sys.stderr.write("E_BUILD_OUT_EXISTS\n")
        return 65
    zig = os.path.join(toolchain_dir, "zig")
    os.makedirs(out_dir)
    sources_seen = {}
    executables = []
    for name, sources in _targets():
        exe = os.path.join(out_dir, name)
        argv = ([zig, "cc", "-target", TARGET] + FLAGS + sources + ["-o", exe])
        subprocess.run(argv, check=True, cwd=SELF_DIR)
        os.chmod(exe, 0o555)
        executables.append({"name": name, "sha256": sha256_file(exe)})
        for src in sources:
            rel = os.path.relpath(src, os.path.dirname(SELF_DIR))
            sources_seen[rel] = sha256_file(src)
    # "archive" (R2.5): the toolchain directory carries no original .tar.xz
    # at this call site (only its extracted contents), so the zig binary
    # actually invoked stands in as the toolchain's own identity -- the
    # bytes this build in fact depended on.
    archive_sha256 = sha256_file(zig) if os.path.exists(zig) else None
    record = {
        "body": {
            "archive_sha256": archive_sha256,
            "executables": sorted(executables, key=lambda e: e["name"]),
            "flags": FLAGS + ["-target", TARGET],
            "script_sha256": sha256_file(os.path.abspath(__file__)),
            "sources": [{"path": p, "sha256": h} for p, h in sorted(sources_seen.items())],
        },
        "kind": "sandbox_guest_build",
        "schema_version": 1,
    }
    with open(os.path.join(out_dir, "build-record.json"), "wb") as fh:
        fh.write(canonical(record))
    return 0


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
    with open(init_path, "rb") as fh:
        init_bytes = fh.read()
    with open(supervisor_path, "rb") as fh:
        supervisor_bytes = fh.read()
    image = build_initramfs(init_bytes, supervisor_bytes)
    out_path = os.path.join(out_dir, "initramfs.cpio")
    with open(out_path, "wb") as fh:
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
