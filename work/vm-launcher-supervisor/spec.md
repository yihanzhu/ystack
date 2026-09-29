---
intent-blob: dad5c3e210d3772b6cc50cb3f556db06d96a7324
risk: high
drafted: 2026-09-29
---

# Spec: VM launcher and supervisor for the real sandbox receipt

Tracks #463. Step-8 child concern 4 (`work/step8-bounded-write-readiness/spec.md:294`),
third child of the sandbox decision (`work/real-sandbox-boundary/spec.md:160-161`): one
host supervisor, one runtime driver, one guest init and guest supervisor, a guest
build, a native qualification harness and their tests. Everything ships inactive; the
four operator requests of R13 gate every host change, VM boot and qualification.
Citations are to origin/main at `e73b76a`.

## Requirements

### R1. Placement, language and fixed contracts

1. The component lives in `sandbox/v1/`. It is one boundary with a host half and a
   guest half, so it is neither `launcher/v1` (the launcher is only one part) nor
   `enforcement/v1` or `control/v1`, which stay byte-identical.
2. Host code is stdlib Python 3, as the trusted preparation process is
   (`preparation/v1/prepare-candidate.py:1-30`), reusing its identity pattern (script
   and interpreter digests, `:1853-1871`) and canonical encoding (`:281-284`), which
   equals `jq -S -c` for the ASCII documents defined here. Guest code is C11, linked
   statically, as the verifier is (`work/fixed-file-digest-verifier/spec.md:20-28`):
   the guest carries no interpreter, and every guest binary is built by one toolchain.
3. Consumed unchanged, as fixed contracts: `enforcement/v1/*` (receipt
   `work/enforcement-evidence-binding/spec.md:97-158`, store rules `:56-79`, accepted
   set `:169-195`, accounting table `:199-221`, check `:225-279`, outcomes `:283-300`)
   and `verifiers/file-digest/v1/*` (argv and environment
   `work/fixed-file-digest-verifier/spec.md:58-69`, fd 0 `:73-97`, exit statuses
   `:165-169`, build identity `:29-50`). A need either cannot meet returns this spec to
   G2 as a named dependency; it is never met by editing them. Two digests those
   contracts name without a format get new kinds here, which changes neither:
   `launch_request_sha256` (R3.1) and `evidence_manifest_sha256` (R8.3).
4. No runtime name enters a core record: mechanism ids (R7) are neutral, and the
   runtime is named only in `sandbox/v1/runtime-vfkit.py` and the host configuration.
5. The policy's all-ones tool digest (`control/v1/sandbox.jq:179-182`) is never
   compared with real bytes; the verifier is bound only through the accepted set.
   Replacing that digest stays concern 5's.

### R2. Runtime selection and byte identities

1. **Hypervisor:** Apple Virtualization framework on the operator's Apple silicon host.
   **Front end:** one pinned release of vfkit, used only through the runtime driver.
   The decision's first candidate, Apple Containerization
   (`work/real-sandbox-boundary/spec.md:86-92`), is not selected: its guest init
   serves an in-guest process-control API over vsock, a supervisor endpoint the
   verifier would have to be proven unable to reach, and its images arrive through an
   OCI registry pull and background services. vfkit is one executable with no service
   that boots a given kernel and initramfs with only the devices listed.
2. **Required runtime capabilities** (closed): Linux boot with kernel, initramfs and
   command line; `--cpus`; `--memory`; `virtio-blk` with `readonly`; no device unless
   listed; a REST endpoint on a Unix socket with `GET /vm/state` and `POST /vm/state`
   `HardStop`; a stopped state it reports after guest power-off or hard stop. The
   acquisition request (R13.2a) cites each at the pinned tag's source; a missing one
   returns this spec to G2.
3. **Slots,** each measured by the host supervisor before admission from the installed
   bytes named in its configuration (R10.1), except `verification_instructions`,
   measured from the package's `instruction` record (R4.2). A composite is the SHA-256
   of the canonical document shown; a version name is a label beside a digest, never an
   identity (`work/real-sandbox-boundary/spec.md:45-52`).

| Slot | Bytes measured |
| --- | --- |
| `host_runtime` | `{files:[{path,sha256}]}` over the vfkit executable, the runtime driver, the framework's VM service executable and the arm64e dyld shared-cache files |
| `guest_kernel` | The uncompressed arm64 `Image` handed to the runtime |
| `guest_kernel_config` | `{command_line,cpu_count,devices,kernel_build_config_sha256,memory_bytes}` with R5.4's values and the kernel build config's digest |
| `guest_init`, `guest_supervisor` | Each static executable; the initramfs must contain exactly these two files |
| `image` | The initramfs (`newc` cpio, two entries, uid/gid 0, mtime 0, fixed inode numbers) |
| `host_supervisor` | `{config_sha256,files:[{path,sha256}],python_sha256}` over the installed `host-supervisor.py`, the host configuration and the interpreter |
| `verifier` | The guest-built executable of the unchanged `verifier.c`, default root `/sandbox` |
| `toolchain` | The pinned toolchain archive (R2.5) |
| `verification_instructions` | The package's `instruction` bytes, the same bytes the input disk carries |

4. **Kernel.** One distribution-built arm64 kernel package, identified by its archive
   digest and the digests of the extracted `Image` and build config; the acquisition
   request names distribution, package, URL and digest. Before admission the host
   supervisor refuses a build config lacking any of: `CONFIG_CGROUPS`, `CONFIG_MEMCG`,
   `CONFIG_CGROUP_PIDS`, `CONFIG_CGROUP_SCHED`, `CONFIG_FAIR_GROUP_SCHED`,
   `CONFIG_CFS_BANDWIDTH`, `CONFIG_SECURITY_LANDLOCK`, `CONFIG_SECCOMP_FILTER`,
   `CONFIG_FANOTIFY_ACCESS_PERMISSIONS`, `CONFIG_TMPFS`, `CONFIG_PID_NS`,
   `CONFIG_NET_NS`, `CONFIG_VIRTIO_BLK`, `CONFIG_BLK_DEV_INITRD`, and one of
   `CONFIG_HZ_250`, `CONFIG_HZ_300`, `CONFIG_HZ_1000`. At boot the guest supervisor
   requires Landlock ABI 6 or later, `pids.peak` (Linux 6.1), `memory.peak`,
   `cgroup.kill`, `clone3` with `CLONE_INTO_CGROUP`, and `sched_cfs_bandwidth_slice_us`
   writable; a missing one records the affected rows `unavailable` (R7.3).
