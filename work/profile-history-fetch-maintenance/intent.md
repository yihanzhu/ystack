# Intent: Keep profile-test history fetches free of background maintenance
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #351. [Intake acceptance](https://github.com/yihanzhu/ystack/issues/351#issuecomment-5721894653).

## Problem

PR #350's original CI run
[35274748416, attempt 1](https://github.com/yihanzhu/ystack/actions/runs/35274748416/attempts/1)
failed in the alternative-profile assembly suite before its first success marker.
Git reported `fatal: shallow file has changed since we read it` and exited 128.
This blocks the separately reviewed receiver-supervision plan.

The suite's successive shallow fetches permit automatic maintenance in their
private history repository. Git can leave that housekeeping running after a fetch
returns, allowing it to rewrite shallow metadata during the next fetch. This is
the strongest source-supported diagnosis. The log does not identify the writer or
failing fetch ordinal, and the race has not been reproduced. The default-profile
suite has the same helper exposure; this run does not show a failure there.

## Proposed outcome

Both private history-fetch helpers suppress unnecessary automatic maintenance
from their first real fetch. They retain exact commit selection, depth-one
history, no tags, all existing object/config assertions and normal error
propagation. Disposable history setup no longer starts this competing writer.

A bounded regression check exercises each actual helper and detects removal of
the suppression. Its evidence must show that real fetches ran; an empty trace or
a disconnected duplicate command cannot prove the behavior. Both affected suites
and required CI must pass, with independent review of the complete evidence.
Success does not depend on reproducing a scheduling race or rerunning until green.

## Affected users and systems

Maintainers and reviewers rely on profile assembly tests to validate selected
packages and producer configuration. This necessary test/CI dependency repair is
within the current Roadmap program and is separate from receiver supervision #347
and candidate preparation #327.

## Constraints

Implementation may change only `scripts/test/alternative-profile-assembly.test.sh`
and `scripts/test/default-profile-assembly.test.sh`, including their bounded
regression checks. Use `work/profile-history-fetch-maintenance/` for this artifact
chain. Keep the existing private helpers; no shared framework or broad refactor.

Use a documented suppression option compatible with the supported native Git
versions. Preserve the isolated environment, private HOME, system-config
suppression, disabled credential helpers/prompts, exact HTTP-extraheader forwarding
and origin handling. Instrumentation must not expose credentials or enable HTTP
credential tracing. Keep exact pinned commits, refspecs, depth, no-tags checks and
every existing oracle. Fetch errors remain failures.

No retries, sleeps, ignored errors, lock deletion or full-history fetching. Keep
product code, workflows, runtime configuration, source/profile pins, credentials
and network authority unchanged. No installation, activation, release, deployment
or real target execution is included.

Independent G1/G2 acceptance and the applicable plan gate precede implementation.
Routine risk is recommended for this test-local concern; G2 decides it explicitly.
If accepted as routine, the implementation branch's first commit is plan-only and
requires independent acceptance before code. The author cannot accept that plan.

Preserve PR #350 at `e958333f37d41638ac4190cc21369e2406c97bba` and its original
failed run. Its plan-content acceptance does not waive red CI. After this repair,
the same branch needs reconciliation with current main, fresh exact-tuple review
and CI without rewriting published history. Preserve PR #346's receiver failure,
the clean candidate plan attempt, frozen #183 and unresolved dirty #271.

## Open questions

Which documented option spelling gives the required native Git compatibility?
Which small regression control will prove suppression from the first actual
helper call, detect its removal and preserve failure propagation without logging
credentials or relying on the race to occur?

G2 must settle those choices and risk before the separate plan check and coding.
