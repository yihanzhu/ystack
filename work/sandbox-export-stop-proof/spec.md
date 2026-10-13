---
intent-blob: 20030b434bcb866f1d625cfac1e572351a51908e
risk: routine
drafted: 2026-10-13
---

# Spec: prove export before an unconfirmed stop

Tracks #552. This repair makes the existing sandbox-launcher Finding 6 reach and
prove its intended fixture phase. It does not change production behavior.

## Requirements

### R1. Closed fixture phase

1. The target case uses the existing fake runtime and launcher harness. Its
   scenario combines the existing `hardstop_writes_export` and
   `hang_after_export` behaviors so an early HardStop cannot take the normal
   stopped-and-return branch before export.
2. The harness gives that case one fresh attempt id and one fresh phase-record
   path inside its test-owned temporary tree. It proves the path is absent before
   launch. No other case may reuse either value.
3. The fake runtime writes the record only after `frame_write` has produced the
   complete frame, the complete frame has been written to the export file, and
   the export file has closed successfully. It writes the record before entering
   the deliberate hang. An exception or partial write creates no record.
4. The record is canonical JSON with exactly `schema_version: 1`, the same
   `attempt_id`, `phase: "export-written-closed"`, `frame_size`, and the SHA-256
   of the exact frame bytes. The id is nonempty; size is a positive integer; the
   digest is lowercase SHA-256. Extra, missing, duplicate or malformed fields
   refuse the test.
5. Create the record exclusively as one regular, one-link test file. Flush and
   close it before the hang. Its path and contents are fixture control data only;
   production code never reads or writes them.

### R2. Reliable cancellation sequence

1. Run the launcher in the background under its ordinary host deadline. Capture
   the exact owned launcher process id from that start. Do not discover a process
   by name, pattern, pid file or global scan.
2. Wait for the phase record with a bounded test-only wait. While waiting, require
   that the exact launcher process is still the owned process. Absence, early
   launcher exit, wrong attempt, malformed record or timeout fails the case.
3. After validating the record, request cancellation only through the launcher's
   existing signal entry on that exact owned process. Then wait for that exact
   process. Do not signal the fake runtime directly or add a production callback.
4. The unchanged supervisor remains responsible for driver stop, HardStop,
   bounded SIGKILL, descendant cleanup and exact reap. Keep its normal deadline,
   stop confirmation rules and receipt lifecycle. Do not make the test pass by
   enlarging only the old 100/200 ms race window.
5. The launch command must still exit through the existing test contract. The
   resulting receipt must report `tree_terminated: false`; every guest-derived
   observation, including CPU, remains unavailable; the valid export remains
   unread. `tree_terminated: true` is a failure for this case.

### R3. Diagnostics and compatibility

1. Before fixture cleanup, retain and print one bounded diagnostic set for the
   target attempt: the exact attempt id, owned launcher pid, phase record bytes,
   receipt bytes when present, launcher status, and existing stderr/runtime facts.
   Missing receipt or phase evidence remains visible as failure evidence.
2. The phase record proves only that this fake runtime completed export write and
   close. It is not a VM, native qualification, CPU/wall, identity, receipt or
   authorization fact and cannot satisfy another test.
3. Preserve every existing Finding 6 refusal assertion and all confirmed-stop,
   self-stop, early-HardStop, timeout, cancellation and reap controls in the full
   launcher suite. Do not skip, retry away or reclassify a failure.
4. The 2026-10-13 full-matrix failure keeps exact cause `UNKNOWN`. This repair
   prevents the same ambiguity in new runs; no new result rewrites old evidence.

## Design boundary

Implementation changes only:

- `scripts/test/sandbox-fake-runtime.py`
- `scripts/test/sandbox-launcher.test.sh`

The runtime receives only the closed target-case scenario fields. The marker is a
private fixture branch beside existing scenario behavior, not a general event,
hook or callback. The launcher test owns its path, attempt and process lifecycle.

Do not change `sandbox/v1/host-supervisor.py`, public schemas, production source or
environment handling, native code, workflows, `scripts/test/run-all.sh`, timeout
standards, installation, credentials, networking, VM setup or cleanup outside the
test-owned tree. CPU and wall enforcement remain `none`; native qualification
remains `BLOCKED`; production identities remain empty.

## Acceptance

1. The target case proves absent-before, matching post-close phase evidence,
   cancellation through the exact owned launcher process, unconfirmed stop,
   unread export and unavailable guest facts.
2. Paired negatives cover a missing record, wrong attempt, malformed record and an
   execution that never reaches post-close. Each fails even if final receipt
   fields resemble the intended refusal.
3. Existing confirmed-stop and early-HardStop controls still pass unchanged.
4. Run the affected case, the complete `scripts/test/sandbox-launcher.test.sh`,
   and the relevant full matrix from the exact reviewed head. Retain complete raw
   output and obtain an independent exact-head G3 review before protected merge.
