# Intent: Make credential-policy race tests synchronize reliably
Author: Codex (intent author at operator direction). Status: draft.

Tracks #291.

## Problem

The credential-policy test can miss the evaluator's pending-to-ready window
before it replaces the input. It then fails without exercising the input-swap
security assertion. This blocks unrelated changes and leaves that run without
the intended security proof.

This happened on spec-only PR #290 in
[run 34763571809](https://github.com/yihanzhu/ystack/actions/runs/34763571809),
after assertion 32. The observer polls a marker and sends SIGSTOP, while the
evaluator can advance without an acknowledgment from the observer. The log does
not establish the exact host scheduling cause.

The candidate and base have identical test and evaluator files. Earlier runs
passed all 45 assertions. That supports a timing-sensitive test diagnosis;
it does not establish a guard failure or a service outage.

## Proposed outcome

The test reliably reaches and proves the intended input-swap behavior. It retains
every ownership, stopped-state, readiness, input mutation, refusal and cleanup
check. A failure clearly distinguishes an unsuccessful test setup from a failed
security assertion. The original failed run remains evidence.

## Affected users and systems

Maintainers and reviewers rely on the credential-policy test and required CI to
judge repository changes. This initiative concerns that test's synchronization
and the evidence it produces, including when unrelated documentation changes run it.

## Constraints

Keep the work separate from PR #290 and preserve its CI gate. Prefer deterministic
coordination on the test side. If design requires bounded fresh attempts, a missed
window never counts as proof and exhaustion must fail. A longer polling timeout
alone cannot recover a window that has already passed.

Retain all security assertions. Do not skip checks or retry until green. Do not add
a shipped evaluator hook, change policy, or broaden a security boundary under this
intent; those changes require their own accepted design. No credential access,
runtime installation or workflow activation is included. A later passing diagnostic
run does not erase the original failure.

## Open questions

Which test-side coordination can reliably establish the required stopped state
before readiness? Can it be deterministic without changing shipped behavior?

If fresh attempts are necessary, design must define their finite budget, distinguish
missed windows from proving attempts, and make exhaustion a clear failure. It must
also define evidence that every existing security and cleanup assertion still runs.