5. **Toolchain.** One pinned Zig release archive for macOS arm64, used only as `zig cc
   -target aarch64-linux-musl`: a single archive with bundled musl, no package
   manager. `sandbox/v1/build-guest.py compile <toolchain-dir> <out-dir>` builds
   `init`, `supervisor`, `probe` and `verifier` with exactly `-std=c11 -Wall -Wextra
   -Werror -O2 -static` plus that target, refuses an existing output directory, and
   writes a canonical `sandbox_guest_build` record (source, script, archive and
   executable digests, flags). Two builds in fresh directories must be byte-identical,
   or the plan stops rather than waiving it (as
   `work/fixed-file-digest-verifier/spec.md:38-44`). `build-guest.py image <out-dir>`
   assembles the initramfs of R2.3 deterministically.

### R3. Launch request and package

1. **Request,** kind `sandbox_launch_request`, `schema_version: 1`, canonical, `body`
   exactly `attempt` `{attempt_id, attempt_number}`, `control` (the six fields of
   `work/enforcement-evidence-binding/spec.md:111-113`), `instruction_sha256`, `nonce`
   (64 lowercase hex, 256 bits from operating-system randomness), `store_id` and
   `subject` (the shape of `:114-119`). `launch_request_sha256` is the SHA-256 of these
   canonical bytes. The nonce never enters the guest, the receipt or the store.
2. **Frame format** `YSFRAME1`, shared by the package, the input disk and the export
   disk: the 8 magic bytes, then records of a 1-byte name length, the name, an 8-byte
   big-endian length and the bytes; last a record named `end` whose 32 bytes are the
   SHA-256 of everything before it. Anything after `end` must be zero bytes. Record
   names are a closed set of ASCII names: the ones R3.3, R5.2 and R8.1 list, with
   `candidate/<nnnnn>` and `evidence/<nnnn>` zero-padded decimal indexes in order from
   0. No path is ever a record name: a candidate record's path is the manifest entry (in
   the package) or the plan entry (on the input disk) at its index, a JSON string
   carrying the preparation component's full path range, strict UTF-8 up to 4,096 bytes
   and 64 components, byte for byte
   (`work/candidate-content-preparation/spec.md:262-270`). A frame detects truncation
   and damage; it authenticates nothing.
