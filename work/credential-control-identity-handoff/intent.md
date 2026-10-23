# Intent: Make credential test control identity handoff complete
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #321.

## Problem

The credential test's private control shell can expose its identity file before
writing the complete PID/PGID line. The parent waits for file existence, then reads
without handling failure. An empty read can end the test silently and bypass the
cleanup that should retire its waiting control child. Maintainers then lose both
the intended test evidence and a clear explanation of the failure.

PR #320's unchanged credential suite exited after assertion 60 in CI run
34843304806, and runner teardown reported an orphan Bash process. The log does
not identify the failing operation. A separate deterministic Darwin experiment
proved the empty-file read hazard and a successful complete-write control. It did
not prove the historical CI cause or full-suite process-group behavior.

## Proposed outcome

The parent receives and checks a complete identity record before releasing the
existing start gate. Every failed handoff produces a bounded, named diagnostic
and retires the exact control child it owns. An incomplete record never supplies
signal authority. Successful startup retains the existing PID/PGID verification.

Deterministic tests cover real empty and partial publication, complete-record
success, malformed or failed handoff, and owned-child cleanup. They supplement
all 99 existing cases. The original failure and first reproduction remain
available; later passing runs do not establish the historical cause.

## Affected users and systems

Maintainers and reviewers rely on this suite when judging unrelated Roadmap
changes. The change belongs only in `scripts/test/control-credential-policy.test.sh`
and its existing description in `docs/components.md`.

This repairs startup of the private signal controls added by #315. It is separate
from the evaluator input-snapshot synchronization repaired by #291 and the adapter
failure reporting in #301. It makes no production evaluator repair claim.

## Constraints

Retain the 45 original assertions, all 54 added controls and their real signal
and lifecycle checks, the three original evaluator mutations, the three-attempt
setup limit and the 180-second suite alarm. Preserve PID/PGID confirmation before
control signals or evaluator launch, and all resource and ownership standards.
Cleanup must distinguish a reaped child from an uncertain result.

Keep the evaluator, policies, dependencies and core identities unchanged. Do not
hide the race with sleeps, retry until green, weaken assertions or add generic
process infrastructure. No workflow changes, unrelated process or cache cleanup,
installation, credentials, target execution or activation are included. This
initiative neither resumes #271 nor accepts its pending cache exception.

G2 and an independently accepted plan must settle the design and proof before code.

## Open questions

How will the private handshake publish and strictly validate one complete record
within a finite bound? How will failed reads and other startup operations reach
a bounded diagnostic without releasing an unverified child?

How will every failure before release retain exact ownership and terminate and
reap that control child, including signal interruptions, without signaling an
unrelated or already reaped process? Which deterministic controls will prove
these boundaries on the supported Linux and Darwin shells?
