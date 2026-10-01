---
spec-blob: c789e5757417cfe0ae829be391112d987323b845
intent-blob: dad5c3e210d3772b6cc50cb3f556db06d96a7324
risk: high
drafted: 2026-09-29
---
# Plan: vm-launcher-supervisor

Tracks #463. Risk: high (`artifact-high`): independent review, green CI and operator
merge of this plan come before any code. The spec (blob above) is the contract; this
plan fixes only what it leaves open. Citations are to origin/main `daa5302`, where the
spec's `e73b76a` citations still hold. Only merged content is used, read unchanged.

Steps 1-4 (R14.4) ship as nine PRs from one branch `ystack/impl/vm-launcher-supervisor`,
each after the previous one merged and the branch took fetched main by an exact merge
(no reset, rebase or force). All use `Tracks #463` and none closes it, because the R13
requests are posted there. Steps 5-9 are operator decisions and host actions; none
starts before its own `approve <id>`, and only step 9 changes the repository.

## Interfaces fixed by this plan

**Runtime driver** (PR 5; `runtime-vfkit.py` and the fake implement it unchanged),
run with an empty environment, stdin `/dev/null`, stdout capped at 65,536 bytes,
2,000 ms per call:

- `driver argv <start.json>` prints canonical `{"argv":[...],"stopped_exit_status":N}`
  with `argv[0]` equal to the configured `runtime.vfkit`. `start.json` is kind
  `sandbox_runtime_start`, `body` exactly `command_line`, `cpu_count`, `export_disk`,
  `initramfs`, `input_disk`, `kernel`, `memory_bytes`, `rest_socket` (R5.4 values; paths
  inside `<work_root>/<attempt_id>/`, socket `rest.sock`).
- `driver state <socket>` prints `running`, `stopped` or `error` and LF (`GET
  /vm/state`); `driver stop <socket>` exits 0 iff `POST /vm/state`
  `{"state":"HardStop"}` returned 200.

The host spawns `argv` as its child (own process group, output to a capped
`runtime.log`), polls `state` every 100 ms and reaps with `waitpid`. "The runtime
reported the VM stopped" (R9.3) is a `stopped` state or an exit with
`stopped_exit_status` (vfkit v0.6.4 exits 0 only after the stopped state,
`cmd/vfkit/main.go:274-296`); any other exit, output or overrun is a runtime error.
For vfkit, `argv` is exactly `[vfkit, "--cpus", "1", "--memory", "512", "--bootloader",
"linux,kernel=<k>,initrd=<i>,cmdline=\"console= quiet lsm=landlock
rdinit=/init\"", "--device", "virtio-blk,path=<input>,readonly", "--device",
"virtio-blk,path=<export>", "--restful-uri", "unix://<socket>"]`.

**Guest plan** (PR 2): `sandbox_guest_plan` `body` exactly `argv`, `environment`,
`entries` (`[{kind,mode,path,sha256,size_bytes}]` in manifest order, directories with
`null` digest and size, the n-th file entry being record `candidate/<n>`),
`instruction_sha256`, `limits` (the R7.1 parameters: `bandwidth_slice_us`, `cpu_max`,
`cpu_max_burst`, `output_inodes`, `output_tmpfs_bytes`, `pids_max`, `scratch_bytes`,
`scratch_inodes`, `tree_deadline_ms`) and `verifier_sha256`; the C parser accepts only
the escapes `json.dumps(ensure_ascii=False)` emits. **Receipt `id`**: `"receipt." +
launch_request_sha256`.

Host Python runs on 3.9 (Command Line Tools) to 3.12 (CI), stdlib only, canonical as
`prepare-candidate.py:281-284`. Guest C is C11; UAPI constants newer than CI's headers
(Landlock ABI 6 scopes) are defined under `#ifndef`, and a syscall aarch64 lacks
(`mknod`) is filtered only where defined.

## Files that change

| Path | PR | Mode |
| --- | --- | --- |
| `sandbox/v1/guest/common.h`, `common.c` | 1 (created), 2 | 100644 |
| `scripts/test/sandbox-guest-harness.c` | 1 (created), 2, 6 | 100644 |
| `scripts/test/sandbox-guest.test.sh` | 1 (created), 2, 3, 6, 7 | 100755 |
| `sandbox/v1/host-supervisor.py` | 3 (created), 4, 5 | 100755 |
| `scripts/test/sandbox-launcher.test.sh` | 3 (created), 4, 5, 8 | 100755 |
| `scripts/test/sandbox-fake-runtime.py` | 5 | 100755 |
| `sandbox/v1/guest/init.c`, `supervisor.c`; `sandbox/v1/build-guest.py` | 6 | 100644; 100755 |
| `sandbox/v1/guest/probe.c` | 7 | 100644 |
| `sandbox/v1/runtime-vfkit.py`, `sandbox/v1/qualify.py` | 8 | 100755 |
| `shadow/v1/shadow-environments.json`, `scripts/test/shadow-slice.test.sh:343-368`, `docs/components.md`, `RESTORE.md`, `ci/required-files.txt` | 9 | |