3. **Package,** read from stdin, at most 88,080,384 bytes: `request.json`,
   `evaluation.json` (the admitting `sandbox_policy_evaluation`), `incident.json` (the
   `shadow_incident_record`, at most 262,144 bytes), `record.json` and `manifest.json`
   (the #396 bundle's), `instruction`, then `candidate/<nnnnn>` for
   the manifest's file entries in manifest order (index 0 is the first file entry),
   then `end`.
4. **Invocation:** `sandbox/v1/host-supervisor.py launch`, no other argument. In
   production the consumer runs it through the sudo rule of R13.3 as the supervisor
   principal; its configuration comes only from `host-config.json` beside the script.

### R4. Admission

1. **Phase A, no receipt.** Exit 65 with one of these on stderr, writing nothing in the
   store: `E_USAGE`; `E_CONFIG` (configuration, install directory, installed control
   files or accepted set fail R10.1 or their shapes, including a placeholder digest in
   the accepted set); `E_STORE` (store root fails R2.3); `E_PACKAGE` (frame, limit,
   order or request shape); `E_STORE_ID` (request `store_id` differs from the
   configuration); `E_NONCE_REUSED` (the file
   `<work_root>/nonces/<sha256 of the nonce bytes>` already exists; it is created
   exclusively first); `E_ATTEMPT_EXISTS` (`<store>/<attempt_id>` exists; nothing is
   touched, per `work/enforcement-evidence-binding/spec.md:64-66`).
2. **Phase B, refusal receipt.** The attempt directory is created exclusively, then
   every check below runs; any failure writes a receipt with `admission: "refused"` and
   `payload/refusal.json` (`{"reason_ids":[...]}`, sorted, unique):
   `launch.identity-missing` (a slot's bytes absent or unreadable: slot `unobserved`
   with that reason), `launch.identity-unaccepted` (a measured digest not in the
   environment's accepted list), `launch.environment-unlisted` (`environment_id` differs
   from the configuration's or is absent from the installed registry or accepted set;
   `environment_entry_sha256` differs from the installed entry's canonical digest;
   `target_repository_id` differs from that entry's), `launch.control-mismatch`
   (`policy_sha256`, `decision_sha256`, `policy_set_sha256`, `evaluator_driver_sha256`
   or `evaluator_program_sha256` differs from the installed file's digest, or
   `sandbox_evaluation_sha256` from the package evaluation's),
   `launch.evaluation-not-satisfied`, `launch.record-mismatch` (record digest differs
   from `subject.candidate.preparation_record_sha256`), `launch.manifest-mismatch`
   (manifest not canonical, or its digest differs from the record's `manifest_sha256`,
   `preparation/v1/prepare-candidate.py:1925`, or from
   `subject.candidate.manifest_sha256`), `launch.subject-mismatch` (any `subject.source`
   field differs from the record's `source`, `subject.candidate.commit_id` or `tree_id`
   from the record's `candidate` (`:1920-1924`); `incident_sha256` differs from the
   package incident's digest; the incident is not canonical with the top-level keys of
   `shadow/v1/incident-record.jq:54-59`, or its `target_repository_id` differs from
   `subject.target_repository_id`, or its `git_revision_ref` from `{repository_id,
   hash_algorithm, commit_id}` of `subject.source`), `launch.candidate-mismatch` (a
   missing, extra, resized or changed file, or a mode or kind differing from the
   manifest entry, `:1662-1677`), `launch.candidate-oversize` (above the preparation
   export limit, `:54`), `launch.instruction-mismatch` (the SHA-256 of the package's
   instruction bytes differs from the request's `instruction_sha256`),
   `launch.instruction-unaccepted` (that digest, which is the
   `verification_instructions` slot, is not in the environment's accepted list),
   `launch.kernel-config` (R2.4). Admission therefore requires three-way equality of the
   supplied bytes' digest, the request digest and an accepted identity, and the receipt
   records the digest of the bytes actually supplied, never an installed or requested
   value. Every other echoed field is bound likewise (`subject` and `control` above,
   `store_id` by R4.1, `launch_request_sha256` computed); only `attempt_id` and
   `attempt_number` are the consumer's own, bound by the exclusive attempt directory
   and the expectation.
3. Otherwise the attempt is admitted; admission is the instant the host deadline clock
   (R9.1) starts.

### R5. Freezing the candidate and the guest inputs

1. **Freeze by copy.** The package bytes are copied into supervisor-owned files and
   checked there, so a later change by the consumer's account cannot reach the guest.
   The source Git directory, checkout, record, manifest and all bundle metadata stay
   host-side; only candidate file bytes enter the guest.
2. **Input disk** `<work_root>/<attempt_id>/input.img`, mode `0400`, a frame of
   `plan.json`, `instruction` (the admitted package bytes), `verifier` and
   `candidate/<nnnnn>` records, padded to a 512-byte multiple, attached read-only.
   `plan.json` (kind `sandbox_guest_plan`) carries the argv, the four variables, the R7
   parameters, the candidate entries in index order (path, kind, mode, size, SHA-256),
   and the verifier and instruction digests; no host path, store id or nonce. The guest
   supervisor refuses instruction bytes whose digest differs from the plan's.
3. **Export disk** `<work_root>/<attempt_id>/export.img`, 12,582,912 zero bytes,
   attached read-write, read by the host only after the VM is stopped (R8).
4. **VM shape,** closed: 1 vCPU; memory 536,870,912 bytes; the kernel, initramfs and
   command line `console= quiet lsm=landlock rdinit=/init`; the two disks. No network,
   shared directory, vsock, serial or console, balloon, entropy, graphics, input, USB
   or Rosetta device. No image is pulled during an attempt.
5. **Guest start.** `init` mounts `proc`, `sysfs`, `devtmpfs` and `cgroup2` and execs
   `supervisor`. The supervisor checks the input frame and every record against
   `plan.json`, materializes the candidate into a tmpfs sized for exactly its files,
   every file and directory owned by uid and gid 65534 (set with `fchown` before the
   read-only remount) with the manifest modes kept (files `0400` or `0500`, directories
   `0500`, `preparation/v1/prepare-candidate.py:1662-1677`), so the dropped identity of
   R6.1 can read it and cannot write it; then it remounts the tmpfs read-only. The
   verifier goes onto a read-only tools tmpfs, owned by root, mode `0555`.

### R6. Starting the verifier

1. The guest supervisor starts the verifier with `clone3` into the tree cgroup
   (`CLONE_INTO_CGROUP`) and new PID, mount, network, IPC and UTS namespaces. In the
   child: a tmpfs root holding only `/sandbox/candidate` (`ro,nosuid,nodev,noexec`),
   `/sandbox/tools` (`ro,nosuid,nodev`), `/sandbox/scratch` and `/sandbox/evidence`
   (`nosuid,nodev,noexec`), then `pivot_root`; no `/proc`, `/dev` or `/sys`; uid and
   gid 65534, no supplementary groups, all capabilities dropped, `no_new_privs`,
   `RLIMIT_CORE` 0, `SCHED_OTHER` with `RLIMIT_RTPRIO` 0.
2. **Landlock,** handling every filesystem right of ABI 6 and scoping abstract Unix
   sockets and signals, granting exactly: candidate `READ_FILE`, `READ_DIR`; tools
   `EXECUTE`, `READ_FILE`, `READ_DIR`; scratch `READ_FILE`, `READ_DIR`, `WRITE_FILE`,
   `MAKE_REG`, `MAKE_DIR`; evidence `WRITE_FILE`, `MAKE_REG`.
3. **seccomp,** default allow, `EPERM` for this closed list: `socket`, `socketpair`,
   `mknod`, `mknodat`, `fallocate`, `truncate`, `ftruncate`, `lseek`, `pwrite64`,
   `pwritev`, `pwritev2`, `openat2`, `open_by_handle_at`, `name_to_handle_at`, `splice`,
   `vmsplice`, `tee`, `sendfile`, `copy_file_range`, `io_uring_setup`, `io_uring_enter`,
   `io_uring_register`, `io_setup`, `io_submit`, `userfaultfd`, `perf_event_open`,
   `bpf`, `ptrace`, `process_vm_readv`, `process_vm_writev`, `linkat`, `symlinkat`,
   `mount`, `umount2`, `pivot_root`, `move_mount`, `open_tree`, `fsopen`, `fsmount`,
   `unshare`, `setns`, `clone3`, `keyctl`, `add_key`, `request_key`, `acct`, `swapon`;
   `openat` with `O_TMPFILE`; `madvise` with `MADV_REMOVE`; `clone` with any
   `CLONE_NEW*` flag. The filter checks `AUDIT_ARCH_AARCH64`.
4. **Wiring,** as `work/fixed-file-digest-verifier/spec.md:58-78` requires: argv after
   `argv[0]` exactly `verify --candidate /sandbox/candidate --evidence
   /sandbox/evidence`; environment exactly the four entries of
   `control/v1/sandbox.jq:161-163`; fd 0 the instruction bytes as a regular file opened
   read-only from the supervisor's private tmpfs; fd 1 and fd 2 files opened
   `O_WRONLY|O_APPEND` on the output tmpfs (R7); every other descriptor closed.

### R7. Limits

1. Bounds, windows and observers are the R6 table's
   (`work/enforcement-evidence-binding/spec.md:206-213`), unchanged. The host records
   `wall_time_ms`; the guest supervisor records the other five.

| Row | `mechanism_id` | Mechanism | `observed` and `resolution` |
| --- | --- | --- | --- |
| `cpu_time_ms` | `mechanism.cpu.single-vcpu-quota-deadline.v1` | 1 vCPU; tree `cpu.max` `45000 100000`, `cpu.max.burst` 0, bandwidth slice 1,000 µs; tree lifetime ends by the host stop at 50,000 ms (R9.1) | `cpu.stat` `usage_usec` rounded up to ms; 1 |
| `wall_time_ms` | `mechanism.wall.host-monotonic-stop.v1` | Host monotonic deadline and hard stop (R9.1) | Admission to confirmed VM stop; 1 |
| `memory_bytes` | `mechanism.memory.vm-ram-ceiling.v1` | Guest RAM equals the bound; no swap, balloon or hotplug device | `memory.peak`; page size |
| `output_bytes` | `mechanism.output.single-tmpfs-append.v1` | stdout, stderr and evidence share one tmpfs of `size=10485760`, `nr_inodes=64`; no seek, positional write, truncate or remove; a fanotify `FAN_OPEN_PERM` mark on the evidence mount allows only the first open of an empty inode | Sum of the three streams' file sizes after tree termination; 1 |
| `process_count` | `mechanism.tasks.cgroup-pids.v1` | Tree `pids.max` 32 | `pids.peak`; 1 |
| `scratch_bytes` | `mechanism.scratch.tmpfs-no-free.v1` | tmpfs `size=` the R12.2 value, `nr_inodes=4096`; no remove, truncate, hole punch, `O_TMPFILE` or `MADV_REMOVE` (R6.2-R6.3) | Used blocks times block size after tree termination; block size |

2. **CPU and wall are `enforcement: "none"` in every receipt.** Both bounds need the
   tree to stop by a known instant, and the only host-side stop, `HardStop`, has no
   known completion bound: the stop is *confirmed* at host time `T_c` when the runtime
   reports the VM stopped and the supervisor has reaped vfkit with `waitpid`, but
   nothing bounds `T_c` after `HardStop` is issued. An attempt that stopped early shows
   only that it stayed under the limits, not that the mechanism prevents overrun
   (`work/enforcement-evidence-binding/spec.md:215-221`). Both rows still record the
   configured mechanism, the observed values and `reached`. **Consequence:** under the
   R8 derivation (`:288-292`), `failure.enforcement-unavailable` makes every admitted
   receipt from this component `failed`; none can be `satisfied` or `violated`. That is
   acceptable for an inactive component. The only path to `hard` is for `vml-qualify`
   (R13.4) to measure and record a `HardStop` completion bound, and then a G2 amendment
   of this spec to adopt it. Given such a bound `B`, CPU would be at most 0.45 (50,000 +
   `B`) + 45 + 9 ceil((50,000 + `B`)/100) ms, from the 45% quota with one quota of
   carry-in and at most 9 ms overrun per 100 ms period (bandwidth slice plus a tick at
   `CONFIG_HZ` 250 or more), and wall would be at most 50,000 + `B` ms. Memory: the tree
   cannot hold more memory than the guest has. Output and scratch: the size limit
   refuses allocation beyond it, and with every free and overwrite path denied, final
   usage equals peak usage and the streams' final sizes equal the bytes written, so the
   after-termination value is complete. A native probe result above any of these
   arguments (R13.4) keeps the mechanism out of the accepted set, and the row stays
   blocked.
3. **Recording.** `enforcement: "hard"` only when every configured parameter was read
   back after setup; `unknown` when one could not be read back; `none` when the
   mechanism is known absent (for example the runtime cannot hard-stop). `observation:
   "complete"` only for a counter read after confirmed tree termination; `partial` for
   one read before it; `unavailable` (with `observed: null`) for a counter not read.
   CPU and wall are always `none` (R7.2). `reached` is true when `observed` is at or above
   `bound`, and also for: CPU, never otherwise; wall, the guest tree deadline fired or
   the host stop was issued (the wall row is then `observed: null`, `unavailable`, if
   the stop was never confirmed); memory,
   `memory.events` `oom_kill` above 0; output and scratch, zero free blocks at the end;
   tasks, `pids.events` `max` above 0. A refused attempt records every row `unavailable`
   and `unknown`, `reached: false`, with its configured mechanism and resolution. No
   bound is raised, and no unknown or partial value is recorded as a pass.

### R8. Guest-to-host channel and payload

1. Before export the guest supervisor requires every regular file on the output tmpfs to
   have link count 1 and a distinct inode number; otherwise the output row is
   `observation: "partial"`. After confirmed tree termination it writes one frame to the
   export disk: `report.json`, `stdout`, `stderr`, `evidence/<nnnn>` (four-digit index,
   one per evidence file), `end`; then it syncs and powers off. That disk is the only
   channel. The verifier cannot reach it: it is outside the verifier's mount namespace
   and Landlock rules, and the verifier has no socket. Nothing flows from host to guest
   after boot.
2. `report.json`, kind `sandbox_guest_report`, `body` exactly: `plan_sha256`,
   `verifier_started`, `exit_state`, `exit_code`, `tree_terminated`,
   `tree_deadline_fired`, `limits` (the five guest rows: `observed`, `observation`,
   `enforcement`, `reached`, `resolution`), `evidence_files` (`[{index, name_hex,
   size_bytes}]`), `stdout_bytes`, `stderr_bytes`. The host requires the plan digest,
   the sizes and the output sum to match its own reading of the frame; otherwise, or
   when the frame is absent or damaged, every guest row is `unavailable` and
   `lifecycle.runtime` is `error`.
3. The host computes `stdout_sha256` and `stderr_sha256` from the exported bytes, and
   `evidence_manifest_sha256` as the SHA-256 of the canonical `sandbox_evidence_manifest`
   (`body.files: [{name_hex, sha256, size_bytes}]`, sorted by `name_hex`). A refused
   or not-started attempt binds empty streams and `files: []`. Payload content never
   changes a verdict.
4. Host-only observations: all ten identities, `wall_time_ms`, teardown, timing,
   `lifecycle` and payload digests. The guest supervisor's rows come only from R8.2.

### R9. Deadlines, cancellation, teardown and lifecycle

1. **Clock** from admission, host monotonic: the guest supervisor kills the tree with
   `cgroup.kill` 40,000 ms after verifier exec (guest monotonic) and waits for
   `cgroup.events` `populated 0`; the host issues `HardStop` at 50,000 ms if the VM is
   not stopped; at 58,000 ms without a confirmed stop it sends `SIGKILL` to the runtime
   process and records the stop unconfirmed.
2. **Cancellation:** `SIGINT`, `SIGTERM` or `SIGHUP` after admission takes the
   `HardStop` path at once. It records `lifecycle.runtime: "error"`.
3. **Teardown.** `tree_terminated` is true iff the runtime reported the VM stopped and
   its process exited and was reaped. `storage_destroyed` is true iff the host removed
   exactly the entries it created in `<work_root>/<attempt_id>/` (the two disks, the
   REST socket, the runtime log) and then the directory, and `lstat` confirms absence;
   an unexpected entry is left in place and makes it false. `state` is `confirmed` iff
   both are true, `failed` iff a stop or remove call returned an error, else
   `unconfirmed`. Nothing outside that directory is stopped or removed.
4. **Lifecycle.** `runtime: "error"` iff the runtime reported an error, R8.2 failed,
   `verifier_started` is false, the host issued `HardStop`, or the attempt was
   cancelled. `control_deadline: "exceeded"` iff runtime start took more than 10,000
   ms, or export reading, storage removal or payload writing each took more than 5,000
   ms. The receipt write itself cannot record its own overrun; if it fails, R10.4
   applies.
5. **Timing and finalization.** `admitted_at` is UTC seconds at admission.
   `terminated_at` is UTC seconds at the confirmed stop; for a refused attempt, the
   refusal instant; for an unconfirmed stop, the instant the supervisor abandons
   confirmation, which is when it sends `SIGKILL` at 58,000 ms (R9.1). It does not wait
   again. That receipt then records `teardown` `{state: "unconfirmed", tree_terminated:
   false}` with `storage_destroyed` as found, `lifecycle.runtime: "error"`, the wall row
   `unavailable`, the CPU and wall rows `enforcement: "none"`, and, since no guest report
   exists, `exit_state: "not-started"` with `exit_code: null` and empty payload streams.
   The receipt contract permits `not-started` only with `runtime: "error"`
   (`work/enforcement-evidence-binding/spec.md:143-146`), and here it means that no
   verifier exit was observed. The receipt contract has no distinct "exit unobserved"
   value, and adding one would be an `enforcement/v1` change (a return-to-G2
   dependency); every such receipt is `failed` anyway.

### R10. Configuration, store and receipt

1. **Trusted configuration** `host-config.json` (kind `sandbox_host_config`) beside
   `host-supervisor.py`, `body` exactly: `principal_uid`, `consumer_gid`, `store_id`,
   `store_root`, `work_root`, `environment_id`, `runtime` (vfkit and driver paths),
   `identity_paths` (the installed file for each R2.3 input but the instruction) and
   `installed_files` (paths of the installed control policy, decision, policy set,
   evaluator driver and program, registry and accepted set). The install directory,
   every ancestor and each listed file must be owned by uid 0 or `principal_uid` and be
   neither group- nor other-writable; `store_root` and `work_root` must be outside every
   `/sandbox/*` root and never attached to the guest.
2. **Store writes,** under `work/enforcement-evidence-binding/spec.md:56-75`: directories
   `0750` and files `0440`, owner `principal_uid`, group `consumer_gid` (inherited from
   the parent or set with `fchown`, then verified), no ACL (Darwin
   `acl_get_fd_np(ACL_TYPE_EXTENDED)` through `ctypes`; Linux
   `system.posix_acl_access` and `system.posix_acl_default`), each file created
   `O_CREAT|O_EXCL|O_NOFOLLOW` relative to its directory descriptor, fsynced, link count
   1. Order: `<attempt_id>/`, `payload/` with `stdout`, `stderr`,
   `evidence-manifest.json`, `evidence/<nnnn>` and, when refused, `refusal.json`; then
   `receipt.json`; then fsync of every directory up to the store root.
3. **Receipt:** canonical bytes at most 1,048,576; `origin` `{producer_role:
   "host-supervisor", store_id, accepted_set_sha256}` from the installed set; `outcome`
   by the R8 derivation (`work/enforcement-evidence-binding/spec.md:283-300`),
   computed by the host supervisor and proven equal to the check's.
4. **Exit statuses,** closed: `0` receipt written, any verdict; `65` phase A; `70` a
   receipt could not be written after the attempt directory existed (no second
   receipt is ever attempted, `:64-66`).

### R11. Boundary map

Every row of `work/real-sandbox-boundary/spec.md:104-116`. The producer is the host
supervisor, reading the guest supervisor's rows through R8. No row is proven until
R13.4.

| Row | Mechanism (requirement) | Evidence recorded | Observation limit |
| --- | --- | --- | --- |
| Candidate-only reads, immutable source | Copy freeze, digest chain, read-only tmpfs, Landlock (R5, R6) | Subject, `launch.*` refusals | Guest kernel trusted |
| Cleared environment, fixed verifier | R6.4 wiring, slots `verifier` and `verification_instructions` | Identities; exit state | Relies on R6 |
| No host or sibling access | No share, private root, uid 65534, namespaces (R5.4, R6.1) | Probe sentinels (R13.4) | Probes only |
| Network denied | No NIC, network namespace, `socket` denied (R5.4, R6.3) | Probe results | Probes only |
| CPU, wall, memory, tasks, output | R7 | R7 rows | R7.2 arguments |
| Write-only evidence | Landlock rights, first-open fanotify rule, seccomp (R6.2-R6.3, R7) | Probe results | Probes only |
| Complete cleanup | R9.3 | `teardown` | Framework VM service ends with the runtime; R13.4 checks no VM process remains |

Supervisor resource bounds (host supervisor and runtime processes, guest supervisor and
kernel inside the 536,870,912-byte guest) are measured at qualification and accepted,
or not, in R13.4; their exclusion from the tree is not unbounded use.

### R12. Environment and registry

1. **Qualified first:** a new entry, appended to `shadow/v1/shadow-environments.json`,
   exactly `{"description":"Operator's Apple silicon macOS host, Apple Virtualization
   framework Linux guest VM, scrubbed bare copy of the external dummy target
   repository.","environment_id":"env.local-macos-vm-dummy-target","evidence_scope":
   "external-target","proof_state":"unproven","source_root_commit":
   "c1cacf5a1dbcc5030d66ecd300bf0b115c792e99","target_repository_id":
   "repo.ystack-dummy-target"}`, in canonical form. It inherits nothing from
   `env.local-macos-dummy-target` (`work/real-sandbox-boundary/spec.md:68-74`). It is
   the step-8 first target's repository
   (`work/step8-bounded-write-readiness/spec.md:27-29`), so one qualification serves
   concerns 5-7; a fixtures-only VM entry would need a second qualification and prove no
   more containment, because probe executables, not candidate bytes, supply adversarial
   behaviour. Registering an `unproven` entry is within the program authorization
   (`work/roadmap-program-authorization/decision.md:304-307`).
2. **`scratch_bytes` = 16,777,216.** The verifier never touches scratch
   (`work/fixed-file-digest-verifier/spec.md:65-69`), scratch lives in guest RAM next to
   the candidate (at most 64 MiB), tools and output (10 MiB), and a multiple of both
   4 KiB and 16 KiB pages keeps the bound exact.
3. The only `shadow/v1/**` changes are that append (with `proof_state: "unproven"`) and,
   after R13.4 and the R7.2 amendment only, that entry's `proof_state` changed to
   `"native-qualified"`. The only `enforcement/v1/**` change is, at that same point,
   appending that environment's
   entry to `accepted-identities.json` under
   `work/enforcement-evidence-binding/spec.md:171-177`.

### R13. Reserved decisions

1. Each is a separate operator decision request on #463 with its own id, since
   `AGENTS.md:44-48` reserves installation and new network scope to the operator.
   Requests are posted only when their package is reviewed and merged, in the order
   R13.2a, R13.2b, R13.3, R13.4. Nothing enables before all four are approved. Plan
   steps 1-4 (R14.4) are inactive and CI-tested with the fake runtime. Step 5 waits for
   R13.2a, step 6 for R13.2b, step 7 for R13.3, step 8 for R13.4, and step 9 also for
   the G2 amendment of R7.2.
2. Intent decision 1 is split into two requests, because the install request must
   quote measurements that only an acquisition can produce.
   - **a. `vml-acquire`:** the vfkit tag and asset, the kernel package (distribution,
     name, version) and the Zig archive, each with its URL and the publisher's stated
     digest; the exact endpoint hosts; the quarantine directory
     `~/ystack-quarantine/vml/` under the operator's account, outside every install
     prefix; R2.2 evidence cited from the tag's source. It authorizes only downloading
     those exact artifacts there, refusing any byte whose digest differs; extracting
     the kernel `Image` and config and running the R2.4 check; read-only measurement of
     the macOS build and the `host_runtime` system files; and running the pinned Zig
     only to build the guest twice there (R2.5). Nothing else is executed: no vfkit
     run, no VM boot, and nothing installed into any supervisor prefix.
   - **b. `vml-install`:** quotes every quarantine measurement (artifact, extracted and
     twice-built digests, R2.4 result); names every host path created (no service,
     daemon, kernel extension, profile or system setting); and copies only those
     measured bytes there, re-measured on arrival. It uses no network. Rollback is
     deleting the listed paths and the quarantine directory. No VM boots under it.
3. **`vml-trust-root`** (intent decision 3): the supervisor account name and uid, the
   consumer group name, gid and sole member, the exact `/etc/sudoers.d` file allowing
   only `host-supervisor.py launch` as that account, the install directory and its file
   digests, the exact `host-config.json`, store and work roots with owners and modes,
   and the question of `work/enforcement-evidence-binding/spec.md:88-92` verbatim. A
   signing credential instead returns this spec to G2, since the store rule changes.
4. **`vml-qualify`** (intent decision 2): the R12.1 entry bytes; the proposed
   accepted-set entry bytes (ten slots, six mechanism ids, `scratch_bytes`); the probe
   list with expected receipt outcomes: the real verifier on match, mismatch and one
   changed-byte refusal, the `HardStop` completion latency over repeated forced stops
   (R7.2), and `probe` modes for candidate reads under the dropped identity, candidate
   and tools writes, evidence read, list, reopen, truncate, link and rename, scratch
   free paths, scratch fill, output overflow, each socket family, host and sibling
   sentinels, environment and descriptors, fork and thread bombs, a 32-thread CPU spin,
   memory exhaustion, sleep, signalling the supervisor, namespace and cgroup escape, and
   forged report text on stdout and evidence; the candidate source (the scrubbed
   dummy-target copy at its step-7 commit); synthetic sentinel locations; the separate
   qualification install directory and accepted set, removed afterwards; supervisor
   resource measurements. Approval authorizes only that run and its qualification
   record. The R12.3 changes land in one reviewed PR only after a G2 amendment adopts a
   measured `HardStop` bound, since before that no receipt can be `satisfied` (R7.2).

### R14. Inactivity and files

1. Each bounded action is permitted only after its own approval, and only as that
   request names it: acquisition, quarantine measurement and builds after `vml-acquire`;
   installation after `vml-install`; the account, sudo rule and store after
   `vml-trust-root`; VM boots, probes and the qualification record after `vml-qualify`;
   the R12.3 PR after the R7.2 amendment as well. No credential, model call, target
   execution beyond R13.4, activation or write is ever authorized here. Production use
   stays blocked until every gate has passed. Until then it refuses by construction: no
   host configuration exists, and the shipped accepted set is empty.
2. Byte-identical except as R12.3 and R14.3 name: `config/**`, `control/v1/**`,
   `enforcement/v1/**`, `verifiers/file-digest/v1/**`, `preparation/v1/**`,
   `shadow/v1/**`, `scope/v1/**`, `evals/v1/**`, `adapters/**`, `ROADMAP.md`,
   `AGENTS.md`, `REVIEW.md`, `NORTH_STAR.md`, `.github/**`, `scripts/merge-pr.sh`,
   `scripts/codex-review.sh`, `scripts/test/run-all.sh`, `scripts/lib/*.sh`, and every
   existing test script except `scripts/test/shadow-slice.test.sh`.
3. **Create exactly:** `sandbox/v1/host-supervisor.py`, `sandbox/v1/runtime-vfkit.py`,
   `sandbox/v1/build-guest.py`, `sandbox/v1/qualify.py` (each mode 100755),
   `sandbox/v1/guest/common.h`, `sandbox/v1/guest/common.c`, `sandbox/v1/guest/init.c`,
   `sandbox/v1/guest/supervisor.c`, `sandbox/v1/guest/probe.c`,
   `scripts/test/sandbox-launcher.test.sh`, `scripts/test/sandbox-guest.test.sh`,
   `scripts/test/sandbox-fake-runtime.py` (each mode 100755),
   `scripts/test/sandbox-guest-harness.c`, and in step 9 only
   `sandbox/v1/qualification/env.local-macos-vm-dummy-target.json`. **Change exactly:**
   `shadow/v1/shadow-environments.json` and `enforcement/v1/accepted-identities.json`
   (R12.3); `scripts/test/shadow-slice.test.sh:343-367` (the expected registry gains
   the R12.1 entry, and later its `proof_state`; the pass message counts four
   environments); `docs/components.md` (a section after `## Inactive sandbox receipt
   check`, and the registry paragraph at `:1448-1456`); `RESTORE.md` (one subsection);
   `ci/required-files.txt` (one block after `# Inactive sandbox receipt check` listing
   the created files and this slug's intent, spec and plan); and
   `work/vm-launcher-supervisor/plan.md`. No executable or disk image is committed.
4. **Steps:** 1 frame format, `common.c` and the guest harness; 2 host supervisor and
   fake runtime; 3 guest init, supervisor, probe and `build-guest.py`; 4 runtime driver,
   `qualify.py`, the R12.1 append, docs, restore and manifest; 5 R13.2a's acquisition
   and quarantine builds; 6 R13.2b's installation (5 and 6 make no repository change);
   7 R13.3's host setup (no repository change); 8 the qualification run; 9 the R12.3
   qualification PR.

### R15. Tests

1. `scripts/test/sandbox-launcher.test.sh` runs the host supervisor from a temporary
   install directory whose configuration names the test account as principal and its
   primary group as consumer, with `sandbox-fake-runtime.py` as runtime, a fixture
   store under `mktemp`, synthetic identity files and a test-only accepted set listing
   their digests for `env.local-macos-fixture`. The R10.1 and R2.3 metadata checks run
   unchanged; only the account differs. It refuses to run as uid 0. The fake runtime
   implements the driver interface and plays scripted guest outcomes into the export
   disk. Each denial has a paired positive control. It proves:
   - each phase A error, including a placeholder digest in the accepted set, nonce
     reuse, and an existing attempt left byte-identical;
   - each phase B reason alone, including changed and missing bytes per slot, and
     manifest, record and candidate mismatch;
   - each of the twelve `subject` and six `control` leaf fields mutated alone in the
     request, artifacts intact, refuses with its R4.2 reason and is never admitted;
   - instruction binding: replacing the package instruction and the request's
     `instruction_sha256` together with an unaccepted instruction refuses with
     `launch.instruction-unaccepted`, and the receipt records the replaced bytes'
     digest (so the check gives `receipt.identity-unaccepted`); replacing only one of
     them refuses with `launch.instruction-mismatch`; the positive control uses an
     accepted instruction;
   - candidate transport of `README.md`, a non-ASCII UTF-8 name and a 4,096-byte
     64-component path, byte for byte into `plan.json`;
   - the input disk's `plan.json` carries exactly the R6.4 argv, variables and
     instruction bytes, and no nonce, host path or store id;
   - for the four guest rows other than CPU, `hard`, `none` and `unknown`; for all six
     rows, `partial` and `unavailable` observation and `reached`; CPU and wall are
     `none` in every case;
   - success, violation, refusal, guest deadline, host `HardStop`, cancellation, runtime
     error, damaged or absent export, and storage removal failure (an unexpected entry);
   - a delayed stop: a fake runtime that ignores `HardStop` and never reports stopped
     yields the R9.5 finalization at the 58,000 ms abandonment (never a confirmed
     stop), CPU and wall `enforcement: "none"`, and `failed`; a self-stopped control
     confirms its stop but still records both `none`. These cases run in real time,
     concurrently;
   - store modes, owner, group, link counts and exclusivity after every case;
   - against the merged check in a temporary repository copy with the test-only set,
     the expectation built from the request as the consumer builds it and the package
     evaluation as evaluation input, every case in exactly one class, each expected
     set being what `enforcement/v1/sandbox-receipt.jq:526-545` reports for it:
     (a) *binding refusals*, `refused`: `launch.evaluation-not-satisfied` receipts give
     `receipt.evaluation-not-satisfied`; a mutated evaluator driver, program or
     evaluation digest `receipt.control-mismatch`; a mutated policy, decision or
     policy-set digest `receipt.control-mismatch` and `receipt.evaluation-not-satisfied`;
     a mutated `environment_entry_sha256` or `target_repository_id`
     `receipt.environment-unlisted`; an unlisted `environment_id` that and
     `receipt.identity-unaccepted`; a produced receipt against an expectation differing
     only in `launch_request_sha256` `receipt.replayed`, only in `store_id`
     `receipt.origin-mismatch`, and after a digest is added to the accepted set
     `receipt.stale`;
     (b) *identity rejections*, `refused`: `launch.identity-unaccepted` and
     `launch.instruction-unaccepted` receipts give `receipt.identity-unaccepted`; a copy
     with one slot set to the all-ones digest `receipt.placeholder-identity`;
     (c) *lifecycle and enforcement failures*, bindings intact, `valid`/`failed`, every
     admitted receipt carrying `failure.enforcement-unavailable` (R7.2): success,
     violation and guest deadline give that alone; `HardStop`, cancellation, runtime
     error and damaged or absent export add `failure.runtime` and
     `failure.observation-unavailable`; the delayed stop adds those and
     `failure.teardown`; storage removal failure adds `failure.teardown`; a `partial` or
     `unavailable` row adds `failure.observation-unavailable`. Every other phase B
     refusal (identity missing, record, manifest, candidate, subject source, candidate or
     incident fields, instruction mismatch, kernel config) gives
     `failure.launch-refused`, `failure.observation-unavailable` and
     `failure.enforcement-unavailable`: the checker sees only the request's own subject,
     so those refusals are proven by the host alone. Copies edited only to set CPU and
     wall `hard`, outcome recomputed, give `satisfied` and `violated` with the matching
     `limit.*` reason, equal to the host derivation;
   - against the shipped files, every class (c) receipt gives exactly
     `receipt.environment-unlisted`, `receipt.identity-unaccepted` and `receipt.stale`,
     and every class (a) or (b) receipt that set plus its own reasons;
   - receipts equal their `jq -S -c` form, and the host outcome equals the check's;
   - `runtime-vfkit.py` builds exactly the R5.4 vfkit argv and REST calls, against a
     fake `vfkit` executable;
   - `qualify.py` runs its probe list end to end in dry-run against the fake runtime.
2. `scripts/test/sandbox-guest.test.sh` builds `sandbox-guest-harness.c` with `common.c`
   using the host compiler and proves: frame parse and write, including every
   truncation, trailing-byte and `end` digest case; plan parsing; the exec wiring (argv,
   the four variables, fd 0 regular, fds 1-2 append-only, no other descriptor) by
   exec'ing a harness child that reports them; the R8.1 export inventory refusing a
   same-directory hard-link alias of an evidence file, with a single-link positive
   control; candidate records whose plan paths are `README.md`, a non-ASCII UTF-8 name
   and a 4,096-byte 64-component path, each materialized byte for byte, and a record
   name outside the closed set refused; R5.5 materialization with the manifest modes and
   a given owner (the invoking non-root uid): every file reads, and each write, create
   or remove attempt fails with `EACCES` (the uid 65534 read is a R13.4 probe);
   `build-guest.py image` determinism over synthetic inputs, and `compile` refusing an
   existing output directory. On Linux it also compiles `init.c`, `supervisor.c` and
   `probe.c` with `-std=c11 -Wall -Wextra -Werror`; Darwin has no Linux headers, so
   there that case is named as a Linux-only proof and CI's Linux run is its evidence.
3. Must pass unedited: `scripts/test/sandbox-receipt.test.sh`,
   `scripts/test/file-digest-verifier.test.sh`,
   `scripts/test/control-sandbox-policy.test.sh`,
   `scripts/test/candidate-content-preparation.test.sh`,
   `scripts/test/shadow-assembler.test.sh`,
   `scripts/test/shadow-self-host-evidence.test.sh`,
   `scripts/test/scope-qualification.test.sh` and
   `scripts/test/portable-core-schema.test.sh`; `shadow-slice.test.sh` passes with only
   the R14.3 edit. `run-all.sh` discovers new suites by name
   (`scripts/test/run-all.sh:66-69`).
4. **Honestly unproven until R13.4:** every guest mechanism of R5-R7, the runtime,
   the framework's VM lifecycle, two distinct host accounts and the consumer group's
   single membership, and the R7.2 arguments. Tests and docs say these tests prove
   contracts, not the Apple VM boundary (`work/real-sandbox-boundary/spec.md:68-74`).

### R16. Order and review size

1. Depends on concerns 2 (#436) and 3 (#437), both merged. Concerns 5 and 7 consume
   the receipt, store and qualification (`work/step8-bounded-write-readiness/spec.md:295`,
   `:297`).
2. This spec PR: `review_size: accepted-exception`, one concern, this file, 500-660
   lines, for the closed lists one boundary needs in one place (slots, limit and
   boundary rows, seccomp and Landlock sets, four decision packages, test classes). It
   waives only the soft line signal; steps 1-4 ship as standard-size PRs.

## Design

Package on stdin, freeze by copy, measure every byte, admit or refuse with a receipt,
boot a one-vCPU guest with two disks, run the verifier inside namespaces, Landlock and
seccomp, count on monotone filesystems, export one frame, stop, remove only the
attempt's files, write payload and receipt. Guest-side limits are structural, not
polled; CPU and wall stay `none` until a stop-completion bound is measured (R7.2).

## Out of scope

Receipt wiring in the shadow driver and replacing `tool.git-blob-digest` (concern 5);
`scope-gates.jq` and `scope.sandbox-receipt-missing` (concern 6); the policy's tool
digest; any change to the receipt kind, verifier or bundle format; a generic
orchestrator or candidate-code runner; any self-host or write-shadow run.

## Areas of concern

- **Environment id.** Step-8 R1.2 names `env.local-macos-dummy-target` for the first
  scope, but R12.1 creates the receipt-bearing entry the sandbox decision requires.
  Which id the write scope records is concern 5's and 6's choice, not settled here.
- **Narrowed rights.** Scratch is readable and writable but cannot free space, and
  evidence files can be opened once. Both are stricter than the declaration, never
  weaker, and exist so the R6 peak and "counted as written" values are exact.
- **No `satisfied` receipt yet** until G2 adopts a measured `HardStop` bound (R7.2); a
  weaker standard returns to the operator (`work/real-sandbox-boundary/spec.md:118-124`).
- **Trusted host.** Origin rests on the supervisor account and administrator (R13.3).

Intent open questions, answered: pinning (R2); mechanisms and `none` rows (R7, R11);
read-only candidate (R5); guest-to-host channel (R8); placement, language, supervisor
identity (R1, R2.3); first environment, `scratch_bytes` (R12); fixture stores and what
stays unproven (R15); operator requests and order (R13).
