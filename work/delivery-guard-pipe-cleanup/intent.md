# Intent: Preserve delivery guard rejection when its input pipe closes
Author: Codex (intent author at manager direction). Status: draft.

Tracks #666. [Accepted intake](https://github.com/yihanzhu/ystack/issues/666#issuecomment-6279844294).

## Problem

The delivery replay guard can lose its original rejection when its input pipe
closes during cleanup. A second pipe error can replace that rejection and skip
child reaping. Reviewers then lose the expected failure evidence.

The complete Linux validation for #558 stopped at `held-lock-error` after the
first 25 delivery replay checks in
[run 39340117891](https://github.com/yihanzhu/ystack/actions/runs/39340117891/job/118359289592).
The test discarded the captured replay error. That run's exact cause remains
unknown. A separate source review found the cleanup defect in code unchanged
from main.

## Proposed outcome

A rejected guard keeps its original error when the input pipe closes. Cleanup
still reaps its owned child and closes its output. Rejection never permits the
protected operation or advances the journal.

A fixed regression must fail on the old code and pass after the repair. The real
Git held-lock case must retain its exact rejection checks, unchanged journal,
and successful resume after release. If that case fails, its evidence must retain
the actual replay output and exit status. The complete delivery replay suite must
pass.

Merge the reviewed repair through its protected PR. Integrate it into the
preserved #558 attempt, then complete that attempt's original Mac/Linux validation.
A later pass does not establish the cause of the historical failure.

## Affected users and systems

Maintainers and reviewers depend on delivery replay's guard and test evidence.
The bounded repair concerns `delivery/v1/replay.py` and
`scripts/test/delivery-replay.test.sh`. It is a prerequisite for the accepted
Roadmap validation, with no added product scope or activation.

## Constraints

Preserve the existing guard, exact assertions, independent review and required CI.
Treat this identity-guard repair as high risk. Accepted intent and spec must
precede a separately reviewed and merged high-risk plan. Code follows that plan.
Use the standard review-size budget.

Fix the normal cleanup path. Do not add retries, sleeps, longer deadlines,
lock-file deletion, a general cleanup refactor, or weaker acceptance rules.
Do not add permissions, credentials, installation, activation or target execution.
Preserve the #558 attempt and its original failed evidence. A base change
requires fresh review against the new base.

## Open questions

How will the regression prove error preservation and child cleanup with a fixed
failure order, without relying on process timing? How will a failing integration
case retain its actual error and exit status without changing its assertions?