Step 9 alone adds `sandbox/v1/qualification/env.local-macos-vm-dummy-target.json` and
changes `enforcement/v1/accepted-identities.json` (R12.3). No executable, image or
fixture is committed. Intent, spec and plan stay byte-identical.

**Existing pins (grepped; only `shadow-slice.test.sh` is edited).** Manifest prefix
pins sit above the new block at line 233 (`portable-core-schema` 89 lines, `-ingress`
96, `-profile-graph` 100, `-stage-request` 108, `-result-facts` 112); live copies at
`construction-publisher-gate.test.sh:360`, `north-star-gate.test.sh:944`. Registry
readers select by entry (`shadow-assembler.test.sh:724-730`,
`shadow-self-host-evidence.test.sh:1185-1197`, `sandbox-receipt.test.sh:63-83`,
`check-sandbox-receipt.sh:150`) or digest it at run time (`shadow-slice.test.sh:58-67,758-763`).
New files avoid the scans of `portable-core-schema.test.sh:880-928` and
`check-rename.sh:26`; `run-all.sh:66-69`, the CI manifest step (`ci.yml:21-42`) and
ShellCheck 0.11.0 (`:86-92`) apply.

## Order of work

1. After operator merge: confirm the three blobs and hash links, record the plan blob
   and merged OID as `plan-base`, branch from it. If main moves before the first code
   commit, follow `work/README.md` (fresh `Plan-verdict`, reaffirmation on #463).
2. PRs 1-9 in order, one commit each (fix rounds add commits), only that PR's paths,
   blobs rechecked first (a mismatch stops, `stale`), each with independent review,
   green CI and operator merge.

None of the nine PRs closes #463, and step 9 cannot open under this spec (no
qualification is possible, R7.2), so #463 stays open until a future concern or an
operator decision resolves R7.2; the manager records this on the issue.

## PR 1: frame format and digest (step 1; R3.2)

`common.h`/`common.c`: FIPS 180-4 SHA-256; a `YSFRAME1` reader and writer over a
descriptor (R3.2 layout, `end` digest, zero-only tail); the input (R5.2) and export
(R8.1) record-name sets, indexes contiguous from 0; strict UTF-8 and the preparation
path range. Harness `frame-write <out> <name>=<file>...`, `frame-read <in> <dir>`.
Test: FIPS vectors; every truncation offset of a three-record frame; a non-zero tail
byte; a flipped `end` byte; bad magic; an empty or out-of-set name; an index gap and
disorder; a length past the device; a byte-identical round trip; paired controls.

## PR 2: plan, materialization, wiring, inventory (step 1; R5.5, R6.4, R8.1)

`common.c`: the plan parser (unknown or duplicate keys and other escapes refused);
materialization under a directory descriptor (`mkdirat`/`openat`, `fchown` to a given
uid and gid, manifest modes, size and digest checks); the R6.4 wiring (`ys_exec`); the
R8.1 inventory. Harness `plan`, `materialize`, `inventory` and `exec-report` (a child
printing argv, environment, fds 0-2 with their `fstat` and `O_APPEND` state, and every
other open descriptor). Test: R15.2's frame, plan, wiring, inventory and
materialization cases. Production init, supervisor and build proof belongs to PR 6.

## PR 3: configuration, ACLs, package and phase A (step 2; R3, R4.1, R10)

`host-supervisor.py launch`: the R10.1 ACL walk first (Darwin `acl_get_fd_np` and the
entry, tag and permset calls via `ctypes`; Linux the two xattrs), then usage,
configuration, owners and modes, the store root (R2.3), package frame and limits,
request, `E_STORE_ID`, the exclusive nonce file and `E_ATTEMPT_EXISTS`; plus the R10.2
store writer and R10.3 receipt and outcome code. Until PR 5 a passing attempt ends at
one stub, the R9.4 runtime-never-started receipt. The test's install tree (control
files, registry, test-only accepted set, synthetic identities, store) sits under
`$TMPDIR` if every ancestor passes R10.1, else `$HOME`, else the test fails; the work
root is `mktemp -d /tmp/ysvml.XXXXXX` (outside R10.1) so socket paths stay short. It
proves each phase A error, the three R15.1 `E_INSTALL_ACL` fixtures per platform, store
modes after every case and canonical receipts. `sandbox-guest.test.sh` cross-checks
the host codec (imported from `host-supervisor.py`) against the harness, both ways.

