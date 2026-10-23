# Intent: credential-handoff coordinator proof
Author: Codex (delegated intent author). Status: draft.

## Problem

The required Linux matrix for the paused self-host milestone stops at case 167.
The credential-handoff timing proof expects status 64, but its private worker reports
70 after the second wait signal. The worker drops the coordinator helper's wait
status, and the bounded failure excerpt omits the second acknowledgment. The current
record cannot tell whether the helper failed, the parent wait was interrupted, or a
different coordination phase failed. #264 and PR #373 therefore cannot meet their
required full-matrix completion condition.

## Proposed outcome

The existing private credential-handoff test first records enough bounded,
credential-free evidence to identify one cause of a Linux failure. It retains the
coordinator helper's exact wait status separately from an interrupted parent wait,
the last completed or failing phase, both request and acknowledgment ordinals and
outcomes, and whether the helper and tested child completed. The complete private raw
evidence survives the Linux failure; the bounded diagnostic output identifies the
failure without exposing credential contents.

Only after that evidence identifies a cause may a later accepted plan authorize a
repair. The repair remains limited to that demonstrated cause.

## Non-goals

- Do not change production behavior, credentials, target execution, installation,
  activation, deployment, repository settings, or authority.
- Do not retry unchanged work until it passes, raise a timeout, weaken an assertion,
  add a generic helper framework, or make a speculative timing change.
- Do not alter the paused #264 / PR #373 attempt or its captured evidence.

## Acceptance

- The diagnostic keeps the expected status 64, both genuine signal interruptions,
  ordinary child completion, descendant retirement proof, the 167-case ledger, finite
  coordination reads, and the 180-second suite alarm.
- The evidence distinguishes a helper exit status from an interrupted parent wait and
  records the phase and both acknowledgment outcomes needed to identify the failure.
- The diagnostic is private, bounded, credential-free, and durable enough to inspect
  a Linux failure after the runner exits.
- The work is high risk. G1, G2, and a separately accepted high-risk plan precede any
  test edit. A later repair requires independent exact-head/base review, affected
  native proof, and the required Linux proof.
