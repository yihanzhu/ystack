---
spec-blob: 2de022dfca23d2911dcba2fabfe8584a1b35bafc
risk: routine
drafted: 2026-10-13
---

# Plan: prove export before an unconfirmed stop

Tracks #552. Implement this one test repair on
`codex/impl/sandbox-export-stop-proof` after an independent routine-plan check of
this exact plan-only head. Implementation `review_size: standard`.

## Scope

Change only:

- `scripts/test/sandbox-fake-runtime.py`
- `scripts/test/sandbox-launcher.test.sh`

Keep the production supervisor, driver, schemas, environment policy, deadlines,
receipt format, workflows and `scripts/test/run-all.sh` unchanged. The private
record supplies no production, VM, native, identity, authorization, CPU or
wall-time fact. Native qualification remains `BLOCKED`; CPU and wall enforcement
remain `none`; production identities remain empty.

## Implementation

### 1. Publish one closed post-export record

Extend only the existing fake-runtime scenario with a fixed phase-record path and
attempt id for Finding 6. Reject missing, non-string or empty values; add no
other phase field, environment variable, public argument, callback or event API.

After `frame_write(records)` returns and the complete frame has been written to
and closed in the export image, build one canonical JSON object with exactly:

- `schema_version: 1`
- the scenario's `attempt_id`
- `phase: "export-written-closed"`
- `frame_size` equal to `len(frame)`
- `frame_sha256` equal to lowercase SHA-256 of those exact frame bytes

Bound the serialized record to 512 bytes. In the test-owned directory, create a
unique staging file with exclusive create and mode `0600`; write all bytes, flush,
`fsync`, close, and verify it is a regular file with one link. Publish to the
absent final path with an exclusive same-directory hard link, then unlink the
staging name. The reader accepts only after the final file is regular, has one
link, and contains the complete canonical bytes. This prevents a partial record
from becoming the synchronization event and never overwrites an existing path.
Any write, close, sync, link, stat or cleanup error fails the fake runtime.

Combine `hardstop_writes_export: true` and `hang_after_export: true` in the target
scenario. Publish the record before entering that hang. An exception, damaged or
partial export, or any path that never completes export close publishes nothing.

### 2. Own the launcher and cancel only after proof

Replace Finding 6's synchronous `run_launch` call with one fixed, single-threaded
Python orchestration block embedded in `sandbox-launcher.test.sh`; do not change
the shared helper. It opens the package as stdin and the existing output files as
stdout/stderr, then creates exactly this direct child:

```text
cwd = install_dir
argv = [python, "host-supervisor.py", "launch"]
env = a copy of the established harness environment with only
      YSTACK_FAKE_SCENARIO set to this case's fixed scenario path
```

Use `subprocess.Popen` directly. The helper alone owns and waits for that child;
no thread, signal handler or other code may reap it. The one Popen object binds
poll, signal and wait to that direct child. Do not use `run_launch`, a wrapper
PID, `kill -0`, process names, pid files or a global process scan as ownership.

Before launch, create a fresh attempt id and fresh phase path in the case's owned
tree and prove the final and staging names absent. Poll only that path for a fixed
10 seconds, below the unchanged 50-second HardStop deadline. First use
`Popen.poll()` to refuse an early exit. Read at most 512 bytes with `O_NOFOLLOW`;
require a regular one-link file, strict UTF-8 JSON without duplicate or extra
keys, canonical byte equality, the exact attempt and phase, positive bounded
size, and a 64-character lowercase hex digest.

After a valid record, call `Popen.send_signal(SIGTERM)` on that still-owned,
unreaped child. This is the launcher's existing cancellation entry. Never signal
the fake runtime or a descendant directly. Wait once with a fixed 65-second
ceiling and retain the exact status. On any fixture failure, still cancel and
wait for that child so the supervisor performs its normal stop, bounded kill,
cleanup, receipt finalization and reap; a ceiling breach kills and reaps only the
owned launcher as failed-test cleanup.

Run this case under the normal 50,000 ms HardStop and 58,000 ms SIGKILL
deadlines. Preserve the existing paired real-time controls and their 55–65 second
timing assertion. Do not lengthen a deadline, retry, or use timing as proof.

### 3. Assert the refusal and closed negatives

For the real target run, validate the size and digest fields but do not read the
export in the harness. Retain the existing successful launcher status,
`tree_terminated: false`, unavailable CPU and every other guest-derived
observation, and unread-export assertions. A valid record never substitutes for
the receipt or makes the export admissible.

Exercise the same validator with bounded test-owned records for missing, wrong
attempt, duplicate or extra keys, malformed/partial/noncanonical bytes, wrong
size or digest, symlink/nonregular/multilink, and never-post-close. Each refuses.
Retain the absent-before positive and all confirmed-stop, self-stop,
early-HardStop, timeout, cancellation and reap controls without retries or skips.

Before fixture cleanup on any target-case failure, print one bounded diagnostic:
attempt id, owned launcher PID, phase bytes or absence, receipt bytes or absence,
launcher status and existing stderr/runtime facts. Do not rewrite the preserved
2026-10-13 failure; its exact cause remains `UNKNOWN`.

## Proof and delivery

Run the focused repaired case and the complete
`scripts/test/sandbox-launcher.test.sh`. Run pinned shellcheck 0.11.0 with
`-x -S style` on the changed shell file and `git diff --check`. Verify the exact
two-path diff, record byte cap, closed scenario fields, no production hook, no
deadline increase, and preservation of every original Finding 6 assertion.

Run the relevant six-shard full matrix from the exact implementation head and
retain complete output and exits. Automatic pull-request `ci` is the quick gate,
not a substitute for that matrix. Obtain a fresh independent exact-head/base G3
review with no unresolved Important finding before protected merge.