## PR 4: phase B, freeze, refusal receipts (step 2; R2.3, R2.4, R4.2, R5.1, R9.3)

Slot measurement (R2.3 composites), the R2.4 `=y` set, every R4.2 reason, freeze by
copy, `payload/refusal.json` and the R9.3 no-launch receipt. Test: each reason alone
with its control; the twelve `subject` and six `control` mutations; instruction
binding; the three R15.1 candidate paths; kernel options absent and `=m`; and, against
the merged check in a temporary repository copy (pinned jq 1.6 as
`shadow-slice.test.sh:24-51`), classes (a), (b), phase B (c) and the shipped files.

## PR 5: launch path and fake runtime (step 2; R5.2-R5.4, R7.3, R8.2-R8.4, R9)

Replaces the stub: the two disks and `plan.json`, the driver interface, the R9.1 clock
(`HardStop` at 50,000 ms, `SIGKILL` at 58,000 ms), R9.2 signals, export reading and
R8.2 checks, payload digests, and the admitted lifecycle, rows, teardown and timing.
`sandbox-fake-runtime.py` implements the interface, reads `scenario.json` beside itself,
imports the host frame codec and writes the scripted export frame. Test: every
remaining R15.1 case, including the row matrix, the concurrent real-time `HardStop`,
delayed-stop and self-stop cases, and class (c) with the edited-`hard` copies.

## PR 6: guest init, supervisor and build (step 3; R2.5, R5.5-R9.1)

`init.c` retains the mounts and exec of R5.5. `supervisor.c` checks inputs; prepares
candidate, tools, output and scratch tmpfs; sets the tree cgroup with read-back of
every R7.1 parameter; and uses `clone3` with the accepted namespaces. The child keeps
`pivot_root` and old-root detachment. No additional boot-root transition or chroot
fallback is introduced. R6.2 Landlock, R6.3 seccomp, the fanotify first-open rule,
40,000 ms tree deadline, counters, report, export, `sync` and power-off remain required.
CPU and wall enforcement remain `none`; these tests cannot qualify the environment.

Guest setup and reporting implement these requirements:

- Derive candidate data capacity from each file's page-rounded allocation using the
  measured page size and checked arithmetic. Count the root and manifest entries for
  inode capacity; use finite positive capacity for empty input. Justify any additional
  allowance and preserve logical-byte and RAM limits. Do not assume 4 KiB geometry.
- Prepare non-writable but searchable root, `/sandbox`, candidate and tools ancestors
  for uid 65534 before dropping privilege. Preserve candidate manifest modes and all
  per-mount flags.
- After the root transition, clear supplementary groups and set all GIDs. Drop the
  bounding set while still privileged, set all UIDs to 65534, then clear remaining
  effective, permitted, inheritable and ambient capabilities. Establish `no_new_privs`
  before Landlock restriction and seccomp installation. Check every required change
  and the final identity/capability state; any failure prevents verifier execution.
- The seccomp `O_TMPFILE` test matches the full temporary-file flag combination,
  allowing ordinary `O_DIRECTORY`. `MADV_REMOVE` uses equality, not a bitmask;
  namespace clone flags use their mask. Preserve the architecture check and closed
  denied-syscall list; fail rather than silently truncate a generated filter.
- Create the instruction in the supervisor's private tmpfs, reopen it read-only,
  and close all writable references before child execution. Only that regular
  read-only descriptor reaches fd 0; duplication or `F_SETFL` cannot change access
  mode. Preserve the exact argv, environment and other descriptor rules.
- Initialize all fanotify history and descriptor state before use. Permit only the
  first open of an empty regular inode; deny when history cannot record it. Close the
  group after tree termination and before export, including checked failure cleanup.
- Build reports with checked capacity arithmetic and checked formatting results.
  Account for full hexadecimal evidence names and every other field; refuse an
  incomplete report on allocation or formatting failure. Never advance past capacity.

`build-guest.py compile|image` follows R2.5. Resolve required sources from the
repository root, including the unchanged verifier and project headers; missing
required inputs fail before compiler invocation. Only the probe is staged until
PR 7. Compile from a fresh controlled extraction of the private archive copy at
`<toolchain-dir>/toolchain.tar.xz`; never invoke an existing extracted caller tool.
Reject unsafe archive members before invocation. Record the extracted archive
copy's digest, source/header identities, script, flags and complete target set.
Preserve existing-output refusal and deterministic image generation.

