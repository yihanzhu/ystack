#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

snapshot_file() {
  /usr/bin/perl -MFcntl=:DEFAULT,:mode -e '
    my ($source,$target,$limit,$mode)=@ARGV;
    sysopen(my $in,$source,O_RDONLY|O_NOFOLLOW) or exit 40;
    my @stat=stat($in);
    @stat && S_ISREG($stat[2]) or exit 40;
    $stat[7] <= $limit or exit 42;
    sysopen(my $out,$target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,oct($mode))
      or exit 40;
    my $total=0;
    while (1) {
      my $read=sysread($in,my $buffer,65536);
      defined($read) or exit 40;
      last if $read == 0;
      $total += $read;
      $total <= $limit or exit 42;
      my $offset=0;
      while ($offset < $read) {
        my $written=syswrite($out,$buffer,$read-$offset,$offset);
        defined($written) && $written > 0 or exit 40;
        $offset += $written;
      }
    }
    close($in) or exit 40;
    close($out) or exit 40;
    chmod(oct($mode),$target) == 1 or exit 40;
  ' "$1" "$2" "$3" "$4"
}

snapshot_expected() {
  local expected=$1 source=$2 target=$3 mode=$4 status=0
  snapshot_file "$source" "$target" 16777216 "$mode" || status=$?
  [ "$status" -eq 0 ] && [ "$(sha256_path "$target")" = "$expected" ]
}

