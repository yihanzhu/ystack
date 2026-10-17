#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_SCOPE_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_SCOPE_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 1800; exec @ARGV; die "exec failed: $!\n"' /bin/bash "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/scope/v1/validate-scope.sh"
evaluator="$root/scope/v1/evaluate-scope.sh"
policy="$root/scope/v1/scope-policy.json"
record_program="$root/scope/v1/workflow-scope.jq"
gate_program="$root/scope/v1/scope-gates.jq"
repo_marker="$root/config/construction-mode.json"

fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-scope-test.XXXXXX")
scope_owner_state=never
scope_controls_state=never
scope_owner_pid=''
scope_owner_writer=false
scope_owner_reader=false
scope_owner_serial=0
scope_owner_status=0
scope_owner_waiting=false
scope_fixture_owner_close_reader() { exec 6<&-; }
scope_fixture_owner_close_writer() { exec 7>&-; }
scope_fixture_owner_cancel() {
  local failed=0
  [ "$scope_owner_state" != unknown ] || failed=1
  if [ "$scope_owner_reader" = true ]; then
    if scope_fixture_owner_close_reader; then scope_owner_reader=false; else failed=1; fi
  fi
  if [ "$scope_owner_writer" = true ]; then
    if scope_fixture_owner_close_writer; then scope_owner_writer=false; else failed=1; fi
  fi
  if [ "$failed" -ne 0 ]; then scope_owner_state=unknown; return 1; fi
}
scope_fixture_owner_wait() {
  [ "$scope_owner_state" != unknown ] || return 1
  [ "$scope_owner_state" != never ] || return 0
  [ "$scope_owner_state" != completed ] || return 0
  if [ -z "$scope_owner_pid" ]; then scope_owner_state=unknown; return 1; fi
  scope_owner_status=0
  scope_owner_waiting=true
  wait "$scope_owner_pid" || scope_owner_status=$?
  scope_owner_waiting=false
  if [ "$scope_owner_status" -ge 127 ]; then
    scope_owner_state=unknown
    scope_fixture_owner_cancel || :
    return 1
  fi
  scope_fixture_owner_cancel || return 1
  if ! /usr/bin/python3 -I -S -B "$scope_owner_channel_helper" confirm "$tmp" "$genuine_base" \
    "$guard_control" "$scope_owner_serial"; then scope_owner_state=unknown; return 1; fi
  scope_owner_state=completed
}
scope_fixture_owner_launch() {
  local proof=$1
  [ "$scope_owner_state" = never ] || [ "$scope_owner_state" = completed ] || return 1
  scope_owner_serial=$((scope_owner_serial+1))
  /usr/bin/python3 -I -S -B "$scope_owner_channel_helper" prepare "$tmp" "$genuine_base" \
    "$guard_control" "$scope_owner_serial" || return 1
  exec 7<>"$tmp/scope-owner-$scope_owner_serial.fifo"
  scope_owner_writer=true
  exec 6<"$tmp/scope-owner-$scope_owner_serial.fifo"
  scope_owner_reader=true
  scope_owner_state=attempted
  scope_owner_pid=''
  /usr/bin/sudo -n "$genuine_python" -I -S -B "$guard_control" \
    "$genuine_base" "$genuine_base/package" "$genuine_python" "$guard_source" "$operator_name" "$entry_source" \
    "$tmp/scope-owner-$scope_owner_serial.json" <&6 6<&- 7>&- &
  scope_owner_pid=$!
  if scope_fixture_owner_close_reader; then scope_owner_reader=false; else scope_owner_state=unknown; return 1; fi
  scope_owner_state=active
  if [ "$proof" = true ]; then
    /usr/bin/python3 -I -S -B "$scope_owner_channel_helper" ready "$tmp" "$genuine_base" \
      "$guard_control" "$scope_owner_serial" 7>&- || return 1
    scope_fixture_owner_cancel || return 1
  fi
  scope_fixture_owner_wait || return 1
  if [ "$proof" = true ]; then
    [ "$scope_owner_status" -ne 0 ] || return 1
    /usr/bin/printf 'actual fixed root-owner cancellation/reap/confirmation: PASS\n'
  else
    return "$scope_owner_status"
  fi
}
scope_fixture_signal=''
trap 'scope_fixture_signal=ALRM;if [ "$scope_owner_waiting" = true ]; then scope_owner_state=unknown;fi;scope_fixture_owner_cancel || :;exit 142' ALRM

cleanup() {
  local prior=$? cleanup_status=0
  if ! scope_fixture_owner_cancel; then cleanup_status=1; fi
  if ! scope_fixture_owner_wait; then
    /usr/bin/printf 'fixture-cleanup: FAIL_PENDING; owner completion is unknown\n' >&2
    cleanup_status=1
  elif { [ "$scope_controls_state" != never ] && [ "$scope_controls_state" != completed ]; } ||
       [ -e "$tmp/observer-owner-controls.pending" ] || [ -L "$tmp/observer-owner-controls.pending" ]; then
    /usr/bin/printf 'fixture-cleanup: FAIL_PENDING; ordinary control completion is unknown\n' >&2
    cleanup_status=1
  elif declare -F cleanup_genuine >/dev/null; then
    cleanup_genuine || cleanup_status=1
  else
    /usr/bin/printf 'genuine-cleanup: NOT_STARTED\n'
  fi
  if [ "$prior" -eq 142 ] && [ "$scope_fixture_signal" = ALRM ]; then
    python3 -I -S -B - "$tmp/stale-observation/observer.py" <<'PY_FIXED_COST_EXPORT' || :
import runpy,sys
try:runpy.run_path(sys.argv[1])['cost_export']()
except BaseException:pass
PY_FIXED_COST_EXPORT
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    /bin/rm -rf -- "$tmp" >/dev/null 2>&1 || cleanup_status=1
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    /usr/bin/printf 'fixture-cleanup: PASS prior-exit=%s\n' "$prior"
  else
    /usr/bin/printf 'fixture-cleanup: FAIL prior-exit=%s\n' "$prior" >&2
    if [ "$prior" -eq 0 ]; then exit 1; fi
  fi
  if [ -n "$scope_fixture_signal" ]; then
    trap - "$scope_fixture_signal"
    kill -s "$scope_fixture_signal" "$$"
    exit 142
  fi
}
trap cleanup EXIT

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*)
    tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Linux:x86_64)
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  *) fail "unsupported host $platform" ;;
esac
# This suite bootstraps the pinned jq 1.6 cache itself so it never depends on an
# earlier suite having filled it.
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ "${platform%%:*}" = Darwin ]; then
  [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] ||
    fail 'genuine origin BLOCKED: a reserved disposable host is required'
  jq_cache=/Library/Frameworks/Python.framework/ystack-private-tools/jq
  [ -f "$jq_cache" ] && [ ! -L "$jq_cache" ] && [ "$(sha256_path "$jq_cache")" = "$jq_sha" ] ||
    fail 'genuine origin BLOCKED: existing fixed pinned jq is required'
else
  if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] ||
     [ "$(sha256_path "$jq_cache")" != "$jq_sha" ]; then
    download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
    [ "$(sha256_path "$download")" = "$jq_sha" ] || fail 'jq release digest'
    /bin/chmod 0555 "$download"
    /bin/mv "$download" "$jq_cache"
  fi
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
if [ "${platform%%:*}" != Darwin ]; then
  [ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
fi

authenticate_genuine_macos_python() {
  [ "$1" = /Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python ] || return 1
  local mac_guard_file="$tmp/runtime-guard/guard.py"
  if [ ! -d "$tmp/runtime-guard" ]; then
    /bin/mkdir -m 700 "$tmp/runtime-guard" || return 1
    (
    set -o noclobber
  /bin/cat >"$mac_guard_file" <<'PY_MAC_FIXED_RUNTIME_GUARD'
import ctypes
import errno
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import time

assert sys.platform == 'darwin' and os.getuid() != 0
assert not any(key.startswith('DYLD_') or key == '__PYVENV_LAUNCHER__' for key in os.environ)
assert len(sys.argv) == 7
def fixed_manifest_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')


def uptime():
    value = time.clock_gettime(time.CLOCK_UPTIME_RAW)
    assert type(value) is float and math.isfinite(value) and value >= 0
    return value


def owner_deadline():
    info = time.get_clock_info('monotonic')
    # Both fixed Darwin APIs use mach_absolute_time: seconds, the same rate, and excluding system sleep.
    assert info.monotonic and not info.adjustable and info.implementation == 'mach_absolute_time()'
    assert math.isfinite(info.resolution) and info.resolution > 0
    resolution = time.clock_getres(time.CLOCK_UPTIME_RAW)
    assert math.isfinite(resolution) and resolution > 0
    local = time.monotonic()
    raw = uptime()
    remaining = deadline - raw
    assert math.isfinite(local) and local >= 0
    assert math.isfinite(remaining) and 0 < remaining <= 120
    converted = local + remaining
    assert math.isfinite(converted) and converted > local
    return converted


stage = sys.argv[4]
assert stage in ('empty', 'real')
guard_started = uptime()
deadline = guard_started + 120 if stage == 'empty' else float(sys.argv[5])
entry_pid = os.getpid() if stage == 'empty' else int(sys.argv[6])
assert math.isfinite(deadline) and uptime() < deadline <= guard_started + 120
fixed_root = Path('/Library/Frameworks/Python.framework')
fixed_prefix = fixed_root / 'Versions/3.15'
fixed_tools = fixed_root / 'ystack-private-tools'
fixed_p = fixed_prefix / 'Resources/Python.app/Contents/MacOS/Python'
if stage == 'real':
    assert os.getpid() == entry_pid
    assert sys.executable == os.path.realpath(sys.executable) == str(fixed_p)
    assert sys.version_info[:3] == (3, 15, 0) and sys.version_info >= (3, 11)
    assert sys.prefix == sys.base_prefix == str(fixed_prefix)
    assert sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
    assert all(Path(value).is_absolute() and (Path(value) == fixed_prefix or fixed_prefix in Path(value).parents)
               for value in sys.path)
package = Path(sys.argv[1])
assert package.is_absolute() and package.resolve() == package
source = package / 'shadow/v1/_consumer.py'
spec = importlib.util.spec_from_file_location('fixture_bootstrap_consumer', source)
assert spec is not None and spec.loader is not None
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)

class FixtureDarwinLedger:
    def __init__(self): self.commands = []
    def record_command(self, role, argv, executable, component):
        c._require(role == 'darwin-acl-uuid-resolution', 'E_RUNTIME')
        c._require(len(self.commands) < 4096, 'E_LIMIT')
        self.commands.append({'role': role, 'argv_sha256': c.digest(c.canonical(argv)),
            'executable_sha256': executable, 'component_sha256': component})

locator = Path(sys.argv[2])
assert locator.is_absolute()
selected = Path(os.path.realpath(str(locator)))
print(json.dumps({'bootstrap_python': sys.executable, 'bootstrap_version': list(sys.version_info[:3]),
    'selected_python': str(selected), 'candidate_executed': stage == 'real'}, sort_keys=True), file=sys.stderr)
assert locator == selected == fixed_p
prefix = fixed_prefix
stdlib = prefix / 'lib/python3.15'
assert (stdlib / 'os.py').is_file() and (stdlib / 'encodings/__init__.py').is_file()
assert not any(os.path.lexists(str(parent / 'pyvenv.cfg')) for parent in (selected.parent, prefix))
assert not any(os.path.lexists(str(selected) + suffix) for suffix in ('._pth', '.zip'))
owned = []
active_path = str(selected)
active_stage = 'bootstrap-held'
rows = {}
links = {}
cache_paths = set()
images = set()
seen = set()
native_inventory = {}
static_paths = set()
load_edges = set()
ledger = FixtureDarwinLedger()
fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')

def identity(state):
    return tuple(getattr(state, field) for field in fields)

def empty_acl(value):
    saved = ctypes.get_errno()
    if value:
        assert library.acl_free(value) == 0
        raise ValueError('nonempty or unknown ACL before real UUID resolver')
    assert saved == errno.ENOENT


def immutable(fd, state, ancestor):
    assert uptime() < deadline
    assert state.st_uid == 0 and not state.st_mode & 0o022
    ctypes.set_errno(0)
    empty_acl(library.acl_get_fd_np(fd, 0x100))
    return True


def rule():
    return immutable if stage == 'empty' else c._root_rule(owner)


def canonical_fixed(path):
    path = Path(os.path.normpath(str(path)))
    if path != fixed_root and fixed_root not in path.parents:
        return path
    relative = str(path.relative_to(fixed_root))
    if relative == '.' or path == fixed_root / 'Versions':
        return path
    pending = relative.split('/')
    resolved = []
    steps = 0
    while pending:
        steps += 1
        assert steps <= 128 and uptime() < deadline
        resolved.append(pending.pop(0))
        name = '/'.join(resolved)
        if name == 'Versions':
            assert pending and pending[0] == '3.15'
            continue
        assert name in manifest
        row = manifest[name]
        if row['kind'] != stat.S_IFLNK:
            continue
        logical = fixed_root / name
        parent = c._open_held(str(logical.parent), True, rule(), 'E_INSTALL')
        try:
            before = logical.lstat()
            assert stat.S_ISLNK(before.st_mode) and before.st_uid == 0 and before.st_nlink == 1
            assert not before.st_mode & 0o022 and stat.S_IMODE(before.st_mode) == 0o755
            assert os.readlink(logical) == row['link']
            ctypes.set_errno(0)
            empty_acl(library.acl_get_link_np(os.fsencode(logical), 0x100))
            target = os.path.normpath(os.path.join(os.path.dirname(name), row['link']))
            assert target == 'Versions/3.15' or target.startswith('Versions/3.15/')
            links[str(logical)] = (identity(before), row['link'])
            assert identity(logical.lstat()) == identity(before) and os.readlink(logical) == row['link']
            parent.recheck('E_STALE')
            pending = target.split('/') + pending
            resolved = []
        finally:
            parent.close()
    physical = fixed_root.joinpath(*resolved)
    assert physical.resolve() == physical
    return physical


def inspect(path, directory=False):
    global active_path, active_stage
    active_path = str(path)
    active_stage = 'candidate-inspect'
    assert uptime() < deadline and len(rows) < 16384
    path = canonical_fixed(path)
    assert path.is_absolute() and path.resolve() == path
    held = c._open_held(str(path), directory, rule(), 'E_INSTALL')
    try:
        raw = b'' if directory else held.read(c.EXECUTABLE_LIMIT, 'E_INSTALL')
        held.recheck('E_STALE')
        value = (identity(held.before), hashlib.sha256(raw).hexdigest())
        assert str(path) not in rows or rows[str(path)] == value
        rows[str(path)] = value
        return raw
    finally:
        held.close()

def native_slices(raw):
    magic = raw[:4]
    if magic == b'\xcf\xfa\xed\xfe':
        header = struct.unpack_from('<8I', raw)
        return [(header[1], header[2], raw)]
    assert magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
    count = struct.unpack_from('>I', raw, 4)[0]
    width = 20 if magic[-1] == 0xbe else 32
    assert 0 < count <= 16 and 8 + count * width <= len(raw)
    slices = []
    for index in range(count):
        values = struct.unpack_from('>IIIII' if width == 20 else '>IIQQII', raw, 8 + index * width)
        cpu, subtype, offset, size, alignment = values[:5]
        assert alignment <= 31 and offset % (1 << alignment) == 0
        assert width == 20 or values[5] == 0
        assert offset >= 8 + count * width and size >= 32 and offset + size <= len(raw)
        slices.append((cpu, subtype, offset, size))
    assert len({value[0] for value in slices}) == count
    ordered = sorted(slices, key=lambda value: value[2])
    assert all(left[2] + left[3] <= right[2] for left, right in zip(ordered, ordered[1:]))
    return [(cpu, subtype, raw[offset:offset + size]) for cpu, subtype, offset, size in slices]

def static_data(name, raw, slices):
    bindings = {
        'Frameworks/Tcl.framework/Versions/9.0/libtclstub.a': ('74fd3db0166b27cbe6aeaa4ef642a2bcca7e68d2fec4c05467bf5c04978d0670',
            ('tclStubLib.o', 'tclStubCall.o', 'tclStubLibTbl.o', 'tclTomMathStubLib.o', 'tclOOStubLib.o')),
        'Frameworks/Tk.framework/Versions/9.0/libtkstub.a': ('c8fac1a39815dbe3ce300961ca125a196363354f0290ff21be65e7592349e935',
            ('tkStubLib.o', 'ttkStubLib.o')),
        'lib/python3.15/config-3.15-darwin/python.o': ('8c1ab81c7a71dbc98218a6ddf230353b2fcb73e51fdc3a0c9ec050ed461f7e21', None)}
    if name not in bindings:
        return False
    digest, members = bindings[name]
    assert hashlib.sha256(raw).hexdigest() == digest and len(slices) == 2
    for cpu, subtype, body in slices:
        assert uptime() < deadline
        if members is None:
            magic, version, offset, size, wrapper_cpu = struct.unpack_from('<5I', body)
            expected = (4888, 0x01000007) if cpu == 0x01000007 else (5252, 0xffffffff)
            assert magic == 0x0b17c0de and version == 0 and offset == 20
            assert (size, wrapper_cpu) == expected and offset + size <= len(body)
            assert body[offset:offset + 4] == b'BC\xc0\xde'
            continue
        assert body[:8] == b'!<arch>\n'
        offset, observed = 8, []
        while offset < len(body):
            assert uptime() < deadline and len(observed) <= len(members)
            header = body[offset:offset + 60]
            assert len(header) == 60 and header[58:] == b'`\n'
            size = int(header[48:58])
            assert size >= 0 and offset + 60 + size + size % 2 <= len(body)
            value = body[offset + 60:offset + 60 + size]
            offset += 60 + size + size % 2
            member = header[:16].decode('ascii').strip()
            if member.startswith('#1/'):
                length = int(member[3:])
                assert 0 < length <= len(value)
                member, value = value[:length].rstrip(b'\0').decode('ascii'), value[length:]
            observed.append(member)
            if member == '__.SYMDEF SORTED':
                assert len(observed) == 1
                continue
            assert member in members and value[:4] == b'\xcf\xfa\xed\xfe'
            mh = struct.unpack_from('<8I', value)
            assert mh[1:4] == (cpu, subtype, 1) and mh[4] <= 4096
            end, position = 32 + mh[5], 32
            assert end <= len(value)
            for _ in range(mh[4]):
                command, length = struct.unpack_from('<II', value, position)
                assert command in (0x19, 0x2, 0x32, 0x29)
                assert length >= 8 and length % 8 == 0 and position + length <= end
                position += length
            assert position == end
        assert offset == len(body) and observed == ['__.SYMDEF SORTED', *members]
    return True

def native_dependencies(path, raw, loaded=False):
    path = canonical_fixed(path)
    name = str(path.relative_to(prefix)) if path.is_relative_to(prefix) else None
    magic = raw[:4]
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        assert not loaded and path.suffix not in ('.so', '.dylib')
        assert magic not in (b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                             b'\xde\xc0\x17\x0b', b'BC\xc0\xde') and not raw.startswith(b'!<arch>\n')
        return
    slices = native_slices(raw)
    if name is not None and len(slices) > 1:
        assert {(cpu, subtype) for cpu, subtype, body in slices} == {(0x01000007, 3), (0x0100000c, 0)}
    if static_data(name, raw, slices):
        assert not loaded
        static_paths.add(str(path))
        return
    assert all(body[:4] == b'\xcf\xfa\xed\xfe' for cpu, subtype, body in slices)
    x86 = [body for cpu, subtype, body in slices if cpu == 0x01000007]
    assert len(x86) == 1
    if name is not None and len(slices) == 1:
        assert name == 'bin/python3.15-intel64'
    for cpu, subtype, body in slices:
        mh = struct.unpack_from('<8I', body)
        assert mh[1:3] == (cpu, subtype) and mh[3] in (2, 6, 8)
    raw = x86[0]
    if name is not None:
        native_inventory[str(path)] = struct.unpack_from('<8I', raw)[3]
    header = struct.unpack_from('<8I', raw)
    assert header[1] == 0x01000007 and header[4] <= 4096
    end = 32 + header[5]
    assert end <= len(raw)
    offset = 32
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', raw, offset)
        assert size >= 8 and size % 8 == 0 and offset + size <= end
        assert command not in (0x6, 0x9, 0x10, 0x27)
        if command in (0xc, 0xe, 0x80000018, 0x8000001c, 0x8000001f, 0x20, 0x80000023):
            name_offset = struct.unpack_from('<I', raw, offset + 8)[0]
            assert 12 <= name_offset < size
            encoded = raw[offset + name_offset:offset + size]
            assert b'\0' in encoded
            name = encoded.split(b'\0', 1)[0].decode('utf8')
            if name is not None and path.is_relative_to(prefix):
                load_edges.add((str(path), command, name))
            if command == 0xe:
                assert name == '/usr/lib/dyld'
                inspect(Path(name))
            else:
                if name.startswith('@loader_path/'):
                    name = str(path.parent / name[len('@loader_path/'):])
                elif name.startswith('@executable_path/'):
                    name = str(selected.parent / name[len('@executable_path/'):])
                assert name.startswith('/') and '@' not in name
                target = Path(os.path.normpath(name))
                if str(target).startswith(('/usr/lib/', '/System/Library/')) and not os.path.lexists(target):
                    assert len(cache_paths) < 256
                    cache_paths.add(target)
                    parent = target.parent
                    while not os.path.lexists(parent):
                        parent = parent.parent
                    inspect(parent, True)
                elif command == 0x8000001c:
                    assert prefix in target.parents or target == prefix
                    inspect(target, True)
                else:
                    assert len(images) < 256
                    images.add(target)
        offset += size
    assert offset == end

try:
    library = c._DARWIN_ACL_FUNCTIONS.library
    library.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
    library.acl_get_link_np.restype = ctypes.c_void_p
    source_held = c._hold_bytes(str(source), c.EXECUTABLE_LIMIT)
    owned.append(source_held)
    guard_path = Path(sys.argv[3])
    guard_held = c._hold_bytes(str(guard_path), c.EXECUTABLE_LIMIT)
    owned.append(guard_held)
    guard_held.recheck('E_INSTALL')
    guard_code = guard_held.raw
    manifest_held = c._hold_bytes(str(guard_path.parent / 'manifest.json'), c.EXECUTABLE_LIMIT)
    owned.append(manifest_held)
    manifest_held.recheck('E_INSTALL')
    manifest_raw = manifest_held.raw
    assert hashlib.sha256(manifest_raw).hexdigest() == 'e0d204e2827885c5f2f4278e709981b7fc1e02424d3bfa5ae2ff2af789789d26'
    manifest_rows = json.loads(manifest_raw)
    assert len(manifest_rows) == 4502
    selected_rows = [row for row in manifest_rows if row['path'] == 'Versions/3.15' or row['path'].startswith('Versions/3.15/')]
    assert len(selected_rows) == 4496 and c.digest(fixed_manifest_bytes(selected_rows)) == '3176a7d3551aaa719fa8ed26964237d0d1771184c6ce7a5159bbf039e7816572'
    supply_rows = [dict(row, mode=row['kind'] | (0o755 if row['kind'] != stat.S_IFREG or row['mode'] & 0o111 else 0o644)) for row in selected_rows]
    supply_rows.extend([{'path': 'ystack-private-tools', 'kind': stat.S_IFDIR, 'mode': 0o40755},
        {'path': 'ystack-private-tools/jq', 'kind': stat.S_IFREG, 'mode': 0o100755, 'size': 864040,
         'sha256': '5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef'}])
    assert c.digest(fixed_manifest_bytes(supply_rows)) == '9184f6976c2be2e1430594adbb406293168c0201c849e31bfd671f2c8e83fb9e'
    manifest = {}
    for row in supply_rows:
        value = {key: row[key] for key in ('kind', 'mode', 'size', 'sha256', 'link')
                 if key in row and (key != 'size' or row['kind'] != stat.S_IFDIR)}
        value['uid'] = 0
        if row['kind'] != stat.S_IFDIR:
            value['nlink'] = 1
        manifest[row['path']] = value
    assert len(manifest) == 4498 and c.digest(fixed_manifest_bytes(manifest)) == 'd6a212cf50fd2593c75e8e011c321e65fa8609cce7add72e69d16ff0e78252c4'
    owner = None
    if stage == 'real':
        bootstrap = c._hold_bytes(sys.executable, c.EXECUTABLE_LIMIT)
        owned.append(bootstrap)
        owner = c._DarwinChildOwner(bootstrap, source_held, owner_deadline(), ledger)
        assert uptime() < deadline
    for item in reversed((locator, *locator.parents)):
        if item == Path('/'):
            continue
        before = item.lstat()
        if stat.S_ISLNK(before.st_mode):
            inspect(item.parent.resolve(), True)
            assert before.st_uid == 0 and before.st_nlink == 1
            ctypes.set_errno(0)
            acl = library.acl_get_link_np(os.fsencode(item), 0x100)
            if acl:
                assert library.acl_free(acl) == 0
                raise ValueError('selector link with ACL is unsupported')
            assert ctypes.get_errno() == errno.ENOENT
            links[str(item)] = (identity(before), os.readlink(item))
        else:
            inspect(item, item != locator)
    root = c._open_held(str(prefix), True, rule(), 'E_INSTALL')
    owned.append(root)
    images.update((selected, prefix / 'bin/python3.15', prefix / 'Python'))
    observed = set()
    pending_tree = [fixed_prefix, fixed_tools]
    while pending_tree:
        directory = pending_tree.pop()
        name = str(directory.relative_to(fixed_root))
        assert name in manifest and name not in observed
        observed.add(name)
        assert directory.lstat().st_mode == manifest[name]['mode']
        inspect(directory, True)
        with os.scandir(str(directory)) as entries:
            for entry in entries:
                assert uptime() < deadline and len(observed) < 16384
                path = Path(entry.path)
                name = str(path.relative_to(fixed_root))
                assert name not in observed
                assert name in manifest
                row = manifest[name]
                before = path.lstat()
                assert stat.S_IFMT(before.st_mode) == row['kind']
                if row['kind'] == stat.S_IFDIR:
                    pending_tree.append(path)
                elif row['kind'] == stat.S_IFLNK:
                    observed.add(name)
                    parent = c._open_held(str(path.parent), True, rule(), 'E_INSTALL')
                    try:
                        assert before.st_uid == 0 and before.st_nlink == 1 and not before.st_mode & 0o022
                        assert stat.S_IMODE(before.st_mode) == 0o755 and os.readlink(path) == row['link']
                        ctypes.set_errno(0)
                        empty_acl(library.acl_get_link_np(os.fsencode(path), 0x100))
                        assert identity(path.lstat()) == identity(before) and os.readlink(path) == row['link']
                        links[str(path)] = (identity(before), row['link'])
                        parent.recheck('E_STALE')
                    finally:
                        parent.close()
                else:
                    observed.add(name)
                    raw = inspect(path)
                    assert len(raw) == row['size'] and hashlib.sha256(raw).hexdigest() == row['sha256']
                    assert stat.S_IMODE(before.st_mode) == (0o755 if row['mode'] & 0o111 else 0o644)
                    if name != 'ystack-private-tools/jq':
                        native_dependencies(path, raw)
    assert observed == set(manifest)
    assert len(native_inventory) == 91 and len(static_paths) == 3
    assert [list(native_inventory.values()).count(kind) for kind in (2, 6, 8)] == [3, 10, 78]
    assert sum(command == 0xe for source, command, name in load_edges) == 3
    assert sum(name.startswith(str(prefix) + '/') for source, command, name in load_edges) == 17
    assert sum(name.startswith(('/usr/lib/', '/System/Library/')) and command != 0xe
               for source, command, name in load_edges) == 117
    directories = [prefix / 'lib', prefix / 'include']
    while directories:
        directory = directories.pop()
        inspect(directory, True)
        with os.scandir(str(directory)) as entries:
            for entry in entries:
                assert len(rows) + len(directories) < 16384
                path = directory / entry.name
                if entry.is_dir(follow_symlinks=False):
                    inspect(path, True)
                    directories.append(path)
                else:
                    raw = inspect(path)
                    native_dependencies(path, raw)
    while images:
        path = images.pop()
        if path in seen:
            continue
        assert len(seen) < 256
        seen.add(path)
        raw = inspect(path)
        assert raw[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
        native_dependencies(path, raw, True)
    for name, (before, _digest) in rows.items():
        assert uptime() < deadline and identity(os.lstat(name)) == before
    assert all(not os.path.lexists(path) for path in cache_paths)
    for name, (before, target) in links.items():
        assert identity(os.lstat(name)) == before and os.readlink(name) == target
    assert not any(os.path.lexists(str(parent / 'pyvenv.cfg')) for parent in (selected.parent, prefix))
    assert not any(os.path.lexists(str(selected) + suffix) for suffix in ('._pth', '.zip'))
    assert Path(os.path.realpath(str(locator))) == selected
    for item in owned:
        item.recheck('E_STALE')
    assert uptime() < deadline
    print(json.dumps({'bootstrap': 'fixed-framework-real-resolver' if stage == 'real' else 'fixed-system-trusted-reader', 'python': str(selected),
        'prefix': str(prefix), 'objects': len(rows), 'native_images': len(seen),
        'closure_sha256': c.digest(c.canonical({'objects': rows, 'selector_links': links})), 'acl_commands': len(ledger.commands),
        'acl_commands_sha256': c.digest(c.canonical(ledger.commands)), 'stage': stage, 'pid': os.getpid(), 'candidate_executed': stage == 'real', 'privileged_execution': False}, sort_keys=True), file=sys.stderr)
    if stage == 'empty':
        assert os.getpid() == entry_pid
        for item in owned:
            item.recheck('E_STALE')
        os.execv(str(selected), [str(selected), '-I', '-S', '-B', '-c', guard_code.decode('utf8'),
            str(package), str(selected), str(guard_path), 'real', str(deadline), str(entry_pid)])
    print(selected)
except BaseException as error:
    try:
        chain = []
        cursor = error
        for _ in range(4):
            if cursor is None:
                break
            chain.append({'type': type(cursor).__name__, 'code': getattr(cursor, 'code', None),
                'errno': getattr(cursor, 'errno', None), 'filename': str(getattr(cursor, 'filename', ''))[:256]})
            cursor = cursor.__cause__ or cursor.__context__
        print(json.dumps({'stage': active_stage, 'bootstrap_refusal_path': active_path[:256],
            'exception': type(error).__name__, 'code': getattr(error, 'code', None),
            'chain': chain, 'candidate_executed': stage == 'real'}, sort_keys=True), file=sys.stderr)
    except BaseException:
        pass
    raise
finally:
    original = sys.exc_info()[1]
    try:
        c._close_paths(owned)
    except OSError as cleanup_error:
        if original is not None:
            raise original from cleanup_error
        raise
PY_MAC_FIXED_RUNTIME_GUARD
    ) || return 1
    /bin/chmod 0500 "$mac_guard_file"
    /usr/bin/python3 -I -S -B - "$root" "$tmp/runtime-guard" <<'PY_MAC_FIXED_MANIFEST'
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys

package = Path(sys.argv[1])
directory_path = Path(sys.argv[2])
assert package.is_absolute() and package.resolve() == package
assert directory_path.is_absolute() and directory_path.resolve() == directory_path
source = package / 'shadow/v1/_consumer.py'
spec = importlib.util.spec_from_file_location('fixed_scope_runtime_reader', source)
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)
owned = []
try:
    guard = c._hold_bytes(str(directory_path / 'guard.py'), c.EXECUTABLE_LIMIT)
    owned.append(guard)
    assert hashlib.sha256(guard.raw).hexdigest() == '3c229ffd250d8b255ae59ae1f507e3815c9f6bfb25b793c9075871675a1a540c'
    cache = Path(os.environ['YSTACK_PROOF_TMP'])
    assert cache.is_absolute() and cache.resolve() == cache
    manifest = c._hold_bytes(str(cache / 'manifest.json'), c.EXECUTABLE_LIMIT)
    owned.append(manifest)
    assert hashlib.sha256(manifest.raw).hexdigest() == 'e0d204e2827885c5f2f4278e709981b7fc1e02424d3bfa5ae2ff2af789789d26'
    guard.recheck('E_STALE')
    manifest.recheck('E_STALE')
    directory = c._open_held(str(directory_path), True,
        lambda fd, state, ancestor: ancestor or state.st_uid == os.getuid() and stat.S_IMODE(state.st_mode) == 0o700,
        'E_INSTALL')
    owned.append(directory)
    before, names = directory.before, set(os.listdir(directory.fd))
    assert names == {'guard.py'}
    fd = os.open('manifest.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o500, dir_fd=directory.fd)
    try:
        offset = 0
        while offset < len(manifest.raw):
            count = os.write(fd, manifest.raw[offset:offset + 65536])
            assert count > 0
            offset += count
        os.fsync(fd)
    finally:
        os.close(fd)
    after = c._metadata(directory.fd)
    assert c._identity(after)[:6] == c._identity(before)[:6]
    assert set(os.listdir(directory.fd)) == {'guard.py', 'manifest.json'}
    assert c._identity(c._metadata(guard.held.components[-2].fd)) == c._identity(after)
    directory.components[-1].before = after
    guard.held.components[-2].before = after
    directory.recheck('E_STALE')
    guard.recheck('E_STALE')
    manifest.recheck('E_STALE')
finally:
    c._close_paths(owned)
PY_MAC_FIXED_MANIFEST
  fi
  [ "$(sha256_path "$mac_guard_file")" = 3c229ffd250d8b255ae59ae1f507e3815c9f6bfb25b793c9075871675a1a540c ] || return 1
  /usr/bin/python3 -I -S -B "$mac_guard_file" "$root" "$1" "$mac_guard_file" empty 0 0
}

run_validator() { PATH="$bin:/usr/bin:/bin" "$validator" validate "$1"; }
if [ "${platform%%:*}" = Darwin ]; then
  python_candidate=/Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python
  python_candidate=$(authenticate_genuine_macos_python "$python_candidate") || fail 'fixed supplied runtime closure required'
  [ "$("$python_candidate" -I -S -B -c 'import sys
from pathlib import Path
p = Path(sys.executable)
print("selected_python=" + str(p) + " version=" + ".".join(map(str, sys.version_info[:3])),
      file=sys.stderr, flush=True)
assert sys.version_info >= (3, 11)
assert p == Path("/Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python")
assert sys.version_info[:3] == (3, 15, 0)
assert sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
prefix = Path("/Library/Frameworks/Python.framework/Versions/3.15")
assert p.resolve() == p and sys.prefix == sys.base_prefix == str(prefix)
assert all(Path(value).is_absolute() and (Path(value) == prefix or prefix in Path(value).parents)
           for value in sys.path)
print(p)')" = "$python_candidate" ] || fail 'selected Python layout differs'
  [ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
else
  python_candidate=$(command -v python3.14 2>/dev/null || command -v python3)
  if [ -x /opt/homebrew/bin/python3.14 ]; then python_candidate=/opt/homebrew/bin/python3.14; fi
fi
python_bin=$("$python_candidate" -I -S -B -c 'import os,sys;print(os.path.realpath(sys.executable))')
"$python_bin" -I -S -B -c 'import sys;assert sys.version_info >= (3,11)' || fail 'existing Python 3.11+ required'
/bin/ln -s "$python_bin" "$bin/python3"
"$python_bin" -I -S -B - "$gate_program" "$tmp/environment-reasons.jq" <<'PY_REASON_PROGRAM'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
boundary='\n$policy[0].body as $p |'
assert source.count(boundary)==1
program=source.split(boundary)[0]
program+='\nall(.[]; . as $case | (.value | environment_evaluation_ok($case.form)) == $case.expected)\n'
pathlib.Path(sys.argv[2]).write_text(program)
PY_REASON_PROGRAM
"$jq_bin" -n --arg sha "$(sha256_path "$gate_program")" '
  {state:"present",value:{verdict:"satisfied",reason_ids:[],evaluation_ref:{
    content_id:"shadow-sandbox-evaluation",
    media_type:"application/vnd.ystack.control-evaluation+json",sha256:$sha}}} as $value |
  ["legacy","enforced-reproduction.v1","withheld-write.v1"] |
  map(. as $form | ["sandbox.declaration-satisfied","sandbox.verifier-binding-satisfied"] |
    map(. as $reason | {form:$form,value:($value | .value.reason_ids=[$reason]),
      expected:(if $form == "legacy" then $reason == "sandbox.declaration-satisfied"
        else $reason == "sandbox.verifier-binding-satisfied" end)})) | add
' >"$tmp/environment-reasons.json"
"$jq_bin" -e --slurpfile policy "$policy" --arg scope_sha '' --arg shadow_set_sha '' \
  -f "$tmp/environment-reasons.jq" "$tmp/environment-reasons.json" >/dev/null ||
  fail 'record forms confused declaration and bound evaluator reasons'
pass 'each record form accepts its evaluator reason and refuses the other evaluator reason'
"$python_bin" -I -S -B - "$root" <<'PY_FIXED_MARKER'
import ast,importlib.util,json,pathlib,sys,types
root=pathlib.Path(sys.argv[1]);source=root/'scope/v1/read-shadow-evidence.py'
spec=importlib.util.spec_from_file_location('scope_fixed_marker_subject',source)
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
tree=ast.parse(source.read_bytes())
method=next(node for node in ast.walk(tree) if isinstance(node,ast.FunctionDef) and node.name=='write_relations')
start=next(index for index,node in enumerate(method.body) if isinstance(node,ast.Assign)
    and any(isinstance(target,ast.Name) and target.id=='marker_raw' for target in node.targets))
body=method.body[start:start+3]+[ast.Return(value=ast.Name(id='marker',ctx=ast.Load()))]
function=ast.FunctionDef(name='fixed_marker',args=ast.arguments(posonlyargs=[],args=[ast.arg(arg='self')],
    kwonlyargs=[],kw_defaults=[],defaults=[]),body=body,decorator_list=[])
namespace={'c':module.c,'require':module.require,'json':json}
exec(compile(ast.fix_missing_locations(ast.Module(body=[function],type_ignores=[])),str(source),'exec'),namespace)
def parse_fixed(raw):
    return namespace['fixed_marker'](types.SimpleNamespace(package_sources={
        'config/construction-mode.json':types.SimpleNamespace(raw=raw)}))
raw=(root/'config/construction-mode.json').read_bytes();canonical=module.c.canonical(json.loads(raw))
assert raw!=canonical
pretty=parse_fixed(raw);normalized=parse_fixed(canonical);assert pretty==normalized
policy=module.parse((root/'scope/v1/scope-policy.json').read_bytes())
for path in ['README.md','ystack-evidence/incident.fixture/shadow-record.json','AGENTS.md']:
    assert module.c.write_path_ok(path,policy,pretty)==module.c.write_path_ok(path,policy,normalized)
for bad in [b'{"status":0,"status":1}',b'{"nested":{"id":0,"id":1}}',
            b'{"value":NaN}',b'{"value":Infinity}',b'{"value":1e9999}',
            b'[]',b'\xff',b' '* (8*module.c.DOCUMENT_LIMIT+1),b'{}'.decode().encode('utf-16'),
            b'{"nested":'+b'{"child":'*2000+b'{"id":0,"id":1}'+b'}'*2000+b'}']:
    try:parse_fixed(bad)
    except module.c.Refusal as error:assert error.code=='E_RELATION'
    else:raise AssertionError('invalid fixed marker accepted')
try:module.parse(raw)
except module.c.Refusal:pass
else:raise AssertionError('untrusted evidence parser accepted pretty bytes')
print('fixed reviewed marker: pretty/canonical policy equality; 10 invalid cases refuse; evidence parser stays strict')
PY_FIXED_MARKER
"$python_bin" -I -S -B - "$root" <<'PY_MAC_TRANSITION'
import json,pathlib,subprocess,sys
source=(pathlib.Path(sys.argv[1])/'scripts/test/scope-qualification.test.sh').read_text()
cleanup=source[source.index('\ncleanup_genuine() {'):source.index('\nsetup_genuine_linux() {')]
condition=cleanup[cleanup.index('    if [ "$current" = "${genuine_mac_identities[index]}" ] ||'):]
condition=condition[:condition.index(' then')+5]
old=json.dumps({'name':'fixture','uuid':'a'*32,'uid':None,'gid':None},sort_keys=True,separators=(',',':'))
new=json.dumps({'name':'fixture','uuid':'a'*32,'uid':56000,'gid':None},sort_keys=True,separators=(',',':'))
third=json.dumps({'name':'fixture','uuid':'a'*32,'uid':56001,'gid':None},sort_keys=True,separators=(',',':'))
other=json.dumps({'name':'fixture','uuid':'b'*32,'uid':56000,'gid':None},sort_keys=True,separators=(',',':'))
program='index=0; current=$1; genuine_mac_identities=($2); pending=$3;\n'+condition+'\n exit 0; else exit 1; fi'
for current,pending,accepted in [(old,new,True),(new,new,True),(third,new,False),
                                (other,new,False),(new,'',False),(old,'',True)]:
    result=subprocess.run(['/bin/bash','-c',program,'transition',current,old,pending],
                          stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=2)
    assert result.returncode==(0 if accepted else 1) and not result.stdout and not result.stderr
setter=source[source.index('\nmac_set_record() {'):source.index('\nsetup_genuine_macos() {')]
assert setter.index('genuine_mac_pending[index]=$expected') < setter.index('/usr/bin/dscl . -create')
assert setter.index('[ "$current" = "$expected" ]') < setter.index("genuine_mac_pending[index]=''")
print('Mac owned cleanup: old/new bounded transition accepts; third identity refuses; journal precedes mutation')
PY_MAC_TRANSITION
/bin/mkdir -m 700 "$tmp/legacy-bundles"
/usr/bin/git init --bare "$tmp/legacy-source.git" >"$tmp/git-init.out" 2>"$tmp/git-init.err"
/bin/mkdir -m 700 "$tmp/stale-observation"
python3 -I -S -B - "$root" "$tmp/stale-observation" <<'PY_STALE_PREPARE'
import difflib,hashlib,json,pathlib,shlex
root=pathlib.Path(__import__('sys').argv[1]);area=pathlib.Path(__import__('sys').argv[2])
expected={'scope/v1/evaluate-scope.sh': 'f120e877973aa0b66d7ce3de2f6b9cc46b6a9b073e89c606fd99fd23fc84356a', 'scope/v1/read-shadow-evidence.py': 'a2e5ba7f8b8274851e727fd0928c2eafb7153305d84daf55a41a1c4315a9c54b', 'shadow/v1/_consumer.py': '34d314505860f7569f53f41491c29979ab30aa08f83cfc151444f8cb6a235f68'}
for path,digest in expected.items():
    assert hashlib.sha256((root/path).read_bytes()).hexdigest()==digest
observer_source = r"""import hashlib,json,os,runpy,stat,sys,time,types
def cost_identity(value):
    return (value.st_dev,value.st_ino,stat.S_IFMT(value.st_mode),value.st_uid,
            stat.S_IMODE(value.st_mode),value.st_nlink)
def cost_open(which,flags):
    path,expected=COST[which]
    fd=os.open(path,flags|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        actual=os.fstat(fd)
        if cost_identity(actual)!=tuple(expected) or actual.st_uid!=os.getuid():raise ValueError('cost identity')
        if cost_identity(os.lstat(path))!=tuple(expected):raise ValueError('cost named identity')
        if actual.st_size>(4096 if which=='data' else 1):raise ValueError('cost cap')
        return fd
    except BaseException:
        os.close(fd);raise

def cost_rows():
    fd=cost_open('data',os.O_RDONLY)
    try:raw=os.read(fd,4097)
    finally:os.close(fd)
    rows=[json.loads(line) for line in raw.splitlines()]
    if len(raw)>4096 or len(rows)>3 or any(len(line)+1>1024 for line in raw.splitlines()):raise ValueError('cost rows')
    if len({row['sample'] for row in rows})!=len(rows):raise ValueError('duplicate cost')
    import math
    for row in rows:
        if row['sample'] not in {'protected-0-frontend','protected-0-observer','terminal-normal'}:raise ValueError('cost case')
        for name in ('source_sha256','reader_sha256','copy_sha256','argv_sha256'):
            value=row[name]
            if type(value) is not str or len(value)!=64 or any(c not in '0123456789abcdef' for c in value):raise ValueError('cost binding')
        if type(row['completed']) is not bool:raise ValueError('cost completion')
        points=row['phases']
        if points!='GAP' and (type(points) is not list or len(points)!=5 or
            not all(type(v) in (int,float) and math.isfinite(v) for v in points) or points[0]!=0 or
            not all(a<=b for a,b in zip(points,points[1:]))):raise ValueError('cost phases')
        if row['completed'] and (points=='GAP' or row.get('outcome')!='normal'):raise ValueError('cost incomplete')
    return rows

def cost_put(row):
    rows=cost_rows()
    if row['sample'] not in {'protected-0-frontend','protected-0-observer','terminal-normal'}:raise ValueError('cost sample')
    rows=[old for old in rows if old['sample']!=row['sample']]+[row]
    lines=[json.dumps(old,separators=(',',':'),ensure_ascii=True).encode()+b'\n' for old in rows]
    raw=b''.join(lines)
    if len(rows)>3 or any(len(line)>1024 for line in lines) or len(raw)>4096:raise ValueError('cost encoded cap')
    fd=cost_open('data',os.O_WRONLY)
    try:
        os.ftruncate(fd,0)
        if os.write(fd,raw)!=len(raw):raise OSError('cost write')
    finally:os.close(fd)

def cost_bind(sample,source,reader,copy,argv):
    cost_put({'sample':sample,'source_sha256':source,'reader_sha256':reader,
        'copy_sha256':copy,'argv_sha256':argv,'completed':False,'phases':'GAP'})

def cost_finish(sample,points,normal):
    import math
    row=next(row for row in cost_rows() if row['sample']==sample)
    valid=len(points)==5 and all(type(value) in (int,float) and math.isfinite(value) for value in points)
    valid=valid and all(a<=b for a,b in zip(points,points[1:]))
    row.update(completed=bool(valid and normal),phases=[value-points[0] for value in points] if valid else 'GAP',
        outcome='normal' if normal else 'unwind-or-incomplete')
    cost_put(row)

def cost_qualify():
    rows=cost_rows()
    if {row['sample'] for row in rows}!={'protected-0-frontend','protected-0-observer','terminal-normal'}:return
    if not all(row['completed'] for row in rows):return
    fd=cost_open('eligible',os.O_WRONLY)
    try:
        if os.write(fd,b'1')!=1:raise OSError('cost eligibility')
    finally:os.close(fd)

def cost_export():
    try:
        fd=cost_open('eligible',os.O_RDONLY)
        try:eligible=os.read(fd,2)
        finally:os.close(fd)
        if eligible!=b'1':return
        rows=cost_rows()
        if len(rows)!=3 or not all(row['completed'] for row in rows):return
        raw=b''.join(json.dumps(row,separators=(',',':'),ensure_ascii=True).encode()+b'\n' for row in rows)
        if len(raw)<=4096:sys.stderr.buffer.write(raw)
    except BaseException:pass

def cost_frontend(source,sample,helper):
    import shlex
    entry="scope_cost_points=($SECONDS GAP GAP GAP GAP)\nscope_cost_done=false\nscope_cost_wait=false\n"
    launch='/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C YSTACK_SCOPE_JQ="$jq_bin"'
    wait='wait "$reader_pid" || reader_status=$?\n'
    cleanup='cleanup() { finish_reader; exec 8<&-; /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }'
    assert source.count(launch)==source.count(wait)==source.count(cleanup)==1
    logger='''cleanup() {
  local scope_cost_status
  scope_cost_points[3]=$SECONDS
  scope_cost_original_cleanup
  scope_cost_status=$?
  scope_cost_points[4]=$SECONDS
  if [ "$scope_cost_done" = false ]; then
    scope_cost_done=true
    python3 -I -S -B - HELPER SAMPLE "$scope_cost_wait" "${scope_cost_points[@]}" <<'PY_FIXED_COST_FINISH' >/dev/null 2>&1 || :
import runpy,sys
m=runpy.run_path(sys.argv[1])
points=[int(value) if value.isdecimal() else None for value in sys.argv[4:]]
m['cost_finish'](sys.argv[2],points,sys.argv[3]=='true')
PY_FIXED_COST_FINISH
  fi
  return "$scope_cost_status"
}'''
    logger=logger.replace('HELPER',shlex.quote(str(helper))).replace('SAMPLE',shlex.quote(sample))
    source=source.replace('umask 077\n','umask 077\n'+entry,1)
    source=source.replace(launch,'scope_cost_points[1]=$SECONDS\n'+launch,1)
    source=source.replace(wait,wait+'scope_cost_points[2]=$SECONDS\n[ "$reader_status" -ne 0 ] || scope_cost_wait=true\n',1)
    return source.replace(cleanup,cleanup.replace('cleanup()', 'scope_cost_original_cleanup()')+'\n'+logger,1)

FIELDS=('dev','ino','type','uid','gid','mode','nlink','size','mtime_ns','ctime_ns')
def state(value):
    return dict(zip(FIELDS,(value.st_dev,value.st_ino,stat.S_IFMT(value.st_mode),
        value.st_uid,value.st_gid,stat.S_IMODE(value.st_mode),value.st_nlink,
        value.st_size,value.st_mtime_ns,value.st_ctime_ns)))
def observe(original,log,case,phase,argv,index):
    descriptor=None
    provisional=None
    record=None
    gap=None
    events={}
    sources={str(original),str(original.parents[2]/'shadow/v1/_consumer.py')}
    started=time.monotonic()
    cost_selected=index==0 and case=='.github/workflows/ci.yml'
    cost_points=[started,None,None,None,None]
    cost_normal=False
    source_lines={}
    source_codes={}
    def code_tree(code):
        result={code}
        for value in code.co_consts:
            if isinstance(value,types.CodeType):result.update(code_tree(value))
        return result
    try:
        for name in sources:
            with open(name,'rb') as source:
                raw=source.read(16*1024*1024+1)
            if len(raw)>16*1024*1024:raise ValueError('diagnostic source bound')
            source_lines[name]=raw.decode().splitlines()
            source_codes[name]=code_tree(compile(raw,name,'exec',dont_inherit=True))
    except BaseException as error:
        gap='source-bind:'+type(error).__name__
    try:
        before=os.lstat(log)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or before.st_uid!=os.getuid():
            raise ValueError('diagnostic sink identity')
        provisional=os.open(log,os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW|os.O_NONBLOCK)
        if state(os.fstat(provisional))!=state(before):raise ValueError('diagnostic sink changed')
        descriptor=provisional
        provisional=None
    except BaseException as error:
        gap=type(error).__name__
        rejected=provisional
        provisional=None
        descriptor=None
        if rejected is not None:
            try:os.close(rejected)
            except BaseException as close_error:
                gap+=';close:'+type(close_error).__name__
    def watched(frame):
        return (frame.f_code.co_filename in source_codes and
                frame.f_code in source_codes[frame.f_code.co_filename])
    def trace(frame,event,arg):
        nonlocal record,gap
        try:
            parent=frame.f_back
            if event=='return' and watched(frame):events.pop(id(frame),None)
            if event=='line' and watched(frame) and frame.f_code.co_name=='recheck':
                if 'component' in frame.f_locals:
                    key=(id(frame),frame.f_locals.get('index'))
                    if events.get(id(frame),{}).get('component')!=key:
                        events[id(frame)]={'component':key,'returns':[]}
            if event=='return' and parent is not None and watched(parent):
                values=events.setdefault(id(parent),{'returns':[]})['returns']
                item={'function':frame.f_code.co_name,'caller_line':parent.f_lineno}
                if hasattr(arg,'st_mtime_ns'):
                    item['stat']=state(arg)
                elif frame.f_code.co_name in {'_identity','identity'}:
                    value=frame.f_locals.get('value',frame.f_locals.get('state'))
                    if hasattr(value,'st_mtime_ns'):item.update(stat=state(value),identity=list(arg))
                elif type(arg) is bool:item['actual_bool_return']=arg
                else:return trace
                values.append(item)
                del values[:-12]
            if event=='exception' and parent is not None and watched(parent) and frame.f_code.co_name in {'_metadata','_named_metadata'}:
                values=events.setdefault(id(parent),{'returns':[]})['returns']
                values.append({'function':frame.f_code.co_name,'caller_line':parent.f_lineno,
                    'exception':type(arg[1]).__name__,'errno':getattr(arg[1],'errno',None)})
                del values[:-12]
            if event!='exception' or record is not None or not watched(frame):return trace
            error=arg[1]
            if str(error)!='E_STALE':return trace
            held_frame=frame
            while held_frame is not None:
                owner=held_frame.f_locals.get('self')
                if held_frame.f_code.co_name=='recheck' and type(owner).__name__=='HeldPath':break
                held_frame=held_frame.f_back
            if held_frame is None:
                gap='E_STALE outside original HeldPath recheck'
                return trace
            record={'status':'FIRST_STALE','case':case,'case_index':index,'phase':phase,
                'exception':type(error).__name__,'predicate_input':frame.f_locals.get('value') if type(frame.f_locals.get('value')) is bool else None,'elapsed':time.monotonic()-started,
                'guard':{'source':frame.f_code.co_filename,'function':frame.f_code.co_name,
                    'line':frame.f_lineno},'frames':[]}
            current=held_frame
            while current is not None and len(record['frames'])<16:
                if watched(current):
                    local=current.f_locals
                    entry={'source':current.f_code.co_filename,'function':current.f_code.co_name,
                        'line':current.f_lineno,'actual_returns':events.get(id(current),{}).get('returns',[])}
                    for name in ('index','fd','name','path','code','ancestor','maximum','commit_sha'):
                        value=local.get(name)
                        if value is None or type(value) in (str,int,bool):entry[name]=value
                    owner=local.get('self')
                    if owner is not None and hasattr(owner,'path'):entry['held_path']=str(owner.path)
                    component=local.get('component')
                    if component is not None:
                        entry['component']={'fd':component.fd,'name':component.name,
                            'ancestor':component.ancestor,'expected':state(component.before)}
                    for name in ('before','current','named','after','after_named'):
                        value=local.get(name)
                        if hasattr(value,'st_mtime_ns'):entry[name+'_local']=state(value)
                        else:entry[name+'_local']='GAP'
                    expected_identity=local.get('expected')
                    entry['expected_identity_local']=list(expected_identity) if type(expected_identity) is tuple else 'GAP'
                    expected=local.get('raw')
                    if isinstance(expected,bytes):entry['raw_local_memory_sha256']=hashlib.sha256(expected).hexdigest()
                    record['frames'].append(entry)
                current=current.f_back
        except BaseException as error:
            gap='observer:'+type(error).__name__
        return trace
    def dispatch(frame,event,arg):
        if event!='call':return None
        if watched(frame):
            frame.f_trace_lines=frame.f_code.co_name=='recheck'
            return trace
        parent=frame.f_back
        if parent is not None and watched(parent):
            frame.f_trace_lines=False
            return trace
        return None
    previous=sys.gettrace()
    try:
        sys.argv=argv
        cost_points[1]=time.monotonic() if cost_selected else None
        try:sys.settrace(dispatch)
        except BaseException as error:gap='trace-install:'+type(error).__name__
        cost_points[2]=time.monotonic() if cost_selected else None
        try:
            runpy.run_path(str(original),run_name='__main__')
            cost_normal=True
        finally:cost_points[3]=time.monotonic() if cost_selected else None
    finally:
        try:sys.settrace(previous)
        except BaseException as error:gap='trace-restore:'+type(error).__name__
        cost_points[4]=time.monotonic() if cost_selected else None
        if index==0 and case=='.github/workflows/ci.yml':
            try:cost_finish('protected-0-observer',cost_points,cost_normal and gap is None)
            except BaseException:pass
        try:
            if descriptor is not None:
                payload=record or {'status':'OBSERVER_GAP','reason':'no original HeldPath E_STALE captured','case':case,'phase':phase}
                payload['observer_gap']=gap
                payload['capture_semantics']='original exception/return frames; no object reread'
                encoded=json.dumps(payload,separators=(',',':'),ensure_ascii=True).encode()+b'\n'
                if len(encoded)>12000:
                    payload['frames']=payload.get('frames',[])[:2]
                    payload['truncated']=True
                    encoded=json.dumps(payload,separators=(',',':'),ensure_ascii=True).encode()+b'\n'
                if len(encoded)>12000:
                    encoded=json.dumps({'status':'OBSERVER_GAP','reason':'core record oversize',
                        'guard':payload.get('guard'),'case':case,'phase':phase}).encode()+b'\n'
                if os.fstat(descriptor).st_size+len(encoded)>16384:
                    encoded=b'{"status":"OBSERVER_GAP","reason":"total cap"}\n'
                if os.fstat(descriptor).st_size+len(encoded)<=16384:
                    sent=os.write(descriptor,encoded)
                    if sent!=len(encoded):gap='short-write'
        except BaseException:
            pass
        finally:
            if descriptor is not None:
                try:os.close(descriptor)
                except BaseException:pass
"""

cost={}
for name,leaf,raw in [('data','same-call-cost.data',b''),('eligible','same-call-cost.eligible',b'0')]:
    path=area/leaf
    fd=__import__('os').open(path,__import__('os').O_CREAT|__import__('os').O_EXCL|__import__('os').O_WRONLY,0o600)
    try:
        assert __import__('os').write(fd,raw)==len(raw)
        value=__import__('os').fstat(fd)
        cost[name]=(str(path),(value.st_dev,value.st_ino,__import__('stat').S_IFMT(value.st_mode),value.st_uid,
            __import__('stat').S_IMODE(value.st_mode),value.st_nlink))
    finally:__import__('os').close(fd)
observer_source+='\nCOST='+repr(cost)+'\n'
observer=area/'observer.py';observer.write_text(observer_source)
cost_functions={};exec(compile(observer_source,str(observer),'exec'),cost_functions)

front=(root/'scope/v1/evaluate-scope.sh').read_text()
reader=root/'scope/v1/read-shadow-evidence.py'
cases=['.github/workflows/ci.yml', 'config/models.conf', 'AGENTS.md', 'control/v1/validate.sh', 'src/migrations/001.sql', 'app/auth/login.ts', 'docs/*/page.md', 'secrets/token.txt']
frontend_capture = r"""diag_record=''
diag_sink_ready=false
diag_log=DIAG_LOG
diag_case_index=DIAG_INDEX
diag_sink_before=$(/usr/bin/stat -Lc '%d:%i:%u:%g:%f:%h' "$diag_log" 2>/dev/null) || diag_sink_before=''
if [ -f "$diag_log" ] && [ ! -L "$diag_log" ] && [ -n "$diag_sink_before" ]; then
  if { exec 19>>"$diag_log"; } 2>/dev/null; then
    diag_sink_open=$(/usr/bin/stat -Lc '%d:%i:%u:%g:%f:%h' /dev/fd/19 2>/dev/null) || diag_sink_open=''
    diag_sink_named=$(/usr/bin/stat -Lc '%d:%i:%u:%g:%f:%h' "$diag_log" 2>/dev/null) || diag_sink_named=''
    IFS=: read -r _ _ diag_uid _ diag_mode diag_links <<<"$diag_sink_open"
    if [ "$diag_sink_before" = "$diag_sink_open" ] && [ "$diag_sink_open" = "$diag_sink_named" ] &&
       [ "$diag_uid" = "$UID" ] && [ "$diag_links" = 1 ] &&
       [[ "$diag_mode" =~ ^[0-9a-f]+$ ]] && [ "$((16#$diag_mode & 0777))" -eq 384 ]; then
      diag_sink_ready=true
    else
      exec 19>&-
    fi
  fi
fi
"""
emit_capture = r"""  diag_original_status=$?
  if [ -z "$diag_record" ]; then
    case "${1:-}" in
      E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE) diag_token=$1 ;;
      *) diag_token=GAP ;;
    esac
    diag_ready_presence=${ready+present}
    diag_commit_presence=${commit+present}
    printf -v diag_record '{"status":"FRONTEND_ERROR","case_index":%s,"original_command_status":%s,"copy_caller_line":%s,"phase":"%s","token":"%s","pid":%s,"reader_pid":"%s","control_open":"%s","control_verified":"%s","reader_status":"%s","ready_presence":"%s","commit_presence":"%s"}' \
      "$diag_case_index" "$diag_original_status" "${BASH_LINENO[0]:-0}" "${FUNCNAME[1]:-main}" "$diag_token" "${BASHPID:-$$}" \
      "${reader_pid-GAP}" "${control_open-GAP}" "${control_verified-GAP}" "${reader_status-GAP}" \
      "${diag_ready_presence:-GAP}" "${diag_commit_presence:-GAP}"
    if [ "${#diag_record}" -gt 512 ]; then diag_record='{"status":"OBSERVER_GAP","reason":"frontend memory cap"}'; fi
  fi
"""
exit_capture = r"""diag_after_cleanup() {
  diag_exit_status=$?
  cleanup
  diag_cleanup_status=$?
  if [ -n "$diag_record" ]; then
    diag_record=${diag_record%\}}
    diag_record+=",\"frontend_exit_status\":$diag_exit_status,\"cleanup_return_status\":$diag_cleanup_status}"
  fi
  if [ "$diag_sink_ready" = true ] && [ -n "$diag_record" ]; then
    diag_sink_now=$(/usr/bin/stat -Lc '%d:%i:%u:%g:%f:%h' /dev/fd/19 2>/dev/null) || diag_sink_now=''
    diag_size=$(/usr/bin/stat -Lc '%s' /dev/fd/19 2>/dev/null) || diag_size=''
    if [ "$diag_sink_now" = "$diag_sink_before" ] && [[ "$diag_size" =~ ^[0-9]+$ ]] &&
       [ "$((diag_size + ${#diag_record} + 1))" -le 16384 ]; then
      /usr/bin/printf '%s\n' "$diag_record" >&19 2>/dev/null || :
    fi
  fi
  if [ "$diag_sink_ready" = true ]; then exec 19>&-; fi
  exit "$diag_exit_status"
}
trap diag_after_cleanup EXIT
"""
for index,case in enumerate(cases+['evaluation-reasons']):
    log=area/(str(index)+'.jsonl');log.touch(mode=0o600,exist_ok=False)
    binding=area/(str(index)+'.binding.json');binding.touch(mode=0o600,exist_ok=False)
    wrapper=area/(str(index)+'.py')
    wrapper.write_text("import pathlib,runpy,sys\n"+
        "m=runpy.run_path("+repr(str(observer))+")\n"+
        "m['observe'](pathlib.Path("+repr(str(reader))+"),"+repr(str(log))+","+repr(case)+
        ",'reader', ["+repr(str(reader))+ "]+sys.argv[1:],"+str(index)+")\n")
    copy=front.replace('source_path=${BASH_SOURCE[0]}','source_path='+shlex.quote(str(root/'scope/v1/evaluate-scope.sh')))
    launch='"$python_bin" -I -S -B "$reader" read'
    assert copy.count(launch)==1 and copy.count('trap cleanup EXIT')==1
    copy=copy.replace(launch,'"$python_bin" -I -S -B '+shlex.quote(str(wrapper))+' read')
    assert '19>&' not in copy and '19<' not in copy
    copy=copy.replace('umask 077\n','umask 077\n'+frontend_capture.replace('DIAG_LOG',shlex.quote(str(log))).replace('DIAG_INDEX',str(index)),1)
    assert copy.count('emit_error() {\n')==1
    copy=copy.replace('emit_error() {\n','emit_error() {\n'+emit_capture,1)
    copy=copy.replace('trap cleanup EXIT',exit_capture.rstrip(),1)
    assert copy.count('7>&- 8>&- &')==1
    copy=copy.replace('7>&- 8>&- &','7>&- 8>&- 19>&- &',1)
    if index==0:copy=cost_functions['cost_frontend'](copy,'protected-0-frontend',observer)
    frontend=area/(str(index)+'.sh');frontend.write_text(copy);frontend.chmod(0o500)
    original_lines=front.splitlines();copied_lines=copy.splitlines();mapping={}
    for match in difflib.SequenceMatcher(a=original_lines,b=copied_lines,autojunk=False).get_matching_blocks():
        for offset in range(match.size):
            if 'emit_error ' in original_lines[match.a+offset]:mapping[match.b+offset+1]=match.a+offset+1
    line_map={'original_sha256':hashlib.sha256(front.encode()).hexdigest(),
        'copy_sha256':hashlib.sha256(copy.encode()).hexdigest(),'line_map':mapping,
        'original_line_sha256':{str(number):hashlib.sha256(original_lines[number-1].encode()).hexdigest() for number in mapping.values()}}
    if index==8:
        import os
        line_map['slot_identity']={name:list((lambda value:(value.st_dev,value.st_ino,value.st_mode,
            value.st_uid,value.st_gid,value.st_nlink))(os.lstat(path)))
            for name,path in (('log',log),('binding',binding))}
    raw=json.dumps(line_map,separators=(',',':')).encode()+b'\n'
    assert len(raw)<=12000
    (area/(str(index)+'.lines.json')).write_bytes(raw)

PY_STALE_PREPARE
python3 -I -S -B - "$root" "$tmp/same-call-owned-controls" "${BASH_SOURCE[0]}" <<'PY_SAME_CALL_OWNED_CONTROLS'
import ast,hashlib,json,os,pathlib,runpy,signal,stat,subprocess,sys,time
root,area=map(pathlib.Path,sys.argv[1:3]);source=pathlib.Path(sys.argv[3]).read_text()
area.mkdir()
prepare=source.split("<<'PY_STALE_PREPARE'",1)[1].split('\n',1)[1].split('\nPY_STALE_PREPARE\n',1)[0]
observer=ast.literal_eval(next(node.value for node in ast.parse(prepare).body
    if isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id=='observer_source' for target in node.targets)))
front=(root/'scope/v1/evaluate-scope.sh').read_text();reports=[];actual={};execution=0;dependencies=[]
def freeze(paths):
    global execution
    execution+=1
    snapshot=area/('preexec-'+str(execution));snapshot.mkdir()
    rows=[]
    for number,path in enumerate(paths):
        path=pathlib.Path(path)
        saved=str(number)+'-'+path.name
        raw=path.read_bytes();(snapshot/saved).write_bytes(raw)
        rows.append({'path':str(path),'snapshot':saved,'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)})
    (snapshot/'binding.json').write_text(json.dumps(rows,sort_keys=True)+'\n')
def run(argv):
    child=None
    freeze(list(dict.fromkeys(dependencies+[pathlib.Path(arg) for arg in argv if str(arg).startswith(str(area)) and pathlib.Path(arg).suffix in ('.py','.sh')])))
    try:
        child=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        stdout,stderr=child.communicate(timeout=4)
        return child.returncode,stdout,stderr
    finally:
        if child is not None:
            try:
                if child.poll() is None:child.kill()
                child.wait(timeout=2)
            finally:
                try:child.stdout.close()
                finally:child.stderr.close()

def fixture(name):
    base=area/name;base.mkdir();config={}
    for key,raw in [('data',b''),('eligible',b'0')]:
        path=base/key;fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
        try:
            assert os.write(fd,raw)==len(raw)
            value=os.fstat(fd);config[key]=(str(path),(value.st_dev,value.st_ino,
                stat.S_IFMT(value.st_mode),value.st_uid,stat.S_IMODE(value.st_mode),value.st_nlink))
        finally:os.close(fd)
    helper=base/'observer.py';helper.write_text(observer+'\nCOST='+repr(config)+'\n')
    dependencies.append(helper)
    freeze([helper])
    module=runpy.run_path(str(helper))
    for sample in ['protected-0-frontend','protected-0-observer','terminal-normal']:
        module['cost_bind'](sample,*['0'*64]*4)
    return base,helper,module

for name,exit_status,success_path in [('success',0,True),('exit-error',1,False),('reader-nonzero',7,False),('missing-wait',1,False)]:
    base,helper,module=fixture(name)
    composed=module['cost_frontend'](front,'protected-0-frontend',helper)
    tree=ast.parse(observer);function=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='cost_frontend')
    assert composed.count('scope_cost_points[3]=$SECONDS')==composed.count('scope_cost_points[4]=$SECONDS')==1
    a=composed.index('scope_cost_original_cleanup()');b=composed.index('signal_exit()',a)
    cleanup=composed[a:b]
    cleanup=cleanup.replace('scope_cost_original_cleanup() { finish_reader; exec 8<&-; /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }',
        'scope_cost_original_cleanup() { /usr/bin/printf x >>"$calls"; }')
    script='set -uo pipefail\ncalls='+repr(str(base/'calls'))+'\nscope_cost_points=($SECONDS GAP GAP GAP GAP)\nscope_cost_done=false\nscope_cost_wait=false\n'+cleanup
    script+='trap cleanup EXIT\n'
    if name!='missing-wait':
        script+='scope_cost_points[1]=$SECONDS\n/bin/bash -c "exit '+str(exit_status)+'" &\nreader_pid=$!\nreader_status=0\n'
        script+='wait "$reader_pid" || reader_status=$?\nscope_cost_points[2]=$SECONDS\n[ "$reader_status" -ne 0 ] || scope_cost_wait=true\n'
    script+=('trap - EXIT\ncleanup\n' if success_path else 'exit '+str(exit_status)+'\n')
    path=base/'copy.sh';path.write_text(script)
    module['cost_bind']('protected-0-frontend',hashlib.sha256(front.encode()).hexdigest(),
        hashlib.sha256(b'fixed ordinary child').hexdigest(),hashlib.sha256(script.encode()).hexdigest(),
        hashlib.sha256(json.dumps(['/bin/bash',str(path)]).encode()).hexdigest())
    rc,out,err=run(['/bin/bash',str(path)])
    actual[name]=(base,helper,module,script)
    assert rc==exit_status and not out and not err,(name,rc,out,err)
    assert (base/'calls').read_bytes()==b'x'
    row=next(row for row in module['cost_rows']() if row['sample']=='protected-0-frontend')
    assert row['completed']==success_path,(name,row)
    assert (row['phases']=='GAP')==(name=='missing-wait')
    reports.append({'case':name,'actual_exit':rc,'cleanup_calls':1,'record':row})

base,helper,module,script=actual['success']
terminal_script=script.replace('protected-0-frontend','terminal-normal')
path=base/'terminal-normal.sh';path.write_text(terminal_script)
module['cost_bind']('terminal-normal',hashlib.sha256(front.encode()).hexdigest(),
    hashlib.sha256(b'fixed ordinary child').hexdigest(),hashlib.sha256(terminal_script.encode()).hexdigest(),
    hashlib.sha256(json.dumps(['/bin/bash',str(path)]).encode()).hexdigest())
assert run(['/bin/bash',str(path)])==(0,b'',b'')
package=base/'package';(package/'scope/v1').mkdir(parents=True);(package/'shadow/v1').mkdir(parents=True)
program=package/'scope/v1/read-shadow-evidence.py';program.write_text('value=True\n')
(package/'shadow/v1/_consumer.py').write_text('value=True\n')
log=base/'observer.jsonl';log.touch(mode=0o600)
module['cost_bind']('protected-0-observer',hashlib.sha256(program.read_bytes()).hexdigest(),
    hashlib.sha256((package/'shadow/v1/_consumer.py').read_bytes()).hexdigest(),
    hashlib.sha256(helper.read_bytes()).hexdigest(),hashlib.sha256(json.dumps([str(program)]).encode()).hexdigest())
freeze([helper,program,package/'shadow/v1/_consumer.py'])
module['observe'](program,str(log),'.github/workflows/ci.yml','reader',[str(program)],0)
assert next(row for row in module['cost_rows']() if row['sample']=='protected-0-observer')['completed']
module['cost_qualify']();assert (base/'eligible').read_bytes()==b'1'
outer=source[source.index('  if [ "$prior" -eq 142 ] && [ "$scope_fixture_signal" = ALRM ]; then'):]
outer=outer[:outer.index('  if [ "$cleanup_status" -eq 0 ]; then')]
outer=outer.replace('"$tmp/stale-observation/observer.py"',repr(str(helper)))
script='scope_fixture_signal=ALRM\ncleanup_status=0\nprior=142\n'+outer
script+='/usr/bin/printf DELETED\n'
path=base/'outer.sh';path.write_text(script)
rc,out,err=run(['/bin/bash',str(path)])
assert rc==0 and out==b'DELETED' and len(err)<=4096 and len(err.splitlines())==3
for eligible in [b'0',b'',b'x']:
    (base/'eligible').write_bytes(eligible)
    assert run(['/bin/bash',str(path)])[2]==b''
(base/'eligible').write_bytes(b'1')
for replacement in [('prior=142','prior=1'),('scope_fixture_signal=ALRM','scope_fixture_signal=TERM')]:
    path.write_text(script.replace(*replacement));assert run(['/bin/bash',str(path)])[2]==b''
program.write_text('raise ValueError("owned unwind")\n')
freeze([helper,program,package/'shadow/v1/_consumer.py'])
try:module['observe'](program,str(log),'.github/workflows/ci.yml','reader',[str(program)],0)
except ValueError as error:assert str(error)=='owned unwind'
else:raise AssertionError('observer swallowed original unwind')
assert not next(row for row in module['cost_rows']() if row['sample']=='protected-0-observer')['completed']
path.write_text(script);assert run(['/bin/bash',str(path)])[2]==b''
program.write_text('value=True\n')
freeze([helper,program,package/'shadow/v1/_consumer.py'])
module['observe'](program,str(log),'.github/workflows/ci.yml','reader',[str(program)],0)
# The original shell cleanup and a real ALRM prove ordering, not a fabricated status.
outer_cleanup=source[source.index('scope_owner_state=never'):source.index('platform=$(/usr/bin/uname')]
outer_cleanup=outer_cleanup.replace('"$tmp/stale-observation/observer.py"',repr(str(helper)))
outer_tmp=base/'outer-tmp';outer_tmp.mkdir()
body='tmp='+repr(str(outer_tmp))+'\n'+outer_cleanup+'\n/bin/sleep 2\n'
alarm_script=base/'alarm.sh';alarm_script.write_text(body)
rc,out,err=run(['/usr/bin/perl','-e','alarm 1;exec @ARGV;die $!','/bin/bash',str(alarm_script)])
assert rc in (-signal.SIGALRM,142) and b'fixture-cleanup: PASS prior-exit=142' in out
assert len(err.splitlines())==3 and len(err)<=4096 and not outer_tmp.exists(),(rc,out,err)
reports.append({'case':'real-ALRM-after-qualification','actual_exit':rc,'before_delete_records':3,'outer_removed_after_original_gates':True})
# The independent owner completes and authenticates before its negative confirmation view.
closed_rows=module['cost_rows']()
assert len(closed_rows)==3 and all(row['completed'] for row in closed_rows)
closed_bytes=(base/'data').read_bytes()
owner_work=base/'refused-owner';owner_work.mkdir();owner_base=owner_work/'base';owner_base.mkdir()
def actual_body(tag):
    lines=source.splitlines(keepends=True)
    starts=[i for i,line in enumerate(lines) if line.rstrip('\n').endswith("<<'"+tag+"'")]
    stops=[i for i,line in enumerate(lines) if line.rstrip('\n')==tag]
    assert len(starts)==len(stops)==1 and starts[0]<stops[0]
    return ''.join(lines[starts[0]+1:stops[0]])
owner_tree=ast.parse(actual_body('PY_GUARD_CONTROLS'))
owner=next(ast.get_source_segment(actual_body('PY_GUARD_CONTROLS'),node) for node in owner_tree.body
    if isinstance(node,ast.ClassDef) and node.name=='ScopeFixtureOwnerCancel')
assert owner.count('assert os.getuid()==0')==1
owner=owner.replace('assert os.getuid()==0','assert os.getuid()=='+str(os.getuid()))
owner_driver=owner_work/'runtime-guard-controls.py'
owner_driver.write_text('from pathlib import Path\nimport fcntl,hashlib,json,os,stat,sys\nbase=Path(sys.argv[1])\n'+owner+'\nowner=ScopeFixtureOwnerCancel()\nowner.finish()\n')
channel=actual_body('PY_FIXTURE_OWNER_CHANNEL')
channel=channel.replace('fixture.st_uid==0','fixture.st_uid=='+str(os.getuid())).replace('info.st_uid==0','info.st_uid=='+str(os.getuid()))
owner_channel=owner_work/'channel.py';owner_channel.write_text(channel)
dependencies.extend([owner_driver,owner_channel])
owner_shell=source[source.index('scope_owner_state=never\n'):source.index("scope_fixture_signal=''\n")]
assert owner_shell.count('/usr/bin/sudo -n "$genuine_python"')==1
owner_shell=owner_shell.replace('/usr/bin/sudo -n "$genuine_python"','"$genuine_python"')
variables={'tmp':owner_work,'genuine_base':owner_base,'guard_control':owner_driver,'genuine_python':sys.executable,
    'guard_source':owner_work/'unused-guard','operator_name':'owned','entry_source':owner_work/'unused-entry',
    'scope_owner_channel_helper':owner_channel}
genuine=owner_work/'genuine.receipt';forbidden=base/'forbidden-genuine-or-restore'
variables=''.join(key+'='+repr(str(value))+'\n' for key,value in variables.items())
refused=source[source.index("scope_fixture_signal=''\n"):source.index('\nplatform=',source.index("scope_fixture_signal=''\n"))]
refused=refused.replace('"$tmp/stale-observation/observer.py"',repr(str(helper)))
command='set -euo pipefail\n'+owner_shell+variables
command+='cleanup_genuine() { printf forbidden >'+repr(str(forbidden))+'; }\n'+refused
command+='scope_owner_serial=1\nscope_fixture_owner_launch false\ntest "$scope_owner_state" = completed\n'
command+='/bin/mv "$tmp/scope-owner-2.receipt" '+repr(str(genuine))+'\nscope_owner_state=active\nkill -s ALRM "$$"\n'
path=base/'refused-owner.sh';path.write_text(command)
rc,out,err=run(['/bin/bash',str(path)])
(base/'refused-owner.stdout.raw').write_bytes(out)
(base/'refused-owner.stderr.raw').write_bytes(err)
assert rc in (-signal.SIGALRM,142) and b'fixture-cleanup: FAIL prior-exit=142' in err,(rc,out,err)
assert b'FileNotFoundError' in err and b'scope-owner-2.receipt' in err and b'owner completion is unknown' in err
exported=[json.loads(line) for line in err.splitlines() if line.startswith(b'{')]
assert exported==closed_rows and (base/'data').read_bytes()==closed_bytes
receipt=json.loads(genuine.read_bytes())
assert receipt['quiescent'] and receipt['cases']==[] and receipt['cancelled'] is False
assert owner_work.is_dir() and owner_base.is_dir() and not forbidden.exists()
assert b'fixture-cleanup: PASS' not in out and b'genuine-cleanup:' not in out
reports.append({'case':'closed-cost-refused-other-owner','actual_exit':rc,'cost_records':len(exported),
    'genuine_owner_pid':receipt['driver_pid'],'genuine_owner_completed_before_negative_view':True,
    'actual_missing_receipt_refusal':True,'tmp_retained':True,'genuine_cleanup_restore_calls':0,
    'ordinary_transport_and_uid_adaptation_only':True})
completed_rows=module['cost_rows']()
module['cost_finish']('protected-0-observer',[1,None,3,4,5],False)
path.write_text(script);assert run(['/bin/bash',str(path)])[2]==b''
try:module['cost_put']({'sample':'terminal-normal','payload':'x'*1024})
except ValueError:pass
else:raise AssertionError('cost cap accepted')
reports.append({'case':'eligibility-and-caps','wrong_eligibility':3,'wrong_cleanup_context':2,'incomplete_record_suppresses':True})

# Original parser, real wait/EOF and original first snapshot, with ordinary data only.
a=front.index('commit=$(');b=front.index('terminal_status=0',a);admission=front[a:b]
a=front.index('/usr/bin/perl -e',b);b=front.index('\nPY_TERMINAL_SNAPSHOT',a)+len('\nPY_TERMINAL_SNAPSHOT');snapshot=front[a:b]
raw=b'{"owned":true}\n';digest=hashlib.sha256(raw).hexdigest()
for extra in [0,1]:
    base=area/('size-'+str(extra));base.mkdir();(base/'observation').mkdir()
    (base/'observation/terminal.json').write_bytes(raw);(base/'terminal.json').write_bytes(b'')
    (base/'reader-stderr').write_bytes(b'');os.mkfifo(base/'fifo',0o600)
    body='set -uo pipefail\nscratch='+repr(str(base))+'\nremaining_time() { /usr/bin/printf 3; }\nemit_error() { /usr/bin/printf "%s\\n" "$1" >&2; exit 1; }\n'
    frame='COMMIT '+str(len(raw)+extra)+' '+digest+'\n'
    body+='/usr/bin/printf '+repr(frame)+' >"$scratch/fifo" &\nreader_pid=$!\nexec 8<"$scratch/fifo"\n'+admission
    body+='terminal_status=0\npython_bin='+repr(sys.executable)+'\n'+snapshot+'\n/usr/bin/printf "actual-wait=%s snapshot=%s\\n" "$reader_status" "$terminal_status"\n'
    trace_prefix='''import atexit,json,pathlib,sys
actual_lines=[]
def actual_trace(frame,event,arg):
    if event=='exception' and type(arg[1]).__name__=='SnapshotRefusal' and str(arg[1])=='E_RELATION':actual_lines.append(frame.f_lineno)
    return actual_trace
atexit.register(lambda:pathlib.Path(TRACE_PATH).write_text(json.dumps(actual_lines)))
sys.settrace(actual_trace)
sys._getframe().f_trace=actual_trace
'''.replace('TRACE_PATH',repr(str(base/'actual-lines.json')))
    body=body.replace('import hashlib,os,stat,sys\n',trace_prefix+'import hashlib,os,stat,sys\n',1)
    expected_line=(trace_prefix+snapshot.split("<<'PY_TERMINAL_SNAPSHOT'",1)[1].split('\n',1)[1]).splitlines().index('    require_snapshot(received==maximum and before.st_size==maximum,"E_RELATION")')+1
    path=base/'admission.sh';path.write_text(body)
    rc,out,err=run(['/bin/bash',str(path)])
    assert rc==0 and not err,(rc,out,err)
    expected=0 if extra==0 else 1
    assert out==('actual-wait=0 snapshot='+str(expected)+'\n').encode(),out
    assert (base/'terminal-error').read_bytes()==(b'' if extra==0 else b'E_RELATION\n')
    assert (base/'terminal.json').read_bytes()==(raw if extra==0 else b'')
    lines=json.loads((base/'actual-lines.json').read_text())
    assert (expected_line in lines)==bool(extra),(expected_line,lines)
    reports.append({'actual_exception_lines':lines,'expected_size_line':expected_line,'case':'actual-N+'+str(extra),'actual_wait':0,'snapshot_status':expected,
        'frame_size':len(raw)+extra,'regular_size':len(raw),'source_size_predicate':front.splitlines().index('    require_snapshot(received==maximum and before.st_size==maximum,"E_RELATION")')+1})
opening='"$python_bin" -I -S -B - "$root" "$tmp" "$bin" "${good[@]}" <<'+"'PY_TERMINAL_TEST'"
lines=source.splitlines(keepends=True)
starts=[i for i,line in enumerate(lines) if line.rstrip('\n')==opening]
ends=[i for i,line in enumerate(lines) if line.rstrip('\n')=='PY_TERMINAL_TEST']
assert len(starts)==len(ends)==1 and starts[0]<ends[0]
terminal=''.join(lines[starts[0]+1:ends[0]])
tree=ast.parse(terminal)
functions=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in {'terminal_failure','run_case'}]
assert len(functions)==2
base,terminal_helper,terminal_module=fixture('terminal-first-failure')
for row in completed_rows:terminal_module['cost_put'](row)
reader=base/'reader.py';driver=base/'driver.sh';reader.write_text('pass\n');driver.touch()
namespace=dict(globals(),area=base,reader_path=reader,frontend=driver,reader_source='pass\n',
    argv=['/bin/bash',str(driver)],environment=dict(os.environ))
actual_asserts=[node for node in ast.walk(next(node for node in functions if node.name=='run_case')) if isinstance(node,ast.Assert)]
exit_asserts=[node for node in actual_asserts if node.msg is None and isinstance(node.test,ast.BoolOp)
    and any(isinstance(value,ast.Attribute) and isinstance(value.value,ast.Name)
        and value.value.id=='result' and value.attr=='returncode' for value in ast.walk(node.test))]
assert len(exit_asserts)==1
exit_assert=exit_asserts[0]
private_assert=next(node for node in actual_asserts if isinstance(node.msg,ast.BinOp) and isinstance(node.msg.right,ast.Constant) and 'retained snapshot' in str(node.msg.right.value))
stat_line=next(node.lineno for node in actual_asserts if isinstance(node.msg,ast.BinOp) and isinstance(node.msg.right,ast.Constant) and 'overflow' in str(node.msg.right.value))
import contextlib,copy,io,types
def terminal_run(*args,**kwargs):
    freeze(list(dict.fromkeys(dependencies+[reader,driver])))
    return subprocess.run(*args,**kwargs)
attributes={node.attr for node in ast.walk(next(node for node in functions if node.name=='run_case'))
    if isinstance(node,ast.Attribute) and isinstance(node.value,ast.Name) and node.value.id=='subprocess'}
assert attributes=={'PIPE','run'}
namespace['subprocess']=types.SimpleNamespace(run=terminal_run,PIPE=subprocess.PIPE)
assert set(vars(namespace['subprocess']))==attributes
success_driver="#!/bin/bash\n/usr/bin/printf '%s\\n' '{\"owned\":true}'\n"
failed_driver="#!/bin/bash\nif false; then\nwait \"$reader_pid\" || reader_status=$?\nfi\n/usr/bin/printf '%s\\n' E_RELATION >&2\nexit 1\n"
for fault in ('normal-success','ordinary-unexpected','serialize-error','output-error','facts-read-error','facts-construct-error','original-stat-error'):
    selected=copy.deepcopy(functions)
    if fault=='facts-construct-error':
        helper_node=next(node for node in selected if node.name=='terminal_failure')
        first=next(node for node in helper_node.body[0].body if isinstance(node,ast.Assign) and isinstance(node.targets[0],ast.Name) and node.targets[0].id=='facts')
        index=helper_node.body[0].body.index(first)
        helper_node.body[0].body[index]=ast.copy_location(ast.Raise(exc=ast.Call(func=ast.Name(id='OSError',ctx=ast.Load()),args=[ast.Constant('fixed diagnostic facts fault')],keywords=[]),cause=None),first)
    selected_tree=ast.fix_missing_locations(ast.Module(body=selected,type_ignores=[]))
    selected_path=base/(fault+'-extracted.py');selected_path.write_text(ast.unparse(selected_tree)+'\n')
    selected_ast=base/(fault+'-extracted.ast');selected_ast.write_text(ast.dump(selected_tree,include_attributes=True))
    freeze([selected_path,selected_ast])
    exec(compile(selected_tree,'exact-terminal-failure-boundary','exec'),namespace)
    fd=terminal_module['cost_open']('eligible',os.O_WRONLY)
    try:assert os.write(fd,b'0')==1
    finally:os.close(fd)
    namespace['frontend_source']=success_driver if fault=='normal-success' else ('#!/bin/bash\nexit 2\n' if fault=='ordinary-unexpected' else failed_driver)
    output=io.BytesIO();sink=io.TextIOWrapper(output,encoding='utf-8',write_through=True)
    namespace['json']=json
    if fault=='serialize-error':namespace['json']=types.SimpleNamespace(dumps=lambda *a,**k:(_ for _ in ()).throw(ValueError('fixed JSON fault')))
    if fault=='output-error':
        class RefusingBuffer:
            def write(self,raw):raise OSError('fixed output fault')
        sink=types.SimpleNamespace(buffer=RefusingBuffer())
    original_read,original_stat=pathlib.Path.read_bytes,pathlib.Path.stat
    def reading(path):
        if path.name=='size-mismatch.same-call':raise OSError('fixed diagnostic read fault')
        return original_read(path)
    def stating(path,*args,**kwargs):
        if path.name=='size-mismatch.terminal-error':raise OSError('fixed original stat fault')
        return original_stat(path,*args,**kwargs)
    if fault=='facts-read-error':pathlib.Path.read_bytes=reading
    if fault=='original-stat-error':pathlib.Path.stat=stating
    label='owned-success' if fault=='normal-success' else ('owned-unexpected' if fault=='ordinary-unexpected' else 'size-mismatch')
    expected=None if label!='size-mismatch' else 'E_RELATION'
    reached_qualification=False;observed=None
    try:
        with contextlib.redirect_stderr(sink):
            namespace['run_case'](label,expected=expected)
            terminal_module['cost_qualify']()
            reached_qualification=True
    except BaseException as error:
        observed=error
        if fault=='original-stat-error':
            assert type(error) is OSError and str(error)=='fixed original stat fault'
            expected_line=stat_line
        else:
            assert type(error) is AssertionError
            assert str(error)==('' if fault=='ordinary-unexpected' else 'size-mismatch did not reject actual retained snapshot digest'),(fault,str(error))
            expected_line=exit_assert.lineno if fault=='ordinary-unexpected' else private_assert.lineno
        frames=[];trace=error.__traceback__
        while trace:
            if trace.tb_frame.f_code.co_name=='run_case':frames.append(trace.tb_lineno)
            trace=trace.tb_next
        assert frames==[expected_line],(fault,frames,expected_line)
    finally:pathlib.Path.read_bytes,pathlib.Path.stat=original_read,original_stat
    if fault=='normal-success':
        assert observed is None and reached_qualification and output.getvalue()==b''
    else:assert observed is not None and not reached_qualification
    assert (base/'eligible').read_bytes()==(b'1' if fault=='normal-success' else b'0')
    if fault=='ordinary-unexpected':
        emitted=output.getvalue();row=json.loads(emitted)
        assert len(emitted)<=16384 and row['returncode']==2 and row['same_call']['normal_wait']=='GAP'
        assert row['reader_sha256']==hashlib.sha256(b'pass\n').hexdigest()
        assert row['frontend_sha256']==hashlib.sha256(b'#!/bin/bash\nexit 2\n').hexdigest()
    reports.append({'case':fault,'original_exit_exact':observed is not None,'qualification_reached':reached_qualification,
        'original_assert_line':None if observed is None else expected_line})
print(json.dumps({'same_call_owned_controls':reports},sort_keys=True),flush=True)
PY_SAME_CALL_OWNED_CONTROLS
run_evaluator() {
  if [ "$#" -eq 7 ]; then
    PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$@" "$tmp/legacy-bundles" "$tmp/legacy-source.git"
  else
    PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$@"
  fi
}
expect_validator_error() {
  local label=$1 expected=$2 input=$3 status=0 out
  out=$(run_validator "$input" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted"
  [ "$out" = "$expected" ] || fail "$label expected $expected got $out"
}
prepare_stale_binding() {
  local index=$1 boundary=$2 frontend=$3
  shift 3
  if [ "$#" -eq 7 ]; then set -- "$@" "$tmp/legacy-bundles" "$tmp/legacy-source.git"; fi
  python3 -I -S -B - "$root" "$tmp/stale-observation" "$index" "$boundary" "$frontend" "$@" <<'PY_PROTECTED_BINDING'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

root, area = map(Path, sys.argv[1:3])
index, glob, frontend = int(sys.argv[3]), sys.argv[4], Path(sys.argv[5])
arguments = sys.argv[6:]
documents = arguments[:7]
assert 0 <= index <= 8 and len(arguments) == 9
assert index != 8 or glob == 'evaluation-reasons'
sources = ('scope/v1/evaluate-scope.sh', 'scope/v1/read-shadow-evidence.py',
           'shadow/v1/_consumer.py', 'scripts/test/scope-qualification.test.sh')
identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
    value.st_gid, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def measured(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1
        chunks, total = [], 0
        while True:
            raw = os.read(descriptor, min(65536, maximum + 1 - total))
            if not raw:
                break
            chunks.append(raw)
            total += len(raw)
            assert total <= maximum
        assert identity(os.fstat(descriptor)) == identity(before)
        assert identity(os.stat(path, follow_symlinks=False)) == identity(before)
        return {'path': str(path), 'bytes': total, 'sha256': hashlib.sha256(b''.join(chunks)).hexdigest()}
    finally:
        os.close(descriptor)


if index == 8:
    descriptor = os.open(area / '8.lines.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.getuid()
        raw = os.read(descriptor, 12001)
        assert len(raw) <= 12000 and identity(os.fstat(descriptor)) == identity(before)
        assert identity(os.stat(area / '8.lines.json', follow_symlinks=False)) == identity(before)
        pinned = json.loads(raw)['slot_identity']
    finally:
        os.close(descriptor)
    for name, suffix, maximum in (('log', '.jsonl', 16384), ('binding', '.binding.json', 3072)):
        path = area / ('8' + suffix)
        descriptor = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(descriptor)
            assert list(identity(before)[:6]) == pinned[name]
            assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
            assert stat.S_IMODE(before.st_mode) == 0o600 and before.st_size <= maximum
            assert identity(os.stat(path, follow_symlinks=False)) == identity(before)
            os.ftruncate(descriptor, 0)
            after = os.fstat(descriptor)
            assert identity(after)[:6] == identity(before)[:6] and after.st_size == 0
            assert identity(os.stat(path, follow_symlinks=False)) == identity(after)
        finally:
            os.close(descriptor)


command = [str(frontend), 'evaluate', *arguments]
try:
    binding = {'status': 'CASE_BINDING', 'index': index, 'glob': glob,
        'source_event_sha': os.environ.get('GITHUB_SHA', 'GAP'),
        'command_sha256': hashlib.sha256(json.dumps(command,
            separators=(',', ':'), ensure_ascii=True).encode()).hexdigest(),
        'inputs': [measured(Path(path), 1048576) for path in documents],
        'source': [measured(root / path, 16 * 1024 * 1024) for path in sources],
        'private_frontend': measured(frontend, 16 * 1024 * 1024)}
except (OSError, AssertionError) as error:
    binding = {'status': 'OBSERVER_GAP', 'index': index, 'glob': glob,
               'boundary': 'case binding before evaluator', 'exception': type(error).__name__}
raw = json.dumps(binding, separators=(',', ':'), ensure_ascii=True).encode() + b'\n'
if len(raw) > 3072:
    raw = (json.dumps({'status':'OBSERVER_GAP','index':index,'glob':glob,'reason':'case binding cap3072'})+'\n').encode()
path = area / (str(index) + '.binding.json')
fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    info = os.fstat(fd)
    assert stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
    if index == 8:
        assert list(identity(info)[:6]) == pinned['binding'] and stat.S_IMODE(info.st_mode) == 0o600
        assert identity(os.stat(path, follow_symlinks=False)) == identity(info)
    os.ftruncate(fd, 0)
    assert os.write(fd, raw) == len(raw)
    if index == 8:
        after = os.fstat(fd)
        assert identity(after)[:6] == identity(info)[:6] and after.st_size == len(raw)
        assert identity(os.stat(path, follow_symlinks=False)) == identity(after)
finally:
    os.close(fd)
if index==0 and binding['status']=='CASE_BINDING':
    import runpy
    module=runpy.run_path(str(area/'observer.py'))
    for sample in ('protected-0-frontend','protected-0-observer'):
        module['cost_bind'](sample,binding['source'][0]['sha256'],binding['source'][1]['sha256'],
            binding['private_frontend']['sha256'],binding['command_sha256'])
if index == 8 and binding['status'] != 'CASE_BINDING':
    raise SystemExit(1)
PY_PROTECTED_BINDING
}
evaluation_reasons() {
  local out evaluator=$evaluator diagnostic_index=8 diagnostic_ready=false
  if [ "$1" = "$tmp/protected.json" ]; then
    diagnostic_index=$protected_index
    diagnostic_ready=true
  elif prepare_stale_binding 8 evaluation-reasons "$tmp/stale-observation/8.sh" "$@" 2>/dev/null; then
    evaluator="$tmp/stale-observation/8.sh"
    diagnostic_ready=true
  fi
  out=$(run_evaluator "$@" 2>&1) ||
    { if [ "$diagnostic_ready" = true ]; then
        python3 -I -S -B - "$tmp/stale-observation/$diagnostic_index.jsonl" "$tmp/stale-observation/$diagnostic_index.binding.json" "$tmp/stale-observation/$diagnostic_index.lines.json" <<'PY_STALE_EXPORT' >&2 2>/dev/null || :
import json,os,pathlib,stat,sys
try:
    fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as source:
        info=os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:raise ValueError('trace type')
        raw=source.read(16385)
    if not raw or len(raw)>16384 or not raw.endswith(b'\n'):raise ValueError('missing/incomplete trace')
    records=[json.loads(line) for line in raw.splitlines()]
    descriptor=os.open(sys.argv[2],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(descriptor,'rb') as source:binding=source.read(3073)
    if len(binding)>3072:raise ValueError('binding cap')
    json.loads(binding)
    descriptor=os.open(sys.argv[3],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(descriptor,'rb') as source:mapping_raw=source.read(12001)
    if len(mapping_raw)>12000:raise ValueError('line map cap')
    mapping=json.loads(mapping_raw)
    for record in records:
        if record.get('status')=='FRONTEND_ERROR':
            line=mapping['line_map'].get(str(record['copy_caller_line']))
            record['original_caller_line']=line if line is not None else 'GAP'
            record['original_line_sha256']=mapping['original_line_sha256'].get(str(line),'GAP')
            record['copy_sha256']=mapping['copy_sha256']
    emitted=binding+b''.join(json.dumps(row,separators=(',',':')).encode()+b'\n' for row in records)
    if len(emitted)>16384:raise ValueError('combined export cap')
    sys.stdout.buffer.write(emitted)
except BaseException:
    print('{"status":"OBSERVER_GAP","reason":"missing/incomplete private transport"}')
PY_STALE_EXPORT
      else
        /usr/bin/printf '%s\n' '{"status":"OBSERVER_GAP","reason":"current private preparation failed"}' >&2
      fi
      fail "evaluator refused a well-formed call ($1): $(/usr/bin/printf '%s' "$out" | /usr/bin/tail -c 300)"
    }
  /usr/bin/printf '%s' "$out" | "$jq_bin" -c '.body.reason_ids'
}
expect_reasons() {
  local label=$1 expected=$2
  expected=$("$jq_bin" -c 'map(select(. != "scope.proposable")) + ["scope.sandbox-receipt-missing"] | sort | unique' <<<"$expected")
  shift 2
  local actual
  actual=$(evaluation_reasons "$@")
  [ "$actual" = "$expected" ] || fail "$label expected $expected got $actual"
}
expect_evaluator_error() {
  local label=$1 expected=$2 status=0 out
  shift 2
  out=$(run_evaluator "$@" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted"
  [ "$out" = "$expected" ] || fail "$label expected $expected got $out"
}

"$python_bin" -I -S -B - "$root" <<'PY_STALE_CONTROLS'
from pathlib import Path
import ast,hashlib,json,os,shlex,subprocess,sys,tempfile
root=Path(sys.argv[1])
source=(root/'scripts/test/scope-qualification.test.sh').read_text()
def heredoc(tag):
    start=source.index("<<'"+tag+"'");start=source.index('\n',start)+1
    return source[start:source.index('\n'+tag+'\n',start)]+'\n'
prepare=heredoc('PY_STALE_PREPARE')
functions=source[source.index('run_evaluator() {'):source.index('\nexpect_reasons() {')]
functions=functions[:functions.index('\nexpect_validator_error() {')]+functions[functions.index('\nprepare_stale_binding() {'):]
expected={'observer_source':'7a7931df84892f2b30cdf412b01757a085e5752211f3e019aed6ae7c501d1e02',
 'frontend_capture':'a21a722a59923fa6ad18f6f6dd26385d46dcd5a3733083f9d7625777d73c4af8',
 'emit_capture':'153556128c04167c2a73d6c91c86b37bd3e1d34eb35fdeea44e865803301afb4',
 'exit_capture':'95bc34214161aa79167d7f33e8cf4980d70177f7771fa5bf30672e8f0e1739ac'}
bodies={n.targets[0].id:n.value.value for n in ast.parse(prepare).body if isinstance(n,ast.Assign) and isinstance(n.targets[0],ast.Name) and isinstance(n.value,ast.Constant) and isinstance(n.value.value,str)}
assert all(hashlib.sha256(bodies[n].encode()).hexdigest()==digest for n,digest in expected.items())
reports=[]
with tempfile.TemporaryDirectory(prefix='ystack-boundary-owned-') as temporary:
    tmp=Path(temporary);area=tmp/'stale-observation';area.mkdir(mode=0o700)
    prior=sys.argv
    try:
        sys.argv=['owned-prepare',str(root),str(area)]
        exec(compile(prepare,'exact-private-copy-preparation','exec'),{})
    finally:sys.argv=prior
    for suffix in ('.jsonl','.binding.json','.sh','.py','.lines.json'):
        assert len(list(area.glob('*'+suffix)))==(10 if suffix=='.py' else 9)
    assert len(list(area.iterdir()))==48
    mapping=json.loads((area/'8.lines.json').read_bytes())
    front=(root/'scope/v1/evaluate-scope.sh').read_text().splitlines()
    copied=(area/'8.sh').read_text().splitlines()
    for c,o in mapping['line_map'].items():
        assert copied[int(c)-1]==front[o-1]
        assert mapping['original_line_sha256'][str(o)]==hashlib.sha256(front[o-1].encode()).hexdigest()
    fixed_line=next(iter(mapping['line_map']))
    docs=[]
    for index in range(7):
        path=tmp/('input'+str(index)+'.json');path.write_text('{}\n');docs.append(path)
    (tmp/'bin').mkdir();trace=tmp/'argv.trace';trace.touch(mode=0o600)
    pytrace=tmp/'python.trace';pytrace.touch(mode=0o600)
    interpreter=shlex.quote(sys.executable)
    (tmp/'bin/python3').write_text('#!/bin/bash\nprintf "%s\\n" "$#" >> '+shlex.quote(str(pytrace))+'\nexec '+interpreter+' "$@"\n')
    (tmp/'bin/python3').chmod(0o500)
    stub='#!/bin/bash\n/usr/bin/printf "%s\\0" "$0" "$@" >> '+shlex.quote(str(trace))+'\n'
    failure=stub+'/usr/bin/printf \'{"status":"FRONTEND_ERROR","case_index":8,"copy_caller_line":'+fixed_line+'}\\n\' >> '+shlex.quote(str(area/'8.jsonl'))+'\n/usr/bin/printf "E_STALE\\n" >&2\nexit 1\n'
    fallback=tmp/'fallback.sh';fallback.write_text(stub+'printf "E_STALE\\n" >&2\nexit 1\n');fallback.chmod(0o500)
    def frontend(text):
        path=area/'8.sh';path.chmod(0o700);path.write_text(text);path.chmod(0o500)
    prefix='set -euo pipefail\n'+functions+'\nroot='+shlex.quote(str(root))+'\ntmp='+shlex.quote(str(tmp))+'\nbin='+shlex.quote(str(tmp/'bin'))+'\nevaluator='+shlex.quote(str(fallback))+'\nPATH="$bin:/usr/bin:/bin"\nowned_jq(){ /bin/cat; }\njq_bin=owned_jq\nfail(){ printf "FAIL: %s\\n" "$1" >&2; exit 1; }\n'
    argv=' '.join(shlex.quote(str(path)) for path in docs)
    frontend(stub+'printf \'["owned"]\'\n')
    call=prefix+'a=$(evaluation_reasons '+argv+'); test "$a" = \'["owned"]\'\nprintf \'{"current":2}\\n\' > '+shlex.quote(str(docs[0]))+'\nb=$(evaluation_reasons '+argv+'); test "$b" = \'["owned"]\'\ntest "$evaluator" = '+shlex.quote(str(fallback))+'\n'
    result=subprocess.run(['/bin/bash','-c',call],capture_output=True,timeout=10)
    assert result.returncode==0 and not result.stdout and not result.stderr,(result.returncode,result.stderr)
    current=json.loads((area/'8.binding.json').read_bytes())
    command=[str(area/'8.sh'),'evaluate',*[str(path)for path in docs],str(tmp/'legacy-bundles'),str(tmp/'legacy-source.git')]
    assert current['index']==8 and current['glob']=='evaluation-reasons'
    assert current['command_sha256']==hashlib.sha256(json.dumps(command,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
    assert current['inputs'][0]['sha256']==hashlib.sha256(docs[0].read_bytes()).hexdigest()
    assert [row['sha256']for row in current['source']]==[hashlib.sha256((root/path).read_bytes()).hexdigest()for path in ('scope/v1/evaluate-scope.sh','scope/v1/read-shadow-evidence.py','shadow/v1/_consumer.py','scripts/test/scope-qualification.test.sh')]
    assert current['private_frontend']['sha256']==hashlib.sha256((area/'8.sh').read_bytes()).hexdigest()
    assert trace.read_bytes().split(b'\0')[:-1]==[os.fsencode(arg)for arg in command]*2
    assert not (area/'8.jsonl').read_bytes()
    reports.append({'case':'serial-reuse','actual_calls':2,'exact_nine_data_argv':True,'fresh_seven_input_source_frontend_hashes':True,'global_frontend_unchanged':True,'success_not_exported':True})
    for fault in ('failure-transport','reset-failure','binding-failure'):
        frontend(failure)
        (area/'8.jsonl').write_text('{"status":"STALE_PREVIOUS_RECORD"}\n')
        (area/'8.binding.json').write_text('{"status":"STALE_PREVIOUS_BINDING"}\n')
        marker=None
        if fault=='reset-failure':
            marker=tmp/'old.log';marker.write_text('STALE_PREVIOUS_RECORD\n')
            (area/'8.jsonl').unlink();(area/'8.jsonl').symlink_to(marker)
        if fault=='binding-failure':docs[0].rename(tmp/'missing-input.json')
        before=pytrace.read_text().splitlines()
        result=subprocess.run(['/bin/bash','-c',prefix+'evaluation_reasons '+argv],capture_output=True,timeout=10)
        assert result.returncode==1 and not result.stdout and b'E_STALE' in result.stderr
        assert b'STALE_PREVIOUS_RECORD' not in result.stderr and b'STALE_PREVIOUS_BINDING' not in result.stderr
        rows=result.stderr.splitlines();added=pytrace.read_text().splitlines()[len(before):]
        if fault=='failure-transport':
            binding,record=map(json.loads,rows[:2])
            assert binding['status']=='CASE_BINDING' and record['status']=='FRONTEND_ERROR'
            assert record['original_caller_line']==mapping['line_map'][fixed_line]
            assert record['original_line_sha256']==mapping['original_line_sha256'][str(record['original_caller_line'])]
            assert record['copy_sha256']==mapping['copy_sha256'] and sum(len(row)+1 for row in rows[:2])<=16384
            assert len(added)==2
        else:
            assert json.loads(rows[0])['status']=='OBSERVER_GAP' and len(added)==1
        if marker is not None:
            assert marker.read_text()=='STALE_PREVIOUS_RECORD\n'
            (area/'8.jsonl').unlink();(area/'8.jsonl').touch(mode=0o600)
            pinned=json.loads((area/'8.lines.json').read_bytes())
            value=os.lstat(area/'8.jsonl');pinned['slot_identity']['log']=[value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink]
            (area/'8.lines.json').write_text(json.dumps(pinned))
        if fault=='binding-failure':(tmp/'missing-input.json').rename(docs[0])
        assert len(list(area.iterdir()))==48
        reports.append({'case':fault,'original_nonzero_and_stderr_preserved':True,'old_evidence_not_read_or_exported':True,'export_invocations':len(added)-1})
print(json.dumps({'cases':reports,'four_body_sha256':expected,'scope':'Exact preparation/binding/evaluation_reasons/run_evaluator bytes; fixed ordinary frontend/jq output adapters only. No actual evaluator, reader, jq, supplied P, genuine fixture or historical cause proof.'},sort_keys=True))
PY_STALE_CONTROLS

(set -C; : >"$tmp/observer-owner-controls.pending")
scope_controls_state=started
"$python_bin" -I -S -B - "$root/scripts/test/scope-qualification.test.sh" "$root" <<'PY_OBSERVER_OWNER_CONTROLS'
from pathlib import Path
import ast,hashlib,importlib.util,json,os,pwd,re,signal,stat,subprocess,sys,tempfile,time,types,shutil,traceback
source=Path(sys.argv[1]).read_text()
def heredoc(tag):
    mark="<<'"+tag+"'";start=source.index('\n',source.index(mark))+1
    return source[start:source.index('\n'+tag+'\n',start)]+'\n'
def literal(code,name):
    return next(n.value.value for n in ast.parse(code).body if isinstance(n,ast.Assign)
                and isinstance(n.targets[0],ast.Name) and n.targets[0].id==name)
prepare=heredoc('PY_STALE_PREPARE');observer=literal(prepare,'observer_source')
guard=heredoc('PY_GUARD_CONTROLS');wrapper=literal(guard,'wrapper_prefix');channel=heredoc('PY_FIXTURE_OWNER_CHANNEL')
timeless=observer[observer.index("FIELDS="):]
timeless=timeless.replace("    cost_selected=index==0 and case=='.github/workflows/ci.yml'\n",'')
timeless=timeless.replace('    cost_points=[started,None,None,None,None]\n    cost_normal=False\n','')
timeless=timeless.replace('        cost_points[1]=time.monotonic() if cost_selected else None\n','')
a=timeless.index('        cost_points[2]=time.monotonic() if cost_selected else None\n');b=timeless.index('    finally:\n        try:sys.settrace(previous)',a)
timeless=timeless[:a]+"        runpy.run_path(str(original),run_name='__main__')\n"+timeless[b:]
a=timeless.index('        cost_points[4]=time.monotonic() if cost_selected else None\n');b=timeless.index('        try:\n            if descriptor is not None:',a)
timeless=timeless[:a]+timeless[b:]
timeless='import hashlib,json,os,runpy,stat,sys,time,types\n'+timeless
old=timeless.replace('sys,time,types','sys,time',1)
a=old.index('    source_lines={}\n');b=old.index('    try:\n        before=os.lstat(log)',a);old=old[:a]+old[b:]
a=old.index('    def dispatch(frame,event,arg):\n');b=old.index('    previous=sys.gettrace()\n',a);old=old[:a]+old[b:]
old=old.replace("return (frame.f_code.co_filename in source_codes and\n                frame.f_code in source_codes[frame.f_code.co_filename])","return frame.f_code.co_filename in sources").replace('sys.settrace(dispatch)','sys.settrace(trace)')
assert hashlib.sha256(old.encode()).hexdigest()=='0c2b1c8c8cb9c662c55e17e134f408693ab4ead8f27357ad6cb2b7bcc0b820eb'
root=Path(sys.argv[2]).resolve()
consumer=(root/'shadow/v1/_consumer.py').read_bytes()
assert hashlib.sha256(consumer).hexdigest()=='34d314505860f7569f53f41491c29979ab30aa08f83cfc151444f8cb6a235f68'
old_wrapper=wrapper.replace('import dis, json, os, signal, sys, time, types','import json, os, signal, sys, time',1)
a=old_wrapper.index('code_path=Path(sys.argv.pop(1))\n');b=old_wrapper.index('foreground = {}',a)
old_wrapper=old_wrapper[:a]+"code = Path(sys.argv.pop(1)).read_bytes()\n"+old_wrapper[b:]
a=old_wrapper.index('compiled_code = compile(');b=old_wrapper.index("print('GUARD_ACTUAL_PRINCIPAL",a);old_wrapper=old_wrapper[:a]+old_wrapper[b:]
a=old_wrapper.index("        if short_proof and event=='line'");b=old_wrapper.index("        if event == 'call':",a);old_wrapper=old_wrapper[:a]+old_wrapper[b:]
old_wrapper=old_wrapper.replace("            foreground.pop('ready',None)\n",'')
old_wrapper=old_wrapper.replace('if bound(caller) and caller.f_lineno in identity_lines:',"line = code.decode().splitlines()[caller.f_lineno - 1]\n            if line.strip() == 'assert uptime() < deadline and identity(os.lstat(name)) == before':")
old_wrapper=old_wrapper.replace('        if bound(frame) and frame.f_lineno in identity_lines:',"        line = code.decode().splitlines()[frame.f_lineno - 1]\n        if line.strip() == 'assert uptime() < deadline and identity(os.lstat(name)) == before':")
a=old_wrapper.index('def dispatch(frame, event, arg):\n');b=old_wrapper.index('def cancel(',a);old_wrapper=old_wrapper[:a]+old_wrapper[b:]
old_wrapper=old_wrapper.replace('sys.settrace(dispatch)','sys.settrace(observe)').replace("exec(compiled_code, {'__name__': '__main__'})","exec(compile(code, original_name, 'exec'), {'__name__': '__main__'})")
assert hashlib.sha256(old_wrapper.encode()).hexdigest()=='0b4348aefe34c0036a2bfa16f9290e4aeefaef169444f3ec987f1474e085fc52'
def proof_materialization_controls(guard,area):
    tree=ast.parse(guard)
    block=next(n for n in ast.walk(tree) if isinstance(n,ast.If) and any(isinstance(x,ast.Assign) and isinstance(x.targets[0],ast.Name) and x.targets[0].id=='proof_program' for x in n.body))
    nodes=block.body[:5]
    assert isinstance(nodes[2],ast.Expr) and nodes[2].value.func.attr=='chmod' and nodes[2].value.args[0].value==0o444
    assert isinstance(nodes[4],ast.Expr) and nodes[4].value.func.id=='run_control'
    actual='\n'.join(ast.get_source_segment(guard,n) for n in nodes)+'\n'
    assert ast.dump(ast.parse(actual),include_attributes=False)==ast.dump(ast.Module(body=nodes,type_ignores=[]),include_attributes=False)
    old='\n'.join(ast.get_source_segment(guard,n) for n in nodes[:2])+'\n'
    expected=nodes[1].value.args[0].value.encode()
    records=[]
    for mask,fault in ((0o077,'normal'),(0o022,'normal'),(0o077,'old'),(0o077,'write'),(0o022,'write'),(0o077,'mode'),(0o022,'mode')):
        fixture=area/('materialize-'+str(mask)+'-'+fault);fixture.mkdir();fixture.chmod(0o755)
        script="from pathlib import Path\nimport hashlib,json,os,stat,sys\nfixture=Path(sys.argv[1])\n"+'mask='+repr(mask)+'\nfault='+repr(fault)+'\nexpected='+repr(expected)+'\nactual='+repr(actual)+'\nold='+repr(old)+'\n'+r"""
assert os.umask(mask)==mask
launches=[]
def run_control(label,expected_error):
    assert label=='fixed-short-owner-cancel' and expected_error==b'E_RUNTIME'
    assert proof_program.read_bytes()==expected and stat.S_IMODE(proof_program.stat().st_mode)==0o444
    launches.append(label)
def failed_write(self,*args,**kwargs):
    assert self==fixture/'owner-cancel-proof.py'
    raise OSError('fixed materialization write failure')
def failed_mode(self,mode):
    assert self==fixture/'owner-cancel-proof.py' and mode==0o444
    raise OSError('fixed materialization mode failure')
if fault=='write':Path.write_text=failed_write
if fault=='mode':Path.chmod=failed_mode
try:exec(compile(old if fault=='old' else actual,'actual-root-proof-materialization','exec'))
except OSError as error:
    assert fault in ('write','mode') and str(error)=='fixed materialization '+fault+' failure' and not launches
    record={'fault':fault,'mask':mask,'error':type(error).__name__,'message':str(error),'launches':len(launches)}
else:
    assert fault in ('normal','old')
    path=fixture/'owner-cancel-proof.py';value=path.lstat();raw=path.read_bytes()
    assert raw==expected and stat.S_ISREG(value.st_mode) and value.st_uid==os.getuid() and value.st_nlink==1
    assert stat.S_IMODE(value.st_mode)==(0o600 if fault=='old' else 0o444)
    assert len(launches)==(0 if fault=='old' else 1) and stat.S_IMODE(fixture.stat().st_mode)==0o755
    record={'fault':fault,'mask':mask,'mode':stat.S_IMODE(value.st_mode),'uid':value.st_uid,'nlink':value.st_nlink,'sha256':hashlib.sha256(raw).hexdigest(),'launches':len(launches),'same_uid_read_only':True}
assert os.umask(mask)==mask
print(json.dumps(record,sort_keys=True))
"""
        print(json.dumps({'actual_materialization_script':script,'sha256':hashlib.sha256(script.encode()).hexdigest(),'mask':mask,'fault':fault}),flush=True)
        result=subprocess.run([sys.executable,'-I','-S','-B','-',str(fixture)],input=script.encode(),capture_output=True,timeout=10,umask=mask)
        assert result.returncode==0,(fault,result.stdout,result.stderr)
        record=json.loads(result.stdout);records.append(record)
    return records

reports=[]
temporary=tempfile.mkdtemp(prefix='scope-observer-owner-')
print(json.dumps({'ordinary_tree':temporary,'on_failure':'RETAIN'}),flush=True)
try:
    area=Path(temporary).resolve();package=area/'package';(package/'shadow/v1').mkdir(parents=True);(package/'scope/v1').mkdir(parents=True)
    (package/'shadow/v1/_consumer.py').write_bytes(consumer)
    helper=area/'outside.py';helper.write_text('allowed=True\ndef rule(fd,value,ancestor):\n return allowed\n')
    reader=package/'scope/v1/reader.py'
    reader.write_text('''import importlib.util,os,sys
from pathlib import Path
p=Path(__file__).parents[2]/'shadow/v1/_consumer.py'
s=importlib.util.spec_from_file_location('observer_owned_consumer',p)
c=importlib.util.module_from_spec(s);sys.modules[s.name]=c;s.loader.exec_module(c)
s=importlib.util.spec_from_file_location('observer_outside',sys.argv[2])
h=importlib.util.module_from_spec(s);s.loader.exec_module(h)
held=c._open_held(sys.argv[1],False,h.rule,'E_STALE')
try:
 if sys.argv[3]=='errno':os.close(held.fd)
 elif sys.argv[3]=='bool':h.allowed=False
 elif sys.argv[3]=='gap':pass
 else:
  with open(sys.argv[1],'ab') as f:f.write(b'changed')
 held.recheck('E_STALE')
finally:
 if sys.argv[3]=='errno':held.components.pop()
 held.close()
''')
    def observe_case(code,kind):
        target=area/'value';target.write_bytes(b'actual owned file');log=area/'log';log.write_bytes(b'')
        ns={};exec(compile(code,'actual-private-observer','exec'),ns)
        callbacks={};wrappers={};install=sys.settrace
        def wrap(fn):
            if fn is None:return None
            if fn not in wrappers:
                def call(frame,event,arg):
                    callbacks[event]=callbacks.get(event,0)+1
                    return wrap(fn(frame,event,arg))
                wrappers[fn]=call
            return wrappers[fn]
        def counted(fn):install(wrap(fn))
        previous=sys.argv;started=time.monotonic();sys.settrace=counted
        try:
            try:ns['observe'](reader,log,'owned', 'owned-phase',[str(reader),str(target),str(helper),kind],8)
            except Exception as error:assert kind!='gap' and str(error)=='E_STALE'
            else:assert kind=='gap'
        finally:
            install(None);sys.settrace=install;sys.argv=previous
        result=json.loads(log.read_bytes());assert result['status']==('OBSERVER_GAP' if kind=='gap' else 'FIRST_STALE')
        if kind=='errno':
            actual=[(frame,item) for frame in result['frames'] for item in frame['actual_returns'] if item.get('errno')==9]
            assert len(actual)==1 and actual[0][1]['function']=='_metadata' and actual[0][1]['exception']=='OSError'
            frame,item=actual[0]
            assert frame['function']=='recheck' and frame['component']['ancestor'] is False
            lines=(package/'shadow/v1/_consumer.py').read_text().splitlines()
            assert lines[item['caller_line']-1].strip()=='current = _metadata(component.fd)'
            assert lines[result['guard']['line']-1].strip()=='raise Refusal(code) from None'
        return result,callbacks,time.monotonic()-started
    for kind in ('identity','errno','bool','gap'):
        first,old_counts,old_cost=observe_case(old,kind);second,new_counts,new_cost=observe_case(observer,kind)
        def shape(value):
            return {'guard':value['guard'],'exception':value['exception'],'predicate_input':value['predicate_input'],
                    'frames':[(f['source'],f['function'],f['line'],
                        [(v['function'],v['caller_line'],v.get('actual_bool_return'),v.get('errno'),v.get('exception'),
                          sorted(v.get('stat',{}))) for v in f['actual_returns']],sorted(f)) for f in value['frames']]}
        assert (first['status'],first.get('reason'))==(second['status'],second.get('reason'))
        if kind!='gap':assert shape(first)==shape(second),(first,second)
        assert sum(new_counts.values())<sum(old_counts.values())
        assert any('actual_bool_return' in item for frame in second.get('frames',[]) for item in frame['actual_returns']) or kind!='bool'
        reports.append({'observer':kind,'old':first,'new':second,'old_callbacks':old_counts,'new_callbacks':new_counts,
                        'old_seconds':old_cost,'new_seconds':new_cost,'same_field_meaning':True})
    # Extract only the existing private owner and actual guard child lifecycle, never the complete fixture.
    tree=ast.parse(guard);names={'ScopeFixtureOwnerCancel','unique_object','confirmation','completed_case','run_control'}
    parts=[ast.get_source_segment(guard,n) for n in tree.body if isinstance(n,(ast.ClassDef,ast.FunctionDef)) and n.name in names]
    assert len(parts)==5
    owned='\n\n'.join(parts)
    assert owned.count('assert os.getuid()==0')==1
    owned=owned.replace('assert os.getuid()==0','assert os.getuid()=='+str(os.getuid()))
    drop='user=operator_record.pw_uid, group=operator_record.pw_gid,\n                extra_groups=operator_groups, '
    assert owned.count(drop)==1;owned=owned.replace(drop,'')
    assert owned.count('end = time.monotonic() + 145')==1 and owned.count('control_end = end - 15')==1
    owned=owned.replace('end = time.monotonic() + 145','end = time.monotonic() + 5').replace('control_end = end - 15','control_end = end - 1')
    channel_owned=channel.replace('fixture.st_uid==0','fixture.st_uid=='+str(os.getuid())).replace('info.st_uid==0','info.st_uid=='+str(os.getuid()))
    shell=source[source.index('scope_owner_state=never\n'):source.index("scope_fixture_signal=''\n")]
    assert shell.count('/usr/bin/sudo -n "$genuine_python"')==1
    shell=shell.replace('/usr/bin/sudo -n "$genuine_python"','"$genuine_python"')
    proof=next(n.value.args[0].value for n in ast.walk(tree) if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call)
               and isinstance(n.value.func,ast.Attribute) and n.value.func.attr=='write_text' and isinstance(n.value.func.value,ast.Name)
               and n.value.func.value.id=='proof_program')
    mac_program=area/'mac-wrapper.py';mac_subject=area/'mac-subject.py';mac_target=area/'mac-target'
    mac_code=proof.replace('time.sleep(30)','time.sleep(0)')
    clock_name='CLOCK_UPTIME_RAW' if sys.platform=='darwin' else 'CLOCK_MONOTONIC'
    mac_code=mac_code.replace('CLOCK_UPTIME_RAW',clock_name)
    foreground_line="instance._foreground(command,b'',4096,65536,10,{'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C'})"
    assert mac_code.count(foreground_line)==1
    mac_code=mac_code.replace(foreground_line,foreground_line+"\nname=sys.argv[2];before=identity(os.lstat(name))\nwith open(name,'ab') as target:target.write(b'changed')\nassert uptime() < deadline and identity(os.lstat(name)) == before")
    mac_subject.write_text(mac_code)
    mac_records=[]
    for version,code in [('old',old_wrapper),('new',wrapper),('wrong-code-same-name',wrapper)]:
        code=code.replace('CLOCK_UPTIME_RAW',clock_name)
        mac_target.write_bytes(b'owned')
        if version=='wrong-code-same-name':
            fake="scope={}\nexec(compile('def _foreground():return None\\n',str(consumer),'exec'),scope)\nscope['_foreground']()\n"
            mac_subject.write_text(mac_code.replace('name=sys.argv[2];before=',fake+'name=sys.argv[2];before='))
        else:mac_subject.write_text(mac_code)
        counted=code.replace('foreground = {}','callback_count=0\nforeground = {}',1)
        for name in ('observe','dispatch'):
            header='def '+name+'(frame, event, arg):\n'
            if header in counted:counted=counted.replace(header,header+'    global callback_count\n    callback_count+=1\n',1)
        counted=counted.replace('    sys.settrace(None)\n',"    sys.settrace(None)\n    print('TRACE_COUNT '+str(callback_count),file=sys.stderr)\n",1)
        mac_program.write_text(counted);started=time.monotonic()
        result=subprocess.run([sys.executable,'-I','-S','-B',str(mac_program),str(mac_subject),str(package),str(mac_target),str(mac_program)],capture_output=True,timeout=10)
        print(json.dumps({'mac_observer_version':version,'actual_rc':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()}),flush=True)
        assert result.returncode!=0
        def row(prefix):return json.loads(next(line[len(prefix):] for line in result.stderr.splitlines() if line.startswith(prefix)))
        clean=row(b'GUARD_OWNED_CLEANUP ');identity=row(b'GUARD_IDENTITY_REFUSAL ')
        assert clean['complete'] and clean['active_calls']==0 and len(clean['foreground_calls'])==1
        assert clean['foreground_calls'][0]['reaped'] and clean['foreground_calls'][0]['pipes_closed']
        assert identity['deadline_valid'] and identity['actual_identity_comparison_reached'] and identity['actual']!=identity['expected']
        count=int(next(line.split()[1] for line in result.stderr.splitlines() if line.startswith(b'TRACE_COUNT ')))
        mac_records.append({'version':version,'cleanup':clean,'identity':identity,'callbacks':count,'seconds':time.monotonic()-started,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()})
    assert mac_records[1]['callbacks']<mac_records[0]['callbacks']
    reports.append({'mac_actual_observer_equivalence':mac_records})
    for fault in ('ordinary-started-no-marker','ordinary-pending','never-started','starting','normal','cancel','alarm','eof-before-launch','actual-deadline','missing-confirmation','wrong-confirmation','reported-wait-error','reported-close-error','wait-interrupted','writer-close-error','terminal-nonzero','mask077-normal','mask022-normal','mask077-cancel','mask022-cancel','mode0400','mode0644','fchmod-error','mask022-fchmod-error','inner-wait-error','inner-close-error'):
        work=area/fault;work.mkdir();base=work/'base';base.mkdir();(base/'package/shadow/v1').mkdir(parents=True);(base/'package/shadow/v1/_consumer.py').write_bytes(consumer);script=work/'runtime-guard-controls.py';ch=work/'channel.py';ch.write_text(channel_owned)
        fixture=base/('runtime-guard-cancel-proof' if fault in ('cancel','alarm','mask077-cancel','mask022-cancel') else 'runtime-guard');fixture.mkdir()
        program=fixture/'wrapper.py';program.write_text(wrapper.replace('CLOCK_UPTIME_RAW',clock_name))
        body=fixture/'subject.py'
        if fault in ('cancel','alarm','mask077-cancel','mask022-cancel'):body=fixture/'owner-cancel-proof.py';body.write_text(proof.replace('CLOCK_UPTIME_RAW',clock_name))
        else:body.write_text("import os,sys,time\nname=sys.argv[2];deadline=time.monotonic()+120\nbefore=tuple(os.lstat(name))\ndef uptime():return time.monotonic()\ndef identity(value):return tuple(value)\nassert uptime() < deadline and identity(os.lstat(name)) == before\nprint('{\"privileged_execution\": false}',file=sys.stderr)\nprint(sys.argv[2])\n")
        selected=base/'selected';selected.write_bytes(b'not executable data')
        prefix='''from pathlib import Path
import fcntl,hashlib,json,os,pwd,selectors,signal,stat,subprocess,sys,time
base=Path(sys.argv[1]);package=Path(sys.argv[2]);python=Path(sys.executable)
operator_record=pwd.getpwuid(os.getuid());operator_groups=os.getgroups()
selected=base/'selected';guard_file=Path(sys.argv[4]);module=selected
pending_path=base/'runtime-guard-cleanup-uncertain'
'''
        suffix="\nprogram=Path("+repr(str(program))+")\noriginal_program=Path("+repr(str(body))+")\nsync_program=original_program\nowner_cancel=ScopeFixtureOwnerCancel()\ntry:\n    run_control("+repr('fixed-short-owner-cancel' if fault in ('cancel','alarm','mask077-cancel','mask022-cancel') else 'owned-normal')+",None)\nfinally:\n    owner_cancel.finish()\n"
        script.write_text(prefix+owned+suffix)
        (work/'guard-source').write_bytes(b'owned guard source')
        mask=0o022 if fault.startswith('mask022-') else 0o077
        publication_hook="""expected_mask=MASK
saved_publish=ScopeFixtureOwnerCancel.publish
def observed_publish(self,suffix,value):
    assert os.umask(expected_mask)==expected_mask
    saved_publish(self,suffix,value)
    assert os.umask(expected_mask)==expected_mask
    fd=os.open(str(self.stem)+suffix,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd);raw=os.read(fd,16385)
        assert stat.S_IMODE(info.st_mode)==0o444 and info.st_uid==os.getuid() and info.st_nlink==1
        assert len(raw)<=16384 and json.loads(raw)==value
        assert raw==json.dumps(value,sort_keys=True,separators=(',',':')).encode()
        print('ACTUAL_PUBLICATION '+json.dumps({'suffix':suffix,'uid':info.st_uid,'mode':stat.S_IMODE(info.st_mode),'nlink':info.st_nlink,'payload':json.loads(raw),'sha256':hashlib.sha256(raw).hexdigest(),'umask':expected_mask}),flush=True)
    finally:os.close(fd)
ScopeFixtureOwnerCancel.publish=observed_publish
""".replace('MASK',str(mask))
        content=script.read_text().replace('owner_cancel=ScopeFixtureOwnerCancel()\n',publication_hook+'owner_cancel=ScopeFixtureOwnerCancel()\n',1)
        if fault in ('fchmod-error','mask022-fchmod-error'):
            hook="""def fixed_fchmod_failure(fd,mode):
    info=os.fstat(fd)
    assert mode==0o444 and stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode)==0o400
    print('FIXED_FCHMOD_ERROR_AFTER_WRITE '+json.dumps({'actual_mode':stat.S_IMODE(info.st_mode),'uid':info.st_uid,'nlink':info.st_nlink,'size':info.st_size,'requested_mode':mode}),flush=True)
    raise OSError('fixed publication fchmod failure')
os.fchmod=fixed_fchmod_failure
"""
            content=content.replace('owner_cancel=ScopeFixtureOwnerCancel()\n',hook+'owner_cancel=ScopeFixtureOwnerCancel()\n',1)
            content=content.replace('    owner_cancel.finish()\n',"    try:owner_cancel.finish()\n    finally:\n        assert not owner_cancel.active and len(owner_cancel.cases)==1\n        print('INDEPENDENT_PUBLICATION_GRAPH_COMPLETE '+json.dumps(owner_cancel.cases),flush=True)\n")
        script.write_text(content)
        if fault=='terminal-nonzero':body.write_text(body.read_text()+"raise ValueError('actual nonzero child terminal')\n")
        if fault=='actual-deadline':body.write_text(body.read_text().replace('print(sys.argv[2])','time.sleep(10)\nprint(sys.argv[2])'))
        if fault in ('inner-wait-error','inner-close-error'):
            hook="""saved_popen=subprocess.Popen
actual_children=[]
def fixed_owned_popen(*args,**kwargs):
    child=saved_popen(*args,**kwargs)
    actual_children.append(child)
    operation=child.wait if FAULT=='inner-wait-error' else child.stdout.close
    injected=[False]
    def reported_error(*args,**kwargs):
        value=operation(*args,**kwargs)
        if not injected[0]:
            injected[0]=True
            raise OSError('fixed reported error after actual operation')
        return value
    if FAULT=='inner-wait-error':child.wait=reported_error
    else:child.stdout.close=reported_error
    return child
subprocess.Popen=fixed_owned_popen
""".replace('FAULT',repr(fault))
            content=script.read_text().replace('owner_cancel=ScopeFixtureOwnerCancel()\n',hook+'owner_cancel=ScopeFixtureOwnerCancel()\n',1)
            content=content.replace('    owner_cancel.finish()\n',"    try:owner_cancel.finish()\n    finally:\n        assert len(actual_children)==1\n        child=actual_children[0]\n        assert type(child.returncode) is int and all(p.closed for p in (child.stdin,child.stdout,child.stderr))\n        print('INDEPENDENT_PHYSICAL_COMPLETION '+json.dumps({'pid':child.pid,'status':child.returncode,'all_pipes_closed':True}),flush=True)\n")
            script.write_text(content)
        serial='1' if fault in ('cancel','alarm','mask077-cancel','mask022-cancel') else '2'
        variables='\n'.join(name+'='+repr(str(value)) for name,value in {'tmp':work,'genuine_base':base,'guard_control':script,'genuine_python':sys.executable,'guard_source':work/'guard-source','operator_name':pwd.getpwuid(os.getuid()).pw_name,'entry_source':work/'guard-source','scope_owner_channel_helper':ch}.items())+'\n'
        # Keep the exact production launch, wait and confirmation functions; only UID and fixed sudo transport adapt.
        if serial=='2':variables+='scope_owner_serial=1\n'
        if fault in ('cancel','alarm','mask077-cancel','mask022-cancel'):call='scope_fixture_owner_launch true\n'
        elif fault=='eof-before-launch':
            call='scope_fixture_owner_launch false\n'
            shell_case=shell.replace('  scope_owner_state=active\n','  scope_owner_state=active\n  scope_fixture_owner_cancel\n',1)
        else:call='scope_fixture_owner_launch false\n'
        negative=fault in ('missing-confirmation','wrong-confirmation','reported-wait-error','reported-close-error','wait-interrupted','writer-close-error','mode0400','mode0644')
        genuine=area/(fault+'.genuine-receipt')
        if negative:
            call+='\n/bin/cp "$tmp/scope-owner-2.receipt" '+repr(str(genuine))+'\n'
            call+='scope_owner_state=active\n'
            if fault=='missing-confirmation':call+='/bin/mv "$tmp/scope-owner-2.receipt" "$tmp/scope-owner-2.saved-receipt"\n'
            elif fault=='wrong-confirmation':
                patch_code='import json,os,sys;p=sys.argv[1];v=json.load(open(p));v["context_sha256"]="0"*64;os.chmod(p,0o600);open(p,"w").write(json.dumps(v));os.chmod(p,0o444)'
                call+='/usr/bin/python3 -I -S -B -c '+repr(patch_code)+' "$tmp/scope-owner-2.receipt"\n'
            elif fault in ('mode0400','mode0644'):
                mode=0o400 if fault=='mode0400' else 0o644
                patch_code='import os,sys;fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW);os.fchmod(fd,'+str(mode)+');os.close(fd)'
                call+='/usr/bin/python3 -I -S -B -c '+repr(patch_code)+' "$tmp/scope-owner-2.receipt"\n'
            else:
                if fault in ('reported-wait-error','wait-interrupted'):
                    status=127 if fault=='reported-wait-error' else 142
                    call+='wait() { local actual=0; builtin wait "$@" || actual=$?; printf "ACTUAL_WAIT_FINISHED:%s\\n" "$actual" >&2; return '+str(status)+'; }\n'
                    repair='unset -f wait\n'
                else:
                    reader=fault=='reported-close-error';number=6 if reader else 7
                    role='reader' if reader else 'writer'
                    call+='exec '+str(number)+('<' if reader else '>')+'"$tmp/guard-source"\nscope_owner_'+role+'=true\n'
                    original='scope_fixture_owner_close_'+role+'() { exec '+str(number)+('<&-' if reader else '>&-')+'; }\n'
                    call+=original.replace('; }','; printf "ACTUAL_CLOSE_FINISHED:'+role+'\\n" >&2; return 1; }')
                    repair=original
                call+='if scope_fixture_owner_wait; then exit 99; fi\ntest "$scope_owner_state" = unknown\nprintf "FIRST_REFUSAL:unknown:%s\\n" "$scope_owner_status" >&2\n'+repair
        cleanup_source=source[source.index("scope_fixture_signal=''\n"):source.index('\nplatform=',source.index("scope_fixture_signal=''\n"))]
        test_shell=shell_case if fault=='eof-before-launch' else shell
        if fault=='alarm':
            assert test_shell.count('    scope_fixture_owner_cancel || return 1\n  fi\n')==1
            test_shell=test_shell.replace('    scope_fixture_owner_cancel || return 1\n  fi\n',"    /usr/bin/python3 -I -S -B -c 'import os,signal,time;time.sleep(0.25);os.kill(os.getppid(),signal.SIGALRM)' 7>&-\n  fi\n",1)
        if fault=='starting':test_shell=test_shell.replace('  scope_owner_state=attempted\n','  scope_owner_state=attempted\n  kill -s ALRM "$$"\n',1)
        if fault in ('ordinary-started-no-marker','ordinary-pending','never-started'):call='exit 0\n'
        if fault=='ordinary-started-no-marker':call='scope_controls_state=started\nexit 0\n'
        if fault=='ordinary-pending':(work/'observer-owner-controls.pending').touch()
        audit=area/(fault+'.deleted')
        stub='cleanup_genuine(){ if [ \"$scope_owner_state\" != never ]; then /bin/cat \"$tmp/scope-owner-$scope_owner_serial.receipt\" > '+repr(str(genuine))+'; fi; /bin/rm -rf -- "$genuine_base";printf DELETED > '+repr(str(audit))+'; }\n'
        command='set -euo pipefail\n'+test_shell+variables+stub+cleanup_source+call
        generated=area/(fault+'.generated.json')
        generated.write_text(json.dumps({'driver':script.read_text(),'wrapper':program.read_text(),'subject':body.read_text(),'channel':ch.read_text(),'bash':command},sort_keys=True))
        print(json.dumps({'generated_parts':str(generated),'sha256':hashlib.sha256(generated.read_bytes()).hexdigest(),'source':json.loads(generated.read_text())}),flush=True)
        start=time.monotonic();result=subprocess.run(['/bin/bash','-c',command],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20,umask=mask)
        (area/(fault+'.stdout')).write_bytes(result.stdout);(area/(fault+'.stderr')).write_bytes(result.stderr)
        confirmed=audit.exists()
        print(json.dumps({'actual_owner_case':fault,'returncode':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode(),'deletion_permitted':confirmed}),flush=True)
        assert confirmed==(fault in ('never-started','normal','cancel','alarm','eof-before-launch','actual-deadline','terminal-nonzero','mask077-normal','mask022-normal','mask077-cancel','mask022-cancel')),(fault,result.returncode,result.stderr)
        assert (result.returncode==0)==(fault in ('never-started','normal','cancel','mask077-normal','mask022-normal','mask077-cancel','mask022-cancel'))
        if fault=='alarm':assert result.returncode==-signal.SIGALRM
        if fault=='eof-before-launch':assert result.returncode!=0 and '\"cases\": []' in result.stdout.decode()
        if fault=='actual-deadline':assert result.returncode!=0 and time.monotonic()-start>=4
        if fault=='cancel':assert 'foreground_count' in result.stdout.decode()
        if fault not in ('ordinary-started-no-marker','ordinary-pending','never-started','starting','inner-wait-error','inner-close-error','fchmod-error','mask022-fchmod-error'):
            original=json.loads(genuine.read_bytes())
            assert original['quiescent'] is True and isinstance(original['cases'],list)
            if fault not in ('eof-before-launch',):assert len(original['cases'])==1
        if fault in ('inner-wait-error','inner-close-error'):
            assert not confirmed and work.exists() and result.returncode!=0
            assert 'INDEPENDENT_PHYSICAL_COMPLETION' in result.stdout.decode()
            assert 'original child supervision not confirmed' in result.stderr.decode()
            assert 'GUARD_OWNED_CLEANUP' in result.stdout.decode()
            assert 'fixed reported error after actual operation' in result.stderr.decode()
        if fault in ('ordinary-started-no-marker','ordinary-pending'):assert work.exists() and 'ordinary control completion is unknown' in result.stderr.decode()
        if fault in ('fchmod-error','mask022-fchmod-error'):
            assert not confirmed and work.exists() and result.returncode!=0
            assert 'FIXED_FCHMOD_ERROR_AFTER_WRITE' in result.stdout.decode()
            assert 'INDEPENDENT_PUBLICATION_GRAPH_COMPLETE' in result.stdout.decode()
            assert 'fixed publication fchmod failure' in result.stderr.decode()
        if fault.startswith('mask') and not fault.endswith('fchmod-error'):
            publications=[json.loads(line[len('ACTUAL_PUBLICATION '):]) for line in result.stdout.decode().splitlines() if line.startswith('ACTUAL_PUBLICATION ')]
            assert {v['suffix'] for v in publications}==({'.ready','.receipt'} if fault.endswith('cancel') else {'.receipt'})
            assert all(v['mode']==0o444 and v['umask']==mask and v['uid']==os.getuid() and v['nlink']==1 for v in publications)
        if negative:
            assert not confirmed and work.exists()
            if fault=='missing-confirmation':assert 'FileNotFoundError' in result.stderr.decode()
            if fault in ('mode0400','mode0644'):assert 'stat.S_IMODE(info.st_mode)==0o444' in result.stderr.decode()
            if fault=='wrong-confirmation':assert "value['context_sha256']==hashlib.sha256(raw).hexdigest()" in result.stderr.decode()
            if fault in ('reported-wait-error','wait-interrupted'):
                assert 'ACTUAL_WAIT_FINISHED:0' in result.stderr.decode() and 'FIRST_REFUSAL:unknown:' in result.stderr.decode()
                assert result.stderr.decode().count('ACTUAL_WAIT_FINISHED:')==1
            if fault in ('reported-close-error','writer-close-error'):
                assert 'ACTUAL_CLOSE_FINISHED:' in result.stderr.decode() and 'FIRST_REFUSAL:unknown:0' in result.stderr.decode()
                assert result.stderr.decode().count('ACTUAL_CLOSE_FINISHED:')==1
        reports.append({'owner_case':fault,'returncode':result.returncode,'deletion_permitted':confirmed,
                        'stdout':result.stdout.decode(),'stderr':result.stderr.decode(),'elapsed':time.monotonic()-start})
    library=area/'never-launched-library';library.write_bytes(b'owned data')
    cleanup_node=next(n for n in ast.walk(tree) if isinstance(n,ast.Try) and n.finalbody and
        any(isinstance(x,ast.Expr) and isinstance(x.value,ast.Call) and isinstance(x.value.func,ast.Attribute) and
            x.value.func.attr=='unlink' and isinstance(x.value.func.value,ast.Name) and x.value.func.value.id=='library' for x in n.finalbody))
    boundary=compile(ast.Module(body=cleanup_node.finalbody,type_ignores=[]),'actual-library-cleanup-boundary','exec')
    for active in (True,False):
        try:exec(boundary,{'owner_cancel':types.SimpleNamespace(active=active),'library':library})
        except AssertionError:assert active and library.read_bytes()==b'owned data'
        else:assert not active and not library.exists()
    namespace={};exec(compile(owned,'actual-owner-never-launched','exec'),globals(),namespace)
    owner=namespace['ScopeFixtureOwnerCancel'].__new__(namespace['ScopeFixtureOwnerCancel'])
    owner.active=True;owner.check=lambda:None
    try:owner.acl([])
    except AssertionError:pass
    else:raise AssertionError('active prior child allowed new ACL operation')
    reports.append({'never_launched_data_cleanup_gate':'PASS','active_library_unlink_refused':True,'active_acl_refused':True})
    reports.append({'actual_proof_materialization':proof_materialization_controls(guard,area)})
except BaseException:
    print(json.dumps({'ordinary_tree_retained':temporary,'reason':'control did not establish complete success'}),flush=True)
    raise
else:
    shutil.rmtree(temporary)
    print(json.dumps({'ordinary_tree_removed_after_complete_evidence':temporary}),flush=True)
print(json.dumps({'observer_owner_controls':'PASS','reports':reports,'ordinary_uid_and_fixed_sudo_transport_adapter':True,
                  'supplied_runtime_executed':False,'not_actual_root_chain_or_full_fixture_proof':True,'fixed_owned_control_deadlines_only':[5,1],
                  'production_deadlines_unchanged':[1800,300,120,145,15]},sort_keys=True))
PY_OBSERVER_OWNER_CONTROLS
python3 -I -S -B - "$root" "$tmp/store-mode-controls" "${BASH_SOURCE[0]}" <<'PY_STORE_MODE_CONTROLS'
import ast,hashlib,json,os,pathlib,subprocess,sys
root,area=map(pathlib.Path,sys.argv[1:3]);source=pathlib.Path(sys.argv[3]).read_text();area.mkdir()
opening='  /bin/cat >"$tmp/genuine-assembler.py" <<'+"'PY_GENUINE_ASSEMBLER'"
lines=source.splitlines(keepends=True)
a=[i for i,line in enumerate(lines) if line.rstrip('\n')==opening]
b=[i for i,line in enumerate(lines) if line.rstrip('\n')=='PY_GENUINE_ASSEMBLER']
assert len(a)==len(b)==1 and a[0]<b[0]
assembler=''.join(lines[a[0]+1:b[0]]);tree=ast.parse(assembler)
start=next(i for i,node in enumerate(tree.body) if isinstance(node,ast.Assign) and isinstance(node.targets[0],ast.Name) and node.targets[0].id=='store')
block=tree.body[start:start+7]
assert len(block)==7 and isinstance(block[-1],ast.Expr)
assert ast.unparse(block[-1].value.func)=='store.chmod' and block[-1].value.args[0].value==0o750
creation=''.join(assembler.splitlines(keepends=True)[block[0].lineno-1:block[-1].end_lineno])
assert len(ast.parse(creation).body)==7
(area/'creation.py').write_text(creation)
host=root/'sandbox/v1/host-supervisor.py';host_raw=host.read_bytes();assert len(host_raw)<=16*1024*1024
worker=r"""import ast,errno,json,os,pathlib,runpy,stat,subprocess,sys
base,creation,host=map(pathlib.Path,sys.argv[1:4]);mask=int(sys.argv[4]);case=sys.argv[5]
uid,gid=os.getuid(),os.getgid();before_mask=os.umask(mask);os.umask(before_mask);assert before_mask==mask
product=runpy.run_path(str(host),run_name='owned_store_mode_product')
block=ast.parse(creation.read_bytes()).body
if case=='old-077':block=block[:-1]
mode_attempted=False;writer_reached=False;error=None;original=pathlib.Path.chmod
calls=[]
def run(argv):
    command=list(map(str,argv));assert command[:2]==['/bin/chmod','-N'] and command[2]==str(base/'store')
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=3)
    calls.append({'argv':command,'status':result.returncode,'stdout_hex':result.stdout.hex(),'stderr_hex':result.stderr.hex()})
    assert result.returncode==0 and not result.stdout and not result.stderr

def fail_mode(path,mode,*args,**kwargs):
    global mode_attempted
    assert path==base/'store' and mode==0o750
    mode_attempted=True
    raise OSError(errno.EIO,'fixed before-mode operation')
if case=='mode-operation-fault':pathlib.Path.chmod=fail_mode
try:
    try:exec(compile(ast.Module(body=block,type_ignores=[]),str(creation),'exec'))
    except OSError as actual:
        assert case=='mode-operation-fault' and actual.errno==errno.EIO and actual.strerror=='fixed before-mode operation'
        error={'type':type(actual).__name__,'errno':actual.errno,'message':actual.strerror}
finally:pathlib.Path.chmod=original
store=base/'store'
if case=='wrong-mode':store.chmod(0o700)
expected=case not in ('old-077','wrong-mode')
if case=='mode-operation-fault':
    assert error is not None and mode_attempted and not writer_reached
else:
    try:fd=product['check_store_root'](store,uid,gid)
    except product['Refusal'] as actual:assert not expected and actual.code=='E_STORE'
    else:
        try:
            assert expected
            writer_reached=True
            assert product['store_root_state_ok'](fd,uid,gid)
            if sys.platform=='darwin':assert product['darwin_acl_entries'](fd)==[]
        finally:os.close(fd)
state=store.stat();assert stat.S_ISDIR(state.st_mode) and state.st_uid==uid and state.st_gid==gid
assert stat.S_IMODE(state.st_mode)==(0o750 if case=='fixed' or (case=='mode-operation-fault' and mask==0o022) else 0o700)
after_mask=os.umask(mask);os.umask(after_mask);assert after_mask==before_mask
print(json.dumps({'case':case,'mask_before':before_mask,'mask_after':after_mask,'mode':stat.S_IMODE(state.st_mode),
    'uid':state.st_uid,'gid':state.st_gid,'nlink':state.st_nlink,'product_accepted':None if error else expected,
    'mode_fault':error,'writer_reach_marker':writer_reached,'actual_acl_commands':calls,
    'scope':'ordinary owned same-uid data; not actual writer/root-origin or failed CI inode'},sort_keys=True),flush=True)
"""
script=area/'worker.py';script.write_text(worker);reports=[]
for mask,cases in [(0o077,('fixed','old-077','wrong-mode','mode-operation-fault')),(0o022,('fixed','wrong-mode','mode-operation-fault'))]:
    for case in cases:
        base=area/(str(mask)+'-'+case);base.mkdir()
        bindings={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in (script,area/'creation.py',host)}
        (base/'preexec.json').write_text(json.dumps(bindings,sort_keys=True)+'\n')
        result=subprocess.run([sys.executable,'-I','-S','-B',str(script),str(base),str(area/'creation.py'),str(host),str(mask),case],
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,umask=mask)
        (base/'stdout.raw').write_bytes(result.stdout);(base/'stderr.raw').write_bytes(result.stderr)
        assert result.returncode==0 and not result.stderr,(case,result.returncode,result.stdout,result.stderr)
        reports.append(json.loads(result.stdout))
print(json.dumps({'store_mode_controls':reports,'creation_sha256':hashlib.sha256(creation.encode()).hexdigest(),
    'host_source_sha256':hashlib.sha256(host_raw).hexdigest(),'no_actual_writer_or_supplied_runtime':True},sort_keys=True),flush=True)
PY_STORE_MODE_CONTROLS
scope_controls_state=completed
/bin/rm -- "$tmp/observer-owner-controls.pending"

for shipped in "$policy" "$record_program" "$gate_program" "$validator" "$evaluator"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing $shipped"
done
[ -x "$validator" ] && [ -x "$evaluator" ] || fail 'drivers must be executable'
"$jq_bin" -S -c . "$policy" >"$tmp/policy-canonical.json"
/usr/bin/cmp -s "$policy" "$tmp/policy-canonical.json" || fail 'policy is not canonical'
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
for source_path in scope/v1/scope-policy.json scope/v1/workflow-scope.jq \
  scope/v1/scope-gates.jq scope/v1/validate-scope.sh scope/v1/evaluate-scope.sh \
  scripts/test/scope-qualification.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation id in $source_path"
done
"$jq_bin" -e '
  .kind == "scope_qualification_policy" and .body.activation_state == "inactive" and
  .body.authority == "none" and .body.fail_mode == "closed" and
  .body.proposable_risk_tiers == ["routine"]
' "$policy" >/dev/null || fail 'policy contract'
pass 'the shipped gate policy is canonical, inactive, and routine-only'

# The identities qualification is attached to. The scope records them, the shadow
# records say which revision they ran against, and the evaluator binds the two.
fixture_revision='{"commit_id":"1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d","hash_algorithm":"sha1","repository_id":"repo.fixture-target"}'
other_revision='{"commit_id":"90abcdef1234567890abcdef1234567890abcdef","hash_algorithm":"sha1","repository_id":"repo.fixture-target"}'
qualified_identity='{
  "adapter_config_refs":[
    {"content_id":"producer-config",
     "media_type":"application/vnd.ystack.adapter-config+json",
     "sha256":"dbb66b0ed70b09061474eb8a8245e7df9c26e3fb8eca1d1b5b5223c74d3699b4"}],
  "model_request":{"effort_id":"high","model_id":"claude.sonnet",
    "provider_id":"anthropic"},
  "prompt_refs":[
    {"location":{"kind":"path","value":"routines/coder.md"},"mode":"100644",
     "object_id":"b307b85339fbfc060aec59c625918a3f20707438",
     "object_type":"blob",
     "revision":{"commit_id":"a637451d4b3fbef6b516a9c08f68c0dde46a7059",
       "hash_algorithm":"sha1","repository_id":"repo.ystack"}}],
  "resolved_profile_ref":{"id":"resolved.docs-typo-fix.v1","kind":"resolved_profile",
    "schema_version":2,
    "sha256":"3bae8e45eea85ad41068735782b4750deb920654c34712b85159195ceec8b688"},
  "skill_refs":[],
  "stage_request_ref":{"id":"stage.docs-typo-fix.request","kind":"stage_request",
    "schema_version":2,
    "sha256":"0cefa6d87f7869958b5ba9f0555a6327e8f49f3047b5bde500c7796024256592"},
  "target_revision":{"commit_id":"1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d",
    "hash_algorithm":"sha1","repository_id":"repo.fixture-target"},
  "verification_instructions_ref":{"content_id":"verification-instructions",
    "media_type":"application/vnd.ystack.verification-instructions+json",
    "sha256":"eebf0a48514a92396eb06ceee8fabc218f6b8c979e01ad5850bdedb42f494488"}}'

# The shadow record fixtures are whole records in the shape
# shadow/v1/reproduce.sh emits, not only the fields this evaluator reads: the
# qualification gate now checks that slice's complete emitted shape, so a stub
# carrying the envelope, the markers, and an accepted outcome is refused as
# malformed. Every block is here field for field - the incident, environment
# claim, registry, and trace ledger references, the sandbox evaluation section,
# the read-only materialization with the materializer receipt's source and
# candidate, and the executed file-digest check - and the reason id, outcome,
# and section states are the combination the slice actually produces for that
# run.
expected_check_sha=8f434346648f6b96df89dda901c5176b10a6d83961dd3c2e6c66a9f0f95d4c9b
observed_check_sha=60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752
"$jq_bin" -S -c -n --argjson revision "$fixture_revision" \
  --argjson identity "$qualified_identity" \
  --arg expected "$expected_check_sha" --arg observed "$observed_check_sha" '
  def digest($character): ($character * 64);
  def record($id;$environment;$outcome;$repository):
    # Every record carries the qualified identity the run was performed under,
    # the way shadow/v1/reproduce.sh records it, and binds the canonical bytes
    # of that identity document by digest.
    ($revision | .repository_id = $repository) as $rev |
    (if $outcome == "reproduced" then "check.failed-at-revision"
     else "check.passed-at-revision" end) as $reason |
    {schema_version:1,kind:"shadow_reproduction_record",id:$id,
     body:{activation_state:"inactive",authority:"none",deploy_authority:"none",
       effects:["caller-disposable-candidate-repository"],
       evaluation_mode:"observation-only",shadow:true,
       qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
       outcome:$outcome,reason_id:$reason,
       observed_at:"2026-09-05T00:00:00Z",target_repository_id:$repository,
       git_revision_ref:$rev,
       qualified_identity:$identity,
       qualified_identity_ref:{content_id:"shadow-qualified-identity",
         media_type:"application/vnd.ystack.qualified-identity+json",
         sha256:digest("9")},
       incident_ref:{content_id:"shadow-incident-record",
         media_type:"application/vnd.ystack.shadow-incident-record+json",
         sha256:digest("a")},
       environment:{environment_id:$environment,
         claim_ref:{content_id:"shadow-environment-claim",
           media_type:"application/vnd.ystack.control-execution-environment-claim+json",
           sha256:digest("b")},
         registry_ref:{content_id:"shadow-environment-registry",
           media_type:"application/vnd.ystack.shadow-environment-registry+json",
           sha256:digest("c")},
         evaluation:{state:"present",
           value:{verdict:"satisfied",
             reason_ids:["sandbox.declaration-satisfied"],
             evaluation_ref:{content_id:"shadow-sandbox-evaluation",
               media_type:"application/vnd.ystack.control-evaluation+json",
               sha256:digest("d")}}}},
       materialization:{state:"present",
         value:{adapter_id:"adapter.local-git-materializer.v1",
           outcome:"no-change",
           source:{repository_id:$repository,
             hash_algorithm:$rev.hash_algorithm,commit_id:$rev.commit_id,
             tree_id:"4b825dc642cb6eb9a060e54bf8d69288fbee4904"},
           candidate:{repository_kind:"bare",
             hash_algorithm:$rev.hash_algorithm,commit_id:$rev.commit_id,
             tree_id:"4b825dc642cb6eb9a060e54bf8d69288fbee4904",
             parent_commit_id:$rev.commit_id},
           stage_result_ref:{schema_version:2,kind:"stage_result",
             id:("stage.docs-typo-fix.result." + $environment),
             sha256:digest("e")}}},
       check:{failing_check:{kind:"file-digest",path:"docs/components.md",
           expected_sha256:$expected},
         execution:{state:"present",
           value:{tool_id:"tool.git-blob-digest",
             observed_sha256:(if $outcome == "no-change" then $expected
                              else $observed end),
             matches_expected:($outcome == "no-change")}}},
       trace_ledger_ref:{content_id:"shadow-trace-ledger",
         media_type:"application/vnd.ystack.telemetry-trace-ledger+json",
         sha256:digest("f")}}};
  {schema_version:1,kind:"shadow_evidence_set",
   id:"scope.evidence.docs-typo-fix.v1",
   body:{records:[
     record("shadow.docs-typo-fix.local";"env.local-macos-fixture";"reproduced";
       "repo.fixture-target"),
     record("shadow.docs-typo-fix.ci";"env.ci-linux-fixture";"no-change";
       "repo.fixture-target")]}}' >"$tmp/shadow-set.json"

# The dashboard fixture is a whole eval dashboard in the shape
# evals/v1/evals.jq emits, not only the parts this evaluator reads: the
# qualification gate now checks the framework's complete emitted shape, so a
# fixture carrying just the families would be refused as malformed. Every block
# is here field for field — the portable core contract the framework pins, the
# catalog and evaluator references, the run inputs, coverage, quality, recovery,
# and the absent telemetry and flow metrics.
"$jq_bin" -S -c -n '
  def family($id;$status;$total;$failed;$inconclusive):
    {family_id:$id,seed_status:$status,
     seed_sources:(if $status == "seeded" then ["core.stage-run.v2"] else [] end),
     grader_kinds:["deterministic"],trial_policy:{kind:"single"},runs:1,
     cases:{total:$total,passed:($total - $failed - $inconclusive),
       failed:$failed,inconclusive:$inconclusive}};
  def absent($reason): {state:"absent",reason_id:$reason};
  def closure($path;$sha): [{path:$path,sha256:$sha}];
  {schema_version:1,kind:"eval_dashboard",id:"evals.dashboard.v1",
   body:{activation_state:"inactive",authority_effect:"none",
     mode:"deterministic-offline",
     core_contract:{
       generation_id_sha256:
         "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
       package_ref:{content_id:"core-contract-package.v2",
         media_type:"application/vnd.ystack.core-contract+json",
         sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
       semantic_identity:"core.contracts.v2"},
     catalog_ref:{schema_version:1,kind:"eval_catalog",id:"evals.catalog.v1",
       sha256:"1111111111111111111111111111111111111111111111111111111111111111"},
     evaluator:{
       sha256:"2222222222222222222222222222222222222222222222222222222222222222",
       content:{schema_version:1,kind:"eval_framework_evaluator",
         id:"evals.framework.v1",
         body:{
           core_contract:{
             generation_id_sha256:
               "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
             package_ref:{content_id:"core-contract-package.v2",
               media_type:"application/vnd.ystack.core-contract+json",
               sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
             semantic_identity:"core.contracts.v2"},
           core_closure:closure("core/v2/generation-registry.json";
             "3333333333333333333333333333333333333333333333333333333333333333"),
           orchestrator_closure:closure("orchestrator/v1/scan-state.sh";
             "4444444444444444444444444444444444444444444444444444444444444444"),
           control_closure:closure("control/v1/kill-switch.jq";
             "5555555555555555555555555555555555555555555555555555555555555555"),
           adapter_closure:closure("adapters/codex-native-reviewer/v1/normalize.jq";
             "6666666666666666666666666666666666666666666666666666666666666666"),
           bootstrap_ref:{content_id:"evals-framework-bootstrap.v1",
             media_type:"text/x-shellscript",
             sha256:"7777777777777777777777777777777777777777777777777777777777777777"},
           launcher_ref:{content_id:"evals-framework-launcher.v1",
             media_type:"text/x-shellscript",
             sha256:"8888888888888888888888888888888888888888888888888888888888888888"},
           driver_ref:{content_id:"evals-framework-driver.v1",
             media_type:"text/x-shellscript",
             sha256:"9999999999999999999999999999999999999999999999999999999999999999"},
           program_ref:{content_id:"evals-framework-program.v1",
             media_type:"text/x-jq",
             sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
           catalog_ref:{content_id:"evals-catalog.v1",
             media_type:"application/vnd.ystack.eval-catalog+json",
             sha256:"1111111111111111111111111111111111111111111111111111111111111111"},
           runtime:{host_os:"linux",host_architecture:"x86_64",
             jq_architecture:"x86_64",execution_mode:"native",
             jq_ref:{content_id:"jq-runtime.v1",
               media_type:"application/x-executable",
               sha256:"af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"},
             shell_ref:{content_id:"bash-runtime",
               media_type:"application/x-executable",
               sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}},
     observed_at:"2026-09-05T00:00:00Z",
     inputs:[{run_id:"evals.run.fixture",seed_source:"core.stage-run.v2",
       result_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
       observed_at:"2026-09-05T00:00:00Z",
       seed_set_ref:{schema_version:1,kind:"eval_seed_set",id:"evals.seed-set.fixture",
         sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
       summary:{total:34,passed:34,failed:0,inconclusive:0}}],
     coverage:{families_total:9,families_seeded:7,families_declared:2,
       families_with_results:7,
       sources_with_results:["core.stage-run.v2"]},
     quality:{total:34,passed:34,failed:0,inconclusive:0},
     recovery:{stranded_recovered:0,cancelled_stayed_terminal:0,
       repeats_redelivered_once:0,repeats_suppressed_after_acknowledgement:0,
       retry_limit_enforced:0,events_refused:0},
     telemetry:{cost:absent("evals.no-live-runs"),
       latency:absent("evals.no-live-runs"),tokens:absent("evals.no-live-runs")},
     flow:([
       "accepted-plan-to-merge-time","dora-instability","dora-throughput",
       "escaped-defects","escaped-vulnerabilities","first-pass-success",
       "human-gate-wait","intent-to-spec-time","queue-wait","review-latency",
       "review-precision","review-recall-samples","review-stale-rate",
       "rework-cycles","target-outcome"] |
       map({key:.,value:absent("evals.no-operating-history")}) | from_entries),
     families:[
       family("actor-rerun-identity";"seeded";4;0;0),
       family("adapter-contract-compliance";"seeded";4;0;0),
       family("approval-invalidation-no-push-after-approval";"seeded";4;0;0),
       family("empty-fake-timed-out-degraded-reviews";"seeded";4;0;0),
       family("malicious-instructions";"declared";0;0;0),
       family("protected-path-credential-network-publisher-boundaries";"seeded";6;0;0),
       family("repeated-cancelled-missed-events";"seeded";5;0;0),
       family("reviewer-severity-false-positive-negative";"declared";0;0;0),
       family("stale-moved-artifacts";"seeded";7;0;0)]}}' >"$tmp/dashboard.json"

# The three gate evaluations are complete documents in the shape their own
# evaluators emit — control/v1/risk-gates.jq, control/v1/kill-switch.jq, and
# control/v1/duty-separation.jq — field for field and ref for ref, because the
# gate program accepts nothing less than an evaluator's whole output. They carry
# the policy set they ran under, the portable core contract, the control
# decision and policy they read, the stage they are about, and the duty
# evaluation the risk and kill-switch evaluators each bind. The duty document is
# written first so the other two can name it.
policy_set='{"id":"control.policy-set.v1","sha256":"42d342f42022ce1fb8c5c8e06c15dd3fd1ef604c215d1ce1ad6f7cc90ba8b747"}'
stage_block='{
  "request_ref":{"id":"stage.docs-typo-fix.request","kind":"stage_request",
    "schema_version":2,
    "sha256":"0cefa6d87f7869958b5ba9f0555a6327e8f49f3047b5bde500c7796024256592"},
  "resolved_profile_ref":{"id":"resolved.docs-typo-fix.v1","kind":"resolved_profile",
    "schema_version":2,
    "sha256":"3bae8e45eea85ad41068735782b4750deb920654c34712b85159195ceec8b688"},
  "result_ref":{"id":"stage.docs-typo-fix.result","kind":"stage_result",
    "schema_version":2,
    "sha256":"0fd5b4136f4b21757eeb1bcbd780cb5baac605663df3a9be4dd7b34c786a045d"}}'
# A fixture generation id, not the shipped one: the guard above forbids the real
# generation id in this file, and the gate program checks the shape only.
core_contract='{
  "generation_id":"g-0bef6d994accaf957358a8f9c833c0ce64bb71fe2bc934b9569277bbe19b8d29",
  "package_ref":{"content_id":"core-contract-package.v2",
    "media_type":"application/vnd.ystack.core-contract+json",
    "sha256":"84d29c91b3018a321dad4c036bc9140cec6ad1c2371e12b8b6a4ac1155e054cb"},
  "semantic_identity":"core.contracts.v2"}'
control_policy_ref='{"content_id":"control.policy.v1",
  "media_type":"application/vnd.ystack.control-policy+json",
  "sha256":"5cc06d264d934d9b143493f47ece687c295c283e8468438d355e3a8c449c95c5"}'
control_decision_ref='{"content_id":"control.decision.docs-typo-fix",
  "media_type":"application/vnd.ystack.control-decision+json",
  "sha256":"47fd3c45b720f57074bf6c666716278c728ccda210df8f95a431dbde0b0b43d0"}'
duty_decision_ref='{"content_id":"control.decision.duty-separation",
  "media_type":"application/vnd.ystack.control-decision+json",
  "sha256":"b4ff4ce76d4dfd90e7a6bace6bae19f95a76d8680ac3778a779d7c883ffc8548"}'
decision_claim_ref='{"content_id":"risk.decision-claim.docs-typo-fix",
  "media_type":"application/vnd.ystack.risk-gate-decision-claim+json",
  "sha256":"ff7a0762578d99a4ebe04b14be2298d9934edebd12e5dc2dcde41ce4633275c6"}'
kill_state_ref='{"schema_version":1,"kind":"kill_switch_state",
  "id":"kill.state.v1",
  "sha256":"e0a9c5c06f7afc6c7804e8033378ac583dba7a5a5adf5e035bb94092ccbe4a32"}'

"$jq_bin" -S -c -n --argjson policy_set "$policy_set" --argjson stage "$stage_block" \
  --argjson core_contract "$core_contract" \
  --argjson policy_ref "$control_policy_ref" \
  --argjson decision_ref "$duty_decision_ref" '
  {schema_version:1,kind:"duty_separation_evaluation",
   id:"stage.docs-typo-fix.result",
   body:{activation_state:"inactive",core_contract:$core_contract,
     decision_ref:$decision_ref,evaluation_mode:"observation-only",
     policy_ref:$policy_ref,policy_set:$policy_set,stage:$stage,
     reference_semantics:"identity-only",verdict:"satisfied",
     reason_ids:["duty.satisfied"]}}' >"$tmp/duty.json"
duty_sha=$(sha256_path "$tmp/duty.json")
"$jq_bin" -S -c -n --argjson policy_set "$policy_set" --argjson stage "$stage_block" \
  --argjson core_contract "$core_contract" \
  --argjson policy_ref "$control_policy_ref" \
  --argjson decision_ref "$control_decision_ref" \
  --argjson claim_ref "$decision_claim_ref" \
  --arg duty_sha "$duty_sha" '
  {schema_version:1,kind:"risk_gate_evaluation",id:"stage.docs-typo-fix.result",
   body:{activation_state:"inactive",authority_effect:"none",
     classification:{declared_tier:"routine",minimum_tier:"routine"},
     core_contract:$core_contract,decision_claim_ref:$claim_ref,
     decision_ref:$decision_ref,
     duty_evaluation_ref:{content_id:"stage.docs-typo-fix.result",
       media_type:"application/vnd.ystack.duty-separation-evaluation+json",
       sha256:$duty_sha},
     policy_ref:$policy_ref,policy_set:$policy_set,stage:$stage,
     evaluation_mode:"observation-only",reference_semantics:"identity-only",
     verdict:"inconclusive",
     reason_ids:["decision.provenance-unqualified"]}}' >"$tmp/risk.json"
"$jq_bin" -S -c -n --argjson policy_set "$policy_set" --arg duty_sha "$duty_sha" \
  --argjson policy_ref "$control_policy_ref" \
  --argjson decision_ref "$control_decision_ref" \
  --argjson duty_decision_ref "$duty_decision_ref" \
  --argjson state_ref "$kill_state_ref" '
  {schema_version:1,kind:"kill_switch_evaluation",
   id:"kill-attempt.docs-typo-fix",
   body:{activation_state:"inactive",authority_effect:"none",
     decision_ref:$decision_ref,duty_decision_ref:$duty_decision_ref,
     duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
       id:"stage.docs-typo-fix.result",sha256:$duty_sha},
     policy_ref:$policy_ref,policy_set:$policy_set,state_ref:$state_ref,
     attempt_ref:{schema_version:1,kind:"kill_switch_attempt",
       id:"kill-attempt.docs-typo-fix",
       sha256:"5f4cf0c000008d393df5f101db749ae7c6a29e967ea15ceb059fe2f84a6a99b9"},
     evaluation_mode:"observation-only",reference_semantics:"identity-only",
     verdict:"satisfied",reason_ids:["kill.cleared-current"]}}' >"$tmp/kill.json"

# A scope claims its evidence by digest, so every evidence document is built
# first and the scope record is written to name exactly the shadow records and
# the three gate evaluations it may count.
set_record_sha() {
  "$jq_bin" -S -c --argjson i "$2" '.body.records[$i]' "$1" >"$tmp/record-digest.json"
  sha256_path "$tmp/record-digest.json"
}
evidence_refs() {
  local set_path=$1 count index refs=()
  count=$("$jq_bin" -r '.body.records | length' "$set_path")
  index=0
  while [ "$index" -lt "$count" ]; do
    refs+=("$("$jq_bin" -S -c -n --arg sha "$(set_record_sha "$set_path" "$index")" \
      --arg id "$("$jq_bin" -r --argjson i "$index" '.body.records[$i].id' "$set_path")" \
      '{schema_version:1,kind:"shadow_reproduction_record",id:$id,sha256:$sha}')")
    index=$((index + 1))
  done
  /usr/bin/printf '%s\n' "${refs[@]}" |
    "$jq_bin" -S -c -s 'sort | unique'
}
# One document ref naming the evaluation in $1 by its own kind, id, and digest.
gate_ref() {
  "$jq_bin" -S -c -n --arg sha "$(sha256_path "$1")" \
    --arg id "$("$jq_bin" -r '.id' "$1")" --arg kind "$("$jq_bin" -r '.kind' "$1")" \
    '{schema_version:1,kind:$kind,id:$id,sha256:$sha}'
}
# $1 = risk, $2 = kill-switch, $3 = duty evaluation the scope claims.
gate_refs() {
  "$jq_bin" -S -c -n --argjson risk "$(gate_ref "$1")" \
    --argjson kill "$(gate_ref "$2")" --argjson duty "$(gate_ref "$3")" \
    '{risk_gate_evaluation_ref:$risk,kill_switch_evaluation_ref:$kill,
      duty_separation_evaluation_ref:$duty}'
}
# $1 = shadow evidence set, $2 = risk, $3 = kill, $4 = duty, $5 = output path.
scope_record() {
  "$jq_bin" -S -c -n --argjson refs "$(evidence_refs "$1")" \
    --argjson gate_refs "$(gate_refs "$2" "$3" "$4")" \
    --argjson identity "$qualified_identity" '
    {schema_version:1,kind:"workflow_scope",id:"scope.docs-typo-fix.v1",
     body:{activation_state:"inactive",authority:"none",enabled:false,
       push_allowed:false,scope_version:"v1",
       target_repository_id:"repo.fixture-target",
       workflow_id:"workflow.docs-typo-fix",task_class:"task.docs-typo-fix",
       risk_tier:"routine",allowed_paths:["docs/guides/setup.md","docs/notes-?.md"],
       required_proof_kinds:["deterministic","independent-review"],
       required_eval_families:["protected-path-credential-network-publisher-boundaries",
         "stale-moved-artifacts"],
       required_shadow_environments:["env.ci-linux-fixture","env.local-macos-fixture"],
       shadow_evidence_refs:$refs,
       qualified_identity:$identity,
       gate_evidence_refs:$gate_refs,
       max_attempts:2}}' >"$5"
}
# $1 = risk, $2 = kill, $3 = duty, $4 = output: the standard scope re-pointed at
# one mutated gate evaluation, so a case can isolate a verdict from a rebinding.
scope_for_gates() {
  scope_record "$tmp/shadow-set.json" "$1" "$2" "$3" "$4"
}
# $1 = mutated shadow evidence set, $2 = output: the standard scope re-pointed at
# that set, so a case can isolate the shadow problem from an unmet claim.
scope_for_shadow() {
  scope_record "$1" "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json" "$2"
}
scope_record "$tmp/shadow-set.json" "$tmp/risk.json" "$tmp/kill.json" \
  "$tmp/duty.json" "$tmp/scope.json"
# Every input the evaluator reads must be canonical, the mode marker included,
# so the committed marker is put into canonical form before it is supplied.
"$jq_bin" -S -c . "$repo_marker" >"$tmp/marker.json"

good=("$tmp/scope.json" "$tmp/shadow-set.json" "$tmp/dashboard.json" "$tmp/risk.json"
  "$tmp/kill.json" "$tmp/duty.json" "$tmp/marker.json")

run_validator "$tmp/scope.json" || fail 'the routine fixture scope was refused'
pass 'the record validator accepts a well-formed routine workflow scope'

mutate_scope() { "$jq_bin" -S -c "$1" "$tmp/scope.json" >"$2"; }
mutate_scope '.body.enabled = true' "$tmp/bad-enabled.json"
mutate_scope '.body.push_allowed = true' "$tmp/bad-push.json"
mutate_scope '.body.workflow_id = "wf.docs"' "$tmp/bad-workflow.json"
mutate_scope '.body.task_class = "docs"' "$tmp/bad-task.json"
mutate_scope '.body.scope_version = "v2"' "$tmp/bad-version.json"
mutate_scope '.body.activation_state = "active"' "$tmp/bad-active.json"
mutate_scope '.body.max_attempts = 0' "$tmp/bad-attempts.json"
mutate_scope '.body.risk_tier = "elevated"' "$tmp/bad-tier.json"
mutate_scope '.body.allowed_paths = ["/etc/passwd"]' "$tmp/bad-absolute.json"
mutate_scope '.body.allowed_paths = ["../outside.md"]' "$tmp/bad-traversal.json"
mutate_scope '.body.allowed_paths = ["docs/**/x.md"]' "$tmp/bad-doublestar.json"
mutate_scope '.body.allowed_paths = ["*/x.md"]' "$tmp/bad-firstwild.json"
mutate_scope '.body.allowed_paths = [".git/config"]' "$tmp/bad-git.json"
mutate_scope '.body.allowed_paths = ["docs\\x.md"]' "$tmp/bad-backslash.json"
mutate_scope '.body.allowed_paths = ["docs/a.md","docs/a.md"]' "$tmp/bad-duplicate.json"
mutate_scope '.body.required_eval_families = ["not-a-family"]' "$tmp/bad-family.json"
mutate_scope '.body.required_proof_kinds = ["vibes"]' "$tmp/bad-proof.json"
mutate_scope '.body.extra = true' "$tmp/bad-extra.json"
mutate_scope 'del(.body.max_attempts)' "$tmp/bad-missing.json"
mutate_scope '.kind = "other_record"' "$tmp/bad-kind.json"
mutate_scope 'del(.body.shadow_evidence_refs)' "$tmp/bad-no-refs.json"
mutate_scope '.body.shadow_evidence_refs = []' "$tmp/bad-empty-refs.json"
mutate_scope '.body.shadow_evidence_refs =
  [{schema_version:1,kind:"shadow_reproduction_record",id:"shadow.x"}]' \
  "$tmp/bad-ref-shape.json"
mutate_scope '.body.shadow_evidence_refs[0].sha256 = "not-a-digest"' \
  "$tmp/bad-ref-digest.json"
mutate_scope '.body.shadow_evidence_refs[0].kind = "other_record"' \
  "$tmp/bad-ref-kind.json"
mutate_scope '.body.shadow_evidence_refs =
  [.body.shadow_evidence_refs[0], .body.shadow_evidence_refs[0]]' \
  "$tmp/bad-ref-duplicate.json"
mutate_scope 'del(.body.qualified_identity)' "$tmp/bad-no-identity.json"
mutate_scope 'del(.body.qualified_identity.stage_request_ref)' "$tmp/bad-no-stage-request.json"
mutate_scope '.id = ("scope." + ("x" * 114))' "$tmp/bad-long-id.json"
mutate_scope 'del(.body.qualified_identity.model_request)' "$tmp/bad-no-model.json"
mutate_scope '.body.qualified_identity.model_request.effort_id = 3' \
  "$tmp/bad-model-shape.json"
mutate_scope '.body.qualified_identity.prompt_refs = []' "$tmp/bad-no-prompt.json"
mutate_scope '.body.qualified_identity.prompt_refs[0].object_id = "not-an-object"' \
  "$tmp/bad-prompt-object.json"
mutate_scope '.body.qualified_identity.adapter_config_refs[0].media_type = "json"' \
  "$tmp/bad-config-media.json"
mutate_scope 'del(.body.qualified_identity.verification_instructions_ref)' \
  "$tmp/bad-no-verification.json"
mutate_scope '.body.qualified_identity.resolved_profile_ref.schema_version = 1' \
  "$tmp/bad-profile-version.json"
mutate_scope '.body.qualified_identity.target_revision.repository_id = "repo.other"' \
  "$tmp/bad-revision-repository.json"
mutate_scope '.body.qualified_identity.target_revision.commit_id = "abc"' \
  "$tmp/bad-revision-commit.json"
mutate_scope 'del(.body.gate_evidence_refs)' "$tmp/bad-no-gate-refs.json"
mutate_scope 'del(.body.gate_evidence_refs.kill_switch_evaluation_ref)' \
  "$tmp/bad-gate-ref-missing.json"
mutate_scope '.body.gate_evidence_refs.risk_gate_evaluation_ref.kind =
  "duty_separation_evaluation"' "$tmp/bad-gate-ref-kind.json"
mutate_scope '.body.gate_evidence_refs.duty_separation_evaluation_ref.sha256 =
  "not-a-digest"' "$tmp/bad-gate-ref-digest.json"
for case_name in bad-attempts bad-tier bad-absolute bad-traversal bad-doublestar \
  bad-firstwild bad-git bad-backslash bad-duplicate bad-family bad-proof bad-extra \
  bad-missing bad-kind bad-no-refs bad-empty-refs bad-ref-shape bad-ref-digest \
  bad-ref-kind bad-ref-duplicate bad-no-identity bad-no-stage-request bad-long-id bad-no-model bad-model-shape \
  bad-no-prompt bad-prompt-object bad-config-media bad-no-verification \
  bad-profile-version bad-revision-repository bad-revision-commit \
  bad-no-gate-refs bad-gate-ref-missing bad-gate-ref-kind bad-gate-ref-digest; do
  expect_validator_error "$case_name" E_SHAPE "$tmp/$case_name.json"
done
for case_name in bad-enabled bad-push bad-workflow bad-task bad-version bad-active; do
  expect_validator_error "$case_name" E_RELATION "$tmp/$case_name.json"
done
pass 'the record validator refuses every malformed or authority-claiming scope'

"$jq_bin" -S . "$tmp/scope.json" >"$tmp/pretty.json"
expect_validator_error non-canonical E_CANONICAL "$tmp/pretty.json"
{ /bin/cat "$tmp/scope.json"; /bin/cat "$tmp/scope.json"; } >"$tmp/multi-root.json"
expect_validator_error multi-root E_PARSE "$tmp/multi-root.json"
/usr/bin/printf '\357\273\277' >"$tmp/bom.json"
/bin/cat "$tmp/scope.json" >>"$tmp/bom.json"
expect_validator_error bom E_PARSE "$tmp/bom.json"
{
  /usr/bin/printf '{"body":{"note":"'
  /usr/bin/head -c 1100000 /dev/zero | /usr/bin/tr '\0' 'a'
  /usr/bin/printf '"},"id":"scope.big.v1","kind":"workflow_scope","schema_version":1}\n'
} >"$tmp/oversized.json"
expect_validator_error oversized E_LIMIT "$tmp/oversized.json"
/bin/ln -s "$tmp/scope.json" "$tmp/symlink.json"
expect_validator_error symlink E_RUNTIME "$tmp/symlink.json"
expect_validator_error absent E_RUNTIME "$tmp/does-not-exist.json"
pass 'the record validator fails closed on bad, oversized, multi-root, and symlink input'

run_evaluator "${good[@]}" >"$tmp/evaluation.json"
run_evaluator "${good[@]}" >"$tmp/evaluation-repeat.json"
/usr/bin/cmp -s "$tmp/evaluation.json" "$tmp/evaluation-repeat.json" ||
  fail 'the evaluation is not byte-identical on repeat'

policy_sha=$(sha256_path "$policy")
scope_sha=$(sha256_path "$tmp/scope.json")
shadow_set_sha=$(sha256_path "$tmp/shadow-set.json")
dashboard_sha=$(sha256_path "$tmp/dashboard.json")
risk_sha=$(sha256_path "$tmp/risk.json")
kill_sha=$(sha256_path "$tmp/kill.json")
duty_sha=$(sha256_path "$tmp/duty.json")
marker_sha=$(sha256_path "$tmp/marker.json")
record_0_sha=$(set_record_sha "$tmp/shadow-set.json" 0)
record_1_sha=$(set_record_sha "$tmp/shadow-set.json" 1)

"$jq_bin" -S -c -n \
  --arg policy_sha "$policy_sha" --arg scope_sha "$scope_sha" \
  --arg shadow_set_sha "$shadow_set_sha" --arg dashboard_sha "$dashboard_sha" \
  --arg risk_sha "$risk_sha" --arg kill_sha "$kill_sha" --arg duty_sha "$duty_sha" \
  --arg marker_sha "$marker_sha" --arg record_0_sha "$record_0_sha" \
  --arg record_1_sha "$record_1_sha" \
  --argjson identity "$qualified_identity" \
  --argjson gate_refs "$(gate_refs "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json")" '
  def policy_ref: {content_id:"scope-qualification-policy",
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha};
  def mode_ref: {content_id:"operating-mode-marker",media_type:"application/json",
    sha256:$marker_sha};
  def scope_ref: {schema_version:1,kind:"workflow_scope",
    id:"scope.docs-typo-fix.v1",sha256:$scope_sha};
  def shadow_record($id;$environment;$outcome;$sha):
    {schema_version:1,kind:"shadow_reproduction_record",id:$id,sha256:$sha,
     environment_id:$environment,outcome:$outcome,
     target_repository_id:"repo.fixture-target"};
  def evidence: {
    duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
      id:"stage.docs-typo-fix.result",sha256:$duty_sha},
    eval_dashboard_ref:{schema_version:1,kind:"eval_dashboard",
      id:"evals.dashboard.v1",sha256:$dashboard_sha},
    kill_switch_evaluation_ref:{schema_version:1,kind:"kill_switch_evaluation",
      id:"kill-attempt.docs-typo-fix",sha256:$kill_sha},
    mode_marker_ref:mode_ref,
    policy_ref:policy_ref,
    risk_evaluation_ref:{schema_version:1,kind:"risk_gate_evaluation",
      id:"stage.docs-typo-fix.result",sha256:$risk_sha},
    shadow_records:([
      shadow_record("shadow.docs-typo-fix.local";"env.local-macos-fixture";
        "reproduced";$record_0_sha),
      shadow_record("shadow.docs-typo-fix.ci";"env.ci-linux-fixture";
        "no-change";$record_1_sha)] | sort_by(.sha256)),
    shadow_set_ref:{schema_version:1,kind:"shadow_evidence_set",
      id:"scope.evidence.docs-typo-fix.v1",sha256:$shadow_set_sha},
    unclaimed_shadow_records:[]};
  {schema_version:1,kind:"scope_qualification_evaluation",
   id:"scope.docs-typo-fix.v1",
   body:{activation_state:"inactive",authority:"none",authority_effect:"none",
     enabled:false,evaluation_mode:"observation-only",
     reference_semantics:"identity-only",
     qualification:{state:"unavailable",
       reason_id:"scope.enablement-requires-operator-pr"},
     operating_mode:{state:"operating",repository_marker:"matched",
       marker_ref:mode_ref},
     outcome:"proposable",reason_ids:["scope.proposable"],
     scope_ref:scope_ref,evidence:evidence,
     proposal:{state:"present",document:{
       schema_version:1,kind:"scope_enablement_proposal",
       id:"proposal.scope.docs-typo-fix.v1",
       body:{activation_state:"inactive",authority:"none",enabled:false,
         push_allowed:false,
         qualification:{state:"unavailable",
           reason_id:"scope.enablement-requires-operator-pr"},
         enablement:{state:"blocked",reason_id:"scope.enablement-requires-operator-pr"},
         operator_action:"Enabling this scope is an independent operator-merged pull request after the operating-mode transition. This document only records what that pull request would add; it turns nothing on and grants no authority.",
         operating_mode:"operating",
         qualification_scope_ref:{purpose:"qualification",
           decision_record_ref:policy_ref,
           subject_ref:{type:"artifact",value:{type:"content",
             value:{content_id:"workflow-scope-record",
               media_type:"application/vnd.ystack.workflow-scope+json",
               sha256:$scope_sha}}},
           scope_sha256:$scope_sha},
         scope_document_ref:scope_ref,
         qualified_identity:$identity,
         gate_evidence_refs:$gate_refs,
         target_repository_id:"repo.fixture-target",
         workflow_id:"workflow.docs-typo-fix",task_class:"task.docs-typo-fix",
         risk_tier:"routine",
         allowed_paths:["docs/guides/setup.md","docs/notes-?.md"],
         required_proof_kinds:["deterministic","independent-review"],
         required_eval_families:[
           "protected-path-credential-network-publisher-boundaries",
           "stale-moved-artifacts"],
         max_attempts:2,
         environments:["env.ci-linux-fixture","env.local-macos-fixture"],
         evidence:evidence}}}}}' >"$tmp/expected.json"
"$jq_bin" -S -c --arg config_sha "$(sha256_path "$tmp/legacy-source.git/config")" '
  .body.outcome="not-proposable" | .body.reason_ids=["scope.sandbox-receipt-missing"] |
  .body.proposal={state:"absent"} |
  .body.evidence.shadow_bundle_facts=(.body.evidence.shadow_records | map({
    record_ref:{schema_version,kind,id,sha256},record_form:"legacy",eligible:false,
    authentication:{state:"missing"},facts:{}})) |
  .body.evidence.git_snapshot={repository_kind:"bare",hash_algorithm:"sha1",config_sha256:$config_sha}
' "$tmp/expected.json" >"$tmp/expected-authenticity.json"
/usr/bin/cmp -s "$tmp/evaluation.json" "$tmp/expected-authenticity.json" ||
  fail "the proposable evaluation does not match the expected document byte for byte: $("$jq_bin" -c '{outcome:.body.outcome,reasons:.body.reason_ids}' "$tmp/evaluation.json" 2>/dev/null)"
pass 'legacy declarations stay readable, byte-identical on repeat, and cannot supply authentic evidence'

"$jq_bin" -e '
  .body.enabled == false and .body.proposal == {state:"absent"} and
  .body.qualification.state == "unavailable" and
  .body.operating_mode.state == "operating" and
  (.body.evidence.shadow_bundle_facts | all(.eligible == false and .authentication.state == "missing")) and
  ((.body | has("grant_ref") or has("activation")) | not)
' "$tmp/evaluation.json" >/dev/null || fail 'legacy declarations claim authority'
pass 'declarations create no proposal, qualification, enablement or authority'

mutate_scope '.body.risk_tier = "high"' "$tmp/tier-high.json"
mutate_scope '.body.risk_tier = "bootstrap"' "$tmp/tier-bootstrap.json"
expect_reasons tier-high '["scope.tier-not-routine"]' "$tmp/tier-high.json" \
  "${good[@]:1}"
expect_reasons tier-bootstrap '["scope.tier-not-routine"]' "$tmp/tier-bootstrap.json" \
  "${good[@]:1}"
# A gate evaluation whose bytes changed is a different document, so each of
# these cases gets a scope that claims the mutated one: the refusal under test is
# the verdict, not an unbound claim.
"$jq_bin" -S -c '.body.classification.minimum_tier = "high"' "$tmp/risk.json" \
  >"$tmp/risk-high.json"
scope_for_gates "$tmp/risk-high.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-high.json"
"$jq_bin" -S -c '.body.verdict = "violated" |
  .body.reason_ids = ["decision.actor-unbound"]' "$tmp/risk.json" \
  >"$tmp/risk-violated.json"
scope_for_gates "$tmp/risk-violated.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-violated.json"
expect_reasons risk-tier-high '["scope.tier-not-routine"]' \
  "$tmp/scope-risk-high.json" "${good[@]:1:2}" "$tmp/risk-high.json" "${good[@]:4}"
expect_reasons risk-violated '["scope.tier-not-routine"]' \
  "$tmp/scope-risk-violated.json" "${good[@]:1:2}" "$tmp/risk-violated.json" \
  "${good[@]:4}"
pass 'only a routine tier the risk gate also classifies routine may be proposed'

protected_index=0
for glob in '.github/workflows/ci.yml' 'config/models.conf' 'AGENTS.md' \
  'control/v1/validate.sh' 'src/migrations/001.sql' 'app/auth/login.ts' \
  'docs/*/page.md' 'secrets/token.txt'; do
  "$jq_bin" -S -c --arg glob "$glob" '.body.allowed_paths = [$glob]' \
    "$tmp/scope.json" >"$tmp/protected.json"
  original_evaluator=$evaluator
  evaluator="$tmp/stale-observation/$protected_index.sh"
  prepare_stale_binding "$protected_index" "$glob" "$evaluator" \
    "$tmp/protected.json" "${good[@]:1}" 2>/dev/null || :
  expect_reasons "protected $glob" '["scope.protected-path"]' "$tmp/protected.json" \
    "${good[@]:1}"
  evaluator=$original_evaluator
  protected_index=$((protected_index + 1))
done
pass 'a scope whose allowed paths touch a protected path is never proposable'
# A leaf wildcard is judged by what it could expand to: src/* and src/auth* can
# reach a protected segment (a bare * is already refused by the record validator,
# which forbids a wildcard in the first segment), while src/*.ts cannot name any
# protected segment and stays allowed.
for glob in 'src/*' 'src/auth*' 'lib/secret?'; do
  "$jq_bin" -S -c --arg glob "$glob" '.body.allowed_paths = [$glob]' \
    "$tmp/scope.json" >"$tmp/protected-leaf.json"
  expect_reasons "protected leaf $glob" '["scope.protected-path"]' "$tmp/protected-leaf.json" \
    "${good[@]:1}"
done
"$jq_bin" -S -c '.body.allowed_paths = ["src/*.ts"]' "$tmp/scope.json" >"$tmp/leaf-allowed.json"
expect_reasons 'leaf wildcard that reaches no protected name' '["scope.proposable"]' \
  "$tmp/leaf-allowed.json" "${good[@]:1}"
pass 'a leaf wildcard is refused when it could expand to a protected name'

# A checkout may be case-insensitive, so a glob that differs from a protected name
# only by case reaches the same file and is refused for the same reason.
for glob in 'agents.md' 'AGENTS.MD' 'src/Auth/login.ts' '.GitHub/workflows/x.yml' \
  'Config/models.conf' 'app/SECRETS/token.txt'; do
  "$jq_bin" -S -c --arg glob "$glob" '.body.allowed_paths = [$glob]' \
    "$tmp/scope.json" >"$tmp/protected-case.json"
  run_validator "$tmp/protected-case.json" || fail "case glob $glob was refused"
  expect_reasons "protected case $glob" '["scope.protected-path"]' \
    "$tmp/protected-case.json" "${good[@]:1}"
done
pass 'protected paths are matched case-insensitively in every segment'

mutate_scope '.body.required_shadow_environments =
  ["env.ci-linux-fixture","env.local-macos-fixture","env.staging-fixture"]' \
  "$tmp/env-missing.json"
expect_reasons shadow-missing '["scope.shadow-evidence-missing"]' \
  "$tmp/env-missing.json" "${good[@]:1}"
# A record whose bytes changed is a different record, so these two fixtures get a
# scope that claims the mutated set: the refusal under test is the outcome or the
# repository, not an unmet claim.
# The inconclusive record is a whole record too: the slice reaches that outcome
# with the environment reason beside it and the materialization and check
# sections it never ran left absent.
"$jq_bin" -S -c '.body.records[0].body |=
  (.outcome = "inconclusive" | .reason_id = "environment.not-satisfied" |
   .environment.evaluation.value.verdict = "inconclusive" |
   .environment.evaluation.value.reason_ids = ["declaration.incomplete"] |
   .materialization = {state:"absent",reason_id:"materialization.not-attempted"} |
   .check.execution = {state:"absent",reason_id:"check.not-attempted"})' \
  "$tmp/shadow-set.json" >"$tmp/shadow-inconclusive.json"
scope_for_shadow "$tmp/shadow-inconclusive.json" "$tmp/scope-inconclusive.json"
expect_reasons shadow-inconclusive \
  '["scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-inconclusive.json" "$tmp/shadow-inconclusive.json" "${good[@]:2}"
"$jq_bin" -S -c '.body.records[0].body |= (.target_repository_id = "repo.other" |
  .git_revision_ref.repository_id = "repo.other" |
  .materialization.value.source.repository_id = "repo.other")' \
  "$tmp/shadow-set.json" >"$tmp/shadow-other-repo.json"
scope_for_shadow "$tmp/shadow-other-repo.json" "$tmp/scope-other-repo.json"
expect_reasons shadow-other-repository '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-repo.json" "$tmp/shadow-other-repo.json" "${good[@]:2}"
"$jq_bin" -S -c '.body.records[1] = .body.records[0]' "$tmp/shadow-set.json" \
  >"$tmp/shadow-replayed.json"
expect_evaluator_error shadow-replayed E_RELATION \
  "${good[@]:0:1}" "$tmp/shadow-replayed.json" "${good[@]:2}"
# An outcome outside the shadow slice's vocabulary is not a record this
# evaluator understands, even when it is claimed: the set is malformed.
"$jq_bin" -S -c '.body.records[0].body.outcome = "failed"' "$tmp/shadow-set.json" \
  >"$tmp/shadow-unknown-outcome.json"
scope_for_shadow "$tmp/shadow-unknown-outcome.json" "$tmp/scope-unknown-outcome.json"
expect_reasons shadow-unknown-outcome \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-unknown-outcome.json" "$tmp/shadow-unknown-outcome.json" "${good[@]:2}"
pass 'shadow evidence must cover every environment, be conclusive, use a known outcome, and be distinct'

# A hand-written record carrying only the fields the gate reads - the envelope,
# the inactive/none markers, an accepted outcome, the repository, the revision,
# and an environment id - is not a shadow output. It is refused as malformed, so
# a stub can never back a scope.
"$jq_bin" -S -c --argjson revision "$fixture_revision" '
  .body.records[0] =
    {schema_version:1,kind:"shadow_reproduction_record",
     id:"shadow.docs-typo-fix.local",
     body:{activation_state:"inactive",authority:"none",deploy_authority:"none",
       shadow:true,
       qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
       outcome:"reproduced",target_repository_id:"repo.fixture-target",
       git_revision_ref:$revision,
       environment:{environment_id:"env.local-macos-fixture"}}}' \
  "$tmp/shadow-set.json" >"$tmp/shadow-stub.json"
scope_for_shadow "$tmp/shadow-stub.json" "$tmp/scope-stub.json"
expect_evaluator_error shadow-stub-record E_RELATION \
  "$tmp/scope-stub.json" "$tmp/shadow-stub.json" "${good[@]:2}"
pass 'a stub carrying only the fields the gate reads is not a shadow record'

# The scope counts only the records it claims by digest. A record it never named
# is ignored even when it would have covered a required environment, and it is
# reported so the operator sees what was left out.
"$jq_bin" -S -c '.body.shadow_evidence_refs =
  [.body.shadow_evidence_refs[] | select(.id == "shadow.docs-typo-fix.ci")]' \
  "$tmp/scope.json" >"$tmp/scope-unclaimed.json"
run_validator "$tmp/scope-unclaimed.json" || fail 'a one-ref scope was refused'
expect_reasons shadow-unclaimed '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-unclaimed.json" "${good[@]:1}"
run_evaluator "$tmp/scope-unclaimed.json" "${good[@]:1}" >"$tmp/evaluation-unclaimed.json"
"$jq_bin" -e --arg sha "$record_0_sha" '
  .body.evidence.unclaimed_shadow_records == [$sha] and
  .body.proposal == {state:"absent"}' "$tmp/evaluation-unclaimed.json" >/dev/null ||
  fail 'the ignored record was not reported by digest'
# A claim the supplied evidence never answers is missing evidence, not a pass.
"$jq_bin" -S -c '.body.shadow_evidence_refs = ((.body.shadow_evidence_refs +
  [{schema_version:1,kind:"shadow_reproduction_record",
    id:"shadow.docs-typo-fix.absent",
    sha256:"0000000000000000000000000000000000000000000000000000000000000000"}]) |
  sort | unique)' "$tmp/scope.json" >"$tmp/scope-dangling-ref.json"
run_validator "$tmp/scope-dangling-ref.json" || fail 'a three-ref scope was refused'
expect_evaluator_error shadow-dangling-ref E_RELATION \
  "$tmp/scope-dangling-ref.json" "${good[@]:1}"
pass 'only the shadow records a scope claims by digest count as its evidence'

mutate_scope '.body.required_eval_families = ["malicious-instructions"]' \
  "$tmp/eval-declared.json"
expect_reasons eval-unseeded '["scope.eval-family-unseeded"]' \
  "$tmp/eval-declared.json" "${good[@]:1}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.failed = 1 | .cases.passed -= 1 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-failing.json"
expect_reasons eval-failing '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-failing.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.inconclusive = 1 | .cases.passed -= 1 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-inconclusive.json"
expect_reasons eval-inconclusive '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-inconclusive.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases = {total:0,passed:0,failed:0,inconclusive:0} else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-empty.json"
expect_reasons eval-no-cases '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-empty.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases = {total:1,passed:0,failed:0,inconclusive:0} else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-unpassed.json"
expect_reasons eval-no-passing-case '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' "${good[@]:0:2}" \
  "$tmp/dashboard-unpassed.json" "${good[@]:3}"
# A dashboard that lists a required family twice, failing once and passing once,
# must not let the later entry win: duplicate family ids are malformed.
"$jq_bin" -S -c '(.body.families | map(select(.family_id == "stale-moved-artifacts"))[0]) as $pass |
  .body.families |= (map(if .family_id == "stale-moved-artifacts" then .cases.failed = 1 | .cases.passed -= 1 else . end) |
    (map(.family_id != "stale-moved-artifacts") | index(true)) as $slot | .[$slot] = $pass)' \
  "$tmp/dashboard.json" >"$tmp/dashboard-duplicate.json"
"$jq_bin" -e '[.body.families[] | select(.family_id == "stale-moved-artifacts")] | length == 2' \
  "$tmp/dashboard-duplicate.json" >/dev/null || fail 'duplicate-family fixture must repeat the family'
"$jq_bin" -e '.body.families | length == 9' "$tmp/dashboard-duplicate.json" >/dev/null ||
  fail 'duplicate-family fixture must keep nine entries'
"$jq_bin" -S -c '.body.families |= map(if .family_id == "stale-moved-artifacts"
  then .cases.skipped = 0 else . end)' "$tmp/dashboard.json" >"$tmp/dashboard-extra-counter.json"
expect_reasons eval-extra-counter '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-extra-counter.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families |= map(if .family_id == "stale-moved-artifacts"
  then .seed_sources = [] else . end)' "$tmp/dashboard.json" >"$tmp/dashboard-seeded-no-source.json"
expect_reasons eval-seeded-without-source '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-seeded-no-source.json" "${good[@]:3}"
expect_reasons eval-duplicate-family '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-duplicate.json" "${good[@]:3}"
pass 'every required eval family must be seeded and free of failing or inconclusive grades'

# Each verdict carries the reasons its own evaluator emits with it: a
# kill-switch or duty evaluation that keeps a cleared or satisfied reason beside
# another verdict is not a document either evaluator produces.
for verdict in violated inconclusive; do
  case "$verdict" in
    violated)
      kill_reason=kill.state-invalid
      duty_reason=actual.capability-mismatch
      # The reasons the other two evaluators emit beside this duty verdict:
      # control/v1/risk-gates.jq puts duty.violated among its violations, which
      # makes its own verdict violated, and control/v1/kill-switch.jq puts
      # kill.duty-violated among its violations, which makes its verdict
      # violated too.
      risk_verdict=violated
      risk_reasons='["duty.violated"]'
      kill_duty_verdict=violated
      kill_duty_reasons='["kill.duty-violated"]'
      # A violated duty therefore never stands alone: the risk gate reporting a
      # violation is not routine, and the kill switch is not clear.
      duty_expected='["scope.duty-violation","scope.kill-switch","scope.tier-not-routine"]'
      ;;
    *)
      # kill.duty-inconclusive belongs to an inconclusive duty verdict, so a
      # kill-switch case beside the satisfied duty fixture uses one of that
      # evaluator's duty-independent unknowns instead.
      kill_reason=kill.scope-missing.repository
      duty_reason=actual.capability-unclassified
      risk_verdict=inconclusive
      risk_reasons='["decision.provenance-unqualified","duty.inconclusive"]'
      kill_duty_verdict=inconclusive
      kill_duty_reasons='["kill.duty-inconclusive"]'
      duty_expected='["scope.duty-violation","scope.kill-switch"]'
      ;;
  esac
  "$jq_bin" -S -c --arg verdict "$verdict" --arg reason "$kill_reason" \
    '.body.verdict = $verdict | .body.reason_ids = [$reason]' \
    "$tmp/kill.json" >"$tmp/kill-$verdict.json"
  scope_for_gates "$tmp/risk.json" "$tmp/kill-$verdict.json" "$tmp/duty.json" \
    "$tmp/scope-kill-$verdict.json"
  expect_reasons "kill-$verdict" '["scope.kill-switch"]' \
    "$tmp/scope-kill-$verdict.json" "${good[@]:1:3}" "$tmp/kill-$verdict.json" \
    "${good[@]:5}"
  "$jq_bin" -S -c --arg verdict "$verdict" --arg reason "$duty_reason" \
    '.body.verdict = $verdict | .body.reason_ids = [$reason]' \
    "$tmp/duty.json" >"$tmp/duty-$verdict.json"
  # The risk and kill evaluations are recomputed over the mutated duty bytes, so
  # they name its digest, and they carry the duty reasons their own evaluators
  # emit for that verdict, so the three still agree with each other.
  duty_verdict_sha=$(sha256_path "$tmp/duty-$verdict.json")
  "$jq_bin" -S -c --arg sha "$duty_verdict_sha" --arg verdict "$risk_verdict" \
    --argjson reasons "$risk_reasons" \
    '.body.duty_evaluation_ref.sha256 = $sha | .body.verdict = $verdict |
     .body.reason_ids = $reasons' \
    "$tmp/risk.json" >"$tmp/risk-duty-$verdict.json"
  "$jq_bin" -S -c --arg sha "$duty_verdict_sha" --arg verdict "$kill_duty_verdict" \
    --argjson reasons "$kill_duty_reasons" \
    '.body.duty_evaluation_ref.sha256 = $sha | .body.verdict = $verdict |
     .body.reason_ids = $reasons' \
    "$tmp/kill.json" >"$tmp/kill-duty-$verdict.json"
  scope_for_gates "$tmp/risk-duty-$verdict.json" "$tmp/kill-duty-$verdict.json" \
    "$tmp/duty-$verdict.json" "$tmp/scope-duty-$verdict.json"
  expect_reasons "duty-$verdict" "$duty_expected" \
    "$tmp/scope-duty-$verdict.json" "${good[@]:1:2}" "$tmp/risk-duty-$verdict.json" \
    "$tmp/kill-duty-$verdict.json" "$tmp/duty-$verdict.json" "${good[@]:6}"
done
pass 'a live kill switch or an unsatisfied duty separation blocks the proposal'
# A kill-switch evaluation that names this duty evaluation by id but over other
# bytes (a different digest) is not evidence about the same attempt.
"$jq_bin" -S -c '.body.duty_evaluation_ref.sha256 = ("d" * 64)' "$tmp/kill.json" >"$tmp/kill-other-duty-bytes.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-other-duty-bytes.json" "$tmp/duty.json" \
  "$tmp/scope-kill-other-duty-bytes.json"
expect_reasons kill-other-duty-bytes '["scope.malformed"]' \
  "$tmp/scope-kill-other-duty-bytes.json" "${good[@]:1:3}" "$tmp/kill-other-duty-bytes.json" \
  "${good[@]:5}"
pass 'gate evaluations must name the duty evaluation by digest, not only by id'
# A gate evaluation whose envelope id was renamed away from the document it
# describes is not that evaluator's output, even when the scope re-claims it.
"$jq_bin" -S -c '.id = "stage.renamed.result"' "$tmp/risk.json" >"$tmp/risk-renamed.json"
scope_for_gates "$tmp/risk-renamed.json" "$tmp/kill.json" "$tmp/duty.json" "$tmp/scope-risk-renamed.json"
expect_reasons risk-renamed-id '["scope.malformed"]' \
  "$tmp/scope-risk-renamed.json" "${good[@]:1:2}" "$tmp/risk-renamed.json" "${good[@]:4}"
"$jq_bin" -S -c '.id = "kill-attempt.renamed"' "$tmp/kill.json" >"$tmp/kill-renamed.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-renamed.json" "$tmp/duty.json" "$tmp/scope-kill-renamed.json"
expect_reasons kill-renamed-id '["scope.malformed"]' \
  "$tmp/scope-kill-renamed.json" "${good[@]:1:3}" "$tmp/kill-renamed.json" "${good[@]:5}"
pass 'a gate evaluation whose id does not match the document it describes is malformed'
# Gate outputs about another stage request never qualify this scope, even when
# they are valid and use the same resolved profile.
other_request='{"id":"stage.other-work.request","kind":"stage_request","schema_version":2,"sha256":"'"$(printf 'e%.0s' {1..64})"'"}'
"$jq_bin" -S -c --argjson req "$other_request" '.body.stage.request_ref = $req' "$tmp/risk.json" >"$tmp/risk-other-stage.json"
"$jq_bin" -S -c --argjson req "$other_request" '.body.stage.request_ref = $req' "$tmp/duty.json" >"$tmp/duty-other-stage.json"
other_duty_sha=$(sha256_path "$tmp/duty-other-stage.json")
"$jq_bin" -S -c --arg sha "$other_duty_sha" '.body.duty_evaluation_ref.sha256 = $sha' "$tmp/risk-other-stage.json" >"$tmp/risk-other-stage2.json"
"$jq_bin" -S -c --arg sha "$other_duty_sha" '.body.duty_evaluation_ref.sha256 = $sha' "$tmp/kill.json" >"$tmp/kill-other-stage.json"
scope_for_gates "$tmp/risk-other-stage2.json" "$tmp/kill-other-stage.json" "$tmp/duty-other-stage.json" \
  "$tmp/scope-other-stage.json"
expect_reasons gates-other-stage-request '["scope.malformed"]' \
  "$tmp/scope-other-stage.json" "${good[@]:1:2}" "$tmp/risk-other-stage2.json" \
  "$tmp/kill-other-stage.json" "$tmp/duty-other-stage.json" "${good[@]:6}"
pass 'gate evidence must be about the scope'"'"'s own stage request'

# A shadow record that claims any deploy authority is not an observation-only
# shadow record, whatever else it says.
"$jq_bin" -S -c '.body.records[0].body.deploy_authority = "grant"' "$tmp/shadow-set.json" \
  >"$tmp/shadow-deploy-authority.json"
scope_record "$tmp/shadow-deploy-authority.json" "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-deploy-authority.json"
expect_reasons shadow-deploy-authority \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-deploy-authority.json" "$tmp/shadow-deploy-authority.json" "${good[@]:2}"
pass 'a shadow record claiming deploy authority is refused as malformed'

# A gate evaluation the scope did not name is not the one it was qualified
# against, even when its verdict is fine: the digest the driver measured has to
# equal the digest the scope claimed.
"$jq_bin" -S -c '.body.reason_ids =
  ["decision.provenance-unqualified","duty.inconclusive"]' "$tmp/risk.json" \
  >"$tmp/risk-restated.json"
expect_reasons risk-digest-mismatch '["scope.malformed"]' "${good[@]:0:3}" \
  "$tmp/risk-restated.json" "${good[@]:4}"
"$jq_bin" -S -c '.body.state_ref.sha256 =
  "1ad2df26c1b0c9d5e3b3f0e0a3b6cf3f70b6e0e8e6b74ff96f5d0e1c6a0a3e12"' \
  "$tmp/kill.json" >"$tmp/kill-restated.json"
expect_reasons kill-digest-mismatch '["scope.malformed"]' "${good[@]:0:4}" \
  "$tmp/kill-restated.json" "${good[@]:5}"
# The three must belong together: one policy set, one stage, one duty
# evaluation. Each of these is a satisfied verdict produced for something else.
"$jq_bin" -S -c '.body.policy_set.id = "control.policy-set.other"' "$tmp/kill.json" \
  >"$tmp/kill-other-policy-set.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-other-policy-set.json" "$tmp/duty.json" \
  "$tmp/scope-kill-other-policy-set.json"
expect_reasons kill-other-policy-set '["scope.malformed"]' \
  "$tmp/scope-kill-other-policy-set.json" "${good[@]:1:3}" \
  "$tmp/kill-other-policy-set.json" "${good[@]:5}"
"$jq_bin" -S -c '.body.stage.request_ref.id = "stage.other.request"' "$tmp/duty.json" \
  >"$tmp/duty-other-stage.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty-other-stage.json" \
  "$tmp/scope-duty-other-stage.json"
expect_reasons duty-other-stage '["scope.malformed"]' \
  "$tmp/scope-duty-other-stage.json" "${good[@]:1:4}" "$tmp/duty-other-stage.json" \
  "${good[@]:6}"
"$jq_bin" -S -c '.body.duty_evaluation_ref.id = "stage.other.result"' "$tmp/kill.json" \
  >"$tmp/kill-other-duty.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-other-duty.json" "$tmp/duty.json" \
  "$tmp/scope-kill-other-duty.json"
expect_reasons kill-other-duty '["scope.malformed"]' \
  "$tmp/scope-kill-other-duty.json" "${good[@]:1:3}" "$tmp/kill-other-duty.json" \
  "${good[@]:5}"
# The scope's own resolved profile is the one the risk and duty evaluations must
# be about; a scope that records a different profile was never qualified by them.
"$jq_bin" -S -c '.body.qualified_identity.resolved_profile_ref.id =
  "resolved.other.v1"' "$tmp/scope.json" >"$tmp/scope-other-profile.json"
run_validator "$tmp/scope-other-profile.json" ||
  fail 'a scope naming another resolved profile was refused as malformed'
# The identity is also what the shadow records are bound to, so a scope that
# records another profile loses its shadow evidence as well as its gate binding.
expect_reasons scope-other-profile \
  '["scope.malformed","scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-profile.json" "${good[@]:1}"
pass 'gate evidence counts only when the scope named it and the three agree'

# Binding the three by digest is not enough: their contents have to agree about
# what the duty evaluation said, because the real evaluators put the duty verdict
# into their own reasons. A pair no run could have produced is malformed, and the
# verdict reasons that follow from each document stand beside it.
"$jq_bin" -S -c '.body.reason_ids = ["decision.actor-unbound"]' \
  "$tmp/risk-duty-violated.json" >"$tmp/risk-duty-dropped.json"
scope_for_gates "$tmp/risk-duty-dropped.json" "$tmp/kill-duty-violated.json" \
  "$tmp/duty-violated.json" "$tmp/scope-risk-duty-dropped.json"
expect_reasons risk-missing-duty-violated \
  '["scope.duty-violation","scope.kill-switch","scope.malformed","scope.tier-not-routine"]' \
  "$tmp/scope-risk-duty-dropped.json" "${good[@]:1:2}" "$tmp/risk-duty-dropped.json" \
  "$tmp/kill-duty-violated.json" "$tmp/duty-violated.json" "${good[@]:6}"
"$jq_bin" -S -c '.body.verdict = "violated" | .body.reason_ids = ["duty.violated"]' \
  "$tmp/risk.json" >"$tmp/risk-claims-duty-violated.json"
scope_for_gates "$tmp/risk-claims-duty-violated.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-claims-duty-violated.json"
expect_reasons risk-claims-duty-violated '["scope.malformed","scope.tier-not-routine"]' \
  "$tmp/scope-risk-claims-duty-violated.json" "${good[@]:1:2}" \
  "$tmp/risk-claims-duty-violated.json" "${good[@]:4}"
# The same contradiction the other way round and without any verdict problem to
# hide behind: an unknown the risk gate only emits for an inconclusive duty,
# beside a duty evaluation that is satisfied.
scope_for_gates "$tmp/risk-restated.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-claims-duty-inconclusive.json"
expect_reasons risk-claims-duty-inconclusive '["scope.malformed"]' \
  "$tmp/scope-risk-claims-duty-inconclusive.json" "${good[@]:1:2}" \
  "$tmp/risk-restated.json" "${good[@]:4}"
# kill.duty-unverifiable is what the kill-switch evaluator emits for a duty
# document it could not verify, which a claimed and fully checked duty evaluation
# is not.
"$jq_bin" -S -c '.body.verdict = "inconclusive" |
  .body.reason_ids = ["kill.duty-unverifiable"]' "$tmp/kill.json" \
  >"$tmp/kill-duty-unverifiable.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-duty-unverifiable.json" "$tmp/duty.json" \
  "$tmp/scope-kill-duty-unverifiable.json"
expect_reasons kill-duty-unverifiable '["scope.kill-switch","scope.malformed"]' \
  "$tmp/scope-kill-duty-unverifiable.json" "${good[@]:1:3}" \
  "$tmp/kill-duty-unverifiable.json" "${good[@]:5}"
pass 'the three gate evaluations must agree with each other about the duty verdict'

# A gate evaluation is accepted only in its own evaluator's complete output
# shape, so a document that carries the envelope, the markers, and a verdict but
# is missing an evaluator field, carries one too many, names a ref of the wrong
# kind, or states a verdict its reasons do not support, is malformed. Each case
# claims the mutated document, so the refusal is the shape and not an unbound
# claim, and the verdict reason for that gate stands beside scope.malformed
# because a document that is not a real evaluation proves no verdict either.
"$jq_bin" -S -c 'del(.body.state_ref)' "$tmp/kill.json" >"$tmp/kill-no-state.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-no-state.json" "$tmp/duty.json" \
  "$tmp/scope-kill-no-state.json"
expect_reasons kill-missing-state-ref '["scope.kill-switch","scope.malformed"]' \
  "$tmp/scope-kill-no-state.json" "${good[@]:1:3}" "$tmp/kill-no-state.json" \
  "${good[@]:5}"
"$jq_bin" -S -c '.body.extra_field = "unexpected"' "$tmp/risk.json" \
  >"$tmp/risk-extra-key.json"
scope_for_gates "$tmp/risk-extra-key.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-extra-key.json"
expect_reasons risk-extra-body-key '["scope.malformed","scope.tier-not-routine"]' \
  "$tmp/scope-risk-extra-key.json" "${good[@]:1:2}" "$tmp/risk-extra-key.json" \
  "${good[@]:4}"
"$jq_bin" -S -c '.body.reason_ids =
  ["kill.cleared-current","kill.state-invalid"]' "$tmp/kill.json" \
  >"$tmp/kill-extra-reason.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-extra-reason.json" "$tmp/duty.json" \
  "$tmp/scope-kill-extra-reason.json"
expect_reasons kill-satisfied-extra-reason '["scope.kill-switch","scope.malformed"]' \
  "$tmp/scope-kill-extra-reason.json" "${good[@]:1:3}" \
  "$tmp/kill-extra-reason.json" "${good[@]:5}"
"$jq_bin" -S -c '.body.stage.result_ref.kind = "stage_request"' "$tmp/duty.json" \
  >"$tmp/duty-wrong-kind.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty-wrong-kind.json" \
  "$tmp/scope-duty-wrong-kind.json"
expect_reasons duty-wrong-kind-ref '["scope.duty-violation","scope.malformed"]' \
  "$tmp/scope-duty-wrong-kind.json" "${good[@]:1:4}" "$tmp/duty-wrong-kind.json" \
  "${good[@]:6}"
pass 'a gate evaluation missing, exceeding, or contradicting its evaluator output is malformed'

# Qualification is attached to one exact target version. Shadow evidence from a
# different revision is evidence about a different target, so it does not count.
"$jq_bin" -S -c --argjson revision "$other_revision" \
  '.body.qualified_identity.target_revision = $revision' "$tmp/scope.json" \
  >"$tmp/scope-other-revision.json"
run_validator "$tmp/scope-other-revision.json" ||
  fail 'a scope naming another target revision was refused as malformed'
expect_reasons scope-other-revision '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-revision.json" "${good[@]:1}"
"$jq_bin" -S -c --argjson revision "$other_revision" \
  '.body.records[0].body |= (.git_revision_ref = $revision |
   .materialization.value.source.commit_id = $revision.commit_id |
   .materialization.value.candidate.commit_id = $revision.commit_id |
   .materialization.value.candidate.parent_commit_id = $revision.commit_id)' \
  "$tmp/shadow-set.json" >"$tmp/shadow-other-revision.json"
scope_for_shadow "$tmp/shadow-other-revision.json" "$tmp/scope-shadow-revision.json"
expect_reasons shadow-other-revision '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-shadow-revision.json" "$tmp/shadow-other-revision.json" "${good[@]:2}"
pass 'shadow evidence counts only at the target revision the scope records'

# Qualification is attached to the whole recorded identity, not only to the
# target revision. A record produced under a different model, profile, adapter
# config, prompt, or skill version is evidence about a different scope, so it
# does not cover the environment it names.
"$jq_bin" -S -c '.body.records[0].body.qualified_identity.model_request.model_id =
  "model.other"' "$tmp/shadow-set.json" >"$tmp/shadow-other-identity.json"
scope_for_shadow "$tmp/shadow-other-identity.json" "$tmp/scope-other-identity.json"
expect_reasons shadow-other-identity '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-identity.json" "$tmp/shadow-other-identity.json" "${good[@]:2}"
# The same mismatch from the scope's side: change one identity field and the
# scope has to earn its own evidence rather than inherit this one's.
"$jq_bin" -S -c '.body.qualified_identity.model_request.model_id = "model.other"' \
  "$tmp/scope.json" >"$tmp/scope-other-model.json"
run_validator "$tmp/scope-other-model.json" ||
  fail 'a scope naming another model was refused as malformed'
expect_reasons scope-other-model '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-model.json" "${good[@]:1}"
pass 'shadow evidence counts only under the qualified identity the scope records'

"$jq_bin" -S -c '.status = "operating"' "$tmp/marker.json" >"$tmp/marker-stale.json"
expect_reasons mode-stale-marker '["scope.mode-construction"]' "${good[@]:0:6}" \
  "$tmp/marker-stale.json"
"$jq_bin" -S -c '{status:"active"}' "$tmp/marker.json" >"$tmp/marker-shape.json"
expect_reasons mode-marker-shape '["scope.mode-construction"]' "${good[@]:0:6}" \
  "$tmp/marker-shape.json"
pass 'a marker that disagrees with the committed one leaves the mode unknown'

# The mode marker is an input like any other: it is snapshotted, size-bounded,
# required to be exactly one JSON text, and required to be canonical, so a
# pretty-printed or two-root marker never reaches the gate program and never has
# its digest recorded.
"$jq_bin" -S '.status = "retired"' "$tmp/marker.json" >"$tmp/marker-pretty.json"
expect_evaluator_error marker-non-canonical E_CANONICAL "${good[@]:0:6}" \
  "$tmp/marker-pretty.json"
{ /bin/cat "$tmp/marker.json"; /bin/cat "$tmp/marker.json"; } \
  >"$tmp/marker-multi-root.json"
expect_evaluator_error marker-multi-root E_PARSE "${good[@]:0:6}" \
  "$tmp/marker-multi-root.json"
pass 'the mode marker is canonicalized and single-rooted like every other input'

# The last four cases are what the whole-shape check adds: a record missing one
# of the slice's blocks, a record carrying one key more than the slice emits, a
# reproduced outcome whose materialization never ran, and a qualification with a
# reason id the slice never writes are all records no shadow run produced.
for malformed_case in 'del(.body.records[0].body.shadow)' \
  '.body.records[0].body.materialization.value.outcome = "changed"' \
  '.body.records[0].body.authority = "publisher"' \
  '.body.records[0].body.activation_state = "active"' \
  '.body.records[0].kind = "other_record"' \
  '.body.records = []' \
  'del(.body.records[0].body.materialization)' \
  '.body.records[0].body.replayed_from = "shadow.other"' \
  '.body.records[0].body.materialization =
     {state:"absent",reason_id:"materialization.not-attempted"}' \
  '.body.records[0].body.qualification.reason_id = "shadow.qualified"' \
  'del(.body.records[0].body.qualified_identity)' \
  'del(.body.records[0].body.qualified_identity_ref)' \
  '.body.records[0].body.qualified_identity.extra = true' \
  '.body.records[0].body.qualified_identity_ref.content_id = "shadow-other"'; do
  "$jq_bin" -S -c "$malformed_case" "$tmp/shadow-set.json" >"$tmp/shadow-malformed.json"
  expect_evaluator_error "malformed shadow $malformed_case" E_RELATION \
    "${good[@]:0:1}" "$tmp/shadow-malformed.json" "${good[@]:2}"
done
"$jq_bin" -S -c '.body.families = (.body.families[0:8])' "$tmp/dashboard.json" \
  >"$tmp/dashboard-malformed.json"
expect_reasons malformed-dashboard \
  '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-malformed.json" "${good[@]:3}"
"$jq_bin" -S -c '.kind = "other_evaluation"' "$tmp/kill.json" >"$tmp/kill-malformed.json"
expect_reasons malformed-kill '["scope.kill-switch","scope.malformed"]' \
  "${good[@]:0:4}" "$tmp/kill-malformed.json" "${good[@]:5}"
pass 'evidence that parses but does not hold its shape is refused as malformed'

# The dashboard is judged against the evals framework's whole emitted shape, so a
# document carrying only the blocks this evaluator reads is not a dashboard. One
# of the framework's real top-level blocks missing, or one key more than it
# emits, is malformed, and the eval reasons follow because a dashboard that is
# not a dashboard grades nothing.
for dashboard_case in 'del(.body.flow)' 'del(.body.telemetry)' \
  'del(.body.evaluator)' 'del(.body.catalog_ref)' 'del(.body.coverage)' \
  '.body.extra_block = {}' '.extra = true' \
  '.body.core_contract.semantic_identity = "core.contracts.v1"' \
  '.body.coverage.families_total = 8' \
  '.body.observed_at = "2026-02-30T00:00:00Z"' \
  '.body.evaluator.content.body.runtime.host_os = "plan9"' \
  '.body.catalog_ref.kind = "eval_seed_set"'; do
  "$jq_bin" -S -c "$dashboard_case" "$tmp/dashboard.json" \
    >"$tmp/dashboard-shape.json"
  expect_reasons "dashboard shape $dashboard_case" \
    '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
    "${good[@]:0:2}" "$tmp/dashboard-shape.json" "${good[@]:3}"
done
pass 'the dashboard is validated against the evals framework complete emitted shape'

expect_evaluator_error evaluator-non-canonical E_CANONICAL "$tmp/pretty.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-multi-root E_PARSE "$tmp/multi-root.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-oversized E_LIMIT "${good[@]:0:1}" \
  "$tmp/oversized.json" "${good[@]:2}"
expect_evaluator_error evaluator-symlink E_RUNTIME "$tmp/symlink.json" "${good[@]:1}"
expect_evaluator_error evaluator-absent E_RUNTIME "$tmp/does-not-exist.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-scope-shape E_SHAPE "$tmp/bad-kind.json" "${good[@]:1}"
expect_evaluator_error evaluator-scope-relation E_RELATION "$tmp/bad-enabled.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-arity E_USAGE "${good[@]:0:6}"
/usr/bin/printf '[1,2]\n' >"$tmp/array-root.json"
expect_evaluator_error evaluator-array-root E_PARSE "$tmp/array-root.json" "${good[@]:1}"
pass 'the evaluator fails closed on bad, oversized, multi-root, symlink, and short calls'

# A scope record that moved is a different record: the evaluation binds the exact
# bytes it read, so no earlier proposal can be replayed against new content.
"$jq_bin" -S -c '.body.max_attempts = 3' "$tmp/scope.json" >"$tmp/scope-moved.json"
run_evaluator "$tmp/scope-moved.json" "${good[@]:1}" >"$tmp/evaluation-moved.json"
moved_sha=$("$jq_bin" -r '.body.scope_ref.sha256' "$tmp/evaluation-moved.json")
[ "$moved_sha" != "$scope_sha" ] || fail 'a moved scope kept the old digest'
/usr/bin/cmp -s "$tmp/evaluation.json" "$tmp/evaluation-moved.json" &&
  fail 'a moved scope produced the same evaluation'
pass 'the evaluation is bound to the exact bytes of every input it read'

# The same component in a tree with no committed mode marker: the supplied marker
# is then all there is, and the evaluator still never enables anything.
fake_repo="$tmp/portable/scope/v1"
/bin/mkdir -p "$fake_repo"
for component_dir in core shadow control enforcement adapters preparation telemetry maintenance evals scripts; do
  /bin/cp -R "$root/$component_dir" "$tmp/portable/$component_dir"
done
for shipped in scope-policy.json workflow-scope.jq scope-gates.jq validate-scope.sh \
  evaluate-scope.sh read-shadow-evidence.py; do
  /bin/cp "$root/scope/v1/$shipped" "$fake_repo/$shipped"
done
/bin/chmod 0500 "$fake_repo/validate-scope.sh" "$fake_repo/evaluate-scope.sh"
"$jq_bin" -S -c -n '{schema_version:1,status:"retired"}' >"$tmp/marker-operating.json"
PATH="$bin:/usr/bin:/bin" "$fake_repo/evaluate-scope.sh" evaluate "${good[@]:0:6}" \
  "$tmp/marker-operating.json" "$tmp/legacy-bundles" "$tmp/legacy-source.git" >"$tmp/evaluation-portable.json"
"$jq_bin" -e '
  .body.outcome == "not-proposable" and .body.reason_ids == ["scope.sandbox-receipt-missing"] and .body.enabled == false and
  .body.operating_mode == {state:"operating",repository_marker:"absent",
    marker_ref:.body.evidence.mode_marker_ref} and
  .body.proposal == {state:"absent"} and .body.qualification.state == "unavailable"
' "$tmp/evaluation-portable.json" >/dev/null ||
  fail 'the portable copy enabled something or misread the mode'
pass 'with no committed mode marker the outcome is still only a blocked proposal'
# In that same portable tree an unknown status is not operating: only "active"
# and "retired" mean anything, and a typo fails closed.
"$jq_bin" -S -c -n '{schema_version:1,status:"activ"}' >"$tmp/marker-typo.json"
PATH="$bin:/usr/bin:/bin" "$fake_repo/evaluate-scope.sh" evaluate "${good[@]:0:6}" \
  "$tmp/marker-typo.json" "$tmp/legacy-bundles" "$tmp/legacy-source.git" >"$tmp/evaluation-typo.json"
"$jq_bin" -e '.body.outcome == "not-proposable" and
  .body.reason_ids == ["scope.mode-construction","scope.sandbox-receipt-missing"] and .body.enabled == false' \
  "$tmp/evaluation-typo.json" >/dev/null || fail 'an unknown mode status was not refused'
pass 'an unknown operating-mode status fails closed even without a committed marker'
# A committed marker present as a symlink is not absent: the portable tree must
# refuse rather than let the supplied marker decide the mode.
/bin/mkdir -p "$tmp/portable/config"
/bin/ln -s /dev/null "$tmp/portable/config/construction-mode.json"
symlink_status=0
PATH="$bin:/usr/bin:/bin" "$fake_repo/evaluate-scope.sh" evaluate "${good[@]:0:6}" \
  "$tmp/marker-operating.json" "$tmp/legacy-bundles" "$tmp/legacy-source.git" >"$tmp/evaluation-symlink-marker.json" 2>"$tmp/symlink-marker.err" ||
  symlink_status=$?
[ "$symlink_status" -ne 0 ] && [ ! -s "$tmp/evaluation-symlink-marker.json" ] &&
  [ "$(/bin/cat "$tmp/symlink-marker.err")" = E_RUNTIME ] || fail 'a symlinked committed marker was not refused'
/bin/rm -f "$tmp/portable/config/construction-mode.json"
pass 'a committed marker that is not a regular file fails closed'

race_marker_case() {
  local label=$1 committed=$2 shape=${3:-file} status=0 out
  local race_repo="$tmp/race-$label" race_bin="$tmp/race-bin-$label"
  /bin/mkdir -p "$race_repo/scope/v1" "$race_repo/config"
  /bin/mkdir -m 700 "$race_bin"
  /bin/ln -s "$python_bin" "$race_bin/python3"
  /bin/cp "$jq_bin" "$race_bin/jq"
  for component_dir in core shadow control enforcement adapters preparation telemetry maintenance evals scripts; do
    /bin/cp -R "$root/$component_dir" "$race_repo/$component_dir"
  done
  for shipped in scope-policy.json workflow-scope.jq scope-gates.jq \
    validate-scope.sh evaluate-scope.sh read-shadow-evidence.py; do
    /bin/cp "$root/scope/v1/$shipped" "$race_repo/scope/v1/$shipped"
  done
  if [ -n "$committed" ]; then
    /bin/cp "$committed" "$race_repo/config/construction-mode.json"
  fi
  "$python_bin" -I -S -B - "$race_repo" "$tmp/marker-operating.json" "$shape" <<'PY_MUTATE'
import pathlib,shlex,sys
root,marker,shape=sys.argv[1:]
path=pathlib.Path(root)/"scope/v1/evaluate-scope.sh"
raw=path.read_text()
boundary='policy_sha=$(sha256_path "$scratch/policy.json")'
assert raw.count(boundary)==1
name=str(pathlib.Path(root)/"config/construction-mode.json")
command=("/bin/ln -s /dev/null " + shlex.quote(name) if shape=="symlink"
         else "/bin/cat " + shlex.quote(marker) + " > " + shlex.quote(name))
path.write_text(raw.replace(boundary,command+"\n"+boundary))
PY_MUTATE
  /bin/chmod 0500 "$race_repo/scope/v1/evaluate-scope.sh"
  out=$(PATH="$race_bin:/usr/bin:/bin" "$race_repo/scope/v1/evaluate-scope.sh" \
    evaluate "${good[@]:0:6}" "$tmp/marker.json" "$tmp/legacy-bundles" "$tmp/legacy-source.git" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted a marker that changed mid-run"
  [ "$out" = E_STALE ] || fail "$label expected E_STALE got $out"
}
race_marker_case rewritten "$tmp/marker.json"
race_marker_case appeared ''
race_marker_case appeared-symlink '' symlink
pass 'held marker changes, appearance, and symlink appearance before SEAL refuse as stale'

"$python_bin" -I -S -B - "$root" "$tmp" "$bin" "${good[@]}" <<'PY_TERMINAL_TEST'
import copy,hashlib,json,os,pathlib,pwd,runpy,shutil,subprocess,sys,time
root,tmp,bin_path=map(pathlib.Path,sys.argv[1:4]);documents=sys.argv[4:]
namespace=runpy.run_path(str(root/'scope/v1/read-shadow-evidence.py'),run_name='terminal_limits_test')
Reader=namespace['_Reader'];c=namespace['c'];canonical=c.canonical
area=tmp/'terminal-controls';area.mkdir()
def reader_at(name,rows):
    location=area/name;location.mkdir()
    reader=Reader.__new__(Reader);reader.commands_open=True;reader.commands=copy.deepcopy(rows)
    reader.scope={'id':'a'};reader.output=location/'result.json'
    return reader
def refusal(operation,code):
    try:operation()
    except c.Refusal as error:assert error.code==code,(error.code,code)
    else:raise AssertionError('required refusal absent: '+code)
row={'role':'a','argv_sha256':'0'*64,'executable_sha256':'0'*64,'component_sha256':'0'*64}
reader=reader_at('append-limit',[])
for _ in range(4096):reader.record_command('a',[],row['executable_sha256'],row['component_sha256'])
assert len(reader.commands)==4096
refusal(lambda:reader.record_command('a',[],row['executable_sha256'],row['component_sha256']),'E_LIMIT')
refusal(lambda:reader.terminal(b'original'),'E_LIMIT')
refusal(lambda:reader.record_command('a',[],row['executable_sha256'],row['component_sha256']),'E_RUNTIME')
assert not (reader.output.parent/'terminal.json').exists()
base=len(canonical({'schema_version':1,'kind':'scope_shadow_evidence_terminal','id':'a',
                    'body':{'observation_sha256':c.digest(b'original'),'commands':[]}}))
count=(c.DOCUMENT_LIMIT-base+1)//len(canonical(row))
rows=[copy.deepcopy(row) for _ in range(count)]
remaining=c.DOCUMENT_LIMIT-(base+count*len(canonical(row))-1)
for item in rows:
    added=min(127,remaining);item['role']+='a'*added;remaining-=added
    if not remaining:break
assert remaining==0 and count<4096
reader=reader_at('document-limit',rows);raw=reader.terminal(b'original')
assert len(raw)==c.DOCUMENT_LIMIT and (reader.output.parent/'terminal.json').read_bytes()==raw
refusal(lambda:reader.terminal(b'original'),'E_RUNTIME')
rows[-1]['role']+='a'
refusal(lambda:reader_at('document-over-limit',rows).terminal(b'original'),'E_LIMIT')
print('terminal limits: 4096 append, 4097 refusal, independent exact 1 MiB and overflow PASS',flush=True)
package=area/'package';package.mkdir();(package/'scope').mkdir()
for component in ('core','shadow','control','enforcement','adapters','preparation','telemetry','maintenance','evals','scripts'):
    shutil.copytree(root/component,package/component)
shutil.copytree(root/'scope/v1',package/'scope/v1')
reader_path=package/'scope/v1/read-shadow-evidence.py';frontend=package/'scope/v1/evaluate-scope.sh'
reader_source=reader_path.read_text();frontend_source=frontend.read_text()
argv=[str(frontend),'evaluate',*documents,str(tmp/'legacy-bundles'),str(tmp/'legacy-source.git')]
environment=dict(os.environ,PATH=str(bin_path)+':/usr/bin:/bin')
frame='require(len(frame) <= 96 and os.write(1, frame) == len(frame), "E_RUNTIME")'
assert reader_source.count(frame)==1
boundary="/usr/bin/perl -e 'alarm shift; exec @ARGV; die \"exec failed: $!\\n\"' \\\n  \"$(remaining_time)\" \"$python_bin\" -I -S -B - \\\n  \"$scratch/observation\""
assert frontend_source.count(boundary)==1
captures=area/'captures';captures.mkdir()
for name in ('original.json','terminal.json','baseline-original.json'):(captures/name).write_bytes(b'')
cost_module=runpy.run_path(str(tmp/'stale-observation/observer.py'))
def terminal_failure(label,result,private_error,reader_bytes,driver_bytes,facts_path,reader_error_path,expected):
    try:
        private_raw=private_error.read_bytes()
        unexpected=(len(private_raw)>65536 or (not(result.returncode==0 and result.stdout and not result.stderr)
            if expected is None else not(result.returncode!=0 and not result.stdout and result.stderr==expected.encode()+b'\n')))
        if label in {'size-mismatch','deleted-suffix','shape-valid-suffix'} and private_raw!=b'E_RELATION\n':unexpected=True
        facts={'normal_wait':'GAP','COMMIT':'GAP','reader_stderr':'GAP'}
        if label=='size-mismatch':
            raw=facts_path.read_bytes()
            if raw:
                lines=raw.decode('ascii','replace').splitlines()
                if len(lines)==2:facts.update(COMMIT=lines[0],normal_wait={'completed':True,'status':lines[1]})
            error_raw=reader_error_path.read_bytes()
            facts['reader_stderr']={'bytes':len(error_raw),'sha256':hashlib.sha256(error_raw).hexdigest(),
                'prefix':error_raw[:768].decode('utf-8','backslashreplace'),'truncated':len(error_raw)>768}
        if not unexpected:return
        def retained(raw):
            return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),
                'prefix':raw[:256].decode('utf-8','backslashreplace'),'truncated':len(raw)>256}
        payload={'status':'TERMINAL_UNEXPECTED','case':label,'returncode':result.returncode,
            'reader_sha256':hashlib.sha256(reader_bytes.encode()).hexdigest(),
            'frontend_sha256':hashlib.sha256(driver_bytes.encode()).hexdigest(),
            'stdout':retained(result.stdout),'stderr':retained(result.stderr),
            'private_error':retained(private_raw),'same_call':facts}
        raw=json.dumps(payload,separators=(',',':'),ensure_ascii=True).encode()+b'\n'
        if len(raw)<=16384:sys.stderr.buffer.write(raw)
    except BaseException:pass

def run_case(label,reader_change=None,driver_change=None,expected=None,timeout=35):
    private_error=area/(label+'.terminal-error');private_error.write_bytes(b'')
    reader_bytes=reader_change or reader_source;driver_bytes=driver_change or frontend_source
    error_capture='emit_error() {\n  if [ -n "${scratch:-}" ] && [ -f "$scratch/terminal-error" ]; then\n'+\
        '    /bin/dd if="$scratch/terminal-error" of='+str(private_error)+' bs=65537 count=1 2>/dev/null\n  fi'
    driver_bytes=driver_bytes.replace('emit_error() {',error_capture)
    facts_path=area/'size-mismatch.same-call'
    reader_error_path=area/'size-mismatch.reader-stderr'
    if label=='size-mismatch':facts_path.write_bytes(b'');reader_error_path.write_bytes(b'')
    if label=='size-mismatch':
        wait='wait "$reader_pid" || reader_status=$?\n'
        capture='/usr/bin/printf \'%s\\n\' "$commit" "$reader_status" >'+str(facts_path)+'\n/bin/dd if="$scratch/reader-stderr" of='+str(reader_error_path)+' bs=65537 count=1 2>/dev/null || :\n'
        assert driver_bytes.count(wait)==1
        driver_bytes=driver_bytes.replace(wait,wait+capture,1)
    if label=='normal':
        driver_bytes=cost_module['cost_frontend'](driver_bytes,'terminal-normal',tmp/'stale-observation/observer.py')
        cost_module['cost_bind']('terminal-normal',hashlib.sha256(frontend_source.encode()).hexdigest(),
            hashlib.sha256(reader_bytes.encode()).hexdigest(),hashlib.sha256(driver_bytes.encode()).hexdigest(),
            hashlib.sha256(json.dumps(argv,separators=(',',':'),ensure_ascii=True).encode()).hexdigest())
    (area/(label+'.reader-source.py')).write_text(reader_bytes)
    (area/(label+'.frontend-source.sh')).write_text(driver_bytes)
    reader_path.write_text(reader_bytes)
    frontend.chmod(0o700);frontend.write_text(driver_bytes);frontend.chmod(0o500)
    result=subprocess.run(argv,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    terminal_failure(label,result,private_error,reader_bytes,driver_bytes,facts_path,reader_error_path,expected)
    assert private_error.stat().st_size<=65536,label+' private stderr overflow'
    (area/(label+'.stdout')).write_bytes(result.stdout);(area/(label+'.stderr')).write_bytes(result.stderr)
    print('terminal control',label,'exit',result.returncode,'stderr',repr(result.stderr),flush=True)
    if expected is None:assert result.returncode==0 and result.stdout and not result.stderr
    else:
        assert result.returncode!=0 and not result.stdout and result.stderr==expected.encode()+b'\n',label
        if label in {'size-mismatch','deleted-suffix','shape-valid-suffix'}:
            assert private_error.read_bytes()==b'E_RELATION\n',label+' did not reject actual retained snapshot digest'
    return result
run_case('normal')
commit_boundary='frame = ("COMMIT " + str(len(terminal)) + " " + c.digest(terminal) + "\\n").encode("ascii")'
assert reader_source.count(commit_boundary)==1
for label,change,expected in (
    ('terminal-schema',"document['schema_version']=2",'E_RELATION'),
    ('terminal-schema-type',"document['schema_version']=True",'E_RELATION'),
    ('terminal-kind',"document['kind']='wrong_terminal'",'E_RELATION'),
    ('terminal-id',"document['id']='scope.other'",'E_RELATION'),
    ('terminal-observation',"document['body']['observation_sha256']='0'*64",'E_RELATION'),
    ('terminal-root-extra',"document['extra']=1",'E_RELATION'),
    ('terminal-root-missing',"del document['kind']",'E_RELATION'),
    ('terminal-body-extra',"document['body']['extra']=1",'E_RELATION'),
    ('terminal-body-type',"document['body']=[]",'E_RELATION'),
    ('terminal-commands-type',"document['body']['commands']={}",'E_RELATION'),
    ('terminal-row-type',"document['body']['commands'][0]=1",'E_RELATION'),
    ('terminal-row-missing',"del document['body']['commands'][0]['component_sha256']",'E_RELATION'),
    ('terminal-row-extra',"document['body']['commands'][0]['extra']=1",'E_RELATION'),
    ('terminal-row-role',"document['body']['commands'][0]['role']='invalid role'",'E_RELATION'),
    ('terminal-row-hash',"document['body']['commands'][0]['argv_sha256']='g'*64",'E_RELATION'),
    ('terminal-prefix-removed',"del document['body']['commands'][0]",'E_RELATION'),
    ('terminal-prefix-reordered',"rows=document['body']['commands'];rows[0],rows[1]=rows[1],rows[0]",'E_RELATION'),
    ('terminal-prefix-changed',"document['body']['commands'][0]['argv_sha256']='0'*64",'E_RELATION'),
    ('terminal-root-duplicate',"duplicate=b'id'",'E_CANONICAL'),
    ('terminal-body-duplicate',"duplicate=b'observation_sha256'",'E_CANONICAL'),
    ('terminal-row-duplicate',"duplicate=b'role'",'E_CANONICAL')):
    alteration="""original = json.loads(raw)
        prefix = original['body']['commands']
        assert len(prefix) >= 2 and prefix[0] != prefix[1]
        assert prefix[0]['argv_sha256'] != '0'*64 and c.digest(raw) != '0'*64
        document = json.loads(terminal)
        duplicate = False
        CHANGE
        terminal = c.canonical(document)
        if duplicate:
            key = b'"' + duplicate + b'":'
            terminal = terminal.replace(key, key + b'"a",' + key, 1)
        path = reader.output.parent / 'terminal.json'
        path.unlink()
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
        try:
            assert os.write(descriptor, terminal) == len(terminal)
        finally:
            os.close(descriptor)
        """.replace('CHANGE',change)
    altered=reader_source.replace(commit_boundary,alteration+commit_boundary,1)
    evidence={name:area/(label+'.'+name) for name in ('O','T','COMMIT','wait')}
    for path in evidence.values():path.write_bytes(b'')
    capture=''
    for name,source in (('O','observation.json'),('T','observation/terminal.json')):
        capture+='/bin/dd if="$scratch/'+source+'" of='+str(evidence[name])+' bs=1048577 count=1 2>/dev/null\n'
    capture+='/usr/bin/printf \'%s\\n\' "$commit" >'+str(evidence['COMMIT'])+'\n'
    capture+='/usr/bin/printf \'%s\\n\' "$reader_status" >'+str(evidence['wait'])+'\n'
    run_case(label,reader_change=altered,driver_change=frontend_source.replace(boundary,capture+boundary,1),expected=expected)
    tested=evidence['T'].read_bytes();observed=evidence['O'].read_bytes()
    assert evidence['COMMIT'].read_bytes()==b'COMMIT '+str(len(tested)).encode()+b' '+c.digest(tested).encode()+b'\n'
    assert evidence['wait'].read_bytes()==b'0\n' and len(json.loads(observed)['body']['commands'])>=2
    assert (area/(label+'.terminal-error')).read_bytes()==b'',label+' failed before terminal semantics'
print('terminal semantic controls: actual matching COMMIT, closed shape, O identity/digest and original prefix refuse PASS',flush=True)
for label,expression in (
    ('partial',"b'COMMIT 1 '"),('duplicate','frame+frame'),('trailing',"frame+b'x'"),
    ('reordered',"b'COMMIT '+c.digest(terminal).encode()+b' '+str(len(terminal)).encode()+b'\\n'"),
    ('zero-size',"b'COMMIT 0 '+c.digest(terminal).encode()+b'\\n'"),
    ('leading-zero',"b'COMMIT 0'+str(len(terminal)).encode()+b' '+c.digest(terminal).encode()+b'\\n'"),
    ('uppercase-digest',"b'COMMIT '+str(len(terminal)).encode()+b' '+c.digest(terminal).upper().encode()+b'\\n'"),
    ('bad-digest',"b'COMMIT '+str(len(terminal)).encode()+b' '+b'0'*64+b'\\n'"),
    ('size-mismatch',"b'COMMIT '+str(len(terminal)+1).encode()+b' '+c.digest(terminal).encode()+b'\\n'")):
    modified=reader_source.replace(frame,'frame = '+expression+'\n        require(os.write(1, frame) == len(frame), "E_RUNTIME")')
    run_case(label,modified,expected='E_RELATION' if label in {'bad-digest','size-mismatch'} else 'E_RUNTIME')
ready_write='require(os.write(1, b"READY\\n") == 6, "E_RUNTIME")'
seal_write="/usr/bin/printf 'SEAL\\n' >&7 || emit_error E_RUNTIME"
assert reader_source.count(ready_write)==frontend_source.count(seal_write)==1
for phase in ('READY','SEAL'):
    for label,raw in (('missing',b''),('partial',phase[:3].encode()),('duplicate',(phase+'\n'+phase+'\n').encode()),
                      ('reordered',b'SEAL\n' if phase=='READY' else b'COMMIT 1 0\n'),
                      ('trailing',(phase+'\nx').encode()),('EOF',b'')):
        if phase=='READY':
            replacement='return' if not raw else 'require(os.write(1, '+repr(raw)+') == '+str(len(raw))+', "E_RUNTIME")'
            run_case('ready-'+label,reader_source.replace(ready_write,replacement,1),expected='E_RUNTIME')
        else:
            replacement='/usr/bin/printf '+repr(raw.decode()).replace('\n','\\n')+' >&7 || emit_error E_RUNTIME'
            if not raw:replacement=':'
            run_case('seal-'+label,driver_change=frontend_source.replace(seal_write,replacement,1),expected='E_RUNTIME')
started=time.monotonic()
run_case('protocol-deadline',reader_source.replace('message = sys.stdin.buffer.read(8)',
    'while True: signal.pause()\n        message = sys.stdin.buffer.read(8)',1),expected='E_RUNTIME',timeout=320)
assert 290 <= time.monotonic()-started < 320
print('READY/SEAL missing, partial, duplicate, reordered, trailing, EOF and original 300s protocol deadline PASS',flush=True)
run_case('missing-commit',reader_source.replace(frame,'return'),expected='E_RUNTIME')
run_case('nonzero-after-commit',reader_source.replace(frame,frame+'\n        raise OSError("controlled exit")'),expected='E_RUNTIME')
late_source=reader_source.replace('terminal = reader.terminal(raw)',
    "reader.record_command('a', ['synthetic suffix control'], '0'*64, '0'*64)\n        terminal = reader.terminal(raw)")
if sys.platform=='darwin':
    probe=package/'late-acl-probe';probe.write_bytes(b'owned ACL fixture\n');probe.chmod(0o400)
    subprocess.run(['/bin/chmod','+a','user:'+pwd.getpwuid(os.getuid()).pw_name+' allow read',str(probe)],check=True)
    acquire="""probe_active = False
        rule = c._installed_rule(os.getuid(), reader.darwin)
        probe = c._open_held(str(PACKAGE / 'late-acl-probe'), False,
            lambda fd,state,ancestor: True if ancestor or not probe_active else rule(fd,state,False), 'E_RUNTIME')
        reader.owned.append(probe)
        """
    late_source=reader_source.replace('raw = reader.evaluate()',acquire+'raw = reader.evaluate()')
    late_source=late_source.replace('message = sys.stdin.buffer.read(8)',
                                    'probe_active = True\n        message = sys.stdin.buffer.read(8)')
    capture='/bin/cat "$scratch/observation.json" > '+str(captures/'original.json')+'\n'+\
            '/bin/cat "$scratch/observation/terminal.json" > '+str(captures/'terminal.json')+'\n'
    baseline=run_case('actual-jq-baseline',reader_source,frontend_source.replace(boundary,capture+boundary))
    original_baseline=(captures/'original.json').read_bytes()
    (captures/'baseline-original.json').write_bytes(original_baseline)
    actual=run_case('actual-late-uuid',late_source,frontend_source.replace(boundary,capture+boundary))
    assert actual.stdout==baseline.stdout
    baseline_observation=json.loads(original_baseline)
    current_observation=json.loads((captures/'original.json').read_bytes())
    del baseline_observation['body']['commands'];del current_observation['body']['commands']
    assert canonical(current_observation)==canonical(baseline_observation)
    original=json.loads((captures/'original.json').read_bytes());terminal=json.loads((captures/'terminal.json').read_bytes())
    before=original['body']['commands'];after=terminal['body']['commands']
    assert after[:len(before)]==before and len(after)==len(before)+1
    assert all(item['role']=='darwin-acl-uuid-resolution' for item in after[len(before):])
    assert terminal['body']['observation_sha256']==c.digest((captures/'original.json').read_bytes())
    final=copy.deepcopy(original);final['body']['commands']=after
    original_noncommands=copy.deepcopy(original);del original_noncommands['body']['commands']
    final_noncommands=copy.deepcopy(final);del final_noncommands['body']['commands']
    assert canonical(final_noncommands)==canonical(original_noncommands)
    print('actual full-SEAL fixed-owner UUID suffix retained with exact original prefix PASS',flush=True)
# These copies alter a committed terminal only after the real reader has exited.
mutation='"$python_bin" -I -S -B - "$scratch/observation/terminal.json" "$scratch/observation.json" <<\'PY_SWAP_TERMINAL\'\n'
for label,code in (
    ('fifo',"path.unlink();os.mkfifo(path,0o600)"),
    ('deleted-suffix',"document=json.loads(path.read_bytes());document['body']['commands']=json.loads(pathlib.Path(sys.argv[2]).read_bytes())['body']['commands'];replace_terminal(document)"),
    ('shape-valid-suffix',"document=json.loads(path.read_bytes());document['body']['commands'][-1]['argv_sha256']='0'*64;replace_terminal(document)")):
    replace_code="""def replace_terminal(document):
    raw=(json.dumps(document,sort_keys=True,separators=(',',':'))+'\\n').encode()
    path.unlink()
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o400)
    try:
        assert os.write(fd,raw)==len(raw)
    finally:os.close(fd)
"""
    inserted=mutation+'import json,os,pathlib,sys\npath=pathlib.Path(sys.argv[1])\n'+replace_code+code+'\nPY_SWAP_TERMINAL\n'

    run_case(label,reader_change=late_source if label!='fifo' else reader_source,
             driver_change=frontend_source.replace(boundary,inserted+boundary),
             expected='E_RUNTIME' if label=='fifo' else 'E_RELATION')
print('terminal protocol framing, EOF, nonzero, first-open FIFO and committed-byte tampering PASS',flush=True)
try:cost_module['cost_qualify']()
except BaseException:pass
PY_TERMINAL_TEST
pass 'terminal append and byte caps are independent; framed commitment binds the first snapshot'

genuine_platform=$(/usr/bin/uname -s)
genuine_chown=/bin/chown
[ "$genuine_platform" != Darwin ] || genuine_chown=/usr/sbin/chown
genuine_mac_nodes=()
genuine_mac_identities=()
genuine_mac_pending=()
genuine_python=''
genuine_base=''
genuine_writer=''
genuine_consumer=''
genuine_group=''
genuine_base_created=false
genuine_libexec_created=false
genuine_writer_created=false
genuine_consumer_created=false
genuine_group_created=false
genuine_anchor_created=false
genuine_writer_identity=''
genuine_consumer_identity=''
genuine_group_identity=''
genuine_base_identity=''
genuine_anchor_identity=''
genuine_libexec_identity=''
genuine_anchor_parents=()
genuine_anchor_parent_identities=()
fixture_directory_identity() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  if [ "$genuine_platform" = Darwin ]; then
    /usr/bin/sudo -n /usr/bin/stat -f '%d:%i:%u:%g:%p' "$1"
  else
    /usr/bin/sudo -n /usr/bin/stat -c '%d:%i:%u:%g:%f' -- "$1"
  fi
}
remove_fixture_directory() {
  local path=$1 identity=$2 recursive=$3
  local current
  current=$(fixture_directory_identity "$path") || return 1
  /usr/bin/printf 'owned-directory: %s expected=%s current=%s\n' "$path" "$identity" "$current"
  [ -n "$identity" ] && [ "$current" = "$identity" ] || return 1
  if [ "$recursive" = true ]; then
    /usr/bin/sudo -n /bin/rm -rf -- "$path" || return 1
  else
    /usr/bin/sudo -n /bin/rmdir -- "$path" || return 1
  fi
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  /usr/bin/printf 'owned-directory-absent: %s\n' "$path"
}
cleanup_genuine() {
  local failed=0 index
  if [ -n "$genuine_base" ] && [ -e "$genuine_base/runtime-guard-cleanup-uncertain" ]; then
    /usr/bin/printf 'genuine-cleanup: FAIL; owned command/helper cleanup pending; preserving fixture objects\n' >&2
    return 1
  fi
  if [ "$genuine_anchor_created" = true ]; then
    remove_fixture_directory /usr/local/libexec/ystack-sandbox/v1/supervisor "$genuine_anchor_identity" true || failed=1
  fi
  if [ "$genuine_base_created" = true ]; then
    remove_fixture_directory "$genuine_base" "$genuine_base_identity" true || failed=1
  fi
  if [ "$genuine_consumer_created" = true ]; then
    if [ -n "$genuine_consumer_identity" ] && [ "$(/usr/bin/getent passwd "$genuine_consumer")" = "$genuine_consumer_identity" ]; then
      /usr/bin/sudo -n /usr/sbin/userdel "$genuine_consumer" || failed=1
      if /usr/bin/getent passwd "$genuine_consumer"; then failed=1
      else /usr/bin/printf 'owned-user-absent: %s expected=%s\n' "$genuine_consumer" "$genuine_consumer_identity"; fi
    else failed=1; fi
  fi
  if [ "$genuine_writer_created" = true ]; then
    if [ -n "$genuine_writer_identity" ] && [ "$(/usr/bin/getent passwd "$genuine_writer")" = "$genuine_writer_identity" ]; then
      /usr/bin/sudo -n /usr/sbin/userdel "$genuine_writer" || failed=1
      if /usr/bin/getent passwd "$genuine_writer"; then failed=1
      else /usr/bin/printf 'owned-user-absent: %s expected=%s\n' "$genuine_writer" "$genuine_writer_identity"; fi
    else failed=1; fi
  fi
  if [ "$genuine_group_created" = true ]; then
    if [ -n "$genuine_group_identity" ] && [ "$(/usr/bin/getent group "$genuine_group" | /usr/bin/cut -d : -f 1-3)" = "$genuine_group_identity" ]; then
      /usr/bin/sudo -n /usr/sbin/groupdel "$genuine_group" || failed=1
      if /usr/bin/getent group "$genuine_group"; then failed=1
      else /usr/bin/printf 'owned-group-absent: %s expected=%s\n' "$genuine_group" "$genuine_group_identity"; fi
    else failed=1; fi
  fi
  for ((index=${#genuine_mac_nodes[@]}-1; index>=0; index--)); do
    local current pending
    current=$(mac_record_identity "${genuine_mac_nodes[index]}") || { failed=1; continue; }
    pending=${genuine_mac_pending[index]:-}
    if [ "$current" = "${genuine_mac_identities[index]}" ] ||
       { [ -n "$pending" ] && [ "$current" = "$pending" ]; }; then
      /usr/bin/sudo -n /usr/bin/dscl . -delete "${genuine_mac_nodes[index]}" || failed=1
      if mac_record_absent "${genuine_mac_nodes[index]}"; then
        /usr/bin/printf 'owned-record-absent: %s expected=%s\n' "${genuine_mac_nodes[index]}" "${genuine_mac_identities[index]}"
      else failed=1; fi
    else failed=1; fi
  done
  for ((index=${#genuine_anchor_parents[@]}-1; index>=0; index--)); do
    remove_fixture_directory "${genuine_anchor_parents[index]}" "${genuine_anchor_parent_identities[index]}" false || failed=1
  done
  if [ "$genuine_libexec_created" = true ]; then
    remove_fixture_directory /usr/local/libexec "$genuine_libexec_identity" false || failed=1
  fi
  if [ "$failed" -eq 0 ]; then /usr/bin/printf 'genuine-cleanup: PASS\n'
  else /usr/bin/printf 'genuine-cleanup: FAIL\n' >&2; fi
  [ "$failed" -eq 0 ]
}
setup_genuine_linux() {
  [ "$(/usr/bin/uname -s)" = Linux ] && [ "${GITHUB_ACTIONS:-}" = true ] &&
    [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] ||
    fail 'genuine origin BLOCKED: a reserved disposable host is required'
  /usr/bin/sudo -n /usr/bin/true || fail 'existing noninteractive sudo is required'
  genuine_python=$(/usr/bin/sudo -n /usr/bin/python3 -I -S -B -c 'import os,sys;assert sys.version_info >= (3,11);print(os.path.realpath(sys.executable))') ||
    fail 'existing root Python 3.11+ required'
  /usr/bin/sudo -n "$genuine_python" -I -S -B -c 'import os,pathlib,stat,sys;p=pathlib.Path(sys.executable);assert p.resolve()==p;assert all(q.stat().st_uid==0 and not q.stat().st_mode & 0o022 for q in (p,*p.parents))' ||
    fail 'physical root-owned Python closure required'
  [ ! -e /usr/local/libexec/ystack-sandbox/v1/supervisor ] &&
    [ ! -L /usr/local/libexec/ystack-sandbox/v1/supervisor ] || fail 'existing fixed anchor'
  local token
  token=$(/usr/bin/printf '%s' "$tmp" | /usr/bin/sha256sum | /usr/bin/cut -c 1-12)
  genuine_writer="yscw_$token"
  genuine_consumer="yscc_$token"
  genuine_group="yscg_$token"
  genuine_base="/usr/local/libexec/ystack-scope-fixture.$token"
  [ ! -e "$genuine_base" ] && [ ! -L "$genuine_base" ] || fail 'existing fixture root'
  ! /usr/bin/getent passwd "$genuine_writer" >/dev/null || fail 'existing writer'
  ! /usr/bin/getent passwd "$genuine_consumer" >/dev/null || fail 'existing consumer'
  ! /usr/bin/getent group "$genuine_group" >/dev/null || fail 'existing fixture group'
  /usr/bin/getent group 65534 >/dev/null || fail 'existing readonly primary group required'
  /usr/bin/sudo -n /usr/sbin/groupadd --system "$genuine_group" || fail 'fixture group creation'
  genuine_group_created=true
  genuine_group_identity=$(/usr/bin/getent group "$genuine_group" | /usr/bin/cut -d : -f 1-3)
  /usr/bin/sudo -n /usr/sbin/useradd --system --no-create-home --no-user-group \
    --gid "$genuine_group" --shell /usr/sbin/nologin "$genuine_writer" || fail 'writer creation'
  genuine_writer_created=true
  genuine_writer_identity=$(/usr/bin/getent passwd "$genuine_writer")
  /usr/bin/sudo -n /usr/sbin/useradd --system --no-create-home --no-user-group \
    --gid 65534 --groups "$genuine_group" --shell /usr/sbin/nologin "$genuine_consumer" || fail 'consumer creation'
  genuine_consumer_created=true
  genuine_consumer_identity=$(/usr/bin/getent passwd "$genuine_consumer")
  genuine_group_identity=$(/usr/bin/getent group "$genuine_group" | /usr/bin/cut -d : -f 1-3)
  local writer_uid consumer_uid fixture_gid consumer_gid actual_groups
  writer_uid=$(/usr/bin/id -u "$genuine_writer")
  consumer_uid=$(/usr/bin/id -u "$genuine_consumer")
  fixture_gid=$(/usr/bin/getent group "$genuine_group" | /usr/bin/cut -d : -f 3)
  consumer_gid=$(/usr/bin/id -g "$genuine_consumer")
  actual_groups=$(/usr/bin/sudo -n -u "$genuine_consumer" /usr/bin/id -G)
  [ "$writer_uid" -gt 0 ] && [ "$consumer_uid" -gt 0 ] && [ "$writer_uid" != "$consumer_uid" ] &&
    [ "$consumer_gid" = 65534 ] && [ "$consumer_gid" != "$fixture_gid" ] &&
    [[ " $actual_groups " = *" $fixture_gid "* ]] || fail 'actual principal membership'
  setup_genuine_paths
}

genuine_mac_stdin_prelude=$(/bin/cat <<'PY_MAC_STDIN_PRELUDE'
import sys
stdin_entry = sys.modules['__main__']
stdin_namespace = globals()
import pathlib

def fixed_stdin_module_paths():
    assert sys.modules.get('__main__') is stdin_entry
    assert stdin_entry.__dict__ is stdin_namespace is globals()
    assert stdin_namespace['__name__'] == '__main__'
    assert stdin_namespace['__file__'] == '<stdin>' and stdin_namespace['__spec__'] is None
    assert sys.argv[0] == '-'
    assert sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
    modules = tuple(sys.modules.items())
    assert all(name == '__main__' for name, module in modules if module is stdin_entry)
    return {pathlib.Path(module.__file__) for name, module in modules
            if module is not stdin_entry and getattr(module, '__file__', None)}

fixed_stdin_module_paths()
PY_MAC_STDIN_PRELUDE
) || fail 'fixed stdin prelude composition'
readonly genuine_mac_stdin_prelude

setup_genuine_paths() {
  if [ ! -e /usr/local/libexec ] && [ ! -L /usr/local/libexec ]; then
    /usr/bin/sudo -n /bin/mkdir -m 0755 -- /usr/local/libexec || fail 'fixture parent creation'
    genuine_libexec_created=true
    genuine_libexec_identity=$(fixture_directory_identity /usr/local/libexec)
  fi
  /usr/bin/sudo -n /bin/mkdir -m 0755 -- "$genuine_base" || fail 'fixture root creation'
  genuine_base_created=true
  genuine_base_identity=$(fixture_directory_identity "$genuine_base")
  local anchor_parent
  for anchor_parent in /usr/local/libexec/ystack-sandbox /usr/local/libexec/ystack-sandbox/v1; do
    if [ ! -e "$anchor_parent" ] && [ ! -L "$anchor_parent" ]; then
      /usr/bin/sudo -n /bin/mkdir -m 0755 -- "$anchor_parent" || fail 'anchor parent creation'
      genuine_anchor_parents+=("$anchor_parent")
      genuine_anchor_parent_identities+=("$(fixture_directory_identity "$anchor_parent")")
    else
      [ -d "$anchor_parent" ] && [ ! -L "$anchor_parent" ] || fail 'unsafe anchor parent'
    fi
  done
  /usr/bin/sudo -n /bin/mkdir -m 0755 -- /usr/local/libexec/ystack-sandbox/v1/supervisor || fail 'exclusive anchor creation'
  genuine_anchor_created=true
  genuine_anchor_identity=$(fixture_directory_identity /usr/local/libexec/ystack-sandbox/v1/supervisor)
  /usr/bin/sudo -n /bin/mkdir -m 0755 -- "$genuine_base/package" || fail 'fixture package creation'
  for component_dir in scope shadow sandbox core config scripts adapters preparation control enforcement telemetry maintenance evals verifiers; do
    /usr/bin/sudo -n /bin/cp -R -- "$root/$component_dir" "$genuine_base/package/$component_dir" || fail 'fixed package copy'
  done
  /usr/bin/sudo -n "$genuine_chown" -R -- 0:0 "$genuine_base/package" || fail 'root package ownership'
  /usr/bin/sudo -n /bin/chmod -R -- a+rX,go-w "$genuine_base/package" || fail 'root package mode'
  if [ "$genuine_platform" = Darwin ]; then
    local mac_import_body
    mac_import_body=$(/bin/cat <<'PY_MAC_IMPORT_CLOSURE'
import importlib.util,pathlib,stat,sys
package=pathlib.Path(sys.argv[1])
source=package/'scope/v1/read-shadow-evidence.py'
spec=importlib.util.spec_from_file_location('scope_fixture_import_closure',source)
assert spec is not None and spec.loader is not None
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module
spec.loader.exec_module(module)
paths=fixed_stdin_module_paths()
for path in paths:
 assert path.resolve()==path and path.is_file()
 for item in (path,*path.parents):
  value=item.lstat()
  assert value.st_uid==0 and not value.st_mode & 0o022 and not stat.S_ISLNK(value.st_mode)
assert '_cancel_release' not in sys.modules
print('actual root-owned P/consumer/reader import closure: PASS; no State/startup/VM')
PY_MAC_IMPORT_CLOSURE
    ) || fail 'fixed stdin body composition'
    /usr/bin/sudo -n "$genuine_python" -I -S -B - "$genuine_base/package" <<<"$genuine_mac_stdin_prelude
$mac_import_body" || fail 'actual fixed consumer import closure is unsafe'
  fi
  prepare_genuine_writer
  /usr/bin/sudo -n /bin/cp -- "$tmp/genuine-writer.py" "$genuine_base/genuine-writer.py" || fail 'fixed storage harness copy'
  /usr/bin/sudo -n "$genuine_chown" -- 0:0 "$genuine_base/genuine-writer.py" || fail 'storage harness owner'
  /usr/bin/sudo -n /bin/chmod -- 0555 "$genuine_base/genuine-writer.py" || fail 'storage harness mode'
  /usr/bin/sudo -n -u "$genuine_writer" /usr/bin/id
  /usr/bin/sudo -n -u "$genuine_consumer" /usr/bin/id
}

mac_record_identity() {
  /usr/bin/sudo -n "$genuine_python" -I -S -B - "$1" <<'PY_MAC_IDENTITY'
import json,plistlib,subprocess,sys,uuid
node=sys.argv[1]
result=subprocess.run(['/usr/bin/dscl','-plist','.','-read',node],capture_output=True,timeout=10)
assert result.returncode==0 and not result.stderr and len(result.stdout)<=65536
value=plistlib.loads(result.stdout)
def field(name):
 rows=value.get('dsAttrTypeStandard:'+name,[])
 assert type(rows) is list and len(rows)<=1 and all(type(item) is str for item in rows)
 return rows[0] if rows else None
name=field('RecordName');identifier=field('GeneratedUID')
assert name==node.rsplit('/',1)[1] and identifier is not None
uid,gid=field('UniqueID'),field('PrimaryGroupID')
print(json.dumps({'name':name,'uuid':uuid.UUID(identifier).hex,
 'uid':int(uid) if uid is not None else None,'gid':int(gid) if gid is not None else None},
 sort_keys=True,separators=(',',':')))
PY_MAC_IDENTITY
}
mac_record_absent() {
  /usr/bin/sudo -n "$genuine_python" -I -S -B - "$1" <<'PY_MAC_ABSENCE'
import subprocess,sys
node,name=sys.argv[1].rsplit('/',1)
result=subprocess.run(['/usr/bin/dscl','.', '-list',node],capture_output=True,timeout=10)
assert result.returncode==0 and not result.stderr and len(result.stdout)<=65536
assert name not in result.stdout.decode('utf8').splitlines()
PY_MAC_ABSENCE
}
mac_create_record() {
  local node=$1 number=$2 identifier expected current
  mac_record_absent "$node" || fail 'fixture record already exists or absence is unverified'
  /usr/bin/sudo -n "$genuine_python" -I -S -B - "$node" "$number" <<'PY_MAC_ABSENT' || fail 'fixture name or numeric ID no longer absent'
import subprocess,sys
for node,field in (('/Users','UniqueID'),('/Groups','PrimaryGroupID')):
 result=subprocess.run(['/usr/bin/dscl','.', '-list',node,field],capture_output=True,timeout=10)
 assert result.returncode==0 and not result.stderr and len(result.stdout)<=65536
 for row in result.stdout.decode('utf8').splitlines():
  name,number=row.rsplit(None,1)
  assert name!=sys.argv[1].rsplit('/',1)[1] and int(number)!=int(sys.argv[2])
PY_MAC_ABSENT
  identifier=$(/usr/bin/sudo -n "$genuine_python" -I -S -B -c 'import uuid;print(uuid.uuid4())') || fail 'fixture UUID'
  expected=$(/usr/bin/sudo -n "$genuine_python" -I -S -B -c \
    'import json,sys,uuid;print(json.dumps(dict(name=sys.argv[1],uuid=uuid.UUID(sys.argv[2]).hex,uid=None,gid=None),sort_keys=True,separators=(",",":")))' \
    "${node##*/}" "$identifier") || fail 'fixture identity encoding'
  /usr/bin/sudo -n /usr/bin/dscl . -create "$node" GeneratedUID "$identifier" || fail 'fixture record creation'
  genuine_mac_nodes+=("$node")
  genuine_mac_identities+=("$expected")
  genuine_mac_pending+=('')
  current=$(mac_record_identity "$node") || fail 'fixture identity capture'
  [ "$current" = "$expected" ] || fail 'unexpected new fixture identity'
}
mac_set_record() {
  local index=$1 key=$2 value=$3 expected current
  current=$(mac_record_identity "${genuine_mac_nodes[index]}") || fail 'fixture identity capture'
  [ "$current" = "${genuine_mac_identities[index]}" ] || fail 'fixture identity changed'
  expected=$(/usr/bin/sudo -n "$genuine_python" -I -S -B -c \
    'import json,sys;v=json.loads(sys.argv[1]);k={"UniqueID":"uid","PrimaryGroupID":"gid"}.get(sys.argv[2]);v.update({k:int(sys.argv[3])} if k else {});print(json.dumps(v,sort_keys=True,separators=(",",":")))' \
    "$current" "$key" "$value") || fail 'fixture identity encoding'
  genuine_mac_pending[index]=$expected
  /usr/bin/sudo -n /usr/bin/dscl . -create "${genuine_mac_nodes[index]}" "$key" "$value" || fail 'fixture record property'
  current=$(mac_record_identity "${genuine_mac_nodes[index]}") || fail 'fixture identity capture'
  [ "$current" = "$expected" ] || fail 'fixture property changed another identity'
  genuine_mac_identities[index]=$current
  genuine_mac_pending[index]=''
}
setup_genuine_macos() {
  [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] ||
    fail 'genuine origin BLOCKED: a reserved disposable host is required'
  /usr/bin/sudo -n /usr/bin/true || fail 'existing noninteractive sudo is required'
  local command
  for command in /usr/bin/python3 /Library/Frameworks/Python.framework/ystack-private-tools/jq /usr/bin/git /usr/bin/cc /usr/bin/dscl \
    /usr/sbin/dseditgroup /usr/bin/stat /bin/chmod /usr/sbin/chown /bin/mkdir /bin/cp /bin/rm /usr/bin/id /usr/bin/false; do
    [ -f "$command" ] && [ ! -L "$command" ] && [ -x "$command" ] || fail 'missing fixed host prerequisite'
  done
  [ "$(authenticate_genuine_macos_python "$python_bin")" = "$python_bin" ] ||
    fail 'trusted existing runtime closure required before privilege'
  genuine_python=$(/usr/bin/sudo -n "$python_bin" -I -S -B -c \
    'import os,sys;assert sys.version_info >= (3,11);print(os.path.realpath(sys.executable))') ||
    fail 'existing root Python 3.11+ required'
  [ "$genuine_python" = "$python_bin" ] || fail 'fixture Python differs from selected physical Python'
  local mac_runtime_body
  mac_runtime_body=$(/bin/cat <<'PY_MAC_RUNTIME'
import os,plistlib,stat,uuid
paths={pathlib.Path(sys.executable),pathlib.Path('/Library/Frameworks/Python.framework/ystack-private-tools/jq')}
paths.update(fixed_stdin_module_paths())
for path in paths:
 assert path.resolve()==path and path.is_file()
 for item in (path,*path.parents):
  value=item.lstat()
  assert value.st_uid==0 and not value.st_mode & 0o022 and not stat.S_ISLNK(value.st_mode)
assert pathlib.Path(sys.executable).resolve()==pathlib.Path(sys.executable)
PY_MAC_RUNTIME
  ) || fail 'fixed stdin body composition'
  /usr/bin/sudo -n "$genuine_python" -I -S -B - <<<"$genuine_mac_stdin_prelude
$mac_runtime_body" || fail 'physical root-owned runtime closure required'
  jq_cache=/Library/Frameworks/Python.framework/ystack-private-tools/jq
  [ "$(sha256_path "$jq_cache")" = "$jq_sha" ] && [ "$("$jq_cache" --version)" = jq-1.6 ] ||
    fail 'existing pinned root jq required'
  [ ! -e /usr/local/libexec/ystack-sandbox/v1/supervisor ] &&
    [ ! -L /usr/local/libexec/ystack-sandbox/v1/supervisor ] || fail 'existing fixed anchor'
  local token first
  token=$(/usr/bin/git -C "$root" rev-parse HEAD) || fail 'immutable checkout OID required'
  [ -z "$(/usr/bin/git -C "$root" status --porcelain)" ] || fail 'clean immutable checkout required'
  token=${token:0:8}
  genuine_writer="yscw_$token";genuine_consumer="yscc_$token";genuine_group="yscg_$token"
  genuine_private_group="yscp_$token"
  genuine_base="/usr/local/libexec/ystack-scope-fixture.$token"
  [ ! -e "$genuine_base" ] && [ ! -L "$genuine_base" ] || fail 'existing fixture root'
  first=$(/usr/bin/sudo -n "$genuine_python" -I -S -B - "$genuine_writer" "$genuine_consumer" \
    "$genuine_group" "$genuine_private_group" <<'PY_MAC_IDS'
import subprocess,sys
used=set()
for node,attribute in (('/Users','UniqueID'),('/Groups','PrimaryGroupID')):
 result=subprocess.run(['/usr/bin/dscl','.', '-list',node,attribute],capture_output=True,timeout=10)
 assert result.returncode==0 and not result.stderr and len(result.stdout)<=65536
 for row in result.stdout.decode('utf8').splitlines():
  name,number=row.rsplit(None,1)
  assert name not in sys.argv[1:]
  used.add(int(number))
for first in range(56000,56997):
 if not used.intersection(range(first,first+4)):
  print(first);break
else:raise ValueError('no unused fixture identities')
PY_MAC_IDS
  ) || fail 'unused fixture names and IDs required'
  mac_create_record "/Groups/$genuine_group" "$((first + 2))"
  mac_set_record 0 PrimaryGroupID "$((first + 2))"
  mac_create_record "/Groups/$genuine_private_group" "$((first + 3))"
  mac_set_record 1 PrimaryGroupID "$((first + 3))"
  mac_create_record "/Users/$genuine_writer" "$first"
  mac_set_record 2 UniqueID "$first"
  mac_set_record 2 PrimaryGroupID "$((first + 2))"
  mac_set_record 2 NFSHomeDirectory /var/empty
  mac_set_record 2 UserShell /usr/bin/false
  mac_create_record "/Users/$genuine_consumer" "$((first + 1))"
  mac_set_record 3 UniqueID "$((first + 1))"
  mac_set_record 3 PrimaryGroupID "$((first + 3))"
  mac_set_record 3 NFSHomeDirectory /var/empty
  mac_set_record 3 UserShell /usr/bin/false
  /usr/bin/sudo -n /usr/sbin/dseditgroup -o edit -a "$genuine_consumer" -t user "$genuine_group" || fail 'fixture supplementary group'
  local groups
  groups=$(/usr/bin/sudo -n -u "$genuine_consumer" /usr/bin/id -G) || fail 'actual consumer groups'
  [ "$(/usr/bin/id -u "$genuine_writer")" = "$first" ] &&
    [ "$(/usr/bin/id -u "$genuine_consumer")" = "$((first + 1))" ] &&
    [ "$(/usr/bin/id -g "$genuine_writer")" = "$((first + 2))" ] &&
    [ "$(/usr/bin/id -g "$genuine_consumer")" = "$((first + 3))" ] &&
    [[ " $groups " = *" $((first + 2)) "* ]] || fail 'actual distinct supplementary-only principals'
  setup_genuine_paths
}

run_genuine_macos_runtime_guard_controls() {
  local operator_name guard_source entry_source
  operator_name=$(/usr/bin/id -un) || fail 'guard operator identity'
  guard_source="$tmp/runtime-guard/guard.py"
  guard_control="$tmp/runtime-guard-controls.py"
  scope_owner_channel_helper="$tmp/scope-fixture-owner-channel.py"
  /bin/cat >"$scope_owner_channel_helper" <<'PY_FIXTURE_OWNER_CHANNEL'
import hashlib,json,os,stat,sys,time
from pathlib import Path

def identity(value):
    return [value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,
            value.st_size,value.st_mtime_ns,value.st_ctime_ns]

def snapshot(path,maximum):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and before.st_nlink==1 and before.st_size<=maximum
        raw=bytearray()
        while len(raw)<=maximum:
            block=os.read(fd,min(65536,maximum+1-len(raw)))
            if not block:break
            raw.extend(block)
        assert len(raw)<=maximum and identity(os.fstat(fd))==identity(before)==identity(os.lstat(path))
        return bytes(raw),before
    finally:os.close(fd)

operation,area,base,driver,serial=sys.argv[1:]
area,base,driver=map(Path,(area,base,driver))
assert area.resolve()==area and base.resolve()==base and driver==area/'runtime-guard-controls.py'
assert serial in ('1','2') and operation in ('prepare','confirm','ready')
stem=area/('scope-owner-'+serial)
context=Path(str(stem)+'.json');channel=Path(str(stem)+'.fifo')
receipt=Path(str(stem)+'.receipt');ready=Path(str(stem)+'.ready')
if operation=='prepare':
    raw,source=snapshot(driver,16*1024*1024)
    fixture=os.lstat(base)
    assert stat.S_ISDIR(fixture.st_mode) and fixture.st_uid==0 and not fixture.st_mode&0o022
    os.mkfifo(channel,0o600)
    pipe=os.lstat(channel)
    value={'invocation':str(stem),'driver_sha256':hashlib.sha256(raw).hexdigest(),
           'driver_identity':identity(source),'fixture':identity(fixture)[:5],
           'channel':identity(pipe)[:6]}
    fd=os.open(context,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        data=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
        assert os.write(fd,data)==len(data);os.fsync(fd)
    finally:os.close(fd)
else:
    raw,state=snapshot(context,4096);expected=json.loads(raw)
    current,source=snapshot(driver,16*1024*1024)
    assert identity(source)==expected['driver_identity'] and hashlib.sha256(current).hexdigest()==expected['driver_sha256']
    assert identity(os.lstat(base))[:5]==expected['fixture']
    assert identity(os.lstat(channel))[:6]==expected['channel']
    if operation=='ready':
        end=time.monotonic()+10
        while not ready.exists():
            assert time.monotonic()<end
            time.sleep(0.02)
        data,info=snapshot(ready,4096)
        assert info.st_uid==0 and stat.S_IMODE(info.st_mode)==0o444
        assert json.loads(data)=={'context_sha256':hashlib.sha256(raw).hexdigest(),'foreground_started':True}
    else:
        data,info=snapshot(receipt,16384);value=json.loads(data)
        assert info.st_uid==0 and stat.S_IMODE(info.st_mode)==0o444
        assert set(value)=={'context_sha256','driver_pid','cases','cancelled','quiescent'}
        assert value['context_sha256']==hashlib.sha256(raw).hexdigest()
        assert type(value['driver_pid']) is int and value['driver_pid']>0 and value['quiescent'] is True
        assert type(value['cancelled']) is bool and type(value['cases']) is list and len(value['cases'])<=16
        assert all(set(row)=={'pid','returncode','foreground_count','foreground_sha256'} and
                   type(row['pid']) is int and row['pid']>0 and type(row['returncode']) is int and
                   type(row['foreground_count']) is int and 0<=row['foreground_count']<=4096 and
                   type(row['foreground_sha256']) is str and len(row['foreground_sha256'])==64
                   for row in value['cases'])
        if serial=='1':
            assert value['cancelled'] and len(value['cases'])==1 and value['cases'][0]['foreground_count']==1
        print(json.dumps(value,sort_keys=True),flush=True)
PY_FIXTURE_OWNER_CHANNEL
  entry_source="$tmp/runtime-bootstrap-entry.py"
  "$python_bin" -I -S -B - "$root/scripts/test/scope-qualification.test.sh" "$guard_source" "$entry_source" <<'PY_GUARD_EXTRACT'
from pathlib import Path
import hashlib
import sys
source = Path(sys.argv[1]).read_bytes().splitlines(keepends=True)
opening = b'  /bin/cat >"$mac_guard_file" <<\'PY_MAC_FIXED_RUNTIME_GUARD\'\n'
closing = b'PY_MAC_FIXED_RUNTIME_GUARD\n'
starts = [index for index, line in enumerate(source) if line == opening]
stops = [index for index, line in enumerate(source) if line == closing]
assert len(starts) == len(stops) == 1 and starts[0] < stops[0]
body = b''.join(source[starts[0] + 1:stops[0]])
assert hashlib.sha256(body).hexdigest() == '3c229ffd250d8b255ae59ae1f507e3815c9f6bfb25b793c9075871675a1a540c'
compile(body, 'actual-runtime-guard', 'exec')
assert Path(sys.argv[2]).read_bytes() == body
Path(sys.argv[3]).write_bytes(body)
PY_GUARD_EXTRACT
  /bin/cat >"$guard_control" <<'PY_GUARD_CONTROLS'
import ast
import ctypes
import errno
import importlib.util
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import pwd
import selectors
import signal
import shutil
import stat
import struct
import subprocess
import sys
import time

base, package, python, guard_file = map(Path, sys.argv[1:5])
operator = sys.argv[5]
entry = Path(sys.argv[6]).read_text()
assert len(entry.encode()) <= 16 * 1024 * 1024
assert os.getuid() == 0 and pwd.getpwnam(operator).pw_uid != 0
assert base.resolve() == base and base.is_dir() and base.stat().st_uid == 0
assert python.resolve() == python
assert python == Path('/Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python')
prefix = Path('/Library/Frameworks/Python.framework/Versions/3.15')
fixture = base / ('runtime-guard-cancel-proof' if Path(sys.argv[7]).name == 'scope-owner-1.json' else 'runtime-guard')
assert not os.path.lexists(fixture)
fixture.mkdir(mode=0o755)
fixture.chmod(0o755)
copied = fixture / 'installation'
copied.mkdir(mode=0o755)
(copied / 'Versions').mkdir(mode=0o755)
shutil.copytree(prefix, copied / 'Versions/3.15', symlinks=True)
shutil.copytree(prefix.parent.parent / 'ystack-private-tools', copied / 'ystack-private-tools', symlinks=True)
selected = copied / 'Versions/3.15/Resources/Python.app/Contents/MacOS/Python'
assert selected.read_bytes() == python.read_bytes()
for path in (fixture, copied, *copied.rglob('*')):
    value = path.lstat()
    if stat.S_ISDIR(value.st_mode):
        path.chmod(0o755)
    elif stat.S_ISLNK(value.st_mode):
        os.chmod(path, 0o755, follow_symlinks=False)
    value = path.lstat()
    assert value.st_uid == 0 and not value.st_mode & 0o022
guard = guard_file.read_bytes()
program = fixture / 'guard.py'
wrapper_prefix = r"""import dis, json, os, signal, sys, time, types
from pathlib import Path
code_path=Path(sys.argv.pop(1))
short_proof=code_path.name=='owner-cancel-proof.py' and code_path.parent==Path(sys.argv[1]).parent/'runtime-guard-cancel-proof'
code = code_path.read_bytes()
foreground = {}
proofs = []
last_identity = None
identity_refusal = None
original_name = 'actual-runtime-guard'
consumer_name = str(Path(sys.argv[1]) / 'shadow/v1/_consumer.py')
compiled_code = compile(code, original_name, 'exec')
source_lines = code.decode().splitlines()
def code_tree(code):
    result = {code}
    for value in code.co_consts:
        if isinstance(value, types.CodeType):
            result.update(code_tree(value))
    return result
with open(consumer_name, 'rb') as source:
    consumer_bytes = source.read(16 * 1024 * 1024 + 1)
assert len(consumer_bytes) <= 16 * 1024 * 1024
bound_codes = {original_name: code_tree(compiled_code),
    consumer_name: code_tree(compile(consumer_bytes, consumer_name, 'exec', dont_inherit=True))}
identity_line = "assert uptime() < deadline and identity(os.lstat(name)) == before"
identity_lines = {index + 1 for index, line in enumerate(source_lines) if line.strip() == identity_line}
assert identity_lines
identity_callers = {item for item in bound_codes[original_name]
    if identity_lines & {line for offset, line in dis.findlinestarts(item)}}

def bound(frame):
    return (frame.f_code.co_filename in bound_codes and
            frame.f_code in bound_codes[frame.f_code.co_filename])
print('GUARD_ACTUAL_PRINCIPAL ' + json.dumps({'pid': os.getpid(), 'uid': os.getuid(), 'gid': os.getgid(),
    'groups': os.getgroups()}, sort_keys=True), file=sys.stderr, flush=True)

def observe(frame, event, arg):
    global last_identity, identity_refusal
    if frame.f_code.co_filename == consumer_name and frame.f_code.co_name == '_foreground':
        if short_proof and event=='line' and not foreground.get('ready'):
            child=frame.f_locals.get('child')
            outputs=frame.f_locals.get('outputs')
            if child is not None and outputs is not None and not child.stdout.closed:
                if outputs.get(child.stdout.fileno())==b'TERM_RESISTANT_READY\n':
                    print('OWNER_FOREGROUND_READY',flush=True)
                    foreground['ready']=True
        if event == 'call':
            foreground[id(frame)] = True
        elif event == 'return':
            child = frame.f_locals.get('child')
            streams = () if child is None else (child.stdin, child.stdout, child.stderr)
            proofs.append({'pid': None if child is None else child.pid,
                'returncode': None if child is None else child.returncode,
                'reaped': child is None or child.returncode is not None,
                'pipes_closed': all(item is None or item.closed for item in streams)})
            foreground.pop(id(frame), None)
            foreground.pop('ready',None)
    if frame.f_code.co_filename == original_name and frame.f_code.co_name == 'identity' and event == 'return':
        caller = frame.f_back
        if caller is not None and caller.f_code.co_filename == original_name:
            if bound(caller) and caller.f_lineno in identity_lines:
                last_identity = {'name': caller.f_locals['name'], 'actual': list(arg),
                    'expected': list(caller.f_locals['before']), 'deadline': caller.f_locals['deadline']}
    if event == 'exception' and frame.f_code.co_filename == original_name:
        if bound(frame) and frame.f_lineno in identity_lines:
            if isinstance(arg[1], AssertionError) and last_identity is not None:
                now = time.clock_gettime(time.CLOCK_UPTIME_RAW)
                identity_refusal = dict(last_identity, observed_time=now,
                    deadline_valid=now < last_identity['deadline'],
                    actual_identity_comparison_reached=True)
    return observe

def dispatch(frame, event, arg):
    if event != 'call' or not bound(frame):
        return None
    foreground_call = frame.f_code.co_filename == consumer_name and frame.f_code.co_name == '_foreground'
    guard_call = (frame.f_code.co_filename == original_name and
                  (frame.f_code.co_name == 'identity' or frame.f_code in identity_callers))
    if not foreground_call and not guard_call:
        return None
    frame.f_trace_lines = short_proof and foreground_call
    if foreground_call:
        observe(frame, event, arg)
    return observe

def cancel(_number, _frame):
    raise InterruptedError('private guard cancelled')

for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, cancel)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
sys.settrace(dispatch)
try:
    exec(compiled_code, {'__name__': '__main__'})
finally:
    sys.settrace(None)
    if identity_refusal is not None:
        print('GUARD_IDENTITY_REFUSAL ' + json.dumps(identity_refusal, sort_keys=True), file=sys.stderr, flush=True)
    print('GUARD_OWNED_CLEANUP ' + json.dumps({'foreground_calls': proofs,
        'active_calls': len(foreground), 'complete': not foreground and all(
            item['reaped'] and item['pipes_closed'] for item in proofs)}, sort_keys=True), file=sys.stderr, flush=True)
"""
program.write_text(wrapper_prefix)
program.chmod(0o444)
original_program = fixture / 'guard-original.py'
guard_ast = ast.parse(guard)
parser_functions = [node for node in guard_ast.body if isinstance(node, ast.FunctionDef)
                    and node.name in ('uptime', 'native_slices', 'static_data', 'native_dependencies')]
assert len(parser_functions) == 4
parser_namespace = {'Path': Path, 'struct': struct, 'hashlib': hashlib, 'time': time, 'math': math,
    'deadline': time.clock_gettime(time.CLOCK_UPTIME_RAW) + 120, 'prefix': copied / 'Versions/3.15',
    'canonical_fixed': lambda path: path, 'static_paths': set()}
exec(compile(ast.Module(body=parser_functions, type_ignores=[]), 'exact-native-format-controls', 'exec'), parser_namespace)
for name in ('Frameworks/Tcl.framework/Versions/9.0/libtclstub.a',
             'Frameworks/Tk.framework/Versions/9.0/libtkstub.a',
             'lib/python3.15/config-3.15-darwin/python.o'):
    path = copied / 'Versions/3.15' / name
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= 16 * 1024 * 1024
        raw = bytearray()
        while True:
            block = os.read(fd, min(65536, 16 * 1024 * 1024 + 1 - len(raw)))
            if not block:
                break
            raw.extend(block)
            assert len(raw) <= 16 * 1024 * 1024
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        assert all(getattr(before, key) == getattr(os.fstat(fd), key) == getattr(path.lstat(), key) for key in fields)
    finally:
        os.close(fd)
    parser_namespace['native_dependencies'](path, bytes(raw))
    malformed = bytearray(raw)
    struct.pack_into('>I', malformed, 4, 0)
    for label, candidate, data, loaded in (
        ('loaded-static', path, bytes(raw), True),
        ('unknown-static-path', path.parent / 'unlisted-native-container', bytes(raw), False),
        ('malformed-fat', path, bytes(malformed), False)):
        try:
            parser_namespace['native_dependencies'](candidate, data, loaded)
        except (AssertionError, ValueError, struct.error):
            print('native-format refuses ' + label + ' ' + name, flush=True)
        else:
            raise AssertionError('native-format control accepted ' + label)
assert len(parser_namespace['static_paths']) == 3
imports = [node for node in guard_ast.body if isinstance(node, (ast.Import, ast.ImportFrom))]
functions = [node for node in guard_ast.body if isinstance(node, ast.FunctionDef)]
package_start = guard.decode().index('package = Path(sys.argv[1])')
package_end = guard.decode().index('locator = Path(sys.argv[2])', package_start)
state_start = guard.decode().index('owned = []', package_end)
state_end = guard.decode().index('def identity(', state_start)
try_start = guard.decode().index('try:\n    library = c._DARWIN_ACL_FUNCTIONS.library')
try_end = guard.decode().index("    if stage == 'empty':", try_start)
report_start = guard.decode().index("    print(json.dumps({'bootstrap':", try_start)
except_start = guard.decode().index('except BaseException as error:', try_end)
metadata_header = """locator = Path(sys.argv[2])
selected = Path(os.path.realpath(str(locator)))
fixed_root = selected.parents[6]
fixed_prefix = fixed_root / 'Versions/3.15'
fixed_tools = fixed_root / 'ystack-private-tools'
fixed_p = selected
prefix = fixed_prefix
stdlib = prefix / 'lib/python3.15'
logical_prefix = Path('/Library/Frameworks/Python.framework/Versions/3.15')

def copied_load_target(name):
    target = Path(name)
    assert target.is_absolute()
    if target == logical_prefix or logical_prefix in target.parents:
        assert '..' not in target.parts
        target = prefix / target.relative_to(logical_prefix)
    elif target == prefix or prefix in target.parents:
        target = Path(os.path.normpath(name))
        c._require(target == prefix or prefix in target.parents, 'E_INSTALL')
    else:
        target = Path(os.path.normpath(name))
        assert str(target).startswith(('/usr/lib/', '/System/Library/'))
    if target == prefix or prefix in target.parents:
        target = canonical_fixed(target)
        assert target == prefix or prefix in target.parents
    return target

assert selected == prefix / 'Resources/Python.app/Contents/MacOS/Python'
stage = 'real'
deadline = time.clock_gettime(time.CLOCK_UPTIME_RAW) + 120
"""
metadata_subject = '\n'.join(ast.get_source_segment(guard.decode(), node) for node in imports) + '\n'
metadata_subject += guard.decode()[package_start:package_end] + metadata_header
metadata_subject += guard.decode()[state_start:state_end]
metadata_functions = '\n'.join(ast.get_source_segment(guard.decode(), node) for node in functions)
assert metadata_functions.count('target = Path(os.path.normpath(name))') == 1
metadata_subject += metadata_functions.replace('target = Path(os.path.normpath(name))',
    'target = copied_load_target(name)') + '\n'
metadata_try = guard.decode()[try_start:report_start]
edge_count = "sum(name.startswith(str(prefix) + '/') for source, command, name in load_edges) == 17"
assert metadata_try.count(edge_count) == 1
metadata_try = metadata_try.replace(edge_count, edge_count.replace('str(prefix)', 'str(logical_prefix)'))
parser_boundary = "    for item in reversed((locator, *locator.parents)):\n"
assert metadata_try.count(parser_boundary) == 1
parser_control = """    parser_file = prefix / 'lib/python3.15/guard-untrusted.dylib'
    if os.path.lexists(parser_file):
        parser_held = c._hold_bytes(str(parser_file), c.EXECUTABLE_LIMIT)
        owned.append(parser_held)
        parser_held.recheck('E_STALE')
        manifest[str(parser_file.relative_to(fixed_root))] = {'kind': stat.S_IFREG}
        parser_raw = inspect(parser_file)
        assert parser_raw == parser_held.raw
        print('GUARD_NATIVE_PARSER_BOUNDARY', file=sys.stderr, flush=True)
        native_dependencies(parser_file, parser_raw)
        raise AssertionError('owned invalid native edge accepted')
"""
metadata_subject += metadata_try.replace(parser_boundary, parser_control + parser_boundary)
metadata_subject += "    print(json.dumps({'metadata_control': True, 'candidate_executed': False, 'privileged_execution': False}, sort_keys=True), file=sys.stderr)\n    print(selected)\n"
metadata_subject += guard.decode()[except_start:].replace("'candidate_executed': stage == 'real'", "'candidate_executed': False")
assert not any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
               and node.func.attr in ('execv', 'execve') for node in ast.walk(ast.parse(metadata_subject)))
compile(metadata_subject, 'actual-runtime-guard', 'exec')
original_program.write_text(metadata_subject)

original_program.chmod(0o444)
sync_program = fixture / 'guard-held-change.py'
boundary = b'    for name, (before, _digest) in rows.items():\n'
assert metadata_subject.encode().count(boundary) == 1
checkpoint = b"    print('HELD_READY', flush=True)\n    assert sys.stdin.buffer.read(1) == b'S'\n"
sync_program.write_bytes(metadata_subject.encode().replace(boundary, checkpoint + boundary))
sync_program.chmod(0o444)
module = copied / 'Versions/3.15/lib/python3.15/os.py'
ancestor = selected.parent
original_module = module.read_bytes()
original_python = selected.read_bytes()

operator_record = pwd.getpwnam(operator)
operator_groups = os.getgrouplist(operator, operator_record.pw_gid)
assert operator_record.pw_uid != 0 and operator_record.pw_gid in operator_groups
pending_path = base / 'runtime-guard-cleanup-uncertain'

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        assert key not in value, 'duplicate cleanup field'
        value[key] = item
    return value

def confirmation(stderr):
    lines = stderr.splitlines()
    rows = [line[len(b'GUARD_OWNED_CLEANUP '):] for line in lines
            if line.startswith(b'GUARD_OWNED_CLEANUP ')]
    assert len(rows) == 1, 'missing or duplicate cleanup confirmation'
    value = json.loads(rows[0].decode('utf-8'), object_pairs_hook=unique_object)
    assert type(value) is dict and set(value) == {'active_calls', 'complete', 'foreground_calls'}
    assert type(value['active_calls']) is int and value['active_calls'] == 0
    assert value['complete'] is True and type(value['foreground_calls']) is list
    assert len(value['foreground_calls']) <= 4096
    for row in value['foreground_calls']:
        assert type(row) is dict and set(row) == {'pid', 'returncode', 'reaped', 'pipes_closed'}
        assert row['reaped'] is True and row['pipes_closed'] is True
        if row['pid'] is None:
            assert row['returncode'] is None
        else:
            assert type(row['pid']) is int and row['pid'] > 0 and type(row['returncode']) is int
    return value

def completed_case(returncode, stderr, cancelled):
    assert type(returncode) is int, 'direct command not reaped'
    value = confirmation(stderr)
    assert not cancelled, 'cancelled completion window'
    return value

valid_cleanup = b'GUARD_OWNED_CLEANUP {"active_calls":0,"complete":true,"foreground_calls":[]}\n'
assert completed_case(0, valid_cleanup, False)['complete']
for label, raw, cancelled in (
    ('EOF-then-wait-cancel', valid_cleanup, True),
    ('post-wait-precommit-cancel', valid_cleanup, True),
    ('missing-cleanup', b'', False),
    ('partial-cleanup', b'GUARD_OWNED_CLEANUP {', False),
    ('malformed-cleanup', b'GUARD_OWNED_CLEANUP []\n', False),
    ('duplicate-cleanup', valid_cleanup * 2, False),
    ('unreaped-native', b'GUARD_OWNED_CLEANUP {"active_calls":0,"complete":true,"foreground_calls":[{"pid":1,"returncode":null,"reaped":true,"pipes_closed":true}]}\n', False)):
    try:
        completed_case(0, raw, cancelled)
    except (AssertionError, ValueError, UnicodeError):
        print('pure completion-state refuses ' + label + '; pending cannot be released', flush=True)
    else:
        raise AssertionError('completion-state accepted ' + label)

class ScopeFixtureOwnerCancel:
    def __init__(self):
        self.cancelled=False
        self.active=False
        self.cases=[]
        self.context=Path(sys.argv[7])
        self.context_raw,self.context_state=self.snapshot(self.context,4096)
        self.expected=json.loads(self.context_raw)
        self.stem=Path(self.expected['invocation'])
        assert self.context==Path(str(self.stem)+'.json') and self.stem.parent==Path(sys.argv[0]).parent
        self.source_fd=None
        self.fixture_fd=None
        try:
            self.source_fd=os.open(sys.argv[0],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            self.fixture_fd=os.open(base,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            assert self.identity(os.fstat(self.source_fd))==self.expected['driver_identity']
            assert self.identity(os.fstat(self.fixture_fd))[:5]==self.expected['fixture']
            assert self.identity(os.fstat(0))[:6]==self.expected['channel'] and stat.S_ISFIFO(os.fstat(0).st_mode)
            assert fcntl.fcntl(0,fcntl.F_GETFL)&os.O_ACCMODE==os.O_RDONLY
            assert os.getuid()==0
            os.set_blocking(0,False)
        except BaseException:
            if self.source_fd is not None:os.close(self.source_fd)
            if self.fixture_fd is not None:os.close(self.fixture_fd)
            raise

    @staticmethod
    def identity(value):
        return [value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,value.st_nlink,
                value.st_size,value.st_mtime_ns,value.st_ctime_ns]

    @classmethod
    def snapshot(cls,path,maximum):
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            before=os.fstat(fd)
            assert stat.S_ISREG(before.st_mode) and before.st_nlink==1 and before.st_size<=maximum
            raw=bytearray()
            while len(raw)<=maximum:
                block=os.read(fd,min(65536,maximum+1-len(raw)))
                if not block:break
                raw.extend(block)
            raw=bytes(raw)
            assert len(raw)<=maximum and cls.identity(os.fstat(fd))==cls.identity(before)==cls.identity(os.lstat(path))
            return raw,before
        finally:os.close(fd)

    def check(self):
        try:
            data=os.read(0,1)
        except BlockingIOError:
            data=None
        if data is not None:self.cancelled=True
        if self.cancelled:raise InterruptedError('scope fixture owner cancelled')

    def publish(self,suffix,value):
        raw=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
        assert len(raw)<=16384
        fd=os.open(str(self.stem)+suffix,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o400)
        try:
            assert os.write(fd,raw)==len(raw)
            os.fchmod(fd,0o444)
            os.fsync(fd)
        finally:os.close(fd)
        parent=os.open(self.stem.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(parent)
        finally:os.close(parent)

    def settled(self,child,stderr):
        assert child is not None and type(child.returncode) is int
        assert all(stream.closed for stream in (child.stdin,child.stdout,child.stderr))
        value=confirmation(stderr)
        self.cases.append({'pid':child.pid,'returncode':child.returncode,
            'foreground_count':len(value['foreground_calls']),
            'foreground_sha256':hashlib.sha256(json.dumps(value['foreground_calls'],sort_keys=True).encode()).hexdigest()})
        assert len(self.cases)<=16
        self.active=False

    def finish(self):
        try:
            assert not self.active
            raw,state=self.snapshot(self.context,4096)
            assert raw==self.context_raw and self.identity(state)==self.identity(self.context_state)
            source,state=self.snapshot(Path(sys.argv[0]),16*1024*1024)
            assert self.identity(state)==self.expected['driver_identity']
            assert hashlib.sha256(source).hexdigest()==self.expected['driver_sha256']
            assert self.identity(os.fstat(self.source_fd))==self.expected['driver_identity']
            assert self.identity(os.fstat(self.fixture_fd))[:5]==self.expected['fixture']==self.identity(os.lstat(base))[:5]
            os.close(self.source_fd)
            self.source_fd=None
            os.close(self.fixture_fd)
            self.fixture_fd=None
            self.publish('.receipt',{'context_sha256':hashlib.sha256(raw).hexdigest(),
                'driver_pid':os.getpid(),'cases':self.cases,'cancelled':self.cancelled,'quiescent':True})
        finally:
            if self.source_fd is not None:os.close(self.source_fd)
            if self.fixture_fd is not None:os.close(self.fixture_fd)

    def acl(self,argv):
        self.check()
        assert not self.active
        assert argv in [[ '/bin/chmod', '+a', 'user:'+operator+' allow write',str(path)]
                        for path in (selected,ancestor,module,entry_data,entry_directory)]+[['/bin/chmod','-N',str(path)]
                        for path in (selected,ancestor,module,entry_data,entry_directory)]
        self.active=True
        result=subprocess.run(argv,capture_output=True,timeout=10)
        self.active=False
        return result

def run_control(label, expected, synchronized=False):
    owner_cancel.check()
    source = sync_program if synchronized else original_program
    command = [str(python), '-I', '-S', '-B', str(program), str(source),
               str(package), str(selected), str(guard_file)]
    end = time.monotonic() + 145
    pending_fd = os.open(pending_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    pending_identity = os.fstat(pending_fd)
    try:
        payload = json.dumps({'case': label, 'state': 'PENDING'}, sort_keys=True).encode() + b'\n'
        assert os.write(pending_fd, payload) == len(payload)
        os.fsync(pending_fd)
    finally:
        os.close(pending_fd)
    directory_fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    watched = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, watched)
    previous_handlers = {number: signal.getsignal(number) for number in watched}
    cancelled = [False]
    def cancelled_signal(_number, _frame):
        cancelled[0] = True
    for number in watched:
        signal.signal(number, cancelled_signal)
    child = None
    waited = False
    supervision_known = True
    selector = selectors.DefaultSelector()
    buckets = {}
    readiness = False
    first_error = None
    def uncertain_cleanup(error):
        print(json.dumps({'case': label, 'guard_cleanup': 'FAIL_PENDING',
            'command_pid': None if child is None else child.pid,
            'command_returncode': None if child is None else child.returncode,
            'error': type(error).__name__, 'pending_retained': pending_path.exists()},
            sort_keys=True), flush=True)
    try:
        try:
            owner_cancel.check()
            owner_cancel.active=True
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, user=operator_record.pw_uid, group=operator_record.pw_gid,
                extra_groups=operator_groups, close_fds=True, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C'})
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            buckets = {child.stdout: bytearray(), child.stderr: bytearray()}
            for stream in (child.stdin, child.stdout, child.stderr):
                os.set_blocking(stream.fileno(), False)
            for stream in buckets:
                selector.register(stream, selectors.EVENT_READ)
            if not synchronized:
                child.stdin.close()
            control_end = end - 15
            while selector.get_map():
                owner_cancel.check()
                assert not cancelled[0] and time.monotonic() < control_end, 'cancel/continuous guard deadline'
                for key, events in selector.select(min(0.1, max(0, control_end - time.monotonic()))):
                    stream = key.fileobj
                    if stream is child.stdin:
                        assert os.write(stream.fileno(), b'S') == 1
                        selector.unregister(stream)
                        stream.close()
                        continue
                    try:
                        chunk = os.read(stream.fileno(), 4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(stream)
                        stream.close()
                        continue
                    assert sum(map(len, buckets.values())) + len(chunk) <= 65536, 'total output cap'
                    buckets[stream].extend(chunk)
                    if label=='fixed-short-owner-cancel' and b'OWNER_FOREGROUND_READY\n' in buckets[stream]:
                        ready=Path(str(owner_cancel.stem)+'.ready')
                        if not ready.exists():
                            owner_cancel.publish('.ready',{'context_sha256':hashlib.sha256(owner_cancel.context_raw).hexdigest(),
                                'foreground_started':True})
                    if synchronized and not readiness and stream is child.stdout:
                        assert b'HELD_READY\n'.startswith(bytes(buckets[stream])), 'readiness frame'
                        if bytes(buckets[stream]) == b'HELD_READY\n':
                            with module.open('ab') as target:
                                assert target.write(b'\n') == 1
                                target.flush()
                                os.fsync(target.fileno())
                            readiness = True
                            selector.register(child.stdin, selectors.EVENT_WRITE)
            child.wait(timeout=max(0.001, control_end - time.monotonic()))
            waited = True
        except BaseException as error:
            first_error = error
            supervision_known = ((isinstance(error,InterruptedError) and owner_cancel.cancelled) or
                (isinstance(error,AssertionError) and str(error)=='cancel/continuous guard deadline'))
            if child is None:
                raise
            if child.returncode is None:
                child.terminate()
            try:
                while selector.get_map() and time.monotonic() < end:
                    for key, events in selector.select(min(0.1, max(0, end - time.monotonic()))):
                        stream = key.fileobj
                        if stream is child.stdin:
                            selector.unregister(stream)
                            stream.close()
                            continue
                        try:
                            chunk = os.read(stream.fileno(), 4096)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(stream)
                            stream.close()
                        elif sum(map(len, buckets.values())) + len(chunk) <= 65536:
                            buckets[stream].extend(chunk)
                child.wait(timeout=max(0.001, end - time.monotonic()))
                waited = True
            except BaseException as cleanup_error:
                supervision_known = False
                if child.returncode is None:
                    child.kill()
                try:
                    child.wait(timeout=max(0.001, end - time.monotonic()))
                    waited = True
                except BaseException as reap_error:
                    uncertain_cleanup(reap_error)
                    raise error from reap_error
                uncertain_cleanup(cleanup_error)
                raise error from cleanup_error
        try:
            signal.pthread_sigmask(signal.SIG_BLOCK, watched)
            stdout, stderr = map(bytes, buckets.values())
            report = {'case': label, 'returncode': child.returncode, 'stdout': stdout.decode('utf-8'),
                'stderr': stderr.decode('utf-8'), 'operator_uid': operator_record.pw_uid,
                'operator_primary_gid': operator_record.pw_gid, 'operator_groups': operator_groups,
                'candidate_executed': False, 'candidate_sudo_executed': False,
                'command_reaped': child.returncode is not None, 'sudo_monitor_created': False}
            print(json.dumps(report, sort_keys=True), flush=True)
            principals = [line[len(b'GUARD_ACTUAL_PRINCIPAL '):] for line in stderr.splitlines()
                          if line.startswith(b'GUARD_ACTUAL_PRINCIPAL ')]
            assert len(principals) == 1
            principal = json.loads(principals[0])
            assert principal['uid'] == operator_record.pw_uid and principal['gid'] == operator_record.pw_gid
            assert set(principal['groups']) == set(operator_groups)
            assert principal['pid'] == child.pid, 'physical entry changed owned PID'
            completed_case(child.returncode, stderr, cancelled[0] or bool(signal.sigpending() & watched))
            if first_error is not None:
                raise first_error
            if expected is None:
                assert child.returncode == 0 and stdout == (str(selected) + '\n').encode()
                assert b'"privileged_execution": false' in stderr
            else:
                assert child.returncode != 0 and stdout == (b'HELD_READY\n' if synchronized else b'')
                assert b'"candidate_executed": false' in stderr and expected in stderr
                if label in ('unknown-load-path', 'escaping-load-path'):
                    assert b'GUARD_NATIVE_PARSER_BOUNDARY' in stderr
                if synchronized:
                    observed = [line[len(b'GUARD_IDENTITY_REFUSAL '):] for line in stderr.splitlines()
                                if line.startswith(b'GUARD_IDENTITY_REFUSAL ')]
                    assert readiness and len(observed) == 1
                    evidence = json.loads(observed[0])
                    assert evidence['deadline_valid'] and evidence['actual_identity_comparison_reached']
                    assert evidence['name'] == str(module) and evidence['actual'] != evidence['expected']

            selector.close()
            for stream in (child.stdin, child.stdout, child.stderr):
                if not stream.closed:
                    stream.close()
            assert all(stream.closed for stream in (child.stdin, child.stdout, child.stderr))
            assert time.monotonic() < end, 'completion deadline'
            owner_cancel.check()
            assert not cancelled[0] and not signal.sigpending() & watched, 'cancelled success transition'
            current = pending_path.lstat()
            assert (current.st_dev, current.st_ino, current.st_uid, current.st_mode, current.st_nlink) == (
                pending_identity.st_dev, pending_identity.st_ino, pending_identity.st_uid,
                pending_identity.st_mode, pending_identity.st_nlink)
            assert pending_path.read_bytes() == payload
            pending_path.unlink()
        except BaseException as error:
            uncertain_cleanup(error)
            raise
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, watched)
        try:
            selector.close()
            if child is not None:
                for stream in (child.stdin, child.stdout, child.stderr):
                    if not stream.closed:
                        stream.close()
            if child is not None:
                assert waited and supervision_known, 'original child supervision not confirmed'
                owner_cancel.settled(child,bytes(buckets.get(child.stderr,b'')))
                if pending_path.exists():
                    current=pending_path.lstat()
                    assert (current.st_dev,current.st_ino,current.st_uid,current.st_mode,current.st_nlink)==(
                        pending_identity.st_dev,pending_identity.st_ino,pending_identity.st_uid,pending_identity.st_mode,pending_identity.st_nlink)
                    assert pending_path.read_bytes()==payload
                    pending_path.unlink()
            for number, handler in previous_handlers.items():
                signal.signal(number, handler)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

entry_ast = ast.parse(entry)
entry_rules = [node for node in ast.walk(entry_ast)
               if isinstance(node, ast.FunctionDef) and node.name in ('uptime', 'empty_acl', 'immutable')]
assert len(entry_rules) == 3
source = package / 'shadow/v1/_consumer.py'
spec = importlib.util.spec_from_file_location('owned_entry_metadata_consumer', source)
assert spec is not None and spec.loader is not None
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)
assert c._DARWIN_ACL_FUNCTIONS is not None
owner_cancel=ScopeFixtureOwnerCancel()
try:
    if owner_cancel.context.name=='scope-owner-1.json':
        proof_program=fixture/'owner-cancel-proof.py'
        proof_program.write_text("""import importlib.util,os,sys,time
from pathlib import Path
consumer=Path(sys.argv[1])/'shadow/v1/_consumer.py'
spec=importlib.util.spec_from_file_location('fixed_owner_cancel_consumer',consumer)
c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c)
child_code='\\n'.join(('import signal,time',
    'signal.signal(signal.SIGTERM,signal.SIG_IGN)',
    "print('TERM_RESISTANT_READY',flush=True)",
    'time.sleep(30)'))
command=[sys.executable,'-I','-S','-B','-c',child_code]
def fixed_sleep(argv,env,owner):
    assert argv==command and env=={'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C'}
c._closed_scope_child=fixed_sleep
instance=c._DarwinChildOwner.__new__(c._DarwinChildOwner)
name=str(consumer);before=tuple(os.lstat(name))
def identity(value):return tuple(value)
def uptime():return time.clock_gettime(time.CLOCK_UPTIME_RAW)
deadline=uptime()+120
assert uptime() < deadline and identity(os.lstat(name)) == before
instance._foreground(command,b'',4096,65536,10,{'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C'})
""")
        proof_program.chmod(0o444)
        original_program=proof_program
        run_control('fixed-short-owner-cancel',b'E_RUNTIME')
        raise AssertionError('short cancellation did not interrupt')
    def native_control_image(target=None):
        load = b''
        if target is not None:
            encoded = target.encode() + b'\0'
            size = (24 + len(encoded) + 7) // 8 * 8
            load = struct.pack('<6I', 0xc, size, 24, 0, 0, 0) + encoded
            load += b'\0' * (size - len(load))
        x86 = struct.pack('<8I', 0xfeedfacf, 0x01000007, 3, 6, int(bool(load)), len(load), 0, 0) + load
        arm = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 6, 0, 0, 0, 0)
        return (struct.pack('>2I', 0xcafebabe, 2) +
                struct.pack('>5I', 0x01000007, 3, 48, len(x86), 0) +
                struct.pack('>5I', 0x0100000c, 0, 48 + len(x86), len(arm), 0) + x86 + arm)

    def copied_binding_controls():
        import tempfile
        import types
        with (guard_file.parent / 'manifest.json').open('rb') as source:
            raw = source.read(16 * 1024 * 1024 + 1)
        assert len(raw) <= 16 * 1024 * 1024
        assert hashlib.sha256(raw).hexdigest() == 'e0d204e2827885c5f2f4278e709981b7fc1e02424d3bfa5ae2ff2af789789d26'
        source_rows = json.loads(raw)
        manifest = {row['path']: row for row in source_rows
                    if row['path'] == 'Versions/3.15' or row['path'].startswith('Versions/3.15/')}
        assert len(manifest) == 4496
        edges = [
            ('Resources/Python.app/Contents/MacOS/Python', 'Python'),
            ('bin/python3.15', 'Python'),
            ('bin/python3.15-intel64', 'Python'),
            ('lib/libform.6.dylib', 'lib/libncurses.6.dylib'),
            ('lib/libmenu.6.dylib', 'lib/libncurses.6.dylib'),
            ('lib/libpanel.6.dylib', 'lib/libncurses.6.dylib'),
            ('lib/libssl.3.dylib', 'lib/libcrypto.3.dylib'),
            ('lib/python3.15/lib-dynload/_curses.cpython-315-darwin.so', 'lib/libncurses.6.dylib'),
            ('lib/python3.15/lib-dynload/_curses_panel.cpython-315-darwin.so', 'lib/libncurses.6.dylib'),
            ('lib/python3.15/lib-dynload/_curses_panel.cpython-315-darwin.so', 'lib/libpanel.6.dylib'),
            ('lib/python3.15/lib-dynload/_hashlib.cpython-315-darwin.so', 'lib/libcrypto.3.dylib'),
            ('lib/python3.15/lib-dynload/_remote_debugging.cpython-315-darwin.so', 'lib/libzstd.1.dylib'),
            ('lib/python3.15/lib-dynload/_ssl.cpython-315-darwin.so', 'lib/libcrypto.3.dylib'),
            ('lib/python3.15/lib-dynload/_ssl.cpython-315-darwin.so', 'lib/libssl.3.dylib'),
            ('lib/python3.15/lib-dynload/_tkinter.cpython-315-darwin.so', 'Frameworks/Tcl.framework/Tcl'),
            ('lib/python3.15/lib-dynload/_tkinter.cpython-315-darwin.so', 'Frameworks/Tk.framework/Tk'),
            ('lib/python3.15/lib-dynload/_zstd.cpython-315-darwin.so', 'lib/libzstd.1.dylib'),
        ]

        def descriptors():
            result = []
            for name in os.listdir('/dev/fd'):
                try:
                    os.fstat(int(name))
                except OSError:
                    continue
                result.append(int(name))
            return sorted(result)

        before_fds = descriptors()
        with tempfile.TemporaryDirectory(prefix='copied-binding-', dir=fixture) as temporary:
            root = Path(temporary).resolve()
            physical_root = root / 'copy'
            physical_prefix = physical_root / 'Versions/3.15'
            physical_prefix.mkdir(parents=True)
            for row in manifest.values():
                if row['kind'] == stat.S_IFLNK:
                    link = physical_root / row['path']
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(row['link'])
                    os.chmod(link, 0o755, follow_symlinks=False)
            assert sum(row['kind'] == stat.S_IFLNK for row in manifest.values()) == 35
            targets = {}
            for source_name, target_name in edges:
                target = (physical_prefix / target_name).resolve()
                assert physical_prefix in target.parents
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(native_control_image())
                target.chmod(0o644)
                targets[target_name] = target
                (physical_prefix / source_name).parent.mkdir(parents=True, exist_ok=True)
            opened = []

            def owned_open(path, directory, rule, code):
                assert Path(path) == physical_root or physical_root in Path(path).parents
                opened.append(path)
                return c._open_held(path, directory, rule, code)

            def owned_rule(fd, value, ancestor):
                # Only the ordinary owned principal and ancestor mode facts adapt here.
                return stat.S_ISDIR(value.st_mode) if ancestor else (
                    value.st_uid == os.getuid() and not value.st_mode & 0o022)

            library = c._DARWIN_ACL_FUNCTIONS.library
            library.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
            library.acl_get_link_np.restype = ctypes.c_void_p
            ns = dict(Path=Path, os=os, stat=stat, ctypes=ctypes, errno=errno, hashlib=hashlib,
                      struct=struct, time=time, math=math, manifest=manifest, library=library,
                      c=types.SimpleNamespace(_open_held=owned_open, _require=c._require,
                                             EXECUTABLE_LIMIT=c.EXECUTABLE_LIMIT),
                      fixed_root=physical_root, prefix=physical_prefix,
                      logical_prefix=Path('/Library/Frameworks/Python.framework/Versions/3.15'),
                      selected=physical_prefix / 'Resources/Python.app/Contents/MacOS/Python',
                      rule=lambda: owned_rule, deadline=time.clock_gettime(time.CLOCK_UPTIME_RAW) + 120,
                      rows={}, links={}, images=set(), seen=set(), load_edges=set(), cache_paths=set(),
                      native_inventory={}, static_paths=set(), fields=fields)
            subject = ast.parse(metadata_subject)
            names = {'uptime', 'identity', 'empty_acl', 'canonical_fixed', 'inspect', 'native_slices',
                     'static_data', 'native_dependencies', 'copied_load_target'}
            functions = [node for node in subject.body if isinstance(node, ast.FunctionDef) and node.name in names]
            assert len(functions) == len(names)
            extracted = '\n'.join(ast.get_source_segment(metadata_subject, node) for node in functions)
            assert extracted.count('before.st_uid == 0') == 1
            extracted = extracted.replace('before.st_uid == 0', 'before.st_uid == os.getuid()')
            exec(compile(extracted, 'actual-copied-binding-functions-owned-principal', 'exec'), ns)
            logical_prefix = ns['logical_prefix']
            for source_name, target_name in edges:
                logical = str(logical_prefix / target_name)
                assert ns['copied_load_target'](logical) == targets[target_name]
                ns['native_dependencies'](physical_prefix / source_name, native_control_image(logical))
            assert len(ns['load_edges']) == 17
            assert all(name.startswith(str(logical_prefix) + '/') for source, command, name in ns['load_edges'])
            assert ns['images'] == set(targets.values())
            traversal = next(node for node in ast.walk(subject) if isinstance(node, ast.While)
                             and isinstance(node.test, ast.Name) and node.test.id == 'images')
            exec(compile(ast.Module(body=[traversal], type_ignores=[]), 'actual-copied-image-traversal', 'exec'), ns)
            assert ns['seen'] == set(targets.values()) and set(ns['rows']) == {str(path) for path in targets.values()}
            assert all(physical_root in Path(path).parents for path in opened)
            assert any('Tcl.framework' in name for name in ns['links'])
            assert any('Tk.framework' in name for name in ns['links'])
            assert any('libzstd.1.dylib' in name for name in ns['links'])
            parser_file = physical_prefix / 'lib/python3.15/guard-untrusted.dylib'
            parser_file.parent.mkdir(parents=True, exist_ok=True)
            manifest[str(parser_file.relative_to(physical_root))] = {'kind': stat.S_IFREG}
            load_refusals = []
            for label, dependency, expected_type, expected_function, expected_line in (
                    ('unknown-load-path', '@rpath/untrusted.dylib', AssertionError,
                     'native_dependencies', "assert name.startswith('/') and '@' not in name"),
                    ('escaping-load-path', '@loader_path/../../../../untrusted.dylib', c.Refusal,
                     'copied_load_target', "c._require(target == prefix or prefix in target.parents, 'E_INSTALL')")):
                data = native_control_image(dependency)
                for thin in (False, True):
                    raw = data[48:48 + struct.unpack_from('>I', data, 20)[0]] if thin else data
                    load_ns = dict(ns, rows={}, links={}, images=set(), load_edges=set(), seen=set())
                    exec(compile(extracted, 'actual-copied-binding-functions-owned-principal', 'exec'), load_ns)
                    parser_file.write_bytes(raw)
                    with_source = c._hold_bytes(str(parser_file), c.EXECUTABLE_LIMIT)
                    try:
                        with_source.recheck('E_STALE')
                        assert load_ns['inspect'](parser_file) == with_source.raw == raw
                    finally:
                        with_source.close()
                    try:
                        load_ns['native_dependencies'](parser_file, raw)
                    except (AssertionError, c.Refusal) as error:
                        frames = []
                        trace = error.__traceback__
                        lines = extracted.splitlines()
                        while trace is not None:
                            if trace.tb_frame.f_code.co_filename == 'actual-copied-binding-functions-owned-principal':
                                frames.append((trace.tb_frame.f_code.co_name, lines[trace.tb_lineno - 1].strip()))
                            trace = trace.tb_next
                        if thin:
                            assert type(error) is AssertionError
                            assert frames[-1] == ('native_dependencies', "assert name == 'bin/python3.15-intel64'")
                            assert all(name != 'copied_load_target' for name, line in frames)
                        else:
                            assert type(error) is expected_type
                            assert frames[-1] == (expected_function, expected_line)
                            if expected_type is c.Refusal:
                                assert error.code == 'E_INSTALL'
                        load_refusals.append({'case': label, 'thin': thin, 'type': type(error).__name__,
                                              'code': getattr(error, 'code', None), 'actual_frames': frames})
                    else:
                        raise AssertionError('native load refusal accepted ' + label)
            refused = []

            def reject(label, action):
                try:
                    action()
                except (AssertionError, OSError, ValueError, c.Refusal):
                    refused.append(label)
                else:
                    raise AssertionError('copied binding accepted ' + label)

            for label, name in (
                    ('other-version', str(logical_prefix.parent / '3.14/Python')),
                    ('prefix-lookalike', str(logical_prefix) + '-other/Python'),
                    ('logical-escape', str(logical_prefix) + '/../3.14/Python'),
                    ('physical-escape', str(physical_prefix) + '/../../../../escape'),
                    ('relative', 'Python'), ('unknown', '/copied-binding-untrusted/Python')):
                reject(label, lambda name=name: ns['copied_load_target'](name))
            assert ns['copied_load_target']('/usr/lib/libSystem.B.dylib') == Path('/usr/lib/libSystem.B.dylib')
            target = targets['Python']
            original_good = root / 'original-good'
            original_good.write_bytes(target.read_bytes())
            target.write_bytes(b'changed-copy')
            reject('changed-copy-not-original-good', lambda: ns['inspect'](ns['copied_load_target'](str(logical_prefix / 'Python'))))
            target.unlink()
            reject('missing-copy-not-original-good', lambda: ns['inspect'](ns['copied_load_target'](str(logical_prefix / 'Python'))))
            target.symlink_to(original_good)
            reject('copy-link-to-original-good', lambda: ns['copied_load_target'](str(logical_prefix / 'Python')))
            assert original_good.read_bytes() == native_control_image()
            assert all(not str(path).startswith(str(logical_prefix)) for path in opened)
        after_fds = descriptors()
        assert before_fds == after_fds
        print(json.dumps({'copied_binding_controls': 'PASS', 'logical_edges': 17, 'fixed_links': 35,
                          'refusals': refused, 'load_refusals': load_refusals, 'actual_opened_copy_paths': opened,
                          'fds_before': before_fds, 'fds_after': after_fds,
                          'ordinary_uid_ancestor_mode_adapter': True, 'copied_runtime_executed': False}, sort_keys=True), flush=True)

    copied_binding_controls()
    entry_namespace = {'ctypes': ctypes, 'errno': errno, 'time': time, 'math': math,
        'deadline': time.clock_gettime(time.CLOCK_UPTIME_RAW) + 120, 'library': c._DARWIN_ACL_FUNCTIONS.library}
    exec(compile(ast.Module(body=entry_rules, type_ignores=[]), 'actual-entry-rules', 'exec'), entry_namespace)
    entry_immutable = entry_namespace['immutable']
    entry_directory = fixture / 'entry-metadata'
    entry_directory.mkdir(mode=0o755)
    entry_directory.chmod(0o755)
    entry_data = entry_directory / 'data'
    entry_data.write_bytes(b'owned entry metadata control\n')
    entry_data.chmod(0o444)
    for path in (entry_directory, entry_data):
        value = path.lstat()
        assert value.st_uid == 0 and not value.st_mode & 0o022
    assert entry_data.stat().st_nlink == 1 and stat.S_ISREG(entry_data.stat().st_mode)

    def entry_metadata(label, refused=False):
        try:
            held = c._open_held(str(entry_data), False, entry_immutable, 'E_INSTALL')
        except c.Refusal as error:
            assert refused and error.code == 'E_INSTALL'
        else:
            try:
                assert not refused
                assert held.read(4096, 'E_INSTALL') == b'owned entry metadata control\n'
                held.recheck('E_STALE')
            finally:
                held.close()
        print(json.dumps({'entry_metadata': label, 'refused': refused,
            'candidate_executed': False, 'candidate_sudo_executed': False}, sort_keys=True), flush=True)

    entry_metadata('clean-owned-data')
    for label, path in (('file-write-ACL', entry_data), ('ancestor-write-ACL', entry_directory)):
        grant = owner_cancel.acl(['/bin/chmod', '+a', 'user:' + operator + ' allow write', str(path)])
        assert grant.returncode == 0 and not grant.stderr
        try:
            entry_metadata(label, refused=True)
        finally:
            remove = owner_cancel.acl(['/bin/chmod', '-N', str(path)])
            assert remove.returncode == 0 and not remove.stderr
    held = c._open_held(str(entry_data), False, entry_immutable, 'E_INSTALL')
    try:
        entry_data.write_bytes(b'owned entry metadata control changed\n')
        try:
            held.recheck('E_STALE')
        except c.Refusal as error:
            assert error.code == 'E_STALE'
        else:
            raise AssertionError('entry held mutation accepted')
    finally:
        held.close()
        entry_data.write_bytes(b'owned entry metadata control\n')
    print('entry metadata held mutation: actual E_STALE', flush=True)
    fd = os.open(entry_data, os.O_RDONLY | os.O_NOFOLLOW)
    saved = os.fstat(fd)
    os.close(fd)
    try:
        entry_immutable(fd, saved, False)
    except AssertionError:
        assert ctypes.get_errno() == errno.EBADF
    else:
        raise AssertionError('entry ACL query on closed fd accepted')
    print('entry metadata closed separate fd: actual EBADF; no second close', flush=True)
    entry_metadata('ACL-cleared-restored-owned-data')

    import types
    startup = next(node for node in guard_ast.body if isinstance(node, ast.If)
        and ast.get_source_segment(guard.decode(), node.test) == "stage == 'real'")
    window = next(node for node in guard_ast.body if isinstance(node, ast.Assert)
        and 'deadline <= guard_started + 120' in ast.get_source_segment(guard.decode(), node))
    assertions = compile(ast.Module(body=[window, *startup.body], type_ignores=[]), 'actual-fixed-entry-assertions', 'exec')
    def startup_namespace():
        proxy = types.SimpleNamespace(executable=sys.executable, version_info=sys.version_info,
            prefix=sys.prefix, base_prefix=sys.base_prefix, flags=sys.flags, path=list(sys.path))
        guard_started = time.clock_gettime(time.CLOCK_UPTIME_RAW)
        return {'sys': proxy, 'os': os, 'Path': Path, 'time': time, 'math': math,
            'uptime': entry_namespace['uptime'], 'guard_started': guard_started, 'entry_pid': os.getpid(),
            'fixed_p': python, 'fixed_prefix': prefix, 'deadline': guard_started + 120}
    exec(assertions, dict(startup_namespace(), sys=sys))
    for label, key, value in (
        ('executable', 'executable', '/entry-control-wrong-physical'),
        ('version', 'version_info', (0, 0, 0)),
        ('prefixes', 'prefix', '/entry-control-wrong-prefix'),
        ('paths', 'path', ['/entry-control-wrong-path']),
        ('flags', 'flags', types.SimpleNamespace(isolated=0, no_site=0, dont_write_bytecode=0)),
        ('pid', 'entry_pid', os.getpid() + 1),
        ('expired-deadline', 'deadline', time.clock_gettime(time.CLOCK_UPTIME_RAW) - 1),
        ('beyond-shared-window', 'deadline', time.clock_gettime(time.CLOCK_UPTIME_RAW) + 240)):
        changed = startup_namespace()
        if key in ('entry_pid', 'deadline'):
            changed[key] = value
        else:
            setattr(changed['sys'], key, value)
        try:
            exec(assertions, changed)
        except AssertionError:
            print('fixed startup operand model refuses ' + label + '; not host qualification', flush=True)
        else:
            raise AssertionError('fixed startup operand accepted ' + label)
    print('fixed entry actual-sys assertions plus eight explicit operand models PASS; actual entry still required', flush=True)

    run_control('unchanged-copied-existing-layout', None)
    for label, path in (('selected-P-write-ACL', selected),
                        ('ancestor-write-ACL', ancestor), ('startup-module-write-ACL', module)):
        grant = owner_cancel.acl(['/bin/chmod', '+a', 'user:' + operator + ' allow write', str(path)])
        assert grant.returncode == 0 and not grant.stderr
        try:
            run_control(label, b'E_INSTALL')
        finally:
            remove = owner_cancel.acl(['/bin/chmod', '-N', str(path)])
            assert remove.returncode == 0 and not remove.stderr
        assert selected.read_bytes() == original_python and module.read_bytes() == original_module
    run_control('held-module-identity-change', b'AssertionError', synchronized=True)
    module.write_bytes(original_module)
    for label, dependency in (('unknown-load-path', '@rpath/untrusted.dylib'),
                              ('escaping-load-path', '@loader_path/../../../../untrusted.dylib')):
        image = native_control_image(dependency)
        library = module.parent / 'guard-untrusted.dylib'
        library.write_bytes(image)
        library.chmod(0o444)
        try:
            run_control(label, b'AssertionError' if label == 'unknown-load-path' else b'E_INSTALL')
        finally:
            assert not owner_cancel.active
            library.unlink()
    run_control('restored-copied-existing-layout', None)
    assert selected.read_bytes() == original_python and module.read_bytes() == original_module
    print('actual Darwin ACL/identity/load-path guard controls PASS; no candidate execution', flush=True)
finally:
    owner_cancel.finish()
PY_GUARD_CONTROLS
  /usr/bin/sudo -n "$genuine_python" -I -S -B - "$guard_control" <<'PY_GUARD_SYNTAX'
from pathlib import Path
import sys
compile(Path(sys.argv[1]).read_bytes(), sys.argv[1], 'exec')
PY_GUARD_SYNTAX
  scope_fixture_owner_launch true
  scope_fixture_owner_launch false
}

prepare_genuine_writer() {
  /bin/cat >"$tmp/genuine-writer.py" <<'PY_STORAGE'
import importlib.util
import json
import os
from pathlib import Path
import sys

base = Path(__file__).absolute().parent
package = base / "package"
spec = importlib.util.spec_from_file_location("scope_fixture_consumer", package / "shadow/v1/_consumer.py")
assert spec is not None and spec.loader is not None
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)
class FixtureDarwinLedger:
    def __init__(self): self.commands = []
    def record_command(self, role, argv, executable, component):
        c._require(role in {"darwin-acl-uuid-resolution", "darwin-group-membership"}, "E_RUNTIME")
        c._require(len(self.commands) < 4096, "E_LIMIT")
        self.commands.append({"role":role,"argv_sha256":c.digest(canonical(argv)),
            "executable_sha256":executable,"component_sha256":component})
canonical = c.canonical
owned = []
store_fd = attempt_fd = None
try:
    darwin = None
    if sys.platform == "darwin":
        import time
        python = c._hold_bytes(sys.executable, c.EXECUTABLE_LIMIT)
        owned.append(python)
        consumer_source = c._hold_bytes(str(package / "shadow/v1/_consumer.py"), c.EXECUTABLE_LIMIT)
        owned.append(consumer_source)
        darwin = c._DarwinChildOwner(python, consumer_source, time.monotonic() + 120, FixtureDarwinLedger())
    source = c._open_held(c.ANCHOR + "/host-supervisor.py", False, c._root_rule(darwin), "E_RUNTIME")
    owned.append(source)
    source_raw = source.read(c.EXECUTABLE_LIMIT, "E_RUNTIME")
    config = c._open_held(c.ANCHOR + "/host-config.json", False, c._root_rule(darwin), "E_RUNTIME")
    owned.append(config)
    config_raw = config.read(c.DOCUMENT_LIMIT, "E_RUNTIME")
    settings = c._parse_config(config_raw)
    packet_file = c._open_held(str(base / "storage-input.json"), False, c._root_rule(darwin), "E_RUNTIME")
    owned.append(packet_file)
    packet_raw = packet_file.read(c.DOCUMENT_LIMIT, "E_RUNTIME")
    packet = c._json(packet_raw, c.DOCUMENT_LIMIT, "E_RUNTIME")
    c._require(set(packet) == {"attempt_id", "receipt_utf8", "stdout_utf8", "stderr_utf8",
                              "manifest_utf8", "evidence_utf8"}
               and c._id(packet["attempt_id"])
               and all(type(packet[key]) is str for key in packet), "E_RUNTIME")
    uid, gid = settings["principal_uid"], settings["consumer_gid"]
    c._require(os.getuid() == os.geteuid() == uid and uid != 0
               and gid in (os.getgid(), *os.getgroups()), "E_RUNTIME")
    receipt = packet["receipt_utf8"].encode()
    c._require(c._json(receipt, c.DOCUMENT_LIMIT, "E_RUNTIME")["body"]["attempt"]["attempt_id"]
               == packet["attempt_id"], "E_RUNTIME")
    host_spec = importlib.util.spec_from_file_location("scope_fixture_storage", source.path)
    c._require(host_spec is not None and host_spec.loader is not None, "E_RUNTIME")
    host = importlib.util.module_from_spec(host_spec)
    sys.modules[host_spec.name] = host
    host_spec.loader.exec_module(host)
    source.recheck("E_STALE")
    c._require(source.read(c.EXECUTABLE_LIMIT, "E_STALE") == source_raw, "E_STALE")
    store_fd = host.check_store_root(settings["store_root"], uid, gid)
    attempt_fd = host.create_attempt_dir(store_fd, uid, gid, packet["attempt_id"])
    host.write_payload(attempt_fd, uid, gid,
        (("stdout", packet["stdout_utf8"].encode()), ("stderr", packet["stderr_utf8"].encode()),
         ("evidence-manifest.json", packet["manifest_utf8"].encode())),
        (("0000", packet["evidence_utf8"].encode()),))
    transferred, attempt_fd = attempt_fd, None
    host.write_receipt_file(store_fd, transferred, uid, gid, receipt)
    for held, raw in ((source, source_raw), (config, config_raw), (packet_file, packet_raw)):
        held.recheck("E_STALE")
        c._require(held.read(len(raw), "E_STALE") == raw, "E_STALE")
    if darwin is not None: darwin.recheck()
    print(json.dumps({"storage_fixture_only": True, "uid": uid, "gid": gid,
        "attempt_id": packet["attempt_id"], "source_sha256": c.digest(source_raw),
        "input_sha256": c.digest(packet_raw), "calls": ["check_store_root", "create_attempt_dir",
            "write_payload", "write_receipt_file"]}, sort_keys=True))
finally:
    original_error = sys.exception()
    cleanup_error = None
    for fd in (attempt_fd, store_fd):
        if fd is not None:
            try:
                os.close(fd)
            except BaseException as error:
                if cleanup_error is None:
                    cleanup_error = error
    try:
        c._close_paths(owned)
    except BaseException as error:
        if cleanup_error is None:
            cleanup_error = error
    if cleanup_error is not None:
        if original_error is not None:
            raise original_error from cleanup_error
        raise cleanup_error
PY_STORAGE
  "$python_bin" -I -S -B - "$tmp/genuine-writer.py" <<'PY_SYNTAX'
import ast,pathlib,sys
ast.parse(pathlib.Path(sys.argv[1]).read_bytes())
PY_SYNTAX
}

prepare_genuine_reader() {
  /bin/cat >"$tmp/genuine-reader.py" <<'PY_GENUINE_READER'
import importlib.util
import os
from pathlib import Path
import sys

base = Path(__file__).absolute().parent
source = base / "package/shadow/v1/_consumer.py"
source_raw = source.read_bytes()
spec = importlib.util.spec_from_file_location("scope_fixture_store_consumer", source)
assert spec is not None and spec.loader is not None
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)
class FixtureDarwinLedger:
    def __init__(self): self.commands = []
    def record_command(self, role, argv, executable, component):
        c._require(role in {"darwin-acl-uuid-resolution", "darwin-group-membership"}, "E_RUNTIME")
        c._require(len(self.commands) < 4096, "E_LIMIT")
        self.commands.append({"role":role,"argv_sha256":c.digest(canonical(argv)),
            "executable_sha256":executable,"component_sha256":component})
canonical = c.canonical
def read():
    owned = []
    anchor = store = None
    try:
        held = c._hold_bytes(str(source), c.EXECUTABLE_LIMIT)
        owned.append(held)
        c._require(held.raw == source_raw, "E_STALE")
        python = c._hold_bytes(sys.executable, c.EXECUTABLE_LIMIT)
        owned.append(python)
        darwin = None
        if sys.platform == "darwin":
            import time
            darwin = c._DarwinChildOwner(python, held, time.monotonic() + 120, FixtureDarwinLedger())
        anchor = c.load_anchor(darwin, darwin)
        if len(sys.argv) == 2 and sys.argv[1] != "observation":
            store = c._HeldStoreRead(anchor, sys.argv[1])
            raw = store.observation
            store.recheck()
        else:
            c._require(sys.argv[1:] == ["observation"], "E_RUNTIME")
            raw = c.verifier_observation(anchor, anchor.config["environment_id"], "fixture.target")
        anchor.recheck("E_STALE")
        for item in owned:
            item.recheck("E_STALE")
        return raw
    finally:
        first = sys.exception()
        cleanup_error = None
        for owner in (store, anchor, *reversed(owned)):
            if owner is not None:
                try:
                    owner.close()
                except BaseException as error:
                    if cleanup_error is None:
                        cleanup_error = error
        if cleanup_error is not None:
            if first is not None:
                raise first from cleanup_error
            raise cleanup_error

try:
    os.write(1, read())
except c.Refusal as error:
    print(error.code, file=sys.stderr)
    raise SystemExit(65)

PY_GENUINE_READER
}
prepare_genuine_assembler() {
  /bin/cat >"$tmp/genuine-assembler.py" <<'PY_GENUINE_ASSEMBLER'
import ctypes,hashlib,importlib.util,json,os,pathlib,pwd,grp,shutil,stat,subprocess,sys,sysconfig,time
base=pathlib.Path(sys.argv[1]);writer,consumer,group=sys.argv[2:5];jq_source=pathlib.Path(sys.argv[5]);documents=pathlib.Path(sys.argv[6]);package=base/'package'
assert os.getuid()==0 and base.resolve()==base and package.resolve()==package
canonical=lambda value:(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)+'\n').encode()
sha=lambda raw:hashlib.sha256(raw).hexdigest()
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);assert spec and spec.loader
 module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module
w=load('scope_fixture_writer_algorithms',package/'shadow/v1/write-shadow.py');e=w.e;c=w.c
uid=pwd.getpwnam(writer).pw_uid;consumer_uid=pwd.getpwnam(consumer).pw_uid;gid=grp.getgrnam(group).gr_gid
consumer_gid=pwd.getpwnam(consumer).pw_gid
assert consumer_gid!=gid and gid in map(int,subprocess.check_output(['/usr/bin/sudo','-n','-u',consumer,'--','/usr/bin/id','-G']).split())
assert uid>0 and consumer_uid>0 and uid!=consumer_uid
for name in ('tools','work','bundles','identities','snapshots'):(base/name).mkdir(mode=0o755)
work=base/'work';work.chmod(0o700);tools=base/'tools';jq=tools/'jq';shutil.copyfile(jq_source,jq);jq.chmod(0o555)
assert sha(jq.read_bytes())==c.JQ_SHA256[sys.platform]
(tools/'python3').symlink_to(sys.executable)
env={'PATH':str(tools)+':/usr/bin:/bin','LC_ALL':'C','LANG':'C','HOME':str(work),'TMPDIR':str(work),'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_NO_REPLACE_OBJECTS':'1','GIT_NO_LAZY_FETCH':'1','GIT_TERMINAL_PROMPT':'0','GIT_OPTIONAL_LOCKS':'0','GIT_AUTHOR_NAME':'fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_NAME':'fixture','GIT_COMMITTER_EMAIL':'fixture@example.invalid','GIT_AUTHOR_DATE':'2000-01-01T00:00:00Z','GIT_COMMITTER_DATE':'2000-01-01T00:00:00Z'}
commands=[]
def run(argv,raw=None,role=None,component=None,limit=16*1024*1024):
 argv=list(map(str,argv))
 r=subprocess.run(argv,input=raw,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=180)
 print(json.dumps({'fixture_command':argv,'returncode':r.returncode,'stdout_sha256':sha(r.stdout),
  'stderr':r.stderr.decode('utf8','backslashreplace')},sort_keys=True),flush=True)
 if str(package/'scope/v1/evaluate-scope.sh') in argv:
  print(json.dumps({'actual_scope_stdout_utf8':r.stdout.decode('utf8','backslashreplace')},sort_keys=True),flush=True)
 assert r.returncode==0 and len(r.stdout)<=limit and not r.stderr
 if role:commands.append({'role':role,'argv_sha256':sha(canonical(argv)),'executable_sha256':sha(pathlib.Path(argv[0]).resolve().read_bytes()),'component_sha256':sha(pathlib.Path(component).read_bytes())})
 return r.stdout
def refuse(argv, label, expected):
    result = subprocess.run(list(map(str, argv)), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, timeout=180)
    print(json.dumps({'negative':label, 'returncode':result.returncode,
        'stdout_hex':result.stdout.hex(), 'stderr_utf8':result.stderr.decode('utf8','backslashreplace')},
        sort_keys=True), flush=True)
    assert result.returncode != 0 and result.stdout == b'' and result.stderr == expected + b'\n'
    return result

def put(path,value,mode=0o444):
 raw=value if type(value) is bytes else canonical(value);path=pathlib.Path(path);path.write_bytes(raw);path.chmod(mode);return path
helper=tools/'object-closure';run(['/usr/bin/cc','-std=c11','-Wall','-Wextra','-Werror','-O2',package/c.HELPER_SOURCE,'-o',helper]);helper.chmod(0o555)
verifier=tools/'file-digest-verifier';run(['/usr/bin/cc','-std=c11','-Wall','-Wextra','-Werror','-O2',package/'verifiers/file-digest/v1/verifier.c','-o',verifier]);verifier.chmod(0o555)
native_dir=base/'native';run(['/bin/bash','-p',package/'shadow/v1/build-cancel-release.sh','build',sys.executable,native_dir])
native_record=native_dir/'build-record.json';native_binary=next(p for p in native_dir.iterdir() if p.name!='build-record.json')
native_handle=ctypes.PyDLL(str(native_binary),mode=os.RTLD_NOW|os.RTLD_LOCAL)
class FixtureDarwinLedger:
 def __init__(self): self.commands=[]
 def record_command(self,role,argv,executable,component):
  c._require(role in {'darwin-acl-uuid-resolution','darwin-group-membership'},'E_RUNTIME')
  c._require(len(self.commands)<4096,'E_LIMIT')
  self.commands.append({'role':role,'argv_sha256':c.digest(canonical(argv)),
   'executable_sha256':executable,'component_sha256':component})
owned=[]
darwin=None
closure_ledger=FixtureDarwinLedger()
try:
 if sys.platform=='darwin':
  python=c._hold_bytes(sys.executable,c.EXECUTABLE_LIMIT);owned.append(python)
  consumer_source=c._hold_bytes(str(package/'shadow/v1/_consumer.py'),c.EXECUTABLE_LIMIT);owned.append(consumer_source)
  darwin=c._DarwinChildOwner(python,consumer_source,time.monotonic()+120,closure_ledger)
 closure=[]
 for name,module in sorted(sys.modules.items()):
  path=getattr(module,'__file__',None)
  if path and pathlib.Path(path).is_file():
   path=pathlib.Path(path).resolve()
   dependency = c._open_held(str(path), False, c._installed_rule(uid,darwin), 'E_INSTALL')
   try:
    raw = dependency.read(c.EXECUTABLE_LIMIT, 'E_INSTALL')
    dependency.recheck('E_STALE')
    closure.append({'module':name,'path':str(path),'sha256':sha(raw),
                    'uid':dependency.before.st_uid,'gid':dependency.before.st_gid,
                    'mode':stat.S_IMODE(dependency.before.st_mode)})
   finally:
    dependency.close()
 for item in owned:item.recheck('E_STALE')
finally:
 original=sys.exc_info()[1]
 try:c._close_paths(owned)
 except OSError as cleanup_error:
  if original is not None:raise original from cleanup_error
  raise
print(json.dumps({'fixture_runtime_acl_commands':closure_ledger.commands},sort_keys=True),flush=True)
closure_raw=canonical({'fixture_runtime_closure':closure,'python':str(pathlib.Path(sys.executable).resolve()),'native_binary':str(native_binary),'loader_mode':'rtld-now-local.v1','state_created':False,'startup_called':False,'vm_called':False})
put(base/'runtime-closure.json',closure_raw)
native={'context_version':2,'source_sha256':sha((package/'shadow/v1/_cancel_release.c').read_bytes()),'build_script_sha256':sha((package/'shadow/v1/build-cancel-release.sh').read_bytes()),'build_record_sha256':sha(native_record.read_bytes()),'binary_locator_sha256':sha(str(native_binary).encode()),'binary_size':native_binary.stat().st_size,'binary_sha256':sha(native_binary.read_bytes()),'python_locator_sha256':sha(sys.executable.encode()),'python_sha256':sha(pathlib.Path(sys.executable).read_bytes()),'python_abi':sysconfig.get_config_var('SOABI'),'dependency_record_sha256':sha(closure_raw),'loader_mode':'rtld-now-local.v1'}
put(base/'native-measurement.json',{'native_release':native,'state_created':False,'startup_called':False,'vm_called':False,'qualification_claimed':False})
source=base/'source.git';run(['/usr/bin/git','init','-q','--bare',source])
def git(args,raw=None):return run(['/usr/bin/git','--no-replace-objects','--git-dir='+str(source),*args],raw)
content=b'fixed content\n';blob=git(['hash-object','-w','--stdin'],content).decode().strip();sibling=git(['hash-object','-w','--stdin'],b'unchanged sibling\n').decode().strip();sibling_tree=git(['mktree'],f'100644 blob {sibling}\tsibling.md\n'.encode()).decode().strip();unrelated_tree=git(['mktree'],f'100644 blob {sibling}\told.txt\n'.encode()).decode().strip();tree=git(['mktree'],f'100644 blob {blob}\tsource.txt\n040000 tree {unrelated_tree}\tunrelated\n040000 tree {sibling_tree}\tystack-evidence\n'.encode()).decode().strip();commit=git(['commit-tree',tree],b'source\n').decode().strip();git(['update-ref','refs/heads/main',commit])
run(['/bin/bash',package/'scripts/test/local-git-materializer-fixtures.sh','build',work/'built',jq,'sha1',commit,tree])
original=json.loads((work/'built/input.json').read_bytes())
for row in original['payloads']:
 if row['input_id']=='input.producer-patch':row['data']=''
for row in original['trust_context']['verified_payloads']:
 if row['input_id']=='input.producer-patch':row['content']['data']='';row['sha256']=sha(b'')
for row in original['stage_request']['content']['body']['inputs']:
 if row['input_id']=='input.producer-patch':row['value']['value']['value']['sha256']=sha(b'')
original['stage_request']['sha256']=sha(canonical(original['stage_request']['content']))
generation=json.loads((package/'core/v2/generation-registry.json').read_bytes())[-1]['generation_id'];modules=package/'core/v2/generations'/generation/'modules'
def component(relative,args,raw=None,role=None):return run(['/bin/bash','-p',package/relative,*args],raw,role,package/relative)
def materialize(doc,label):
 path=put(work/(label+'-input.json'),doc);candidate=work/(label+'-candidate');scratch=work/(label+'-materializer');candidate.mkdir(mode=0o700);scratch.mkdir(mode=0o700)
 raw=component('adapters/local-git-materializer/v1/materialize.sh',['materialize',path,'fixture.target',source,candidate,scratch,helper,jq],role='materialization');response=json.loads(raw)
 receipt=json.loads(response['payloads'][0]['data']);print(json.dumps({'candidate_directory':str(candidate),'receipt_candidate':receipt['candidate']},sort_keys=True),flush=True)
 return path,raw,candidate
prior_path,prior_raw,_=materialize(original,'prior');prior=json.loads(prior_raw)
prior_request=put(work/'prior-request.json',original['stage_request']['content']);prior_profile=put(work/'prior-profile.json',original['resolved_profile']['content']);prior_result=put(work/'prior-result.json',prior['stage_result'])
duty_raw=component('control/v1/evaluate-duty.sh',['evaluate',package/'control/v1/control-policy-set-sandbox-bound.json',prior_request,prior_profile,prior_result]);duty=json.loads(duty_raw);assert duty['body']['verdict']=='satisfied'
environment='env.scope-genuine';registry=json.loads((package/'shadow/v1/shadow-environments.json').read_bytes());entry=registry['body']['environments'][0];entry.update(environment_id=environment,target_repository_id='fixture.target',source_root_commit=commit,proof_state='native-qualified');registry['body']['environments']=[entry];put(package/'shadow/v1/shadow-environments.json',registry)
incident={'schema_version':1,'kind':'shadow_incident_record','id':'incident.scope-genuine','body':{'deploy_authority':'none','target_repository_id':'fixture.target','git_revision_ref':{'repository_id':'fixture.target','hash_algorithm':'sha1','commit_id':commit},'failing_check':{'kind':'file-digest','path':'source.txt','expected_sha256':sha(content)},'observed_symptom':'synthetic completed-run facts for controlled storage only','reporter_actor_ref':'actor.scope-fixture','observed_at':'2026-08-30T00:00:04Z'}}
instruction=e.make_instruction(incident)
identities={key:sha((package/'control/v1/sandbox-bound-policy.json').read_bytes()+key.encode()) for key in c.IDENTITY_SLOTS};identities.update(host_runtime=sha(pathlib.Path(sys.executable).read_bytes()),host_supervisor=sha((package/'sandbox/v1/host-supervisor.py').read_bytes()),verifier=sha(verifier.read_bytes()),toolchain=sha(jq.read_bytes()),image=sha(canonical(registry)),verification_instructions=sha(instruction))
mechanisms={'cpu_time_ms':'mechanism.cpu.single-vcpu-quota-deadline.v1','wall_time_ms':'mechanism.wall.host-monotonic-stop.v1','memory_bytes':'mechanism.memory.vm-ram-ceiling.v1','output_bytes':'mechanism.output.single-tmpfs-append.v1','process_count':'mechanism.tasks.cgroup-pids.v1','scratch_bytes':'mechanism.scratch.tmpfs-no-free.v1'}
accepted={'schema_version':1,'kind':'sandbox_accepted_identity_set','id':'sandbox.accepted-identities.v1','body':{'activation_state':'inactive','environments':[{'environment_id':environment,'identities':{key:[value] for key,value in identities.items()},'mechanisms':{key:[value] for key,value in mechanisms.items()},'scratch_bytes':16777216}],'set_version':'v1'}};put(package/'enforcement/v1/accepted-identities.json',accepted)
anchor=pathlib.Path(c.ANCHOR);assert anchor.is_dir()
shutil.copyfile(package/'sandbox/v1/host-supervisor.py',anchor/'host-supervisor.py');(anchor/'host-supervisor.py').chmod(0o555)
installed={role:str(package/relative) for role,relative in c.INSTALLED_SOURCES.items()}
identity_paths={key:str(put(base/'identities'/key,(key+'\n').encode())) for key in c.IDENTITY_KEYS if key!='dyld_cache_files'};identity_paths['dyld_cache_files']=[str(put(base/'identities/dyld-cache',b'fixture-only dyld identity\n'))];identity_paths['verifier']=str(verifier);identity_paths['host_runtime']=sys.executable;identity_paths['host_supervisor']=str(anchor/'host-supervisor.py')
store=base/'store';store.mkdir(mode=0o750);os.chown(store,uid,gid);(base/'writer-work').mkdir(mode=0o700);os.chown(base/'writer-work',uid,gid)
if sys.platform=='darwin':run(['/bin/chmod','-N',store])
store.chmod(0o750)
config={'schema_version':1,'kind':'sandbox_host_config','id':'scope.fixture.host','body':{'principal_uid':uid,'consumer_gid':gid,'environment_id':environment,'store_id':'store.scope-genuine','store_root':str(store),'work_root':str(base/'writer-work'),'identity_paths':identity_paths,'installed_files':installed,'runtime':{'driver':str(put(base/'identities/runtime-driver',b'not executed\n')),'vfkit':str(put(base/'identities/vfkit',b'not executed\n'))}}};put(anchor/'host-config.json',config)
policy=json.loads((package/'control/v1/sandbox-bound-policy.json').read_bytes());claim={'schema_version':1,'kind':'execution_environment_claim','id':environment,'body':{key:policy['body'][key] for key in ('environment','filesystem','isolation','limits','network','resources','sensitive_material')}}
if sys.platform=='darwin':
    run(['/bin/chmod','+a','user:'+consumer+' allow read',verifier])
    print(run(['/bin/ls','-lde',verifier]).decode(),flush=True)
claim['body'].update(declaration_status='complete',duty_evaluation_ref=e.document_ref(duty_raw),effects={'external_writes':False,'target_writes':False},execution_identity={'adapter_instance_id':'instance.verifier','execution_boundary_id':'boundary.verifier','principal_id':'principal.verifier','role':'verifier'},policy_set_ref=e.document_ref((package/'control/v1/control-policy-set-sandbox-bound.json').read_bytes()),stage_result_ref=duty['body']['stage']['result_ref'],tools=[{key:value for key,value in policy['body']['tools'][0].items() if key!='identity_binding'}|{'sha256':sha(verifier.read_bytes())}])
claim_raw=canonical(claim);observation={'schema_version':1,'kind':'sandbox_verifier_observation','id':'sandbox.observation.verifier','body':{'environment_id':environment,'environment_entry_sha256':sha(canonical(entry)),'target_repository_id':'fixture.target','accepted_set_sha256':sha(canonical(accepted)),'verifier_sha256':sha(verifier.read_bytes())}}
put(work/'duty.json',duty_raw);put(work/'claim.json',claim_raw);put(work/'observation.json',observation)
evaluation_raw=component('control/v1/evaluate-bound-sandbox.sh',['evaluate',work/'duty.json',work/'claim.json',work/'observation.json'],role='sandbox-bound-evaluation');assert json.loads(evaluation_raw)['body']['verdict']=='satisfied'
q=json.loads(canonical(original));q['stage_request']['content']['body']['environment_ref']={'environment_id':environment,'fingerprint_sha256':sha(claim_raw)};q['stage_request']['sha256']=sha(canonical(q['stage_request']['content']))
print(json.dumps({'fixture_stage_ready':True,'uid':uid,'consumer_uid':consumer_uid,'gid':gid,'source_commit':commit,'source_tree':tree,'actual_native_loaded':True,'state_created':False,'startup_called':False,'vm_called':False},sort_keys=True),flush=True)
put(base/'stage-state.json',{'original':original,'q':q,'incident':incident,'claim':claim,'duty_utf8':duty_raw.decode(),'evaluation_utf8':evaluation_raw.decode(),'observation':observation,'native':native,'identities':identities,'mechanisms':mechanisms,'commands':commands,'source_commit':commit,'source_tree':tree,'blob':blob})

q_path, response_raw, candidate_root = materialize(q, 'consumer')
response_path = put(work / 'response.json', response_raw)
protocol = package / 'adapters/local-git-materializer/v1/protocol.jq'
run([jq, '-L', modules, '-e', '--arg', 'command', 'validate-input', '-f', protocol, q_path],
    role='materializer-input-validation', component=protocol)
response_check = put(work / 'response-check.json', e.response_check(q, response_raw))
run([jq, '-L', modules, '-e', '--arg', 'command', 'validate-response', '-f', protocol, response_check],
    role='materializer-response-validation', component=protocol)
prep, scratch = work / 'preparation', work / 'preparation-scratch'
scratch.mkdir(mode=0o700)
preparation_source = package / 'preparation/v1/prepare-candidate.py'
common = ['--input', q_path, '--input-sha256', sha(q_path.read_bytes()),
          '--response', response_path, '--response-sha256', sha(response_raw),
          '--candidate-repository', candidate_root / 'repository.git', '--output', prep,
          '--scratch', scratch, '--jq', jq]
run([sys.executable, '-I', '-S', '-B', preparation_source, 'prepare', *common],
    role='candidate-preparation', component=preparation_source)
for path in scratch.iterdir():
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
run([sys.executable, '-I', '-S', '-B', preparation_source, 'inspect', *common],
    role='candidate-inspection', component=preparation_source)
record_raw = (prep / 'record.json').read_bytes()
manifest_raw = (prep / 'manifest.json').read_bytes()
manifest = json.loads(manifest_raw)
identity = {'schema_version': 1, 'kind': 'qualified_identity', 'id': 'identity.scope-genuine',
            'body': {'adapter_config_refs': [{'content_id': 'producer-config',
                      'media_type': 'application/json', 'sha256': sha(b'fixed producer config')}],
                     'model_request': {'effort_id': 'high', 'model_id': 'model.fixture',
                                       'provider_id': 'provider.fixture'},
                     'prompt_refs': [{'location': {'kind': 'path', 'value': 'source.txt'},
                       'mode': '100644', 'object_id': blob, 'object_type': 'blob',
                       'revision': incident['body']['git_revision_ref']}],
                     'resolved_profile_ref': e.pair_ref(q['resolved_profile']), 'skill_refs': [],
                     'stage_request_ref': e.pair_ref(q['stage_request']),
                     'target_revision': incident['body']['git_revision_ref'],
                     'verification_instructions_ref': {'content_id': 'verification-instructions',
                       'media_type': 'text/plain', 'sha256': sha(instruction)}}}
identity_raw = canonical(identity)
run([jq, '-L', modules, '-r', '--arg', 'repository_id', 'fixture.target', '--arg',
     'hash_algorithm', 'sha1', '--arg', 'commit_id', commit, '-f',
     package / 'shadow/v1/qualified-identity.jq'], identity_raw,
    role='qualified-identity-validation', component=package / 'shadow/v1/qualified-identity.jq')
e.validate_input_relations(q, incident, claim, identity, instruction)
component('shadow/v1/validate-incident.sh', ['validate', put(work / 'incident.json', incident)],
          role='incident-validation')
from types import SimpleNamespace
facts_anchor = SimpleNamespace(config=config['body'], registry=c._parse_registry(canonical(registry)),
    installed={role: (pathlib.Path(path).read_bytes(), sha(pathlib.Path(path).read_bytes()))
               for role, path in installed.items()})
attempt_id = 'attempt.scope-genuine-first'
request = {'id': attempt_id, 'body': {'attempt_id': attempt_id}}
launch_raw, expectation_raw = e.make_launch(facts_anchor, request, canonical(incident),
    evaluation_raw, canonical(observation), record_raw, manifest_raw, instruction)
launch = json.loads(launch_raw)
expectation = json.loads(expectation_raw)
result_raw = canonical({'schema_version': 1, 'kind': 'file_digest_verifier_payload',
                       'id': 'file-digest-payload', 'body': {
                         'check': {'path': 'source.txt', 'expected_sha256': sha(content)},
                         'instruction_sha256': sha(instruction),
                         'observed': {'sha256': sha(content), 'size_bytes': len(content)},
                         'outcome': 'match', 'reason_id': 'file.match'}})
evidence_raw = canonical({'schema_version': 1, 'kind': 'sandbox_evidence_manifest',
                          'id': 'evidence-manifest', 'body': {'files': [{
                            'name_hex': b'file-digest-result.json'.hex(),
                            'sha256': sha(result_raw), 'size_bytes': len(result_raw)}]}})
bounds = {'cpu_time_ms': (30000, 1000, 1, 'guest-supervisor'),
          'wall_time_ms': (60000, 2000, 1, 'host-supervisor'),
          'memory_bytes': (536870912, 1048576, 4096, 'guest-supervisor'),
          'output_bytes': (10485760, len(result_raw), 1, 'guest-supervisor'),
          'process_count': (32, 1, 1, 'guest-supervisor'),
          'scratch_bytes': (16777216, 4096, 4096, 'guest-supervisor')}
limits = {key: {'bound': bound, 'observed': observed, 'resolution': resolution,
               'observation': 'complete', 'enforcement': 'hard', 'reached': False,
               'mechanism_id': mechanisms[key], 'observer': observer}
          for key, (bound, observed, resolution, observer) in bounds.items()}
receipt_raw = canonical({'schema_version': 1, 'kind': 'sandbox_enforcement_receipt',
    'id': 'receipt.' + sha(launch_raw), 'body': {
        'contract_version': 'v1', 'origin': {'producer_role': 'host-supervisor',
          'store_id': config['body']['store_id'], 'accepted_set_sha256': sha(canonical(accepted))},
        'attempt': expectation['body']['attempt'], 'control': launch['body']['control'],
        'subject': launch['body']['subject'],
        'identities': {key: {'state': 'observed', 'sha256': value} for key, value in identities.items()},
        'limits': limits,
        'teardown': {'state': 'confirmed', 'tree_terminated': True, 'storage_destroyed': True},
        'lifecycle': {'admission': 'admitted', 'runtime': 'completed', 'control_deadline': 'met'},
        'payload': {'stdout_sha256': sha(b''), 'stderr_sha256': sha(b''),
          'evidence_manifest_sha256': sha(evidence_raw), 'exit_state': 'exited', 'exit_code': 0},
        'timing': {'admitted_at': '2026-08-30T00:00:05Z', 'terminated_at': '2026-08-30T00:00:06Z'},
        'outcome': {'verdict': 'satisfied', 'reason_ids': ['enforcement.satisfied']}}})
put(base / 'storage-input.json', {'attempt_id': attempt_id, 'receipt_utf8': receipt_raw.decode(),
    'stdout_utf8': '', 'stderr_utf8': '', 'manifest_utf8': evidence_raw.decode(),
    'evidence_utf8': result_raw.decode()})
run(['/usr/bin/sudo', '-n', '-u', writer, '--', sys.executable, '-I', '-S', '-B',
     base / 'genuine-writer.py'])
origin_raw = run(['/usr/bin/sudo', '-n', '-u', consumer, '--', sys.executable,
                  '-I', '-S', '-B', base / 'genuine-reader.py', attempt_id])
origin = json.loads(origin_raw)
put(work / 'receipt.json', receipt_raw)
put(work / 'expectation.json', expectation_raw)
put(work / 'evaluation.json', evaluation_raw)
checker_raw = component('enforcement/v1/check-sandbox-receipt.sh',
    ['check-bound', work / 'receipt.json', work / 'expectation.json', work / 'evaluation.json',
     work / 'observation.json'], role='sandbox-receipt-check')
checker = json.loads(checker_raw)
assert checker['body']['check_verdict'] == 'valid' and checker['body']['enforcement_verdict'] == 'satisfied'
trace_raw = e.trace_ledger(incident, attempt_id, environment, 'no-change', 'tool.verifier',
                           evaluation_raw, checker_raw)
trace_path = put(work / 'trace.json', trace_raw)
trace_receipt = component('telemetry/v1/validate-trace-ledger.sh',
    ['validate', incident['id'], attempt_id, trace_path], role='trace-validation')
provenance = canonical({'schema_version': 1, 'kind': 'shadow_consumer_provenance', 'id': attempt_id,
    'body': {'activation_state': 'inactive', 'authority': 'none',
      'instruction_utf8': instruction.decode(), 'instruction_sha256': sha(instruction),
      'observation': observation, 'observation_sha256': sha(canonical(observation)),
      'helper_source_sha256': sha((package / c.HELPER_SOURCE).read_bytes()),
      'helper_build_record_sha256': sha(canonical({'compiler': '/usr/bin/cc', 'fixture_only': True,
           'helper_source_sha256': sha((package / c.HELPER_SOURCE).read_bytes()),
           'helper_executable_sha256': sha(helper.read_bytes())})),
      'helper_executable_sha256': sha(helper.read_bytes()),
      'consumer_source_sha256': sha((package / 'shadow/v1/enforced-reproduction.py').read_bytes()),
      'python_sha256': sha(pathlib.Path(sys.executable).read_bytes()), 'jq_sha256': sha(jq.read_bytes()),
      'native_release': native, 'commands': commands}})
material_receipt = json.loads(json.loads(response_raw)['payloads'][0]['data'])
stage_result = json.loads(response_raw)['stage_result']
content_ref = lambda name, media, raw: {'content_id': name, 'media_type': media, 'sha256': sha(raw)}
shadow_record = canonical({'schema_version': 1, 'kind': 'shadow_reproduction_record',
 'id': incident['id'], 'body': {
  'record_form': 'enforced-reproduction.v1', 'activation_state': 'inactive', 'authority': 'none',
  'deploy_authority': 'none', 'effects': ['caller-disposable-candidate-repository'],
  'evaluation_mode': 'observation-only', 'shadow': True,
  'qualification': {'state': 'unavailable', 'reason_id': 'shadow.unqualified'},
  'outcome': 'no-change', 'reason_id': 'check.passed-at-revision',
  'observed_at': incident['body']['observed_at'], 'target_repository_id': 'fixture.target',
  'git_revision_ref': incident['body']['git_revision_ref'], 'qualified_identity': identity['body'],
  'qualified_identity_ref': content_ref('shadow-qualified-identity', 'application/vnd.ystack.qualified-identity+json', identity_raw),
  'incident_ref': content_ref('shadow-incident-record', 'application/vnd.ystack.shadow-incident-record+json', canonical(incident)),
  'environment': {'environment_id': environment,
    'claim_ref': content_ref('shadow-environment-claim', 'application/vnd.ystack.control-execution-environment-claim+json', claim_raw),
    'registry_ref': content_ref('shadow-environment-registry', 'application/vnd.ystack.shadow-environment-registry+json', canonical(registry)),
    'evaluation': {'state': 'present', 'value': {'verdict': 'satisfied',
      'reason_ids': json.loads(evaluation_raw)['body']['reason_ids'],
      'evaluation_ref': content_ref('shadow-sandbox-evaluation', 'application/vnd.ystack.control-evaluation+json', evaluation_raw)}}},
  'materialization': {'state': 'present', 'value': {'adapter_id': 'adapter.local-git-materializer.v1',
    'outcome': 'no-change', 'source': material_receipt['source'], 'candidate': material_receipt['candidate'],
    'stage_result_ref': e.document_ref(canonical(stage_result))}},
  'check': {'failing_check': incident['body']['failing_check'], 'execution': {'state': 'present',
    'value': {'tool_id': 'tool.verifier', 'observed_sha256': sha(content), 'matches_expected': True}}},
  'sandbox': {'state': 'satisfied', 'reason_id': 'shadow.sandbox-satisfied',
    'launch_request_ref': e.document_ref(launch_raw), 'expectation_ref': e.document_ref(expectation_raw),
    'receipt_ref': e.document_ref(receipt_raw), 'check_ref': e.document_ref(checker_raw),
    'origin': {'state': 'authenticated', 'store_id': config['body']['store_id'],
       'method': 'controlled-storage.v1', 'observation_sha256': sha(origin_raw)},
    'payload_ref': content_ref('file-digest-result', 'application/json', result_raw)},
  'producer_invocations': 0, 'consumer_provenance_ref': e.document_ref(provenance),
  'trace_ledger_ref': content_ref('shadow-trace-ledger', 'application/vnd.ystack.telemetry-trace-ledger+json', trace_raw)}})
files = {'incident.json': canonical(incident), 'claim.json': claim_raw, 'duty-evaluation.json': duty_raw,
 'materialization-input.json': q_path.read_bytes(), 'materialization-response.json': response_raw,
 'qualified-identity.json': identity_raw, 'preparation-record.json': record_raw,
 'preparation-manifest.json': manifest_raw, 'sandbox-evaluation.json': evaluation_raw,
 'sandbox-request.json': launch_raw, 'sandbox-expectation.json': expectation_raw,
 'sandbox-receipt.json': receipt_raw, 'sandbox-check.json': checker_raw,
 'origin-observation.json': origin_raw, 'payload-stdout.txt': b'', 'payload-stderr.txt': b'',
 'evidence-manifest.json': evidence_raw, 'file-digest-result.json': result_raw,
 'consumer-provenance.json': provenance, 'shadow-record.json': shadow_record,
 'trace-ledger.json': trace_raw, 'trace-receipt.json': trace_receipt}
for name, role in {'evaluator-driver.txt':'evaluator_driver', 'evaluator-program.txt':'evaluator_program',
                  'policy.json':'control_policy', 'decision.json':'control_decision',
                  'policy-set.json':'control_policy_set', 'accepted-identities.json':'accepted_set',
                  'registry.json':'registry'}.items():
    files[name] = pathlib.Path(installed[role]).read_bytes()
assert set(files) == set(e.EVIDENCE_NAMES)
marker = canonical({'schema_version': 1, 'kind': 'shadow_consumer_bundle',
    'id': 'bundle.' + sha(files['incident.json'])[:32], 'body': {
      'activation_state': 'inactive', 'record_form': 'enforced-reproduction.v1',
      'incident_sha256': sha(files['incident.json']), 'target_revision': incident['body']['git_revision_ref'],
      'files': [{'name': name, 'size_bytes': len(files[name]), 'sha256': sha(files[name])}
                for name in sorted(files)]}})
bundle = base / 'bundles' / sha(shadow_record)
bundle.mkdir(mode=0o755)
for name, raw in files.items():
    put(bundle / name, raw)
put(bundle / 'bundle.json', marker)
print(json.dumps({'genuine_enforced_bundle': str(bundle), 'record_sha256': sha(shadow_record),
                  'actual_storage_writer_uid': uid, 'actual_consumer_uid': consumer_uid,
                  'synthetic_runtime_facts': True, 'vm_executed': False}, sort_keys=True), flush=True)

reader_observation = run(['/usr/bin/sudo', '-n', '-u', consumer, '--', sys.executable,
                          '-I', '-S', '-B', base / 'genuine-reader.py', 'observation'])
assert reader_observation == canonical(observation)
doc_root = base / 'documents'
doc_root.mkdir(mode=0o755)
for name in ('scope', 'dashboard', 'risk', 'kill', 'duty', 'marker'):
    value = json.loads((documents / (name + '.json')).read_bytes())
    if name in ('risk', 'duty'):
        value['body']['stage']['request_ref'] = identity['body']['stage_request_ref']
        value['body']['stage']['resolved_profile_ref'] = identity['body']['resolved_profile_ref']
    put(doc_root / (name + '.json'), value)
duty_gate_raw = (doc_root / 'duty.json').read_bytes()
for name in ('risk', 'kill'):
    gate = json.loads((doc_root / (name + '.json')).read_bytes())
    gate['body']['duty_evaluation_ref']['sha256'] = sha(duty_gate_raw)
    put(doc_root / (name + '.json'), gate)
scope_doc = json.loads((doc_root / 'scope.json').read_bytes())
scope_doc['body'].update(target_repository_id='fixture.target',
    qualified_identity=identity['body'], required_shadow_environments=[environment],
    shadow_evidence_refs=[e.document_ref(shadow_record)])
for key, name in (('risk_gate_evaluation_ref', 'risk'), ('kill_switch_evaluation_ref', 'kill'),
                  ('duty_separation_evaluation_ref', 'duty')):
    scope_doc['body']['gate_evidence_refs'][key] = e.document_ref((doc_root / (name + '.json')).read_bytes())
put(doc_root / 'scope.json', scope_doc)
put(doc_root / 'shadow-set.json', {'schema_version': 1, 'kind': 'shadow_evidence_set',
    'id': 'scope.evidence.genuine', 'body': {'records': [json.loads(shadow_record)]}})
consumer_work = base / 'consumer-work'
consumer_work.mkdir(mode=0o700)
os.chown(consumer_work, consumer_uid, consumer_gid)
for root, dirs, names in os.walk(source):
    pathlib.Path(root).chmod(0o755)
    for name in names:
        (pathlib.Path(root) / name).chmod(0o444)
scope_argv = ['/usr/bin/sudo', '-n', '-u', consumer, '--', '/usr/bin/env', '-i',
    'PATH=' + str(tools) + ':/usr/bin:/bin', 'LANG=C', 'LC_ALL=C', 'HOME=' + str(consumer_work),
    'TMPDIR=' + str(consumer_work), '/bin/bash', '-p', package / 'scope/v1/evaluate-scope.sh',
    'evaluate', *[doc_root / (name + '.json') for name in
                 ('scope', 'shadow-set', 'dashboard', 'risk', 'kill', 'duty', 'marker')],
    base / 'bundles', source]
scope_raw = run(scope_argv)
put(base / 'genuine-scope-evaluation.json', scope_raw)
evaluation = json.loads(scope_raw)
facts = evaluation['body']['evidence']['shadow_bundle_facts']
assert len(facts) == 1 and facts[0]['eligible'] is True
assert facts[0]['authentication']['state'] == 'authenticated'
assert 'scope.sandbox-receipt-missing' not in evaluation['body']['reason_ids']
assert evaluation['body']['authority'] == 'none' and evaluation['body']['enabled'] is False
print(json.dumps({'genuine_scope_contract': 'PASS', 'synthetic_runtime_facts': True,
    'vm_executed': False, 'actual_writer_uid': uid, 'actual_consumer_uid': consumer_uid,
    'scope_sha256': sha(scope_raw)}, sort_keys=True), flush=True)

readonly_scope_raw=(doc_root/'scope.json').read_bytes()
fixed_scope=json.loads(readonly_scope_raw)
fixed_scope['body'].update(workflow_id='workflow.shadow-evidence-commit',task_class='task.commit-shadow-evidence')
try:
    put(doc_root/'scope.json',fixed_scope)
    fixed_nochange=json.loads(run(scope_argv))['body']['evidence']['shadow_bundle_facts']
    assert len(fixed_nochange)==1 and fixed_nochange[0]['eligible'] is True
    assert fixed_nochange[0]['authentication']['state']=='authenticated'
    assert fixed_nochange[0]['record_form']=='enforced-reproduction.v1'
    for key in ('workflow_id','task_class'):
        partial=json.loads(canonical(fixed_scope));del partial['body'][key]
        put(doc_root/'scope.json',partial)
        refuse(scope_argv,'classification-partial-'+key,b'E_SHAPE')
        mixed=json.loads(canonical(fixed_scope));mixed['body'][key]=json.loads(readonly_scope_raw)['body'][key]
        put(doc_root/'scope.json',mixed)
        assert run([jq,'-r','-f',package/'scope/v1/workflow-scope.jq',doc_root/'scope.json'])==b''
        refuse(scope_argv,'classification-mixed-'+key,b'E_RELATION')
finally:
    put(doc_root/'scope.json',readonly_scope_raw)
assert (doc_root/'scope.json').read_bytes()==readonly_scope_raw
print(json.dumps({'classification_fixed_pair_nochange':'authenticated',
    'partial_refusals':2,'shape_valid_mixed_refusals':2},sort_keys=True),flush=True)

frozen = dict(files, **{'bundle.json': marker})
seed_dir = work / 'seed'
seed_dir.mkdir(mode=0o700)
seed_raw = component('maintenance/v1/incident-to-eval.sh',
    ['convert', put(work / 'frozen-incident.json', frozen['incident.json']),
     put(work / 'frozen-record.json', frozen['shadow-record.json']), seed_dir],
    role='write-seed-conversion')
assert [path.name for path in seed_dir.iterdir()] == ['eval-seed-case-stale-moved-artifacts.json']
assert (seed_dir / 'eval-seed-case-stale-moved-artifacts.json').read_bytes() == seed_raw
prefix = 'ystack-evidence/' + incident['id'] + '/'
write_files = {prefix + name: raw for name, raw in frozen.items()}
write_files[prefix + 'eval-seed.json'] = seed_raw
write_files[prefix + 'README.md'] = b'Shadow evidence. Publication is withheld.\n'
paths = sorted(write_files)
patch_raw, write_set = c.evidence_patch(write_files, 'sha1')
assert len(write_set) == 32
write_attempt = 'attempt.scope-genuine-write'
contract_raw = c.write_contract(paths)
contract_path = put(work / 'write-contract.json', contract_raw)
patch_path = put(work / 'write.patch', patch_raw)
metadata = {key: sha(raw) for key, raw in c.WRITE_TEXTS.items()}
metadata.update(contract=sha(contract_raw), patch=sha(patch_raw), allowed_paths=paths,
    attempt_id=write_attempt, suffix=sha(write_attempt.encode())[:32],
    environment_id=environment, claim_sha256=sha(claim_raw))
builder = package / 'shadow/v1/write-materialization-input.jq'
def build_phase(phase, input_path, metadata_path):
    return run([jq, '-L', modules, '-S', '-c', '--arg', 'phase', phase,
        '--rawfile', 'contract', contract_path, '--rawfile', 'patch', patch_path,
        '--slurpfile', 'metadata', metadata_path, '-f', builder, input_path],
        role='write-materialization-input', component=builder, limit=8*1024*1024)
first_raw = build_phase('stage-request', q_path, put(work / 'write-metadata-first.json', metadata))
first = json.loads(first_raw)
assert canonical(first['original']) == frozen['materialization-input.json']
metadata['stage_request_sha256'] = sha(canonical(first['stage_request']))
write_input_raw = build_phase('final-input', put(work / 'write-first.json', first_raw),
    put(work / 'write-metadata-final.json', metadata))
write_input = json.loads(write_input_raw)
write_input_path, write_response_raw, write_candidate = materialize(write_input, 'write')
assert write_input_path.read_bytes() == write_input_raw
write_response_path = put(work / 'write-response.json', write_response_raw)
run([jq, '-L', modules, '-e', '--arg', 'command', 'validate-input', '-f', protocol, write_input_path],
    role='materializer-input-validation', component=protocol)
write_check = put(work / 'write-response-check.json', e.response_check(write_input, write_response_raw))
run([jq, '-L', modules, '-e', '--arg', 'command', 'validate-response', '-f', protocol, write_check],
    role='materializer-response-validation', component=protocol)
write_prep, write_scratch = work / 'write-preparation', work / 'write-preparation-scratch'
write_scratch.mkdir(mode=0o700)
write_common = ['--input', write_input_path, '--input-sha256', sha(write_input_raw),
    '--response', write_response_path, '--response-sha256', sha(write_response_raw),
    '--candidate-repository', write_candidate / 'repository.git', '--output', write_prep,
    '--scratch', write_scratch, '--jq', jq]
run([sys.executable, '-I', '-S', '-B', preparation_source, 'prepare', *write_common],
    role='candidate-preparation', component=preparation_source)
for path in write_scratch.iterdir():
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
run([sys.executable, '-I', '-S', '-B', preparation_source, 'inspect', *write_common],
    role='candidate-inspection', component=preparation_source)
write_record_raw = (write_prep / 'record.json').read_bytes()
write_manifest_raw = (write_prep / 'manifest.json').read_bytes()
write_identity = json.loads(identity_raw)
write_identity['body']['stage_request_ref'] = e.pair_ref(write_input['stage_request'])
write_identity_raw = canonical(write_identity)
launch_raw, expectation_raw = e.make_launch(facts_anchor,
    {'id': write_attempt, 'body': {'attempt_id': write_attempt}}, canonical(incident),
    evaluation_raw, canonical(observation), write_record_raw, write_manifest_raw, instruction)
launch, expectation = json.loads(launch_raw), json.loads(expectation_raw)
write_receipt = json.loads(receipt_raw)
write_receipt['id'] = 'receipt.' + sha(launch_raw)
write_receipt['body'].update(attempt=expectation['body']['attempt'], control=launch['body']['control'],
    subject=launch['body']['subject'], timing={'admitted_at':'2026-08-30T00:00:07Z',
                                             'terminated_at':'2026-08-30T00:00:08Z'})
write_receipt_raw = canonical(write_receipt)
put(base / 'storage-input.json', {'attempt_id': write_attempt, 'receipt_utf8': write_receipt_raw.decode(),
    'stdout_utf8': '', 'stderr_utf8': '', 'manifest_utf8': evidence_raw.decode(),
    'evidence_utf8': result_raw.decode()})
run(['/usr/bin/sudo', '-n', '-u', writer, '--', sys.executable, '-I', '-S', '-B',
     base / 'genuine-writer.py'])
write_origin_raw = run(['/usr/bin/sudo', '-n', '-u', consumer, '--', sys.executable,
    '-I', '-S', '-B', base / 'genuine-reader.py', write_attempt])
write_checker_raw = component('enforcement/v1/check-sandbox-receipt.sh',
    ['check-bound', put(work / 'write-receipt.json', write_receipt_raw),
     put(work / 'write-expectation.json', expectation_raw), work / 'evaluation.json',
     work / 'observation.json'], role='sandbox-receipt-check')
assert json.loads(write_checker_raw)['body']['enforcement_verdict'] == 'satisfied'
write_trace_raw = e.trace_ledger(incident, write_attempt, environment, 'no-change', 'tool.verifier',
    evaluation_raw, write_checker_raw)
write_trace_receipt = component('telemetry/v1/validate-trace-ledger.sh',
    ['validate', incident['id'], write_attempt, put(work / 'write-trace.json', write_trace_raw)],
    role='trace-validation')
write_provenance = json.loads(provenance)
write_provenance['id'] = write_attempt
write_provenance['body'].update(consumer_source_sha256=sha((package / 'shadow/v1/write-shadow.py').read_bytes()),
                                 commands=commands)
write_provenance_raw = canonical(write_provenance)
write_material_receipt = json.loads(json.loads(write_response_raw)['payloads'][0]['data'])
write_tree = write_material_receipt['candidate']['tree_id']
publisher, publisher_body = w._publisher(incident, write_tree)
write_section = {'bundle_ref': w._bundle_ref(frozen['bundle.json']), 'scope_id': scope_doc['id'],
    'workflow_id': 'workflow.shadow-evidence-commit', 'task_class': 'task.commit-shadow-evidence',
    'write_set': write_set, 'publisher_request': publisher,
    'admission': {'state':'checked', 'effect':'none', 'request_sha256':sha(canonical(publisher)),
                  'write_set_sha256':sha(canonical(write_set))},
    'publication': {'state':'withheld','reason_id':'shadow.write-not-published'},
    'post_write_verification': {'target_revision':incident['body']['git_revision_ref'],
                               'candidate_tree_id':write_tree, 'write_set':write_set}}
outer_files = dict(files)
outer_files.update({'materialization-input.json':write_input_raw, 'materialization-response.json':write_response_raw,
    'preparation-record.json':write_record_raw, 'preparation-manifest.json':write_manifest_raw,
    'qualified-identity.json':write_identity_raw, 'sandbox-request.json':launch_raw,
    'sandbox-expectation.json':expectation_raw, 'sandbox-receipt.json':write_receipt_raw,
    'sandbox-check.json':write_checker_raw, 'origin-observation.json':write_origin_raw,
    'trace-ledger.json':write_trace_raw, 'trace-receipt.json':write_trace_receipt,
    'consumer-provenance.json':write_provenance_raw, 'publisher-body.txt':publisher_body})
materialized = SimpleNamespace(response_raw=write_response_raw, evaluation_raw=evaluation_raw,
                               qualified_identity_raw=write_identity_raw)
outer_record = w._outer_record(SimpleNamespace(anchor=facts_anchor), materialized, frozen,
                              outer_files, write_section, write_provenance_raw, write_trace_raw)
outer_files['shadow-record.json'] = outer_record
w._record_relations(outer_files, incident, json.loads(result_raw)['body'], write_origin_raw,
                    facts_anchor, write_section)
outer_marker = canonical({'schema_version':1,'kind':'shadow_consumer_bundle',
    'id':'bundle.'+sha(frozen['incident.json'])[:32], 'body':{
      'activation_state':'inactive', 'record_form':'withheld-write.v1',
      'incident_sha256':sha(frozen['incident.json']), 'target_revision':incident['body']['git_revision_ref'],
      'files':[{'name':name,'size_bytes':len(outer_files[name]),'sha256':sha(outer_files[name])}
               for name in sorted(outer_files)]}})
outer_bundle = base / 'snapshots' / sha(outer_record)
outer_bundle.mkdir(mode=0o755)
for name, raw in outer_files.items():
    put(outer_bundle / name, raw)
put(outer_bundle / 'bundle.json', outer_marker)
shutil.copytree(write_candidate / 'repository.git/objects', source / 'objects', dirs_exist_ok=True)
for root, dirs, names in os.walk(source):
    pathlib.Path(root).chmod(0o755)
    for name in names:
        (pathlib.Path(root) / name).chmod(0o444)
# The frozen first attempt remains valid after the writer creates a lawful sibling.
sibling_scope = json.loads(run(scope_argv))
assert sibling_scope['body']['evidence']['shadow_bundle_facts'][0]['authentication']['state'] == 'authenticated'
scope_doc['body'].update(workflow_id='workflow.shadow-evidence-commit', task_class='task.commit-shadow-evidence',
    allowed_paths=paths, qualified_identity=write_identity['body'], shadow_evidence_refs=[e.document_ref(outer_record)])
for name in ('risk','duty'):
    gate = json.loads((doc_root / (name+'.json')).read_bytes())
    gate['body']['stage']['request_ref'] = write_identity['body']['stage_request_ref']
    put(doc_root / (name+'.json'), gate)
for name in ('risk','kill'):
    gate = json.loads((doc_root / (name+'.json')).read_bytes())
    gate['body']['duty_evaluation_ref']['sha256'] = sha((doc_root / 'duty.json').read_bytes())
    put(doc_root / (name+'.json'), gate)
for key, name in (('risk_gate_evaluation_ref','risk'), ('kill_switch_evaluation_ref','kill'), ('duty_separation_evaluation_ref','duty')):
    scope_doc['body']['gate_evidence_refs'][key] = e.document_ref((doc_root / (name+'.json')).read_bytes())
put(doc_root / 'scope.json', scope_doc)
put(doc_root / 'shadow-set.json', {'schema_version':1,'kind':'shadow_evidence_set',
    'id':'scope.evidence.genuine','body':{'records':[json.loads(outer_record)]}})
# A bundle not claimed by the current evidence set must not remain in the input root.
archive = base / 'snapshots' / bundle.name
bundle.rename(archive)
outer_bundle.rename(base / 'bundles' / outer_bundle.name)
outer_scope_raw = run(scope_argv)
put(base / 'genuine-write-scope-evaluation.json', outer_scope_raw)
outer_facts = json.loads(outer_scope_raw)['body']['evidence']['shadow_bundle_facts']
assert len(outer_facts)==1 and outer_facts[0]['eligible'] is True
assert outer_facts[0]['authentication']['state']=='authenticated'
assert outer_facts[0]['record_form']=='withheld-write.v1'
print(json.dumps({'genuine_withheld_contract':'PASS','frozen_files':32,'synthetic_runtime_facts':True,
    'vm_executed':False,'publisher_executed':False,'lawful_sibling_before_read':'PASS'},sort_keys=True),flush=True)

# These private calls retain the real package, command owner and actual Git database.
relation_area=base/'reader-relations';relation_area.mkdir(mode=0o755)
relation_cases=[]
write_commit=write_material_receipt['candidate']['commit_id']
actual_facts={}
for entry_raw in git(['ls-tree','-r','-t','-z',write_commit]).split(b'\0'):
    if entry_raw:
        head,path=entry_raw.split(b'\t');actual_facts[path.decode()]=tuple(head.decode().split())
def object_tree(entries,directory=''):
    children={path[len(directory):].split('/')[0] for path in entries if path.startswith(directory)}
    rows=[]
    for name in sorted(children):
        path=directory+name;mode,kind,oid=entries[path]
        if kind=='tree':oid=object_tree(entries,path+'/')
        rows.append(f'{mode} {kind} {oid}\t{name}\n')
    return git(['mktree'],''.join(rows).encode()).decode().strip()
changed_blob=git(['hash-object','-w','--stdin'],b'changed existing file\n').decode().strip()
for label,change in (
    ('old-blob',lambda f:f.update({'source.txt':('100644','blob',changed_blob)})),
    ('old-mode',lambda f:f.update({'source.txt':('100755','blob',blob)})),
    ('old-type',lambda f:f.update({'source.txt':('120000','blob',blob)})),
    ('old-removal',lambda f:f.pop('source.txt')),
    ('extra-leaf',lambda f:f.update({'extra.txt':('100644','blob',changed_blob)})),
    ('unrelated-tree',lambda f:f.update({'unrelated/old.txt':('100644','blob',changed_blob)}))):
    changed=dict(actual_facts);change(changed);bad_tree=object_tree(changed)
    bad_commit=git(['commit-tree',bad_tree,'-p',commit],b'reader negative\n').decode().strip()
    relation_cases.append({'label':label,'mode':'write','commit':bad_commit,'tree':bad_tree})
wrong_parent=git(['commit-tree',write_tree],b'wrong actual sole parent\n').decode().strip()
for label,mode in (('actual-parent','git'),('parent-field','git'),('tree-field','git')):
    relation_cases.append({'label':label,'mode':mode,'commit':wrong_parent if label=='actual-parent' else write_commit,
                           'tree':write_tree})
for label in ('rows-missing','rows-extra','rows-reordered','rows-unmatched','row-blob',
              'scope-glob','bundle-ref','publisher-body','rebuilt-input','frozen-marker','frozen-seed','frozen-readme'):
    case={'label':label,'mode':'write','commit':write_commit,'tree':write_tree}
    if label.startswith('frozen-'):
        name={'frozen-marker':'bundle.json','frozen-seed':'eval-seed.json','frozen-readme':'README.md'}[label]
        path='ystack-evidence/'+incident['id']+'/'+name
        raw=b'Wrong readme\n' if name=='README.md' else canonical({'wrong':True})
        oid=git(['hash-object','-w','--stdin'],raw).decode().strip()
        changed=dict(actual_facts);changed[path]=('100644','blob',oid)
        bad_tree=object_tree(changed)
        case.update(tree=bad_tree,commit=git(['commit-tree',bad_tree,'-p',commit],b'frozen relation negative\n').decode().strip(),
                    row={'path':path,'git_blob_oid':oid,'sha256':sha(raw)})
    relation_cases.append(case)
bundle_area=relation_area/'bundles';bundle_area.mkdir(mode=0o755)
for label in ('bundle-complete','missing-receipt','missing-origin','missing-check','missing-marker','early-marker',
              'extra-file','marker-form','marker-size','marker-digest','marker-inventory','swapped-directory'):
    directory=bundle_area/label;shutil.copytree(base/'bundles'/sha(outer_record),directory)
    if label.startswith('missing-'):
        name={'missing-receipt':'sandbox-receipt.json','missing-origin':'origin-observation.json',
              'missing-check':'sandbox-check.json','missing-marker':'bundle.json'}[label]
        (directory/name).unlink()
    elif label=='early-marker':
        for path in directory.iterdir():
            if path.name!='bundle.json':path.unlink()
    elif label=='extra-file':put(directory/'extra.txt',b'extra\n')
    elif label not in ('swapped-directory','bundle-complete'):
        marker=json.loads((directory/'bundle.json').read_bytes())
        if label=='marker-form':marker['body']['record_form']='enforced-reproduction.v1'
        if label=='marker-size':marker['body']['files'][0]['size_bytes']+=1
        if label=='marker-digest':marker['body']['files'][0]['sha256']='0'*64
        if label=='marker-inventory':marker['body']['files'].pop()
        put(directory/'bundle.json',marker)
    if label=='swapped-directory':
        shutil.copytree(directory,bundle_area/'replacement')
        os.chown(bundle_area,consumer_uid,consumer_gid)
    relation_cases.append({'label':label,'mode':'bundle'})
for label,form,change,needle in (
    ('form-missing','withheld',lambda b:b.pop('record_form'),'set(body) =='),
    ('form-wrong','withheld',lambda b:b.update(record_form='other'),'form in'),
    ('write-missing','withheld',lambda b:b.pop('write'),'set(body) =='),
    ('write-mixed','enforced',lambda b:b.update(write={}), 'set(body) =='),
    ('enforced-changed','enforced',lambda b:b['materialization']['value'].update(outcome='changed'),'outcome'),
    ('withheld-nochange','withheld',lambda b:b['materialization']['value'].update(outcome='no-change'),'outcome')):
    selected=dict(outer_files if form=='withheld' else files)
    record=json.loads(selected['shadow-record.json']);change(record['body'])
    selected['shadow-record.json']=canonical(record)
    marker=json.loads(outer_marker if form=='withheld' else frozen['bundle.json'])
    marker['body']['files']=[{'name':name,'size_bytes':len(raw),'sha256':sha(raw)} for name,raw in sorted(selected.items())]
    selected['bundle.json']=canonical(marker)
    location=relation_area/('dispatch-'+label);location.mkdir(mode=0o755)
    bundle_root=location/'bundles';bundle_root.mkdir(mode=0o755)
    directory=bundle_root/sha(selected['shadow-record.json']);directory.mkdir(mode=0o755)
    for name,raw in selected.items():put(directory/name,raw)
    selected_scope=json.loads((doc_root/'scope.json').read_bytes())
    selected_scope['body'].update(qualified_identity=record['body']['qualified_identity'],
        shadow_evidence_refs=[e.document_ref(selected['shadow-record.json'])])
    put(location/'scope.json',selected_scope)
    put(location/'set.json',{'schema_version':1,'kind':'shadow_evidence_set','id':'scope.evidence.genuine','body':{'records':[record]}})
    relation_cases.append({'label':label,'mode':'dispatch','needle':needle})
location=relation_area/'dispatch-environment-duplicate';location.mkdir(mode=0o755)
duplicated=json.loads(outer_record);duplicated['id']='record.scope-second-eligible'
assert sha(canonical(duplicated))!=sha(outer_record)
bundle_root=location/'bundles';bundle_root.mkdir(mode=0o755)
shutil.copytree(base/'bundles'/sha(outer_record),bundle_root/sha(outer_record))
current=json.loads((doc_root/'scope.json').read_bytes())
current['body']['shadow_evidence_refs'].append(e.document_ref(canonical(duplicated)))
put(location/'scope.json',current)
put(location/'set.json',{'schema_version':1,'kind':'shadow_evidence_set','id':'scope.evidence.genuine',
    'body':{'records':[json.loads(outer_record),duplicated]}})
relation_cases.append({'label':'environment-duplicate','mode':'dispatch','needle':'environment not in identities'})
put(relation_area/'cases.json',relation_cases)
for name,raw in outer_files.items():put(relation_area/name,raw)
put(relation_area/'bundle.json',outer_marker)
for label in [row['label'] for row in relation_cases]+['qualified','unproven']:
    scratch=relation_area/label;scratch.mkdir(mode=0o700,exist_ok=True);scratch.chmod(0o700);os.chown(scratch,consumer_uid,consumer_gid)
    for name in ('reader-captures','reader-runtime','observation','reader-runtime/no-hooks'):
        child=scratch/name;child.mkdir(mode=0o700);os.chown(child,consumer_uid,consumer_gid)
relation_program=put(base/'reader-relations.py',b"""import copy,importlib.util,json,os,pathlib,sys
base=pathlib.Path(sys.argv[1]);label=sys.argv[2];package=base/'package';area=base/'reader-relations'
source=package/'scope/v1/read-shadow-evidence.py'
spec=importlib.util.spec_from_file_location('scope_actual_relation_reader',source)
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
c=module.c;canonical=c.canonical
cases=json.loads((area/'cases.json').read_bytes())
case=next((row for row in cases if row['label']==label),None)
location=area/('dispatch-'+label) if case and case['mode']=='dispatch' else base/'documents'
reader=module._Reader(location/'scope.json',location/('set.json' if case and case['mode']=='dispatch' else 'shadow-set.json'),
                     location/'bundles' if case and case['mode']=='dispatch' else base/'bundles',
                     base/'source.git',area/label/'observation/result.json')
files={name:(area/name).read_bytes() for name in c.SHADOW_EVIDENCE_NAMES+('publisher-body.txt','bundle.json')}
incident=json.loads(files['incident.json']);body=json.loads(files['shadow-record.json'])['body']
try:
    if label in ('qualified','unproven'):
        if label=='unproven':files['registry.json']=(package/'shadow/v1/shadow-environments.json').read_bytes()
        operation=lambda:reader._authenticate(files)
        target='_authenticate';needle='registry["proof_state"]'
    else:
        case=next(row for row in json.loads((area/'cases.json').read_bytes()) if row['label']==label)
        if case['mode']=='dispatch':
            try:reader.evaluate()
            except c.Refusal as error:
                assert error.code=='E_RELATION',(label,error.code)
                tb=error.__traceback__;reached=[]
                while tb:
                    if tb.tb_frame.f_code is module._Reader.evaluate.__code__:reached.append(tb.tb_lineno)
                    tb=tb.tb_next
                lines=source.read_text().splitlines()
                assert any(case['needle'] in '\\n'.join(lines[max(0,n-2):n+4]) for n in reached),(label,reached)
                print(json.dumps({'actual_reader_dispatch':label,'code':error.code,'lines':reached}),flush=True)
            else:raise AssertionError('mixed record form accepted: '+label)
            raise SystemExit(0)
        if case['mode']=='bundle':
            parent=reader.directory(area/'bundles')
            if label=='bundle-complete':
                held=c._HeldBundle(parent,label,'withheld-write.v1')
                try:assert held.files['shadow-record.json']==files['shadow-record.json'];held.recheck();print('actual HeldBundle complete positive PASS')
                finally:held.close()
            elif label=='swapped-directory':
                held=c._HeldBundle(parent,label,'withheld-write.v1')
                try:
                    (area/'bundles'/label).rename(area/'bundles'/'previous')
                    (area/'bundles'/'replacement').rename(area/'bundles'/label)
                    try:held.recheck()
                    except c.Refusal as error:assert error.code=='E_STALE';print('actual HeldBundle swapped directory Stale PASS')
                    else:raise AssertionError('swapped completed bundle accepted')
                finally:held.close()
            else:
                try:c._HeldBundle(parent,label,'withheld-write.v1')
                except c.Refusal as error:
                    assert error.code=='E_RELATION',(label,error.code)
                    tb=error.__traceback__;reached=False
                    while tb:
                        reached|=tb.tb_frame.f_code is c._HeldBundle.__init__.__code__;tb=tb.tb_next
                    assert reached;print('actual HeldBundle '+label+' Relation PASS',flush=True)
                else:raise AssertionError('malformed completed bundle accepted: '+label)
            raise SystemExit(0)
        revision=incident['body']['git_revision_ref']
        facts=reader.git.inventory(dict(revision,commit_id=case['commit']))
        source_facts=reader.git.inventory(revision)
        assert reader.commit(case['commit'])[0]==case['tree']
        target='write_relations';needle='facts.get(path)'
        if label=='extra-leaf':needle='if path not in source_facts and value[1] !='
        if case['mode']=='git':
            response=json.loads(files['materialization-response.json']);receipt=json.loads(response['payloads'][0]['data'])
            receipt['candidate'].update(commit_id=case['commit'],tree_id=case['tree'])
            if label=='parent-field':receipt['candidate']['parent_commit_id']='0'*40
            if label=='tree-field':receipt['candidate']['tree_id']='0'*40
            receipt_raw=canonical(receipt);response['payloads'][0].update(data=receipt_raw.decode(),sha256=c.digest(receipt_raw))
            files['materialization-response.json']=canonical(response)
            prep=json.loads(files['preparation-record.json'])
            prep.update(response_sha256=c.digest(files['materialization-response.json']),receipt_sha256=c.digest(receipt_raw))
            prep['candidate'].update({key:receipt['candidate'][key] for key in ('commit_id','tree_id','parent_commit_id')})
            files['preparation-record.json']=canonical(prep)
            operation=lambda:reader.git_relations(files,json.loads(files['materialization-input.json']),incident,body)
            target='git_relations';needle={'actual-parent':'parents ==','parent-field':'candidate["parent_commit_id"]','tree-field':'candidate_tree =='}[label]
        else:
            rows=body['write']['write_set']
            if 'row' in case:
                selected=next(row for row in rows if row['path']==case['row']['path']);selected.update(case['row'])
            if label=='rows-missing':rows.pop()
            if label=='rows-extra':rows.append(copy.deepcopy(rows[-1]))
            if label=='rows-reordered':rows[0],rows[1]=rows[1],rows[0]
            if label=='rows-unmatched':rows[0]['path']='unmatched.txt'
            if label.startswith('rows-'):needle='[row.get("path")'
            if label=='row-blob':rows[0]['git_blob_oid']='0'*40;needle='set(row) =='
            if label=='scope-glob':reader.scope_body['allowed_paths']=['unmatched/*'];needle='self.allowed(path)'
            if label.startswith('frozen-'):needle={'frozen-marker':'same(marker_doc','frozen-seed':'seed ==','frozen-readme':'frozen["incident.json"]'}[label]
            if label=='bundle-ref':body['write']['bundle_ref']['sha256']='0'*64;needle='write["bundle_ref"]'
            if label=='publisher-body':files['publisher-body.txt']=b'wrong body\\n';needle='publisher_request'
            if label=='rebuilt-input':files['materialization-input.json']=canonical(dict(json.loads(files['materialization-input.json']),extra=1));needle='self.rebuild_input'
            operation=lambda:reader.write_relations(files,json.loads(files['materialization-input.json']),incident,body,
                                                    facts,source_facts,case['tree'])
    try:operation()
    except c.Refusal as error:
        assert label!='qualified' and error.code=='E_RELATION',(label,error.code)
        reached=[];tb=error.__traceback__
        while tb:
            if tb.tb_frame.f_code.co_filename==str(source) and tb.tb_frame.f_code.co_name==target:
                reached.append(tb.tb_lineno)
            tb=tb.tb_next
        lines=source.read_text().splitlines()
        assert any(needle in '\\n'.join(lines[max(0,n-2):n+4]) for n in reached),(label,target,needle,reached)
        print(json.dumps({'actual_reader_refusal':label,'code':error.code,'function':target,'lines':reached}),flush=True)
    else:
        assert label=='qualified','missing actual Reader refusal: '+label
        print('actual Reader native-qualified authentication positive PASS',flush=True)
finally:reader.close()
""",0o555)
relation_argv=['/usr/bin/sudo','-n','-u',consumer,'--','/usr/bin/env','-i',
    'PATH='+str(tools)+':/usr/bin:/bin','TMPDIR='+str(base/'consumer-work'),
    'YSTACK_SCOPE_JQ='+str(jq),sys.executable,'-I','-S','-B',relation_program,base]
for case in relation_cases:run([*relation_argv,case['label']])
run([*relation_argv,'qualified'])
registry_path=package/'shadow/v1/shadow-environments.json';qualified_registry=registry_path.read_bytes()
try:
    unproven=json.loads(qualified_registry);unproven['body']['environments'][0]['proof_state']='unproven'
    put(registry_path,unproven)
    run([*relation_argv,'unproven'])
finally:put(registry_path,qualified_registry)

original_scope=(doc_root/'scope.json').read_bytes();original_set=(doc_root/'shadow-set.json').read_bytes()
completed=base/'bundles'/sha(outer_record);missing=base/'snapshots'/'missing-digest-control'
completed.rename(missing)
try:
    missing_result=json.loads(run(scope_argv))
    assert missing_result['body']['outcome']=='not-proposable'
    assert 'scope.sandbox-receipt-missing' in missing_result['body']['reason_ids']
finally:missing.rename(completed)
for label,with_legacy in (('required-environment-missing',False),('required-environment-legacy',True)):
    current=json.loads(original_scope);current['body']['required_shadow_environments'].append('env.scope-missing')
    records=[json.loads(outer_record)]
    if with_legacy:
        legacy=json.loads(outer_record);legacy['id']='record.scope-legacy'
        for key in ('record_form','sandbox','producer_invocations','consumer_provenance_ref','write'):legacy['body'].pop(key)
        legacy['body']['environment']['environment_id']='env.scope-missing';records.append(legacy)
        current['body']['shadow_evidence_refs'].append(e.document_ref(canonical(legacy)))
    try:
        put(doc_root/'scope.json',current)
        put(doc_root/'shadow-set.json',{'schema_version':1,'kind':'shadow_evidence_set','id':'scope.evidence.genuine','body':{'records':records}})
        report=json.loads(run(scope_argv));facts=report['body']['evidence']['shadow_bundle_facts']
        assert report['body']['outcome']=='not-proposable' and 'scope.sandbox-receipt-missing' in report['body']['reason_ids']
        assert sum(row['eligible'] and row['authentication']['state']=='authenticated' for row in facts)==1
        print(label+' authenticated member cannot replace every required environment PASS',flush=True)
    finally:put(doc_root/'scope.json',original_scope);put(doc_root/'shadow-set.json',original_set)

reader_command = ['/usr/bin/sudo','-n','-u',consumer,'--',sys.executable,'-I','-S','-B',
                  base / 'genuine-reader.py', write_attempt]
refuse(['/usr/bin/sudo','-n','-u',writer,'--',sys.executable,'-I','-S','-B',
        base / 'genuine-reader.py',write_attempt], 'writer-is-not-consumer', b'E_CONFIG')
run(['/usr/sbin/dseditgroup','-o','edit','-d',consumer,'-t','user',group] if sys.platform=='darwin'
    else ['/usr/bin/gpasswd','--delete',consumer,group])
try:
    assert str(gid).encode() not in run(['/usr/bin/sudo','-n','-u',consumer,'--','/usr/bin/id','-G']).split()
    refuse(reader_command,'missing-consumer-group',b'E_CONFIG')
finally:
    run(['/usr/sbin/dseditgroup','-o','edit','-a',consumer,'-t','user',group] if sys.platform=='darwin'
        else ['/usr/sbin/usermod','--append','--groups',group,consumer])
assert str(gid).encode() in run(['/usr/bin/sudo','-n','-u',consumer,'--','/usr/bin/id','-G']).split()
store_snapshot = {str(path.relative_to(store)): (path.lstat().st_uid,path.lstat().st_gid,
    stat.S_IMODE(path.lstat().st_mode),path.read_bytes() if path.is_file() else None)
    for path in store.rglob('*')}
permissions_source = base / 'consumer-permissions.py'
put(permissions_source, b"""import os,pathlib,sys
base=pathlib.Path(__file__).parent
store=base/'store'
receipt=store/'attempt.scope-genuine-write/receipt.json'
source=base/'consumer-work/replacement'
source.write_bytes(b'consumer-owned replacement')
actions=(('create',lambda:os.open(store/'created',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)),
 ('replace',lambda:os.replace(source,receipt)),
 ('rename',lambda:os.rename(receipt,receipt.with_name('renamed'))),
 ('chmod',lambda:os.chmod(receipt,0o600)),
 ('link',lambda:os.link(receipt,receipt.with_name('linked'))),
 ('remove',lambda:os.unlink(receipt)))
for name,action in actions:
 try: action()
 except PermissionError: print('consumer denied '+name,flush=True)
 else: raise AssertionError('consumer acquired write authority: '+name)
source.unlink()
""", 0o555)
permission_report = run(['/usr/bin/sudo','-n','-u',consumer,'--',sys.executable,'-I','-S','-B',
                         permissions_source])
assert len(permission_report.splitlines()) == 6
assert store_snapshot == {str(path.relative_to(store)): (path.lstat().st_uid,path.lstat().st_gid,
    stat.S_IMODE(path.lstat().st_mode),path.read_bytes() if path.is_file() else None)
    for path in store.rglob('*')}
for path in (store, store/write_attempt, store/write_attempt/'receipt.json'):
    print(json.dumps({'actual_metadata':str(path),'uid':path.stat().st_uid,'gid':path.stat().st_gid,
        'mode':stat.S_IMODE(path.stat().st_mode),'device':path.stat().st_dev,'inode':path.stat().st_ino,
        'xattrs':{name:os.getxattr(path,name).hex() for name in os.listxattr(path)}},sort_keys=True),flush=True)

receipt_path = store / write_attempt / 'receipt.json'
receipt_before = receipt_path.read_bytes()
for label, mode, owner in (('wrong-owner',0o440,0),('group-write',0o460,uid),('world-read',0o444,uid)):
    os.chown(receipt_path,owner,gid)
    receipt_path.chmod(mode)
    refuse(reader_command,label,b'E_STORE')
    os.chown(receipt_path,uid,gid)
    receipt_path.chmod(0o440)
assert receipt_path.read_bytes()==receipt_before
hardlink = store / write_attempt / 'hardlink'
os.link(receipt_path,hardlink)
refuse(reader_command,'hardlink',b'E_STORE')
hardlink.unlink()
original_receipt = store / write_attempt / 'original-receipt'
receipt_path.rename(original_receipt)
receipt_path.symlink_to(original_receipt.name)
refuse(reader_command,'symlink',b'E_STORE')
receipt_path.unlink()
original_receipt.rename(receipt_path)
if sys.platform=='darwin':
    run(['/bin/chmod','+a','user:'+consumer+' allow write',receipt_path])
    print(run(['/bin/ls','-lde',receipt_path]).decode(),flush=True)
    try:refuse(reader_command,'extra-write-acl',b'E_STORE')
    finally:run(['/bin/chmod','-a#','0',receipt_path])
else:
    acl_raw = (2).to_bytes(4,'little')
    for tag, permission, identity_number in ((1,4,0xffffffff),(2,6,consumer_uid),(4,4,0xffffffff),
                                             (16,6,0xffffffff),(32,0,0xffffffff)):
        acl_raw += tag.to_bytes(2,'little')+permission.to_bytes(2,'little')+identity_number.to_bytes(4,'little')
    os.setxattr(receipt_path,'system.posix_acl_access',acl_raw)
    print(json.dumps({'actual_acl':os.getxattr(receipt_path,'system.posix_acl_access').hex()},sort_keys=True),flush=True)
    refuse(reader_command,'extra-write-acl',b'E_STORE')
    os.removexattr(receipt_path,'system.posix_acl_access')
    receipt_path.chmod(0o440)
assert receipt_path.read_bytes()==receipt_before

# Every archive mutation is canonical and rehashes its marker and enclosing references.
positive_bundle = base / 'bundles' / sha(outer_record)
positive_bundle.rename(base / 'snapshots' / ('positive-'+positive_bundle.name))
positive_scope = (doc_root/'scope.json').read_bytes()
positive_set = (doc_root/'shadow-set.json').read_bytes()
def archive_negative(label, name, change):
    changed = dict(outer_files)
    value=json.loads(changed[name])
    change(value)
    changed[name]=canonical(value)
    record=json.loads(changed['shadow-record.json'])
    if name=='consumer-provenance.json':
        record['body']['consumer_provenance_ref']=e.document_ref(changed[name])
    elif name=='sandbox-expectation.json':
        record['body']['sandbox']['expectation_ref']=e.document_ref(changed[name])
    elif name=='preparation-record.json':
        pass
    changed['shadow-record.json']=canonical(record)
    marker_doc=json.loads(outer_marker)
    marker_doc['body']['files']=[{'name':key,'size_bytes':len(raw),'sha256':sha(raw)}
                               for key,raw in sorted(changed.items())]
    directory=base/'bundles'/sha(changed['shadow-record.json'])
    directory.mkdir(mode=0o755)
    try:
        for key,raw in changed.items():put(directory/key,raw)
        put(directory/'bundle.json',marker_doc)
        current_scope=json.loads(positive_scope)
        current_scope['body']['shadow_evidence_refs']=[e.document_ref(changed['shadow-record.json'])]
        put(doc_root/'scope.json',current_scope)
        put(doc_root/'shadow-set.json',{'schema_version':1,'kind':'shadow_evidence_set',
            'id':'scope.evidence.genuine','body':{'records':[json.loads(changed['shadow-record.json'])]}})
        refuse(scope_argv,label,b'E_RELATION')
    finally:
        shutil.rmtree(directory)
        put(doc_root/'scope.json',positive_scope)
        put(doc_root/'shadow-set.json',positive_set)
archive_cases=(
 ('native-abi','consumer-provenance.json',lambda value:value['body']['native_release'].__setitem__('python_abi','wrong-abi')),
 ('native-source','consumer-provenance.json',lambda value:value['body']['native_release'].__setitem__('source_sha256',sha(b'wrong source'))),
 ('consumer-source','consumer-provenance.json',lambda value:value['body'].__setitem__('consumer_source_sha256',sha(b'wrong consumer'))),
 ('command-role','consumer-provenance.json',lambda value:value['body']['commands'][0].__setitem__('role','caller-selected-role')),
 ('expectation-subject','sandbox-expectation.json',lambda value:value['body']['subject'].__setitem__('incident_sha256',sha(b'wrong incident'))),
 ('preparation-source','preparation-record.json',lambda value:value['source'].__setitem__('commit_id','a'*40)),
 ('publisher-title','shadow-record.json',lambda value:value['body']['write']['publisher_request']['body'].__setitem__('title','wrong title')),
 ('publisher-schema-type','shadow-record.json',lambda value:value['body']['write']['publisher_request'].__setitem__('schema_version',True)),
 ('admission-effect','shadow-record.json',lambda value:value['body']['write']['admission'].__setitem__('effect','write')),
 ('write-add-only-type','shadow-record.json',lambda value:value['body']['write']['write_set'][0].__setitem__('add_only',1)),
 ('publication-state','shadow-record.json',lambda value:value['body']['write']['publication'].__setitem__('state','published')),
 ('postwrite-tree','shadow-record.json',lambda value:value['body']['write']['post_write_verification'].__setitem__('candidate_tree_id','a'*40)))
for label,name,change in archive_cases:
    archive_negative(label,name,change)
(base/'snapshots'/('positive-'+positive_bundle.name)).rename(positive_bundle)
assert json.loads(run(scope_argv))['body']['evidence']['shadow_bundle_facts'][0]['authentication']['state']=='authenticated'
print(json.dumps({'genuine_paired_storage_controls':'PASS','consumer_denials':6,
    'canonical_archive_refusals':len(archive_cases),'original_receipt_terminated_at':
        json.loads(receipt_before)['body']['timing']['terminated_at']},sort_keys=True),flush=True)

race_package = base / 'through-use-package'
shutil.copytree(package, race_package)
frontend = race_package / 'scope/v1/evaluate-scope.sh'
frontend_before = frontend.read_bytes()
seal_boundary = b"/usr/bin/printf 'SEAL\\n' >&7 || emit_error E_RUNTIME\n"
assert frontend_before.count(seal_boundary)==1
synchronization = b"""exec 6<>"$TMPDIR/test-ack" || emit_error E_RUNTIME
/usr/bin/printf 'ACQUIRED\\n' >"$TMPDIR/test-ready" || emit_error E_RUNTIME
reply=''
IFS= read -r -t 30 reply <&6 || emit_error E_RUNTIME
exec 6>&-
case "$reply" in
  CONTINUE) ;;
  CANCEL) kill -s TERM "$BASHPID" ;;
  *) emit_error E_RUNTIME ;;
esac
"""
cleanup_boundary=b'cleanup() { finish_reader; exec 8<&-; /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }'
assert frontend_before.count(cleanup_boundary)==1
capture_cleanup=b"""cleanup() { finish_reader; exec 8<&-;
 /usr/bin/printf '%s' "$test_reader_status" 2>/dev/null >"$TMPDIR/test-reader-status" ||
  /usr/bin/printf capture_error 2>/dev/null >"$TMPDIR/test-reader-capture-error" || :
 /bin/dd if="$scratch/reader-stderr" of="$TMPDIR/test-reader-stderr" bs=65537 count=1 2>/dev/null ||
  /usr/bin/printf capture_error 2>/dev/null >"$TMPDIR/test-reader-capture-error" || :
 /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }"""
wait_boundary=b'    wait "$reader_pid" 2>/dev/null || :'
assert frontend_before.count(wait_boundary)==1
wait_capture=b'    if wait "$reader_pid" 2>/dev/null; then test_reader_status=0; else test_reader_status=$?; fi'
execution=frontend_before.replace(b"reader_pid=''\n",b"reader_pid=''\ntest_reader_status=unreaped\n",1)
execution=execution.replace(wait_boundary,wait_capture,1)
execution=execution.replace(seal_boundary,synchronization+seal_boundary,1)
frontend.write_bytes(execution.replace(cleanup_boundary,capture_cleanup,1))
frontend.chmod(0o555)
print(json.dumps({'private_frontend_original_sha256':sha(frontend_before),
    'private_frontend_execution_sha256':sha(frontend.read_bytes()),
    'difference':'fixed before-SEAL synchronization and bounded same-reader stderr copy after original finish/reap; production reader unchanged'},sort_keys=True),flush=True)
ready_path, ack_path = consumer_work/'test-ready', consumer_work/'test-ack'
reader_stderr_path=consumer_work/'test-reader-stderr'
capture_error_path=consumer_work/'test-reader-capture-error'
reader_status_path=consumer_work/'test-reader-status'
for path in (reader_stderr_path,capture_error_path,reader_status_path):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    os.close(fd);os.chown(path,consumer_uid,consumer_gid)
    state=path.lstat()
    assert stat.S_ISREG(state.st_mode) and state.st_nlink==1 and stat.S_IMODE(state.st_mode)==0o600
for path in (ready_path,ack_path):
    os.mkfifo(path,0o600)
    os.chown(path,consumer_uid,consumer_gid)
    st=path.lstat()
    assert stat.S_ISFIFO(st.st_mode) and st.st_nlink==1 and stat.S_IMODE(st.st_mode)==0o600
race_argv = list(scope_argv)
race_argv[race_argv.index(package/'scope/v1/evaluate-scope.sh')] = frontend

def metadata(path):
    state=path.lstat()
    return [state.st_dev,state.st_ino,stat.S_IFMT(state.st_mode),state.st_uid,state.st_gid,
            stat.S_IMODE(state.st_mode),state.st_nlink,state.st_size,state.st_mtime_ns,state.st_ctime_ns]

def through_use(label, target, mutate, restore, cancellation=False):
    ready_fd=os.open(ready_path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
    st=os.fstat(ready_fd)
    assert metadata(ready_path)[:7]==[st.st_dev,st.st_ino,stat.S_IFIFO,consumer_uid,consumer_gid,0o600,1]
    child=None
    original_error=None
    before=None
    started=time.monotonic()
    deadline=started+150
    for path in (reader_stderr_path,capture_error_path,reader_status_path):
        fd=os.open(path,os.O_WRONLY|os.O_TRUNC|os.O_NOFOLLOW)
        os.close(fd)
    try:
        child=subprocess.Popen(list(map(str,race_argv)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                               env=env,start_new_session=True,close_fds=True)
        message=b''
        while message!=b'ACQUIRED\n':
            assert time.monotonic()<deadline and child.poll() is None, 'consumer exited before acquisition'
            readable,_,_=select.select([ready_fd],[],[],min(0.1,deadline-time.monotonic()))
            if readable:
                message+=os.read(ready_fd,32)
                assert len(message)<=9
        before=metadata(target)
        if not cancellation:
            mutate()
            print(json.dumps({'through_use':label,'held_object':str(target),
                'expected_before':before,'current_after':metadata(target)},sort_keys=True),flush=True)
        ack_fd=os.open(ack_path,os.O_WRONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
        try:
            ack_state=os.fstat(ack_fd)
            assert stat.S_ISFIFO(ack_state.st_mode) and ack_state.st_uid==consumer_uid
            assert ack_state.st_gid==consumer_gid and ack_state.st_nlink==1
            assert (ack_state.st_dev,ack_state.st_ino)==(ack_path.lstat().st_dev,ack_path.lstat().st_ino)
            message=b'CANCEL\n' if cancellation else b'CONTINUE\n'
            assert os.write(ack_fd,message)==len(message)
        finally:
            os.close(ack_fd)
        stdout,stderr=child.communicate(timeout=max(0.001,deadline-time.monotonic()))
        print(json.dumps({'through_use':label,'returncode':child.returncode,'stdout_hex':stdout.hex(),
            'stderr_utf8':stderr.decode('utf8','backslashreplace'),'elapsed':time.monotonic()-started},sort_keys=True),flush=True)
        with reader_stderr_path.open('rb') as stream:inner_stderr=stream.read(65537)
        with capture_error_path.open('rb') as stream:capture_error=stream.read(64)
        with reader_status_path.open('rb') as stream:reader_status=stream.read(16)
        print(json.dumps({'through_use':label,'original_reader_stderr_utf8':inner_stderr.decode('utf8','backslashreplace'),
            'capture_error':capture_error.decode('utf8','backslashreplace'),
            'original_reader_wait_status':reader_status.decode('utf8','backslashreplace')},sort_keys=True),flush=True)
        assert child.returncode!=0 and stdout==b'' and stderr==b'E_RUNTIME\n'
        assert not capture_error and len(inner_stderr)<=65536
        if not cancellation:
            assert inner_stderr==b'E_STALE\n' and reader_status.isdigit() and 0<int(reader_status)<=255
    except BaseException as error:
        original_error=error
        raise
    finally:
        os.close(ready_fd)
        try:
            if child is not None and child.returncode is None:
                os.killpg(child.pid,signal.SIGTERM)
                child.communicate(timeout=10)
            if before is not None:
                restore()
        except BaseException as cleanup_error:
            if original_error is not None:
                raise original_error from cleanup_error
            raise

import select,signal
original_config=(anchor/'host-config.json').read_bytes()
through_use('anchor-bytes-during-use',anchor/'host-config.json',
    lambda:put(anchor/'host-config.json',original_config+b' '),
    lambda:put(anchor/'host-config.json',original_config))
source_config=(source/'config').read_bytes()
through_use('git-config-during-use',source/'config',
    lambda:put(source/'config',source_config+b'\n'),
    lambda:put(source/'config',source_config))
through_use('receipt-bytes-during-use',receipt_path,
    lambda:receipt_path.write_bytes(receipt_before+b' '),
    lambda:receipt_path.write_bytes(receipt_before))
# The third attempt has real exclusive writes. It does not replace old payload or timing bytes.
third_packet=json.loads((base/'storage-input.json').read_bytes())
third_packet['attempt_id']='attempt.scope-genuine-sibling'
third_receipt=json.loads(third_packet['receipt_utf8'])
third_receipt['body']['attempt']['attempt_id']=third_packet['attempt_id']
third_packet['receipt_utf8']=canonical(third_receipt).decode()
put(base/'storage-input.json',third_packet)
through_use('lawful-sibling-during-use',store,
    lambda:run(['/usr/bin/sudo','-n','-u',writer,'--',sys.executable,'-I','-S','-B',base/'genuine-writer.py']),
    lambda:None)
assert receipt_path.read_bytes()==receipt_before
assert json.loads(receipt_path.read_bytes())['body']['timing']['terminated_at']==json.loads(receipt_before)['body']['timing']['terminated_at']
through_use('watched-cancellation',store,lambda:None,lambda:None,cancellation=True)
ready_path.unlink()
ack_path.unlink()
assert json.loads(run(scope_argv))['body']['evidence']['shadow_bundle_facts'][0]['authentication']['state']=='authenticated'
print(json.dumps({'through_use_controls':'PASS','sibling_before':'PASS','sibling_during':{'public':'E_RUNTIME','reader':'E_STALE'},
    'original_timing_unchanged':True,'watched_cancellation':'E_RUNTIME'},sort_keys=True),flush=True)

PY_GENUINE_ASSEMBLER
}
run_genuine() {
  case "$genuine_platform" in
    Linux) setup_genuine_linux ;;
    Darwin) setup_genuine_macos ;;
    *) fail 'unsupported genuine fixture platform' ;;
  esac
  prepare_genuine_reader
  if [ "$genuine_platform" = Darwin ]; then run_genuine_macos_runtime_guard_controls; fi
  prepare_genuine_assembler
  local script
  for script in genuine-reader.py genuine-assembler.py; do
    /usr/bin/sudo -n /bin/cp -- "$tmp/$script" "$genuine_base/$script" || fail 'fixed fixture source copy'
    /usr/bin/sudo -n "$genuine_chown" -- 0:0 "$genuine_base/$script" || fail 'fixed fixture source ownership'
    /usr/bin/sudo -n /bin/chmod -- 0555 "$genuine_base/$script" || fail 'fixed fixture source mode'
  done
  /usr/bin/sudo -n "$genuine_python" -I -S -B "$genuine_base/genuine-assembler.py" \
    "$genuine_base" "$genuine_writer" "$genuine_consumer" "$genuine_group" "$jq_cache" "$tmp"
  pass 'actual root anchor, distinct storage writer and read-only consumer authenticate one complete bundle'
}

mac_stdin_controls=$(/bin/cat <<'PY_MAC_STDIN_CONTROLS'
import ast
import hashlib
import importlib.util
import json
import pathlib
import stat
import subprocess
import sys
import tempfile
import types

with pathlib.Path(sys.argv[1]).open('rb') as stream:
    source = stream.read(16 * 1024 * 1024 + 1)
assert len(source) <= 16 * 1024 * 1024
def literal(tag):
    opening = b"<<'" + tag.encode() + b"'\n"
    closing = b'\n' + tag.encode() + b'\n'
    assert source.count(opening) == 1
    start = source.index(opening) + len(opening)
    return source[start:source.index(closing, start)].decode() + '\n'


prelude = literal('PY_MAC_STDIN_PRELUDE')
assert source.count(b'\ndef fixed_stdin_module_paths():\n') == 1
body_digests = {
    'PY_MAC_RUNTIME': 'c30fb527aab7ecefea60c6e413c73cbfdc76edfe42334d86c11164f5d86b97e9',
    'PY_MAC_IMPORT_CLOSURE': '70279637e8f9166987bc0763f6d710ad65ccf650c2d92937bc5ebb11efb6fdb5',
}
assert sys.argv[2] in body_digests
collector = prelude.rstrip('\n') + '\n' + literal(sys.argv[2]).rstrip('\n') + '\n'
assert hashlib.sha256(collector.encode()).hexdigest() == body_digests[sys.argv[2]]
assert source.index(b"<<'PY_MAC_STDIN_PRELUDE'\n") < source.index(("<<'" + sys.argv[2] + "'\n").encode())
assert source.count(b'<<<"$genuine_mac_stdin_prelude\n$mac_runtime_body"') == 1
assert source.count(b'<<<"$genuine_mac_stdin_prelude\n$mac_import_body"') == 1
module = ast.parse(collector)
first = next(index for index, node in enumerate(module.body)
             if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
             and node.targets[0].id == 'stdin_entry')
parts = module.body[first:first + 5]
assert [type(node).__name__ for node in parts] == ['Assign', 'Assign', 'Import', 'FunctionDef', 'Expr']
exec(compile(ast.Module(body=parts, type_ignores=[]), '<exact-stdin-classifier>', 'exec'), globals())
assert stdin_entry is sys.modules['__main__'] and stdin_namespace is globals()
results = []

def refused(label, operation):
    try:
        operation()
    except AssertionError:
        results.append({'case': label, 'refused': True})
    else:
        raise AssertionError(label)


# Only UID and ancestor write-mode facts adapt to this ordinary owned tree.
class OwnedPath(type(pathlib.Path())):
    def lstat(self):
        value = super().lstat()
        mode = value.st_mode if self == leaf else value.st_mode & ~0o022
        return types.SimpleNamespace(st_uid=0, st_mode=mode)

    def is_file(self):
        regular = super().is_file()
        if self == changed_path:
            self.unlink()
            self.symlink_to('target.py')
        return regular


loop = next(node for node in module.body if isinstance(node, ast.For)
            and isinstance(node.target, ast.Name) and node.target.id == 'path')
physical = compile(ast.Module(body=[loop], type_ignores=[]), '<exact-fixture-physical-loop>', 'exec')
legacy_paths = set()
legacy_update = """legacy_paths.update(pathlib.Path(module.__file__) for module in sys.modules.values()
 if getattr(module,'__file__',None))"""
exec(compile(legacy_update, '<original-fixture-collection>', 'exec'), globals())
assert pathlib.Path('<stdin>') in legacy_paths
refused('old-real-stdin-collection', lambda: exec(physical, globals() | {'paths': {OwnedPath('<stdin>')}}))
changed_path = None
with tempfile.TemporaryDirectory(prefix='ystack-stdin-owned-') as temporary:
    area = pathlib.Path(temporary).resolve()
    runtime_prefix = OwnedPath(area / 'runtime')
    runtime_prefix.mkdir()
    leaf = runtime_prefix / 'ordinary.py'
    leaf.write_bytes(b'VALUE = 7\n')
    (runtime_prefix / 'target.py').write_bytes(b'VALUE = 9\n')
    before = fixed_stdin_module_paths()
    spec = importlib.util.spec_from_file_location('owned_stdin_module', leaf)
    imported = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = imported
    try:
        spec.loader.exec_module(imported)
        paths = fixed_stdin_module_paths()
        expected = {pathlib.Path(value.__file__) for value in tuple(sys.modules.values())
                    if value is not stdin_entry and getattr(value, '__file__', None)}
        assert paths == expected and leaf in paths and pathlib.Path('<stdin>') not in paths
        assert leaf not in before
        exec(physical, globals() | {'paths': {leaf}})
        results.append({'case': 'real-stdin-entry-and-imported-file', 'accepted': True,
                        'all_other_module_candidates_retained': paths == expected})
        for label, path in [('relative-file', OwnedPath('relative.py')),
                            ('missing-file', runtime_prefix / 'missing.py'),
                            ('other-module-stdin', OwnedPath('<stdin>'))]:
            imported.__file__ = str(path)
            assert pathlib.Path(path) in fixed_stdin_module_paths()
            refused(label, lambda: exec(physical, globals() | {'paths': {path}}))
        imported.__file__ = str(leaf)
        changed_path = leaf
        refused('changed-real-file', lambda: exec(physical, globals() | {'paths': {leaf}}))
        changed_path = None
        leaf.unlink()
        leaf.write_bytes(b'VALUE = 7\n')
        leaf.chmod(0o777)
        refused('unsafe-real-mode', lambda: exec(physical, globals() | {'paths': {leaf}}))
        leaf.chmod(0o600)
        previous_entry = stdin_entry
        try:
            stdin_entry = types.ModuleType('__main__')
            refused('entry-object-rebind', fixed_stdin_module_paths)
        finally:
            stdin_entry = previous_entry
        for attribute, wrong in [('__name__', 'wrong'), ('__file__', 'wrong'), ('__spec__', object())]:
            previous = getattr(stdin_entry, attribute)
            try:
                setattr(stdin_entry, attribute, wrong)
                refused('entry-' + attribute, fixed_stdin_module_paths)
            finally:
                setattr(stdin_entry, attribute, previous)
        sys.modules['owned_entry_alias'] = stdin_entry
        try:
            refused('entry-alias', fixed_stdin_module_paths)
        finally:
            del sys.modules['owned_entry_alias']
        sys.modules['__main__'] = types.ModuleType('__main__')
        try:
            refused('entry-mapping-rebind', fixed_stdin_module_paths)
        finally:
            sys.modules['__main__'] = stdin_entry
        previous = stdin_namespace
        try:
            stdin_namespace = {}
            refused('entry-namespace', fixed_stdin_module_paths)
        finally:
            stdin_namespace = previous
        previous = sys.argv[0]
        try:
            sys.argv[0] = 'wrong'
            refused('entry-argv', fixed_stdin_module_paths)
        finally:
            sys.argv[0] = previous
    finally:
        del sys.modules[spec.name]
fragment = '\n'.join(ast.get_source_segment(collector, node) for node in parts)
for label, flags in [('without-I', ['-S', '-B']), ('without-S', ['-I', '-B'])]:
    result = subprocess.run(['/usr/bin/python3', *flags, '-'], input=('import sys\n' + fragment).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    assert result.returncode != 0 and b'AssertionError' in result.stderr and not result.stdout
    results.append({'case': label, 'refused': True, 'actual_rc': result.returncode})
print(json.dumps({'kind': 'real trusted stdin; ordinary owned-data UID/mode adaptation only',
                  'controls': results, 'supplied_runtime_executed': False, 'entry': sys.argv[2],
                  'composed_sha256': body_digests[sys.argv[2]]}, sort_keys=True))
PY_MAC_STDIN_CONTROLS
) || fail 'fixed stdin control composition'
for stdin_boundary in PY_MAC_RUNTIME PY_MAC_IMPORT_CLOSURE; do
  /usr/bin/python3 -I -S -B - "$root/scripts/test/scope-qualification.test.sh" "$stdin_boundary" <<<"$mac_stdin_controls" ||
    fail 'fixed stdin entry controls'
done

run_genuine
/usr/bin/printf 'scope qualification: %s focused checks passed\n' "$passes"