Tests extend `sandbox-guest.test.sh` and the existing `sandbox-guest-harness.c` to
invoke production init/supervisor helpers, not copied implementations. Separate test
builds may substitute syscalls to record setup order and inject failures; those
substitutions are compiled out of production, with no runtime bypass. Cover all
R15.2 cases with allowed controls beside denials: maximum report names/counts and
writer failures; privilege ordering and final state; traversal and forbidden writes;
filter flag combinations and advice values; fanotify initialization, first/repeated
open and full history; read-only instruction descriptors with writable copies closed;
and many-small-file, zero-length, boundary and invalid/overflow geometry cases.

A recording synthetic compiler archive tests the real `compile` command, mandatory
targets, source/header identities, archive digest, safe extraction, unsafe-member
refusal before invocation, incomplete-build refusal and separate-directory
reproducibility. Changing bundled headers while keeping compiler bytes unchanged
must change the archive identity. Retain synthetic-image determinism and the Linux
`-std=c11 -Wall -Wextra -Werror` compile gates for init and supervisor. Execute the
production report path under Linux ASan/UBSan, evaluate the generated filter with
positive and negative inputs, and exercise real descriptor modes. Privileged Linux
setup cases use only capabilities already available in the isolated test environment;
report unavailable capabilities explicitly, never as passes. These are contract tests;
R13.4 still supplies the separately authorized arm64 guest and Apple VM proof.

## PR 7: probe (step 3; R13.4)

`probe.c` reads its mode from fd 0, runs exactly one R13.4 mode and prints one result
line. The Linux compile case adds it.

## PR 8: runtime driver and qualification harness (step 4; R2.2, R13, R15.1)

`runtime-vfkit.py`: the argv above, REST over `AF_UNIX` via `http.client`, and `argv`
failing for a socket path over 103 bytes, which vfkit refuses (`pkg/rest/rest.go:17-21,141-142`).
`qualify.py`: `measure <host-config>` (the nine installed slots of R2.3, every slot but
`verification_instructions`, which R10.1 keeps out of the configuration),
`instruction-digest <file>` (the SHA-256 of one instruction's bytes, the
`verification_instructions` value its launch package will carry, R2.3, R4.2),
`check-kernel-config <file>` (the host R2.4 function), `dry-run` (the probe list
against the fake runtime) and `run <dir>` (a canonical `sandbox_qualification_record`).
`run` and `dry-run` take two trusted host configurations, `verifier` and `probe`, that
differ in exactly `identity_paths.verifier` (the real verifier or the probe),
`store_id`, `store_root` and `work_root` (plus, outside the configuration, each one's
sudoers rule); every other field is identical. The host supervisor puts the executable
its own configuration names on the input disk (R2.3, R5.2). Real-verifier cases launch
through `verifier`, probe modes through `probe`, each request with that
configuration's `store_id`. Test: vfkit argv and REST calls against a fake `vfkit`, the
over-long socket path, `measure` and `instruction-digest` on the fixture trees, and
the dry run through `host-supervisor.py launch` and the fake runtime with both fixture
configurations (distinct synthetic verifier files, stores and work roots): the fake
echoes the input disk's `verifier` digest to stdout; each receipt's
`identities.verifier`, `stdout_sha256` and `origin.store_id` match its own
configuration, and a request carrying the other configuration's `store_id` is refused
`E_STORE_ID` with nothing written in either store.

## PR 9: registry entry, docs, restore, manifest (step 4; R12.1, R14.3)

Append the R12.1 entry; with pinned jq 1.6 the file's SHA-256 becomes
`655771163e18384904eeaf2b7f22e3999957a037dce845b7fa6fdff2196ac4c7` and the entry's
`jq -S -c` text hashes to `2ce3bb652c679d446e8f053acbfa5c06bbcb4129bd0dcbddfdd37e8f8addbf69`;
the PR recomputes both. `shadow-slice.test.sh`: `--arg vm_description` with the R12.1
description, a fourth element with the R12.1 fields, and the pass message `the
environment registry lists four environments, each bound to a target repository and a
source root commit`. The registry paragraph (`docs/components.md:1448-1456`) says four
entries, adding `` `env.local-macos-vm-dummy-target` (`external-target`, `unproven`),
the VM guest environment, which inherits nothing from the checkout entry ``. New
section after `## Inactive sandbox receipt check` (`:317-336`), wrapping adjustable:

> ## Inactive VM launcher and supervisor
>
> `sandbox/v1/host-supervisor.py` is the only producer of sandbox enforcement
> receipts ([spec](../work/vm-launcher-supervisor/spec.md)). It refuses before launch
> unless every byte identity, binding and candidate file matches, freezes the
> candidate by copy, boots one offline guest through `sandbox/v1/runtime-vfkit.py`,
> runs the fixed verifier under the guest supervisor, tears down and writes one
> receipt into its own store. Nothing runs it outside its tests: no host
> configuration, account or store exists, and the shipped accepted set is empty, so
> every receipt is refused. CPU and wall time are `enforcement: "none"`, so no receipt
> can be `satisfied`. The tests use a fake runtime and prove contracts, not the Apple
> VM boundary.