stage_expected() {
  local digest=$1 source=$2 target=$3 mode=$4 token=$5 parent
  parent=${source%/*}
  while [ "$parent" != / ]; do
    [ -d "$parent" ] && [ ! -L "$parent" ] || emit_error "$token"
    parent=${parent%/*}
    [ -n "$parent" ] || parent=/
  done
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || emit_error "$token"
    [ "$(sha256_path "$target")" = "$digest" ] || emit_error "$token"
  else
    /bin/mkdir -p "${target%/*}" || emit_error "$token"
    snapshot_expected "$digest" "$source" "$target" "$mode" || emit_error "$token"
  fi
}

shadow_source_rows() {
  [ "$record_generation" = "$generation" ] || return 1
  /usr/bin/printf '%s\n' \
    'adapters/local-git-materializer/v1/materialize.sh 9b806bb5e202f98166aae60d391107c29aa0d19176765bf48fef47155f9fd358 28742 100755' \
    'adapters/local-git-materializer/v1/object-closure.c f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27 9312 100644' \
    'adapters/local-git-materializer/v1/protocol.jq 232517c19455667cca795769ffc0d8edad7873a9d55be0c21166de5b436bf323 22709 100644' \
    'config/construction-mode.json 5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda 3178 100644' \
    'control/v1/control-policy-set-sandbox-bound.json a50d1ab32ef5964c9e3074084870bffa264fd138f325d830d166135545e3dc8d 3057 100644' \
    'control/v1/control-policy-set.json a3f9a8d16bd60a0cfc32da3e802a207c1e225013b7ef115030ef567d0ccd366a 3043 100644' \
    'control/v1/credential-policy-decision.json 73877276c868eae2da9dcedf8eb465b0526ce26a66506691b9cedbba15f00615 1583 100644' \
    'control/v1/credential-policy.jq 428ea96f23a18c6938421b9cc709d36ba83b34e2441347d5891a971f92d5ec77 13968 100644' \
    'control/v1/credential-policy.json 2ba0ec54d11ab4e9d02993e9283c5f820c662a20cf33d2bff25b1393a5ee403d 1444 100644' \
    'control/v1/duty-separation-decision.json 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 1409 100644' \
    'control/v1/duty-separation-policy.json b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 2104 100644' \
    'control/v1/duty-separation.jq b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c 10060 100644' \
    'control/v1/evaluate-bound-sandbox.sh 710615c6709250f40d0c494914e2577ee84896cde2b5828b4f457940b0347980 11866 100755' \
    'control/v1/evaluate-credential-policy.sh 5c9bab9d00754d63e4ead770489564db8122c53ab1bc8b6e92c27719265c18f7 40417 100755' \
    'control/v1/evaluate-duty.sh 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa 21883 100755' \
    'control/v1/evaluate-evidence-integrity.sh f0ecbe036601102db082d0a94c860ea868614ff79d06f2b37ec8dcd672c367a2 79982 100755' \
    'control/v1/evaluate-kill-switch.sh ea1d40c50de706fa52198dc09e783ee613933aa0dbea72bfff8072becd79bb3b 19218 100755' \
    'control/v1/evaluate-risk-gates.sh 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 18673 100755' \
    'control/v1/evaluate-sandbox.sh 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb 10018 100755' \
    'control/v1/evidence-integrity-decision.json 03e9225face347f1a4990beb6812f0e839d777cfbc6b95997d8031c4ad85e879 1859 100644' \
    'control/v1/evidence-integrity-policy.json 8e630c4aaee1cf1d97b3c04e96da6bb8408a0a46a2ce42bca2583767ee42f604 914 100644' \
    'control/v1/evidence-integrity.jq 3b57277a3eab151da66801254af65196fb6a71800486fe781232135169f68619 11254 100644' \
    'control/v1/kill-switch-decision.json c6328eb730b9c73c30469b90874c7811adc7b27a512f905f4a8dcdcd356b69cd 1604 100644' \
    'control/v1/kill-switch-policy.json b46eebfeb9de37eb0ebdb8fb297e0e200b537d0ca08dcf28eab7f91ef603e799 503 100644' \
    'control/v1/kill-switch.jq 59378b0049c511160427a113559089a81c17d5501662bf3ac02650bdfaf58817 13863 100644' \
    'control/v1/policy-set.jq 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 2560 100644' \
    'control/v1/risk-gates-decision.json 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 1563 100644' \
    'control/v1/risk-gates-policy.json 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e 1844 100644' \
    'control/v1/risk-gates.jq d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff 13732 100644' \
    'control/v1/sandbox-bound-decision.json c8685bc8d15bb2375ab2263b0add5c151aa7c763fa3197bbacf886606f87df47 1492 100644' \
    'control/v1/sandbox-bound-policy.json ad1eab67be239e0f06f049bca91d51c475b3abb5917952a85c2a67f0450fbc6f 1875 100644' \
    'control/v1/sandbox-bound.jq 66a90e8847d70d297f6ea73dfc7879ffe44f7cb173a119c091c93a48f5f4b5cc 16172 100644' \
    'control/v1/sandbox-decision.json c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd 1459 100644' \
    'control/v1/sandbox-policy.json 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e 1829 100644' \
    'control/v1/sandbox.jq 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 14949 100644' \
    'control/v1/validate.sh cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a 3189 100755' \
    'core/v2/generation-registry.json 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 614 100644' \
    "core/v2/generations/${record_generation}/contracts.jq 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a 2632 100644" \
    "core/v2/generations/${record_generation}/core-ingress.sh dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 56400 100644" \
    "core/v2/generations/${record_generation}/modules/profile_graph.jq c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207 13338 100644" \
    "core/v2/generations/${record_generation}/modules/result_facts.jq 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281 6035 100644" \
    "core/v2/generations/${record_generation}/modules/result_truth.jq ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46 15385 100644" \
    "core/v2/generations/${record_generation}/modules/schema.jq 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade 16121 100644" \
    "core/v2/generations/${record_generation}/modules/stage_request.jq 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e 15123 100644" \
    'enforcement/v1/accepted-identities.json c75dcd8d9268cb42677f5aa526fd374c3e45f2ba0fe678f47562ae49ad6851a0 174 100644' \
    'enforcement/v1/check-sandbox-receipt.sh 7db3412a4e740f79bde6af24891837fd5daa27d0811ff970b2f58534fcd59b97 10816 100755' \
    'enforcement/v1/sandbox-receipt.jq 43ab3a97b90444be17958112b7ff63966d1052981313c81bcb463618adae8619 30838 100644' \
    'evals/v1/replay-malicious.py 695c73dcf739e2a63c3758ea0b4d683546fd19a0f646e8a39b03661226b469a7 36612 100644' \
    'maintenance/v1/bands.jq 594994c057a1130da6727f5f825d2fed3ff01de4a9fafe3a722d9e964f05c8e4 10714 100644' \
    'maintenance/v1/incident-to-eval.jq 2229722267c3e9544d9cf53bd37d6d798f27adebad4a7439294989d0194ad92a 7237 100644' \
    'maintenance/v1/incident-to-eval.sh e000f961d7851c48b650ca36ed0c60fd2bc97ffc32442214b3f8937efc97f967 7449 100755' \
    'preparation/v1/prepare-candidate.py a860891bb3c20f757e2d15934e0ea6577cb3181b19e935a4c781e4f410f9fde5 138141 100644' \
    'sandbox/v1/build-guest.py 9aceb3492800d14d1842132c96ff6c5bf8b1ca83ad37477f9210908a78b08074 11671 100755' \
    'sandbox/v1/coverage-source.py 16b3204ce6a06a31199e585b71a41fc9949c307acd1a2782df5965d00fa8ed25 43901 100644' \
    'sandbox/v1/guest/common.c 731db0f01a72c0e319a36ee668cff16d30e298b4a8a75b2a1a0317c8b738f732 44272 100644' \
    'sandbox/v1/guest/common.h ef192e3fd3f5ae99f8e49b4bfbe58e6b0df6316d77c1690231b4138f4504cdd1 11926 100644' \
    'sandbox/v1/guest/init.c f2de00c7af19291d31160c5d22427c6e5b90f2c5e9702736fa82e6d13533acd3 5039 100644' \
    'sandbox/v1/guest/observation-values.c c93bf7ebc56b4c3ebb309f5314efed32f34799e8018a55b4163cdcabc08e6110 55289 100644' \
    'sandbox/v1/guest/observation-values.h 8253a4e121c374792f86f2cbbdc8e65a39abbb10be2055f8db81b9966779ad96 8028 100644' \
    'sandbox/v1/guest/probe.c ab17cae1f35aa09889c63bcf3758f63c15bdb84bd6be895b685a4317c3199d71 255622 100644' \
    'sandbox/v1/guest/supervisor.c 905b2d57ba21c4a9b5622158135c547578bc7571d8b5ef43d5598e37a6688437 103685 100644' \
    'sandbox/v1/host-supervisor.py 64639f621192705eb8e4e3a39ea17993d4b65563c4c5712991c954f0242f9afe 225420 100755' \
    'sandbox/v1/runtime-vfkit.py 50a400dd73e8fa8d46cf93e5f8824ac80d5921cc1bf69d522bf11d4330050a14 6764 100755' \
    'scope/v1/evaluate-scope.sh fe6048b5eada5d86531e085acd0a9f46b73028d348349ab932e8c59f4e2ed66a 25253 100755' \
    'scope/v1/generate-gate-evidence.py 087fd3d31ef3096a216ce11ea7a5da2dbf9c0eb7b0cb46ac9d495fdff53e39c4 36067 100755' \
    'scope/v1/read-shadow-evidence.py 52b40828a99c5a009a89500701142898970f35b9a8361a9be711a25191df9e94 92980 100644' \
    'scope/v1/scope-gates.jq 302e882b4b351186987e8b5f3e13d1725d0e2e9f7a996a4033ea893bd0a87487 57306 100644' \
    'scope/v1/scope-policy.json 5c6db4debedfcd7117735bd1d4bf907293f73972ec8909c4eab9f25cf6417fe5 1181 100644' \
    'scope/v1/validate-scope.sh 99c0abae1bdcc3809dfac535a8b24137842abaec2418b90566b6ac8ff213b406 3194 100755' \
    'scope/v1/workflow-scope.jq 2d1df5f99b7019c4c41aece4f9fb89b00785ca47f9f8a713b2f43b212481366a 9728 100644' \
    'scripts/core-contract.sh b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 9176 100755' \
    'shadow/v1/_cancel_release.c 00ef369edbed569d50471b97f64aef57591b7afb8d9f25c286bffa5725faf015 55056 100644' \
    'shadow/v1/_consumer.py e874ca59a7dfd9da3383186f73151c05e14e09db0591503fde6ae8a8d536f946 231005 100644' \
    'shadow/v1/build-cancel-release.sh be1ad0afd99f72ea73fe52cca63c03381793710c587a82b57b9a38ed87c896d4 6169 100755' \
    'shadow/v1/enforced-reproduction.py 6d3de5e81f99e6d1c793e750f03ba4d93f4ee075d1c93d15ac781989e905134d 119034 100755' \
    'shadow/v1/incident-record.jq 9ea6e1ec6556f54887ea6937533157856271aab68c74bda6d18dae1354d2687c 3695 100644' \
    'shadow/v1/qualified-identity.jq 33267bca348ad2b4923a5858b4788a6ca6adf1a1e9f471ee4450d7fe06387071 5343 100644' \
    'shadow/v1/shadow-environments.json 655771163e18384904eeaf2b7f22e3999957a037dce845b7fa6fdff2196ac4c7 1471 100644' \
    'shadow/v1/validate-incident.sh c9f907bfd73307c977c4191d65f6783a3bf969c3bb0be988f14aa9cb66ebe262 4870 100755' \
    'shadow/v1/write-materialization-input.jq 467a8f2901f053ff059302974ad80c5aaf1c805c6302e2333e1af0524fb3c510 4907 100644' \
    'shadow/v1/write-shadow.py 6b5c38b34ce29be0f4e8241358406b99acb21c11920e5cd43fabaddb7a0bc5be 66057 100755' \
    'telemetry/v1/trace-ledger.jq 5436deb48eca6d988a24bbce07855628edd3bc60386d9993a1169d6d373a4212 5849 100644' \
    'telemetry/v1/validate-trace-ledger.sh fc4b7cdd36b5d48675ed1d851c7b2d4fe59d0c431a31f3c361d6196f8900e208 8095 100755' \
    'verifiers/file-digest/v1/verifier.c fcf244b70dc6bcbfd1e6983e6c23d5f38a60654aa074adb472b0e749184dcfeb 28827 100644'
}

shadow_source_work_records=()
snapshot_shadow_sources() {
  local rows status=0 last
  rows=$(shadow_source_rows) || return 1
  shadow_source_work=$(/usr/bin/python3 -I -S -B - "$repo" "$runtime" "$rows" <<'PY_SHADOW_SOURCE'
import ctypes
import errno
import hashlib
import json
import os
import re
import signal
import stat
import sys

source_root, target_root, table = sys.argv[1:]
work = {"rows": [], "read_bytes": 0, "write_bytes": 0, "sha_bytes": 0,
        "equality_bytes": 0, "copy_bytes": 0, "physical_bytes": 0,
        "logical_bytes": 0, "logical_occurrences": 0, "reused_files": 0,
        "created_files": 0, "prior_physical_bytes": 0, "close_calls": 0, "observation_bytes": 0,
        "table_bytes": len(table.encode()), "snapshots": [], "snapshot_metadata_bytes": 0,
        "failures": [], "data_and_close_complete": False}
owned, directories, sources, targets = [], {}, {}, {}
library = None

def cancelled(error):
    return isinstance(error, KeyboardInterrupt) or getattr(error, "_D_source_cancel", False)

def first_error(first, later):
    return later if first is None or cancelled(later) and not cancelled(first) else first

def require(value):
    if not value:
        raise ValueError("D_SOURCE")

def note(site, *values):
    row = [site, *values]
    cost = len(json.dumps(row, separators=(",", ":")).encode()) + 1
    require(work["observation_bytes"] + cost <= 1048576 - 65536)
    work["rows"].append(row)
    work["observation_bytes"] += cost

def remember(site, error):
    try:
        work["failures"].append([site, type(error).__name__, getattr(error, "errno", None)])
    except BaseException:
        work["accounting_incomplete"] = True

def identity(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode), value.st_uid,
            value.st_gid, stat.S_IMODE(value.st_mode), value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)

def measured(fd):
    value = os.fstat(fd)
    note("fstat", fd, identity(value))
    return value

def absence(fd):
    global library
    before = identity(measured(fd))
    pointer, failure = None, None
    try:
        if sys.platform == "linux":
            empty = {getattr(errno, key) for key in ("ENODATA", "ENOATTR") if hasattr(errno, key)}
            for key in ("system.posix_acl_access", "system.posix_acl_default"):
                try:
                    value = os.getxattr(fd, key)
                except OSError as error:
                    note("getxattr", fd, key, None, error.errno)
                    if error.errno not in empty:
                        raise
                else:
                    work["read_bytes"] += len(value)
                    note("getxattr", fd, key, len(value), None)
                    raise ValueError("D_ACL_PRESENT")
        elif sys.platform == "darwin":
            if library is None:
                candidate = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
                candidate.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
                candidate.acl_get_fd_np.restype = ctypes.c_void_p
                candidate.acl_free.argtypes = [ctypes.c_void_p]
                candidate.acl_free.restype = ctypes.c_int
                library = candidate
            ctypes.set_errno(0)
            pointer = library.acl_get_fd_np(fd, 0x100)
            saved = ctypes.get_errno()
            note("acl_get_fd_np", fd, pointer, saved)
            require(not pointer and saved == errno.ENOENT)
        else:
            raise ValueError("D_PLATFORM")
        require(identity(measured(fd)) == before)
    except BaseException as error:
        failure = error
        raise
    finally:
        if pointer:
            freeing = None
            try:
                ctypes.set_errno(0)
                result = library.acl_free(pointer)
                saved = ctypes.get_errno()
                note("acl_free", fd, result, saved)
                if result != 0:
                    raise OSError(saved, "D ACL release")
            except BaseException as error:
                freeing = error
                remember("acl-free", error)
            if freeing is not None and first_error(failure, freeing) is freeing:
                raise freeing

def close_fd(fd, primary=None):
    failure = None
    try:
        os.close(fd)
    except BaseException as error:
        failure = error
        remember("close", error)
    try:
        work["close_calls"] += 1
        note("close", fd, 0 if failure is None else -1,
             getattr(failure, "errno", None))
    except BaseException as error:
        work["accounting_incomplete"] = True
        failure = first_error(failure, error)
    if failure is not None and first_error(primary, failure) is failure:
        raise failure

def close_one(row, primary=None):
    if not row["closed"]:
        row["closed"] = True
        close_fd(row["fd"], primary)

def acquire(path, parent, name, flags, mode=0o400):
    if not flags & os.O_DIRECTORY:
        require(hasattr(os, "O_NONBLOCK"))
        flags |= os.O_NONBLOCK
    fd = os.open(name if parent else path, flags, mode,
                 dir_fd=parent["fd"] if parent else None)
    try:
        row = {"fd": fd, "parent": parent, "name": name, "path": path, "closed": False}
        owned.append(row)
    except BaseException as error:
        close_fd(fd, error)
        raise
    note("open", parent["fd"] if parent else None, name, flags, fd)
    row["before"] = measured(fd)
    return row

def check(row):
    require(not row["closed"])
    before = identity(row["before"])
    require(identity(measured(row["fd"])) == before)
    if row["parent"]:
        current = os.stat(row["name"], dir_fd=row["parent"]["fd"], follow_symlinks=False)
        note("named-stat", row["parent"]["fd"], row["name"], identity(current))
        require(identity(current) == before)
    absence(row["fd"])

def trusted_directory(row, private=False):
    value = row["before"]
    require(stat.S_ISDIR(value.st_mode) and value.st_uid in {0, os.geteuid()})
    require(not value.st_mode & 0o022 or value.st_uid == 0 and value.st_mode & stat.S_ISVTX)
    if private:
        require(value.st_uid == os.geteuid() and value.st_gid == os.getegid()
                and stat.S_IMODE(value.st_mode) == 0o700)
    check(row)

def directory(path, create=False):
    if path in directories:
        check(directories[path])
        return directories[path]
    require(path.startswith("/") and os.path.normpath(path) == path)
    if path == "/":
        row = acquire(path, None, None, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    else:
        parent = directory(os.path.dirname(path), create)
        name = os.path.basename(path)
        check(parent)
        if create:
            try:
                os.mkdir(name, 0o700, dir_fd=parent["fd"])
            except FileExistsError:
                pass
            else:
                note("mkdir", parent["fd"], name, 0)
                refresh(parent)
        row = acquire(path, parent, name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    directories[path] = row
    trusted_directory(row, path == target_root or path.startswith(target_root + "/"))
    return row

def refresh(row):
    before, current = identity(row["before"]), measured(row["fd"])
    require(before[:6] == identity(current)[:6])
    row["before"] = current
    check(row)

def read_chunk(row, count):
    value = os.read(row["fd"], count)
    work["read_bytes"] += len(value)
    note("read", row["fd"], count, len(value))
    return value

def scan(rows):
    for folder in ("control/v1", "scope/v1"):
        parent = directory(source_root + "/" + folder)
        names = os.listdir(parent["fd"])
        note("listdir", parent["fd"], names)
        actual = set()
        for name in names:
            if name.endswith((".sh", ".jq", ".json", ".py")):
                value = os.stat(name, dir_fd=parent["fd"], follow_symlinks=False)
                note("scan-stat", parent["fd"], name, identity(value))
                require(stat.S_ISREG(value.st_mode))
                actual.add(folder + "/" + name)
        require(actual == {name for name in rows if name.startswith(folder + "/")})
        check(parent)

def parse_table():
    require(len(table.encode()) <= 1048576)
    entries = table.splitlines()
    require(len(entries) == 84)
    rows = {}
    for entry in entries:
        fields = entry.split(" ")
        require(len(fields) == 4)
        name, digest, size, mode = fields
        require(re.fullmatch(r"[A-Za-z0-9_./-]+", name) and not name.startswith("/")
                and all(part not in {"", ".", ".."} for part in name.split("/"))
                and re.fullmatch(r"[0-9a-f]{64}", digest)
                and re.fullmatch(r"0|[1-9][0-9]*", size)
                and mode in {"100644", "100755"} and name not in rows)
        size = int(size)
        require(size <= 16 * 1024 * 1024)
        rows[name] = (digest, size, int(mode, 8) & 0o777)
    require(sum(row[1] for row in rows.values()) <= 32 * 1024 * 1024)
    return rows

def source_inputs(rows):
    for name, (_digest, size, mode) in rows.items():
        parent = directory(os.path.dirname(source_root + "/" + name))
        item = acquire(source_root + "/" + name, parent, os.path.basename(name), os.O_RDONLY | os.O_NOFOLLOW)
        value = item["before"]
        require(stat.S_ISREG(value.st_mode) and value.st_uid in {0, os.geteuid()}
                and stat.S_IMODE(value.st_mode) == mode and value.st_size == size
                and value.st_nlink == 1)
        check(item)
        sources[name] = item
    scan(rows)
    registry = sources["core/v2/generation-registry.json"]
    registry_size = registry["before"].st_size
    require(registry_size <= 1048576)
    chunks, remaining = [], registry_size
    while remaining:
        chunk = read_chunk(registry, min(65536, remaining))
        require(bool(chunk))
        chunks.append(chunk)
        remaining -= len(chunk)
    raw = b"".join(chunks)
    work["registry_buffer_processing"] = "UNKNOWN: join/JSON processing is not in data-stream counters"
    measured_hash = hashlib.sha256(raw).hexdigest()
    work["sha_bytes"] += len(raw)
    require(measured_hash == rows["core/v2/generation-registry.json"][0])
    value = json.loads(raw)
    work["registry_parse_bytes"] = len(raw)
    require(type(value) is list and len(value) == 2 and value[1] == value[-1])
    keys = {"authorization_comment_id", "concern", "generation_id", "parent_generation_id", "semantic_identity"}
    for row in value:
        require(type(row) is dict and set(row) == keys and row["semantic_identity"] == "core.contracts.v2"
                and type(row["authorization_comment_id"]) is int and row["authorization_comment_id"] > 0
                and type(row["concern"]) is str and bool(row["concern"])
                and re.fullmatch(r"g-[0-9a-f]{64}", row["generation_id"])
                and re.fullmatch(r"g-[0-9a-f]{64}", row["parent_generation_id"]))
    require(value[1]["parent_generation_id"] == value[0]["generation_id"])
    prefix = "core/v2/generations/" + value[1]["generation_id"] + "/"
    require({name for name in rows if name.startswith("core/v2/generations/")} == {
        prefix + suffix for suffix in ("contracts.jq", "core-ingress.sh", "modules/profile_graph.jq",
            "modules/result_facts.jq", "modules/result_truth.jq", "modules/schema.jq", "modules/stage_request.jq")})

def copy_inputs(rows):
    for name, (expected, size, _mode) in rows.items():
        original = sources[name]
        parent = directory(os.path.dirname(target_root + "/" + name), True)
        check(parent)
        try:
            target = acquire(target_root + "/" + name, parent, os.path.basename(name),
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            target = acquire(target_root + "/" + name, parent, os.path.basename(name), os.O_RDONLY | os.O_NOFOLLOW)
            created = False
            work["reused_files"] += 1
            work["prior_physical_bytes"] += target["before"].st_size
            require(target["before"].st_size == size)
        else:
            created = True
            work["created_files"] += 1
            refresh(parent)
        work["logical_bytes"] += size
        work["logical_occurrences"] += 1
        os.lseek(original["fd"], 0, os.SEEK_SET)
        digest, consumed = hashlib.sha256(), 0
        while consumed < size:
            chunk = read_chunk(original, min(65536, size - consumed))
            require(bool(chunk))
            consumed += len(chunk)
            digest.update(chunk)
            work["sha_bytes"] += len(chunk)
            if created:
                view = memoryview(chunk)
                while view:
                    sent = os.write(target["fd"], view)
                    require(sent > 0)
                    work["write_bytes"] += sent
                    work["copy_bytes"] += sent
                    work["physical_bytes"] += sent
                    note("write", target["fd"], len(view), sent)
                    view = view[sent:]
        require(digest.hexdigest() == expected)
        check(original)
        if created:
            os.fchmod(target["fd"], 0o400)
            note("fchmod", target["fd"], 0o400)
            os.fsync(target["fd"])
            note("fsync", target["fd"], 0)
            target["before"] = measured(target["fd"])
            reader = acquire(target["path"], parent, target["name"], os.O_RDONLY | os.O_NOFOLLOW)
            require(identity(reader["before"]) == identity(target["before"]))
            close_one(target)
            target = reader
        state = target["before"]
        require(stat.S_ISREG(state.st_mode) and state.st_uid == os.geteuid()
                and state.st_gid == os.getegid() and state.st_nlink == 1
                and stat.S_IMODE(state.st_mode) == 0o400 and state.st_size == size)
        check(target)
        record = {"path": name, "size_bytes": size, "source_sha256": digest.hexdigest(),
                  "source_identity": identity(original["before"]),
                  "snapshot_identity": identity(target["before"]), "reused": not created}
        work["snapshot_metadata_bytes"] += len(json.dumps(record, separators=(",", ":")).encode())
        work["snapshots"].append(record)
        target["record"] = record
        targets[name] = target

def final_checks(rows):
    scan(rows)
    for row in directories.values():
        check(row)
        if row["path"] == target_root or row["path"].startswith(target_root + "/"):
            os.fsync(row["fd"])
            note("fsync-directory", row["fd"], 0)
    for name, (expected, size, _mode) in rows.items():
        left, right = sources[name], targets[name]
        check(left);check(right)
        os.lseek(left["fd"], 0, os.SEEK_SET);os.lseek(right["fd"], 0, os.SEEK_SET)
        left_hash, right_hash, count = hashlib.sha256(), hashlib.sha256(), 0
        while count < size:
            amount = min(65536, size - count)
            a, b = read_chunk(left, amount), read_chunk(right, amount)
            work["equality_bytes"] += len(a) + len(b)
            left_hash.update(a);right_hash.update(b)
            work["sha_bytes"] += len(a) + len(b)
            require(len(a) == len(b) == amount and a == b)
            count += amount
        require(left_hash.hexdigest() == right_hash.hexdigest() == expected)
        previous_record_size = len(json.dumps(right["record"], separators=(",", ":")).encode())
        right["record"]["final_source_sha256"] = left_hash.hexdigest()
        right["record"]["snapshot_sha256"] = right_hash.hexdigest()
        work["snapshot_metadata_bytes"] += (len(json.dumps(right["record"], separators=(",", ":")).encode())
                                            - previous_record_size)
        check(left);check(right)
    for row in owned:
        if not row["closed"]:
            check(row)

def interrupt(_number, _frame):
    error = InterruptedError("D source acquisition cancelled")
    error._D_source_cancel = True
    raise error

for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, interrupt)

failure = None
try:
    require(os.path.isabs(source_root) and os.path.isabs(target_root)
            and os.path.normpath(source_root) == source_root and os.path.normpath(target_root) == target_root
            and source_root != target_root and not source_root.startswith(target_root + "/")
            and not target_root.startswith(source_root + "/"))
    rows = parse_table()
    source_inputs(rows)
    directory(target_root)
    copy_inputs(rows)
    final_checks(rows)
except BaseException as error:
    failure = error
    work["unobserved_call_results"] = "UNKNOWN; failed-operation counters are observed lower bounds"
    if isinstance(error, MemoryError):
        work["accounting_incomplete"] = True
    remember("acquisition", error)
finally:
    for row in reversed(owned):
        try:close_one(row, failure)
        except BaseException as error:
            failure = first_error(failure, error)
    if failure is not None:
        work.setdefault("unobserved_call_results", "UNKNOWN; failed-operation counters are observed lower bounds")
    work["data_and_close_complete"] = failure is None and not work.get("accounting_incomplete", False)

print(json.dumps(work, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if work["data_and_close_complete"] else 1)
PY_SHADOW_SOURCE
  ) || status=$?
  shadow_source_receipt_bytes=${#shadow_source_work}
  shadow_source_work_records+=("$shadow_source_work")
  last=$(( ${#shadow_source_work_records[@]} - 1 ))
  shadow_source_receipt_total_bytes=$(( ${shadow_source_receipt_total_bytes:-0} + ${#shadow_source_work_records[$last]} ))
  [ "$shadow_source_receipt_bytes" -le 1048576 ] || return 1
  [ "$status" -eq 0 ]
}

# run SEED-SET.json OBSERVED_AT
# dashboard OBSERVED_AT SEED-SET.json RUN-RESULT.json [SEED-SET.json RUN-RESULT.json]...
mode=${1:-}
case "$mode" in
  run)
    [ "$#" -eq 3 ] || emit_error E_USAGE
    input=$2
    observed_at=$3
    pair_files=()
    ;;
  dashboard)
    [ "$#" -ge 4 ] && [ "$#" -le 34 ] && [ $(( ($# - 2) % 2 )) -eq 0 ] || emit_error E_USAGE
    observed_at=$2
    input=''
    shift 2
    pair_files=("$@")
    ;;
  *) emit_error E_USAGE ;;
esac
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$source_dir/${self##*/}"
[ "$self" = "$source_dir/evals-launcher.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/evals/v1" ] || emit_error E_RUNTIME
if [ "$mode" = run ]; then
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
else
  for pair_file in "${pair_files[@]}"; do
    [ -f "$pair_file" ] && [ ! -L "$pair_file" ] || emit_error E_RUNTIME
  done
fi

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64)
    host_os=linux; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  Darwin:x86_64)
    host_os=darwin; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Darwin:arm64)
    host_os=darwin; host_arch=arm64; jq_arch=x86_64; execution_mode=rosetta
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  *) emit_error E_RUNTIME ;;
esac

