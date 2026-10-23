---
intent-blob: ad058ac7bb664df2de55a6a46b0a82d17f524318
risk: high
drafted: 2026-10-19
---
# Preserve delivery guard rejection during pipe cleanup

Tracks #666.

## Requirements

1. When the candidate-ref guard rejects a replay, a broken input pipe during
   cleanup must not replace that rejection. The original error type and message
   must reach the caller. The protected operation must not run.
2. The same failure path must still reap its owned Git child and perform the
   existing output-stream closure. Preserve existing cleanup deadlines and
   termination behavior. Do not suppress unrelated errors.
3. A deterministic regression must exercise the real guard cleanup. The initial
   prepare request succeeds. The guard then rejects, and both the cleanup flush
   and input close encounter a broken pipe. Assert the original rejection,
   unentered protected body, child reaping and output closure. The same regression
   must fail on the old driver and pass on the repaired driver.
4. Keep the real Git held-lock integration case. Require nonzero replay status,
   the exact guard rejection message, no traceback, and a journal still at
   `publish-wait` without a publisher record. After the holder releases the lock,
   the same attempt must reach `completed-offline`.
5. If the held-lock replay or its checks fail, report its actual captured output
   and original exit status before temporary-file cleanup removes them. A
   diagnostic must not overwrite the status or convert a failure into success.
6. Run the complete delivery replay suite, including every existing assertion.
   Keep raw old-driver failure and repaired-driver success evidence, bound to
   exact source identities. Required CI and independent G3 review must pass before
   protected merge.
7. Integrate the repair into the preserved #558 attempt and complete its original
   full Mac/Linux validation. A quick CI pass or the fixed regression alone cannot
   replace that proof. Preserve the original failed run as historical evidence.
   A base change requires fresh review for the changed tuple.

## Design

### Scope and cleanup

Implementation changes only `delivery/v1/replay.py` and
`scripts/test/delivery-replay.test.sh`. The artifact chain stays under
`work/delivery-guard-pipe-cleanup/`.

In `hold_candidate_ref`, keep the existing Git transaction and preparation
acknowledgement as the ownership boundary. A foreign lock must remain a refusal.
Handle the expected broken pipe across the input cleanup, including close, so it
cannot replace an active guard rejection or skip the later reap and output-close
steps. Keep this change local to the existing cleanup path. Do not add a reusable
cleanup abstraction or treat an unowned lock as ours.

### Fixed regression

Add the regression within the existing delivery replay test. Use its Python
wrapper pattern to replace the process returned at the `Popen` boundary. Run the
real `hold_candidate_ref` and its acknowledgement reader; do not replace the
cleanup under test or add a shipped test hook.

The controlled child accepts the initial prepare write and flush. Its output then
reaches EOF before a preparation acknowledgement, so the real reader rejects the
guard. At cleanup, its status check reports the child still running. The abort
flush and subsequent input close each raise the expected broken-pipe error.
Record that wait and output close occur. The regression must check every outcome
in requirement 3. It must not depend on scheduling, sleep or repeated attempts.

Use the identical regression against the unmodified driver and the repaired
one. Record their hashes and outputs. The old driver must fail because cleanup
loses the rejection or skips required cleanup, not because the fixture fails
before the intended path. This answers the intent's fixed-failure-order question.

### Real contention and failure evidence

Retain the real Git holder, its preparation acknowledgement and the existing
held-lock/resume sequence. The controlled child test supplements this integration
proof. It cannot replace it.

Capture the replay's wait status before running diagnostic commands. Keep its
combined output available to the failed assertions, and print that output with
the captured status before the existing temporary-directory cleanup. Retain all
assertions and their failure outcomes. This answers the intent's evidence question.

Implementation PR review_size: standard.

## Out of scope

No retries, added sleeps, longer deadlines, lock-file deletion, new permissions,
credentials, installation, activation or target execution. No general cleanup
refactor, unrelated error repair, workflow change or weaker test expectation.
Do not change the Git ownership test, journal contract or publisher authority.
This work does not establish why the historical Linux run failed.

## Areas of concern

The repair touches a candidate identity guard, so its risk is high. G2 accepts
this specification and risk; it does not authorize code. A separately reviewed
and merged high-risk plan must precede implementation. Keep author/reviewer
separation, required CI, exact artifact hashes and protected merge.

The historical job omitted the captured replay error. The diagnosed source defect
has a fixed regression, but a later pass cannot prove that defect caused the old
job's failure. If the real integration case still fails, retain its actual output
and status and diagnose that evidence. Do not retry until green or broaden this
repair without the required artifact gate.

No conflict with the accepted intent, north star or working rules is identified.
This repairs the normal guard path and adds no exception or authority.