`RESTORE.md`, after `### Restore the inactive fixed file-digest verifier` (`:337-353`):

> ### Restore the inactive VM launcher and supervisor
>
> Restore the paths listed under "Inactive VM launcher and supervisor" in
> [`ci/required-files.txt`](ci/required-files.txt) from one commit, then run:
>
> ```sh
> bash scripts/test/sandbox-guest.test.sh
> bash scripts/test/sandbox-launcher.test.sh
> ```
>
> They prove the guest frame, plan and wiring code with the host compiler, and the
> host supervisor against a fake runtime, fixture store and test-only accepted set.
> Restoring installs no runtime, account, sudo rule or store, boots no VM, accepts no
> identity and uses no network beyond the pinned jq 1.6 release.

`ci/required-files.txt`, after the receipt-check block (`:224-231`) and its blank line,
before `# Inactive credential policy and evaluator`, one blank line after:

```text
# Inactive VM launcher and supervisor
sandbox/v1/host-supervisor.py
sandbox/v1/runtime-vfkit.py
sandbox/v1/build-guest.py
sandbox/v1/qualify.py
sandbox/v1/guest/common.h
sandbox/v1/guest/common.c
sandbox/v1/guest/init.c
sandbox/v1/guest/supervisor.c
sandbox/v1/guest/probe.c
scripts/test/sandbox-launcher.test.sh
scripts/test/sandbox-guest.test.sh
scripts/test/sandbox-fake-runtime.py
scripts/test/sandbox-guest-harness.c
work/vm-launcher-supervisor/intent.md
work/vm-launcher-supervisor/spec.md
work/vm-launcher-supervisor/plan.md
```

## Steps 5-9: decision packages and host actions

Each request is a comment on #463 to @yihanzhu with label `needs-human` and its id,
posted after PRs 1-9 merged, the previous step's evidence is posted and a fresh
non-author reviewer read it. Only the operator's new comment exactly `approve <id>`
approves; a changed value takes a new id (`vml-acquire-2`). Commands run from a clean
clone at a recorded main commit `HOST_COMMIT`; evidence is posted verbatim on #463.
No step 5-9 action, download included, happens before its own approval.

**`vml-acquire`** (step 5; R13.2a). Quarantine `~/ystack-quarantine/vml/` (fresh, 0700).
Artifacts, re-read from the publisher when posting (a difference is stated):

| Artifact | URL | Bytes | Publisher SHA-256 |
| --- | --- | ---: | --- |
| vfkit `v0.6.4`, asset `vfkit` | `https://github.com/crc-org/vfkit/releases/download/v0.6.4/vfkit` | 66,431,936 | `0ed83fc8ca7aa708598835480dba1362406aa7cd1dab3b27464eb76327d9652d` (release asset digest) |
| Zig `0.16.0` | `https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz` | 52,238,004 | `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489` (`download/index.json`) |
| Ubuntu 26.04 `linux-image-unsigned-7.0.0-34-generic` `7.0.0-34.34` arm64 | `https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-image-unsigned-7.0.0-34-generic_7.0.0-34.34_arm64.deb` | 17,623,232 | `7ff12701db794da19eac5f15d7e08b75c0dbf9d388f0b9e04c130d97ea528cf7` |
| `linux-buildinfo-7.0.0-34-generic` `7.0.0-34.34` arm64 (build config) | same pool, `linux-buildinfo-7.0.0-34-generic_7.0.0-34.34_arm64.deb` | 629,902 | `c83bb6ad4423c3603c8d9905abb7c65c4fc7414122ab9755ef92968666588377` |