jq_source=''
for candidate in "${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset" "/usr/bin/jq"; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
     [ "$(sha256_path "$candidate")" = "$jq_sha" ]; then
    jq_source=$candidate
    break
  fi
done
[ -n "$jq_source" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
runtime="$scratch/runtime"
/bin/mkdir -m 0700 "$runtime" "$runtime/bin" "$runtime/core" "$runtime/core/v2" \
  "$runtime/core/v2/generations" "$runtime/scripts" "$runtime/orchestrator" \
  "$runtime/orchestrator/v1" "$runtime/control" "$runtime/control/v1" "$runtime/adapters" \
  "$runtime/adapters/codex-native-reviewer" "$runtime/adapters/codex-native-reviewer/v1" \
  "$runtime/adapters/github-actions-ci" "$runtime/adapters/github-actions-ci/v1" \
  "$runtime/adapters/github-forge" "$runtime/adapters/github-forge/v1" \
  "$runtime/adapters/gitlab-forge" "$runtime/adapters/gitlab-forge/v1" \
  "$runtime/adapters/codex-cli-producer" "$runtime/adapters/codex-cli-producer/v1" "$scratch/work" ||
  emit_error E_RUNTIME
generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
generation_runtime="$runtime/core/v2/generations/$generation"
/bin/mkdir -m 0700 "$generation_runtime" "$generation_runtime/modules" ||
  emit_error E_RUNTIME

program_sha=18bfacfaabbb87fc6bb3e4be8d182cc81a9d526caa4db8e17c51d583b52e1009
review_approval_sha=none
catalog_sha=0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac
driver_sha=c5fe4b2c71189a6079b7f76a19f998f7e96659cdf9f3152e8e35e0b049c00a4d
snapshot_file "$source_dir/run-evals.sh" "$runtime/bootstrap.sh" 1048576 0400 ||
  emit_error E_RUNTIME
bootstrap_sha=$(sha256_path "$runtime/bootstrap.sh") || emit_error E_RUNTIME
snapshot_file "$self" "$runtime/launcher.sh" 1048576 0400 || emit_error E_RUNTIME
launcher_sha=$(sha256_path "$runtime/launcher.sh") || emit_error E_RUNTIME
snapshot_expected "$driver_sha" "$source_dir/evals-driver.sh" "$runtime/driver.sh" 0400 ||
  emit_error E_STALE
snapshot_expected "$program_sha" "$source_dir/evals.jq" "$runtime/program.jq" 0400 ||
  emit_error E_STALE
snapshot_expected "$catalog_sha" "$source_dir/eval-catalog.json" "$runtime/catalog.json" 0400 ||
  emit_error E_STALE
snapshot_expected 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
  "$repo/core/v2/generation-registry.json" \
  "$runtime/core/v2/generation-registry.json" 0400 || emit_error E_STALE
snapshot_expected 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
  "$repo/core/v2/generations/$generation/contracts.jq" \
  "$generation_runtime/contracts.jq" 0400 || emit_error E_STALE
snapshot_expected dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
  "$repo/core/v2/generations/$generation/core-ingress.sh" \
  "$generation_runtime/core-ingress.sh" 0400 || emit_error E_STALE
for member in \
  'profile_graph.jq c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207' \
  'result_facts.jq 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281' \
  'result_truth.jq ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46' \
  'schema.jq 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade' \
  'stage_request.jq 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" \
    "$repo/core/v2/generations/$generation/modules/$name" \
    "$generation_runtime/modules/$name" 0400 || emit_error E_STALE
done
snapshot_expected b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
  "$repo/scripts/core-contract.sh" "$runtime/scripts/core-contract.sh" 0400 ||
  emit_error E_STALE
# The inactive state scanner, replayed for the events family from inside the
# private runtime. It reads its core from this runtime's mirror, never the repo.
for member in \
  'reconciliation-plan.jq 03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4' \
  'scan-state.sh 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5' \
  'state-scanner-driver.sh 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b' \
  'state-scanner-launcher.sh 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb' \
  'state-scanner.jq 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/orchestrator/v1/$name" \
    "$runtime/orchestrator/v1/$name" 0400 || emit_error E_STALE
done
# The inactive control evaluators replayed here: sandbox policy for the boundaries
# family; risk gates (with the duty-separation evaluator it regenerates) for the
# approval family; that same duty-separation evaluator on its own for the actor
# and re-run identity family. They read only this runtime.
for member in \
  'duty-separation-decision.json 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99' \
  'duty-separation-policy.json b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9' \
  'duty-separation.jq b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c' \
  'evaluate-duty.sh 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa' \
  'evaluate-risk-gates.sh 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8' \
  'evaluate-sandbox.sh 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb' \
  'policy-set.jq 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58' \
  'risk-gates-decision.json 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5' \
  'risk-gates-policy.json 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e' \
  'risk-gates.jq d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff' \
  'sandbox-decision.json c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd' \
  'sandbox-policy.json 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e' \
  'sandbox.jq 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3' \
  'validate.sh cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/control/v1/$name" \
    "$runtime/control/v1/$name" 0400 || emit_error E_STALE
done
# The inactive provider-snapshot normalizers, replayed for the adapter family.
for member in \
  'codex-cli-producer dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25' \
  'gitlab-forge ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a' \
  'codex-native-reviewer 7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603' \
  'github-actions-ci 690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7' \
  'github-forge b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/adapters/$name/v1/normalize.jq" \
    "$runtime/adapters/$name/v1/normalize.jq" 0400 || emit_error E_STALE
done
snapshot_expected "$jq_sha" "$jq_source" "$runtime/bin/jq" 0500 || emit_error E_RUNTIME
bash_sha=$(sha256_path /bin/bash) || emit_error E_RUNTIME
record_generation=$("$runtime/bin/jq" -er '
  if type == "array" and length == 2 and .[1] == .[-1] and all(.[];
    type == "object" and keys == ["authorization_comment_id","concern","generation_id",
      "parent_generation_id","semantic_identity"] and
    (.authorization_comment_id | type == "number" and . == floor and . > 0) and
    (.concern | type == "string" and length > 0) and
    .semantic_identity == "core.contracts.v2" and
    (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")) and
    (.parent_generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z"))) and
    .[1].parent_generation_id == .[0].generation_id
  then .[1].generation_id else error("E_STALE") end
' "$runtime/core/v2/generation-registry.json" 2>/dev/null) || emit_error E_STALE
record_schema="core/v2/generations/$record_generation/modules/schema.jq"
record_files="$record_schema 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade
evals/v1/framework.jq d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4
evals/v1/run.sh 51770c5597d55bf05020502796810637bfbe697038a541ea6124530c0fffe55c"
while read -r path digest; do
  stage_expected "$digest" "$repo/$path" "$runtime/$path" 0400 E_STALE
done <<< "$record_files"
if [ "$review_approval_sha" != none ]; then
  [[ "$review_approval_sha" =~ ^[0-9a-f]{64}$ ]] || emit_error E_STALE
  stage_expected "$review_approval_sha" "$repo/evals/v1/seeds/reviewer-severity/approval.json" \
    "$runtime/evals/v1/seeds/reviewer-severity/approval.json" 0400 E_STALE
fi
: >"$runtime/review-files.tsv" || emit_error E_RUNTIME
snapshot_input() {
  local status=0
  snapshot_file "$1" "$2" 1048576 0400 || status=$?
  [ "$status" -eq 42 ] && emit_error E_LIMIT
  [ "$status" -eq 0 ] || emit_error E_RUNTIME
}
if [ "$mode" = run ]; then
  snapshot_input "$input" "$scratch/input.json"
  driver_input="$scratch/input.json"
  input_document="$scratch/input.json"
else
  # Each (seed set, run result) pair is snapshotted once; a manifest of their
  # digests is the single input document the driver binds to.
  /bin/mkdir -m 0700 "$scratch/inputs" || emit_error E_RUNTIME
  pair_count=$(( ${#pair_files[@]} / 2 ))
  manifest_entries=''
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    snapshot_input "${pair_files[$((j * 2))]}" "$scratch/inputs/seed-$j.json"
    snapshot_input "${pair_files[$((j * 2 + 1))]}" "$scratch/inputs/result-$j.json"
    manifest_entries="$manifest_entries$(/usr/bin/printf '{"result_sha256":"%s","seed_sha256":"%s"}' \
      "$(sha256_path "$scratch/inputs/result-$j.json")" \
      "$(sha256_path "$scratch/inputs/seed-$j.json")")"
    j=$((j + 1))
    [ "$j" -eq "$pair_count" ] || manifest_entries="$manifest_entries,"
  done
  /usr/bin/printf '[%s]' "$manifest_entries" | "$runtime/bin/jq" -S -c . \
    > "$scratch/inputs/manifest.json" 2>/dev/null || emit_error E_RUNTIME
  /bin/chmod 0400 "$scratch/inputs/manifest.json" || emit_error E_RUNTIME
  driver_input="$scratch/inputs"
  input_document="$scratch/inputs/manifest.json"
fi
seed_sha=$(sha256_path "$input_document") || emit_error E_RUNTIME
review_seed_inputs=("$scratch/input.json")
if [ "$mode" = dashboard ]; then
  review_seed_inputs=()
  for ((j=0; j<pair_count; j++)); do review_seed_inputs+=("$scratch/inputs/seed-$j.json"); done
fi
for review_seed in "${review_seed_inputs[@]}"; do
  review_source=$("$runtime/bin/jq" -r '.body.seed_source // empty' "$review_seed" 2>/dev/null) || continue
  if [ "$review_source" = shadow.malicious-instructions.v1 ]; then
    snapshot_shadow_sources || emit_error E_STALE
  fi
  [ "$review_source" = reviews.independent-verdicts.v1 ] || continue
  "$runtime/bin/jq" -e '
    any(.body.families[]; .family_id == "reviewer-severity-false-positive-negative" and
      .seed_status == "seeded" and (.seed_sources | index("reviews.independent-verdicts.v1") != null))
  ' "$runtime/catalog.json" >/dev/null 2>&1 || emit_error E_SHAPE
  "$runtime/bin/jq" -e '
    .body.shared.files | type == "array" and length >= 1 and length <= 16 and
    all(.[]; type == "object" and (keys == ["path","sha256"]) and
      (.path | type == "string" and
       test("\\Aevals/v1/seeds/reviewer-severity/verdicts/[1-9][0-9]*[.]md\\z") and length <= 255) and
      (.sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z")))
  ' "$review_seed" >/dev/null 2>&1 || emit_error E_SHAPE
  "$runtime/bin/jq" -r '.body.shared.files[] | [.sha256,.path] | @tsv' "$review_seed" \
    >"$scratch/review-files.current" || emit_error E_RUNTIME
  while IFS=$'\t' read -r digest path; do
    stage_expected "$digest" "$repo/$path" "$runtime/$path" 0400 E_RELATION
    /usr/bin/printf '%s\t%s\n' "$digest" "$path" >>"$runtime/review-files.tsv" || emit_error E_RUNTIME
  done <"$scratch/review-files.current"
done
record_closure=$("$runtime/bin/jq" -R -s -c '
  split("\n") | map(select(length > 0) | split(" ") | {path:.[0],sha256:.[1]})
' <<< "$record_files") || emit_error E_RUNTIME

"$runtime/bin/jq" -S -c -n \
  --arg bootstrap_sha "$bootstrap_sha" --arg launcher_sha "$launcher_sha" \
  --arg driver_sha "$driver_sha" --arg program_sha "$program_sha" \
  --arg catalog_sha "$catalog_sha" --argjson record_closure "$record_closure" \
  --arg jq_sha "$jq_sha" --arg bash_sha "$bash_sha" \
  --arg host_os "$host_os" --arg host_arch "$host_arch" \
  --arg jq_arch "$jq_arch" --arg execution_mode "$execution_mode" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  {
    schema_version:1,kind:"eval_framework_evaluator",id:"evals.framework.v1",
    body:{
      core_contract:{
        generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
        package_ref:ref("core-contract-package.v2";
          "application/vnd.ystack.core-contract+json";
          "eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"),
        semantic_identity:"core.contracts.v2"
      },
      core_closure:[
        {path:"core/v2/generation-registry.json",sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
        {path:"scripts/core-contract.sh",sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
      ],
      orchestrator_closure:[
        {path:"orchestrator/v1/reconciliation-plan.jq",sha256:"03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4"},
        {path:"orchestrator/v1/scan-state.sh",sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
        {path:"orchestrator/v1/state-scanner-driver.sh",sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
        {path:"orchestrator/v1/state-scanner-launcher.sh",sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
        {path:"orchestrator/v1/state-scanner.jq",sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
      ],
      adapter_closure:[
        {path:"adapters/codex-cli-producer/v1/normalize.jq",sha256:"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25"},
        {path:"adapters/codex-native-reviewer/v1/normalize.jq",sha256:"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603"},
        {path:"adapters/github-actions-ci/v1/normalize.jq",sha256:"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7"},
        {path:"adapters/github-forge/v1/normalize.jq",sha256:"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be"},
        {path:"adapters/gitlab-forge/v1/normalize.jq",sha256:"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}
      ],
      control_closure:[
        {path:"control/v1/duty-separation-decision.json",sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
        {path:"control/v1/duty-separation-policy.json",sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
        {path:"control/v1/duty-separation.jq",sha256:"b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c"},
        {path:"control/v1/evaluate-duty.sh",sha256:"146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa"},
        {path:"control/v1/evaluate-risk-gates.sh",sha256:"0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8"},
        {path:"control/v1/evaluate-sandbox.sh",sha256:"8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"},
        {path:"control/v1/policy-set.jq",sha256:"2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58"},
        {path:"control/v1/risk-gates-decision.json",sha256:"8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5"},
        {path:"control/v1/risk-gates-policy.json",sha256:"3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e"},
        {path:"control/v1/risk-gates.jq",sha256:"d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff"},
        {path:"control/v1/sandbox-decision.json",sha256:"c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"},
        {path:"control/v1/sandbox-policy.json",sha256:"4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"},
        {path:"control/v1/sandbox.jq",sha256:"83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"},
        {path:"control/v1/validate.sh",sha256:"cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a"}
      ],
      record_closure:$record_closure,
      bootstrap_ref:ref("evals-framework-bootstrap.v1";"text/x-shellscript";$bootstrap_sha),
      launcher_ref:ref("evals-framework-launcher.v1";"text/x-shellscript";$launcher_sha),
      driver_ref:ref("evals-framework-driver.v1";"text/x-shellscript";$driver_sha),
      program_ref:ref("evals-framework-program.v1";"text/x-jq";$program_sha),
      catalog_ref:ref("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json";$catalog_sha),
      runtime:{
        host_os:$host_os,host_architecture:$host_arch,jq_architecture:$jq_arch,
        execution_mode:$execution_mode,
        jq_ref:ref("jq-runtime.v1";"application/x-executable";$jq_sha),
        shell_ref:ref("bash-runtime";"application/x-executable";$bash_sha)
      }
    }
  }
' > "$runtime/evaluator.json" 2>/dev/null || emit_error E_RUNTIME
evaluator_sha=$(sha256_path "$runtime/evaluator.json") || emit_error E_RUNTIME
"$runtime/bin/jq" -e --arg path "$record_schema" '
  [.body.core_closure[] | select(.path == $path)] ==
    [{path:$path,sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"}]
' "$runtime/evaluator.json" >/dev/null 2>&1 || emit_error E_STALE

output="$scratch/output.json"
error="$scratch/error"
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scratch/work" \
  /bin/bash "$runtime/driver.sh" "$mode" "$runtime" "$driver_input" \
  "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" "$observed_at" \
  </dev/null >"$output" 2>"$error"
status=$?
if [ "$status" -ne 0 ]; then
  [ ! -s "$output" ] || emit_error E_RUNTIME
  driver_error=$(/bin/cat "$error" 2>/dev/null) || emit_error E_RUNTIME
  case "$driver_error" in
    E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      emit_error "$driver_error"
      ;;
    *) emit_error E_RUNTIME ;;
  esac
fi
[ ! -s "$error" ] || emit_error E_RUNTIME

# Independent re-validation of the delivered document against the exact same
# private program and core, after the driver has exited.
# program_check OPERATION EVALUATOR EVALUATOR_SHA SEED_SHA SEEDS OBSERVATIONS CANDIDATE RESULTS RESULT_SHAS
# check_observed_at names the time the candidate was built at; a run result is
# rebuilt at its own recorded time, the dashboard at this invocation's time.
check_observed_at=$observed_at
program_check() {
  [ "$("$runtime/bin/jq" -S -c -n -L "$generation_runtime/modules" \
    --arg evals_operation "$1" \
    --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
    --arg catalog_sha256 "$catalog_sha" --arg evaluator_sha256 "$3" \
    --arg seed_set_sha256 "$4" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 \
    --arg planner_sha256 03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4 \
    --arg sandbox_sha256 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb \
    --argjson normalizer_shas '{"codex-cli-producer":"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25","codex-native-reviewer":"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603","github-actions-ci":"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7","github-forge":"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be","gitlab-forge":"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}' \
    --arg risk_gates_sha256 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 \
    --arg duty_sha256 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa \
    --arg observed_at "$check_observed_at" \
    --slurpfile catalog_docs "$runtime/catalog.json" \
    --slurpfile seed_set_docs "$5" \
    --slurpfile observation_docs "$6" \
    --slurpfile evaluator_docs "$2" \
    --slurpfile candidate_docs "$7" \
    --slurpfile result_docs "$8" --argjson result_shas "$9" \
    -f "$runtime/program.jq" 2>/dev/null)" = true ]
}
if [ "$mode" = run ]; then
  program_check validate-run-result "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" \
    "$scratch/input.json" "$scratch/work/observations.json" "$output" \
    "$scratch/work/observations.json" '[]' || emit_error E_RUNTIME
else
  # Every pair is re-validated against the driver's replay, then the dashboard itself.
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    check_observed_at=$("$runtime/bin/jq" -r '.body.observed_at' "$scratch/inputs/result-$j.json") ||
      emit_error E_RUNTIME
    # The driver replayed this seed set into pair-$j; re-validate the supplied
    # result against that fresh observation set and this runtime's evaluator.
    [ -f "$scratch/work/pair-$j/observations.json" ] || emit_error E_RUNTIME
    program_check validate-run-result "$runtime/evaluator.json" "$evaluator_sha" \
      "$(sha256_path "$scratch/inputs/seed-$j.json")" "$scratch/inputs/seed-$j.json" \
      "$scratch/work/pair-$j/observations.json" "$scratch/inputs/result-$j.json" \
      "$scratch/work/pair-$j/observations.json" '[]' || emit_error E_RELATION
    j=$((j + 1))
  done
  check_observed_at=$observed_at
  program_check validate-dashboard "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" \
    "$scratch/work/seeds.jsonl" "$scratch/work/pair-0/observations.json" "$output" \
    "$scratch/work/results.jsonl" \
    "$("$runtime/bin/jq" -c 'map(.result_sha256)' "$scratch/inputs/manifest.json")" ||
    emit_error E_RUNTIME
fi
"$runtime/bin/jq" -S -c . "$output" > "$scratch/output.canonical" 2>/dev/null ||
  emit_error E_CANONICAL
/usr/bin/cmp -s "$output" "$scratch/output.canonical" || emit_error E_CANONICAL
[ "$(sha256_path "$runtime/bootstrap.sh")" = "$bootstrap_sha" ] &&
[ "$(sha256_path "$runtime/launcher.sh")" = "$launcher_sha" ] &&
[ "$(sha256_path "$runtime/adapters/codex-cli-producer/v1/normalize.jq")" = \
    dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25 ] &&
[ "$(sha256_path "$runtime/adapters/gitlab-forge/v1/normalize.jq")" = \
    ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a ] &&
[ "$(sha256_path "$runtime/adapters/codex-native-reviewer/v1/normalize.jq")" = \
    7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603 ] &&
[ "$(sha256_path "$runtime/adapters/github-actions-ci/v1/normalize.jq")" = \
    690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7 ] &&
[ "$(sha256_path "$runtime/adapters/github-forge/v1/normalize.jq")" = \
    b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-sandbox.sh")" = \
    8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-risk-gates.sh")" = \
    0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates-policy.json")" = \
    3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates-decision.json")" = \
    8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates.jq")" = \
    d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation-policy.json")" = \
    b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation-decision.json")" = \
    4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation.jq")" = \
    b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-duty.sh")" = \
    146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa ] &&
[ "$(sha256_path "$runtime/control/v1/policy-set.jq")" = \
    2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox-decision.json")" = \
    c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox-policy.json")" = \
    4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox.jq")" = \
    83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 ] &&
[ "$(sha256_path "$runtime/control/v1/validate.sh")" = \
    cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/reconciliation-plan.jq")" = \
    03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/scan-state.sh")" = \
    556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-driver.sh")" = \
    5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-launcher.sh")" = \
    9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner.jq")" = \
    722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae ] &&
[ "$(sha256_path "$runtime/driver.sh")" = "$driver_sha" ] &&
[ "$(sha256_path "$runtime/program.jq")" = "$program_sha" ] &&
[ "$(sha256_path "$runtime/catalog.json")" = "$catalog_sha" ] &&
[ "$(sha256_path "$runtime/bin/jq")" = "$jq_sha" ] &&
[ "$(sha256_path /bin/bash)" = "$bash_sha" ] &&
[ "$(sha256_path "$input_document")" = "$seed_sha" ] &&
[ "$(sha256_path "$runtime/evaluator.json")" = "$evaluator_sha" ] ||
  emit_error E_RUNTIME
while read -r path digest; do
  [ -f "$runtime/$path" ] && [ ! -L "$runtime/$path" ] &&
    [ "$(sha256_path "$runtime/$path")" = "$digest" ] || emit_error E_STALE
done <<< "$record_files"
while IFS=$'\t' read -r digest path; do
  [ -f "$runtime/$path" ] && [ ! -L "$runtime/$path" ] &&
    [ "$(sha256_path "$runtime/$path")" = "$digest" ] || emit_error E_RELATION
done <"$runtime/review-files.tsv"
if [ "$review_approval_sha" != none ]; then
  [ -f "$runtime/evals/v1/seeds/reviewer-severity/approval.json" ] &&
    [ ! -L "$runtime/evals/v1/seeds/reviewer-severity/approval.json" ] &&
    [ "$(sha256_path "$runtime/evals/v1/seeds/reviewer-severity/approval.json")" = "$review_approval_sha" ] ||
    emit_error E_STALE
fi
/bin/cat "$output" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
