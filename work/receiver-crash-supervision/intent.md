# Intent: Preserve receiver crash-test evidence and clean up owned processes
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #347. [Intake acceptance](https://github.com/yihanzhu/ystack/issues/347#issuecomment-5718204870).

## Problem

PR #346's original CI run
[35243355489, attempt 1](https://github.com/yihanzhu/ystack/actions/runs/35243355489/attempts/1)
failed with `crash-process-timeout` in the unchanged receiver test. Its readiness
loop allows roughly ten seconds for real materialization and validation. On timeout,
it exits without guaranteed child cleanup and deletes the child's diagnostics.
This blocks unrelated changes and leaves reviewers unable to locate the failure.

The retained log cannot distinguish slow setup from a hung internal stage. It does
not establish a product crash-consistency defect. The original failed run remains
failed; an earlier passing run cannot supply its missing crash proof.

## Proposed outcome

The receiver test proves both real crash windows and explains failures without
abandoning its owned processes. Setup has a justified finite time budget and actual
readiness acknowledgment. A watchdog expiry remains failure. Diagnostics identify
the case and last observed phase, preserve the actual child outcome, and show
whether cleanup completed before disposable scratch is removed.

Cleanup covers demonstrably owned children and descendants on the supported failure
and interruption paths. It cannot signal unrelated or retired process identities.
Keep the distinction between missing result evidence before publication and retained
original result bytes after publication. Preserve every recovery and preservation
assertion and the complete receiver test matrix.

## Affected users and systems

Maintainers and reviewers depend on this receiver test and required CI to evaluate
the offline materialization slice. This is necessary test/CI repair under the current
Roadmap program. It concerns the test harness and its evidence, including when an
unrelated artifact-only PR runs the suite.

## Constraints

Limit implementation to `scripts/test/replay-materialization-result.test.sh`,
including private test helpers. Use `work/receiver-crash-supervision/` for the
artifact chain. Independent G1/G2 review and a separately accepted high-risk plan
precede implementation. The design must justify its finite monotonic setup budget
from the real work and measurements; this intent accepts no particular timeout or
supervision algorithm.

Prove delayed real readiness, early child failure, watchdog expiry, parent
interruption, descendant cleanup and deliberate SIGKILL status, alongside unchanged
before/after recovery outcomes. Keep required CI and all existing test assertions.
Do not skip cases, retry until green, hide cleanup failure or claim cleanup after
an uncatchable parent SIGKILL. A longer wait alone is not a complete repair.

Keep product behavior, materializer, fixture builder, profile/source pins, workflows,
CI gates and safety policy unchanged. A discovered product defect or wider repair
returns to the appropriate scope gate. No new credentials or network scope, real
target execution, installation, activation, release or deployment is included.

Keep this repair separate from spec-only PR #346 and preserve its recorded head/base
and the clean candidate plan attempt. Do not rewrite the merged receiver history or
discard failed evidence. Frozen #183 and unresolved dirty #271 remain excluded.

## Open questions

What private supervision boundary can prove readiness, ownership, termination and
reaping on native Darwin and required Linux CI without weakening either crash test?
Which interruption paths can it support, and how will it report cleanup failure?

What setup budget do real measurements justify? Which bounded diagnostics can locate
slow or stuck setup while preserving the original failure? How will regression
controls prove these paths and retain the full existing recovery matrix?