Ubuntu digests come from `dists/resolute-updates/main/binary-arm64/Packages.gz`, bound
in `InRelease`, whose OpenPGP signature is not verified (no base-system `gpg`), as the
package states. Hosts: `github.com`, its asset redirect host (named from `curl -sI`),
`ziglang.org`, `ports.ubuntu.com`. R2.2 at v0.6.4: `pkg/config/virtio.go:975-979`,
`pkg/vf/vm.go:134-190`, `pkg/rest/rest.go:135-142`, `pkg/rest/vf/state_change.go:25-27`,
`doc/usage.md:26-33,51-81,529-555`, `cmd/vfkit/main.go:274-296`. The manager runs `curl
-fL --proto '=https' --max-redirs 2` per artifact and `shasum -a 256` (a mismatch
deletes the file and stops); `/usr/bin/ar -x` and `/usr/bin/tar -xf` of each `.deb`;
Python `gzip` of `boot/vmlinuz-*`, requiring the arm64 `Image` magic at offset 56;
`qualify.py check-kernel-config`; `sw_vers`, `uname -a` and `qualify.py measure` (nine slots) on a
draft configuration (vfkit, driver, the Virtualization VM service executable, the arm64e
dyld shared-cache files); copy the approved Zig archive byte-for-byte into a fresh
quarantine toolchain directory as `toolchain.tar.xz`, verify its digest, and run
`build-guest.py compile <toolchain-dir> <out-dir>` twice into fresh output directories.
Each build copies and extracts the archive privately under R2.5; there is no separate
caller extraction. Compare all executables and both build records with `cmp`, require
both `archive_sha256` values to equal the approved archive digest, then run
`build-guest.py image`. Evidence: each URL, size and digest, `Image` and config
digests, the R2.4 result, the `host_runtime` files, both `sandbox_guest_build` records
and the image digest. No vfkit run, VM boot or install.

**`vml-install`** (step 6; R13.2b). Quotes that evidence. Creates only
`/usr/local/libexec/ystack-sandbox/v1/artifacts/` (root:wheel 0755, ancestors checked
first): `vfkit`, `Image`, `kernel.config`, `initramfs.cpio`, `init`, `supervisor`,
`verifier`, `probe` and the Zig archive (executables 0555, else 0444); no service,
daemon, extension, profile or setting. The operator runs `sudo /usr/bin/install -o root
-g wheel -m <mode>` per file, then `shasum -a 256`, `ls -lde@` of every file and
ancestor, and `codesign -dv --entitlements - vfkit`. No network or VM boot. Rollback:
remove that directory and the quarantine.

**`vml-trust-root`** (step 7; R13.3). Principal `_ystacksbx` (own empty group
`_ystacksbx`, shell `/usr/bin/false`, home `/var/empty`, hidden); consumer group
`_ystackrcpt`, sole member `yihanzhu`; each id the lowest free value in 400-499.
Install directory `/usr/local/libexec/ystack-sandbox/v1/supervisor/` (root:wheel 0755):
the four `sandbox/v1/*.py` (0555), `host-config.json` (0444, exact bytes in the package,
`store_id` `store.local-macos-vm.v1`) and copies of the R10.1 installed files at
`HOST_COMMIT` (0444), with digests; main's empty accepted set keeps every launch
refused. Store `/private/var/db/ystack-sandbox/store` (`_ystacksbx:_ystackrcpt` 0750),
work root `…/w` (`_ystacksbx:_ystacksbx` 0700), parent root:wheel 0755. Sudoers file
`/etc/sudoers.d/ystack-sandbox` (root:wheel 0440, `visudo -cf`), exactly: `yihanzhu
ALL=(_ystacksbx) NOPASSWD: <interpreter> <install-dir>/host-supervisor.py launch`, with
both paths spelled out. The question of `work/enforcement-evidence-binding/spec.md:88-92`
verbatim. The operator runs the listed `dscl`, `dseditgroup`, `install` and `visudo`
commands. Evidence: `dscl . -read` of user and groups, `dseditgroup -o read`, `ls -lde@`
of every path and ancestor, `sudo -l -U yihanzhu`, and one smoke run through the rule
with empty stdin giving `E_PACKAGE` (no VM). Rollback: delete those paths, user and groups.

**`vml-qualify`** (step 8; R13.4). The R12.1 entry and digest above; the proposed
accepted-set entry, whose slots are the union of `qualify.py measure` on each of the
two qualification configurations (so `verifier` lists the real verifier and the probe,
`host_supervisor` both configuration composites, the other seven slots one digest
each) and whose `verification_instructions` list is `qualify.py instruction-digest` of
each qualification instruction (the three real-verifier cases and each probe mode),
plus six R7.1 mechanism ids and `scratch_bytes` 16,777,216; the two configurations'
exact bytes and which runs use which (real verifier: match, mismatch, changed-byte
refusal and the `HardStop` repeats; probe: every R13.4 probe mode, the mode being the
instruction), each run with its expected verdict and reasons; the candidate, a #396
bundle from `prepare-candidate.py prepare` over the scrubbed dummy-target copy at
`e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e` (step-7 post revision), with its arguments
and digests; sentinels under `~/ystack-quarantine/vml/sentinels/`; the `HardStop`
repeat count; and two qualification install directories (`…/v1/qualify-verifier/`,
`…/v1/qualify-probe/`) whose configurations differ only in the PR 8 fields (stores
`store.local-macos-vm.qualify-verifier.v1` and `…qualify-probe.v1` at
`/private/var/db/ystack-sandbox-q/store-verifier` and `…/store-probe`, work roots
`…/w-v` and `…/w-p`), each with its own sudoers rule of the same shape and one shared
qualification accepted set, all installed, measured and later removed by the operator.
The manager runs `qualify.py run <dir>` as `yihanzhu`, launching through those rules
and reading each receipt as the consumer (R2.3). Evidence: receipt digests and verdicts,
stop latencies (information only), supervisor resource use, the record's SHA-256 and
bytes (kept outside git).

