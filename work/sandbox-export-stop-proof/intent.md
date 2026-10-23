# Intent: prove export before an unconfirmed stop

Author: Codex, intent author at the operator's direction. Status: draft.

## Problem

Sandbox launcher Finding 6 is meant to exercise one state: the fake runtime has
finished writing a valid export, then stays alive, and the supervisor refuses to
read that export because stop was not confirmed.

The fixture does not prove it reached this state. Its short HardStop can arrive
before export is written. A no-spawn or other early-stop path can also produce the
observed `tree_terminated: true` and unavailable guest facts. The failed
full-matrix run remains valid, but its exact execution branch is `UNKNOWN`.
A passing rerun or unchanged production source cannot establish the missing
precondition.

## Desired outcome

Finding 6 proves its precondition with an attempt-unique fixture record. The fake
runtime creates it only after the complete export frame is written and closed,
and before the deliberate hang. The test proves it was absent before launch and
matches the same attempt afterward.

The original refusal remains exact: an unconfirmed stop keeps
`tree_terminated: false`, guest facts unavailable, and the export unreadable. A
missing or mismatched record fails. Existing successful-stop and normal HardStop
controls keep their assertions. The historical failure remains unknown.

## Affected users and systems

Maintainers and reviewers get a reliable regression for the existing
stop-before-read rule. Later implementation is limited to these test paths,
subject to G2 and plan review:

- `scripts/test/sandbox-fake-runtime.py`
- `scripts/test/sandbox-launcher.test.sh`

## Constraints

Production supervisor behavior, public interfaces, native qualification, timing
and stop rules, and existing launcher tests remain unchanged. CPU and wall
enforcement remain `none`; native qualification remains `BLOCKED`; production
identities remain empty.

Any phase record stays in the test-owned temporary tree, binds the same attempt,
and is removed by fixture cleanup. It proves only that the fake runtime crossed
its write-and-close boundary. It is not a native positive, VM receipt,
authorization fact, production callback, or reusable control channel.

Do not accept `tree_terminated: true`, increase deadlines alone, retry away the
failure, skip the case, weaken export-read gating, or use a mock positive. No
installation, activation, VM, credential, network, workflow, run-all, or unrelated
cleanup change is included.

## Proof

Run the export-then-hang case with its attempt-bound post-write record and retain
its refusal assertions. Pair it with the existing confirmed-stop controls. Run
the complete sandbox launcher suite and relevant full matrix from the exact
reviewed head. Preserve the original failed log and its unknown cause.

## Open questions

G2 must select the smallest fixture sequence and closed record shape that cannot
be emitted before export close or reused by another attempt. The plan must bind
the exact tests and diagnostics without adding a production hook.