**Step 9** (R12.3) opens only on a `qualified` record: the record file, the `proof_state`
change and its `shadow-slice.test.sh` pin, and the accepted-set entry.

## What does not change

Every R14.2 path and every other existing test stays byte-identical; no README row.
Reserved for the operator and excluded: the four R13 decisions, activation or any
write scope, credentials, network beyond the tests' pinned jq fetch, a real publisher,
target installation, and any change to `config/**`, `ROADMAP.md`, `AGENTS.md`,
`REVIEW.md`, `NORTH_STAR.md`, `.github/**`, `scripts/merge-pr.sh`,
`scripts/codex-review.sh`, `scripts/test/run-all.sh` or `scripts/lib/*.sh`.

## Follow-up intakes

A structural CPU and wall bound, or an operator decision on an empirical standard
(R7.2); concerns 5-7 as step-8 R8 lists them.

## Review size

| PR | Record | Net lines | Concern |
| --- | --- | ---: | --- |
| 1 | `review_size: accepted-exception` | 700-950 | the frame codec and its exhaustive damage cases |
| 2 | `review_size: accepted-exception` | 800-1,100 | guest input: plan, materialization, wiring, inventory |
| 3 | `review_size: accepted-exception` | 1,100-1,700 | trusted configuration, ACLs, phase A, store and receipt writer |
| 4 | `review_size: accepted-exception` | 600-1,500 | phase B admission and its binding matrix |
| 5 | `review_size: accepted-exception` | 1,400-3,500 | the launch lifecycle against the fake runtime |
| 6 | `review_size: accepted-exception` | 2,800-4,200 | guest containment setup, build provenance and production-path regression proof |
| 7 | `review_size: accepted-exception` | 450-700 | the probe modes |
| 8 | `review_size: accepted-exception` | 850-1,200 | runtime driver and qualification harness |
| 9 | `review_size: standard` | 70-110 | registry entry, docs, restore, manifest |
| This plan PR | `review_size: accepted-exception` | 500-600 | one plan: the nine-PR split, guest repair proof and four decision packages |

Evidence: #460 measured 1,694 (an 831-line C verifier with SHA-256, a 771-line test);
#454 3,530 (a 1,556-line stdlib Python store and test); #455 641 and #457 599;
`prepare-candidate.py` (2,288) and its test plus fixtures (3,209). PR 3 as built in
#470 measures about 1,600-1,700: the component-by-component ancestor walk with
descriptor-bound reads and ACL iteration (R10.1), the accepted-set schema mirror of
`fixed_accepted_shape_ok`, the runtime driver in the trusted walk, bounded JSON
nesting, and the CI-only trust-root anchor hook with its gating tests (#463 record).
PR 4 as built in #473 measures about 1,200-1,500: it extends PR 3's phase-A
infrastructure (validated-descriptor reads, store and receipt writers, test fixtures)
rather than duplicating it, and carries the complete consumer-checker matrix for the
R15.1 classes run in a temporary repository copy, the full dyld shared-cache inventory
in the host_runtime composite, created-entry teardown and manifest kind/mode
validation (#463 record). PR 5 as built in #477 measures about 3,300-3,500: the
launch lifecycle carries bounded reaping under the absolute deadline, deadline-first
polling with driver calls capped by the time to the next deadline, cancellation stops
retried until accepted, post-claim finalization for every failure after the attempt
is claimed, observation validation against guest-tree termination, foreign
work-directory preservation on attempt-id collision, clean-exit ordering before
endpoint-failure poll errors, freeze-failure deadline measurement, malformed
driver-response containment, wall-limit evidence derived from an issued stop,
manifest path validation in phase B, creation recording immediately after the
work-directory mkdir, the wall-time endpoint captured at confirmed stop, a
deterministic cancel-during-poll race, a bounded drain-worker shutdown that retains
descriptor ownership, serialized fake-runtime mailbox updates,
an environment-independent mailbox lock, post-spawn initialization guarded so the
runtime is always stopped, reaped and receipted, timed-out driver reads rejected as
incomplete with the driver process tree cleaned up,
index-stored evidence under the R10.2 layout with hex-name validation, the real-time
default-deadline cases beside the fast overridden ones, and receipt diagnostics on
assertion failure (#463 record). PR 6's range covers the guest containment/build
implementation plus controlled archive extraction, checked reporting and setup,
and production-path regression harnesses. Keep readable setup and complete proof,
including sanitizer and negative controls. Remove redundant narration without
compressing code or trimming tests. A PR outside its range, or PR 9 past 400, stops
and returns to this plan gate, never split ad hoc. The plan's range covers the nine-PR
split, those proof requirements and four decision packages; #452's 579-line plan is
the precedent.

## Risks

- **No qualification from this concern (R7.2, R12.3).** CPU and wall rows stay
  `enforcement: "none"`, so this concern yields only `failed` receipts and cannot
  qualify the environment: step 8 proves the other rows, R12.3 does not land and the
  entry stays `unproven`. Step-8 R7.1 therefore stays blocked on a future
  structural-bound concern or an operator-accepted empirical standard; concerns 5
  and 6 may be built inactive meanwhile.
- **R16.2 sizes.** Standard-size PRs would mean 25 or more, several shipping untested
  halves. R16.2 of the linked spec makes the plan's recorded ranges binding. Scope
  is unchanged.
- **Staged stub.** In PRs 3-4 a passing attempt gets a runtime-error receipt and never
  runs; no text calls the supervisor usable before PR 5.
- **Socket path.** vfkit refuses a Unix path over 103 bytes, so under the
  `vml-trust-root` work root an `attempt_id` over 61 bytes fails as a runtime error
  (fail closed). Concern 5 chooses attempt ids.
- **Unproven host facts.** The framework under a hidden `sudo` account, the kernel's
  options and compression, and Zig's reproducibility are known only in steps 5-8. A
  failure stops that step; another artifact or account is a plan-only PR change, and a
  store-rule change returns to G2.
- **Overclaiming.** No text presents a receipt, digest or test as VM proof (R15.4).

## Proof

BASE is the PR's merge base with main (full OID); report it and the head.

For PR 6, the guest suite must include the production-helper regressions and Linux
sanitizer runs above. Record their command, exact head, platform and complete output;
distinguish actual Linux operations from substituted syscalls and filter evaluation.
Compilation alone does not satisfy behavioral proof. Report missing privileged test
capabilities and Darwin's Linux-only limits explicitly; neither counts as a passing
mechanism test or replaces R13.4. The build fixture proves orchestration and byte
identity only, not real Zig reproducibility or native qualification.

```sh
for f in intent spec plan; do git rev-parse "HEAD:work/vm-launcher-supervisor/$f.md"; done
git show HEAD:work/vm-launcher-supervisor/plan.md | sed -n '1,6p'
git diff --name-only BASE HEAD; git diff --check BASE HEAD
git ls-files -s sandbox scripts/test/sandbox-*
git diff --quiet BASE HEAD -- config control enforcement verifiers preparation scope \
  evals adapters ROADMAP.md AGENTS.md REVIEW.md NORTH_STAR.md .github scripts/lib \
  scripts/merge-pr.sh scripts/codex-review.sh scripts/test/run-all.sh work && echo unchanged
git diff --name-only --diff-filter=MD BASE HEAD -- scripts/test shadow ':!scripts/test/sandbox-*'
grep -v -e '^$' -e '^#' ci/required-files.txt | while IFS= read -r f; do
  [ -f "$f" ] || echo "missing required file: $f"; done
shellcheck -x -S style scripts/test/sandbox-guest.test.sh scripts/test/sandbox-launcher.test.sh
bash scripts/check-rename.sh && bash scripts/test/run-all-sharding.check.sh
for t in sandbox-guest sandbox-launcher sandbox-receipt file-digest-verifier \
  control-sandbox-policy candidate-content-preparation shadow-slice shadow-assembler \
  shadow-self-host-evidence scope-qualification portable-core-schema; do
  bash "scripts/test/$t.test.sh" || echo "FAILED $t"; done
```

Require both blobs, the accepted plan blob, `risk: high`, only that PR's paths and
modes, silent `--check`, `unchanged`, the `--diff-filter` list empty except in PR 9,
and every command exiting 0 with no `FAILED` (new suites from the PR creating them);
record command, head, platform and full output. PR 9 also counts each new manifest path
once (`grep -Fxc`), resolves both new links and recomputes the registry digests. Never
run `scripts/test/run-all.sh` locally. On the exact final head and base require every
CI job plus a dispatched six-shard run (both suites on Linux). A fresh non-author
reviewer applies Bugs, Security and Compliance passes to the diff, hash links and this
evidence; every Important finding is resolved before operator merge.
