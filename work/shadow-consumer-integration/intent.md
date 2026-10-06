# Intent: inactive shadow-consumer integration
Author: Codex (intent author, briefed by the Roadmap manager). Status: draft.

## Problem

The shadow driver cannot yet use the sandbox evidence needed for Step 8. It still
checks a Git blob itself (`tool.git-blob-digest`), records declaration-only
environment evidence and accepts only no-change materialization. The fixed
file-digest verifier, receipt checker and VM launcher now exist, but their outputs
are not connected to the driver. A write scope also has no shadow record showing
its planned write with publication withheld.

This leaves the operator and later scope gate without the evidence required by
`work/step8-bounded-write-readiness/spec.md` R2. Concerns 1–3 are delivered
(#426, #436, #437), and concern 4's nine code slices are merged through #504
(intake #463). Its native qualification remains blocked. The accepted VM spec R13.4
explicitly permits concerns 5 and 6 to be built inactive in the meantime.

## Proposed outcome

One inactive shadow-consumer path connects the existing fixed verifier, launcher
and receipt contracts. It establishes the receipt expectation before launch,
checks origin through the controlled supervisor store, and verifies the exact
attempt, candidate, environment, policy and accepted-byte bindings. The evidence
retains the receipt, checker result, evaluator bytes and recorded origin. A copied
or caller-supplied receipt never proves authentic origin. Old declaration-only
and no-change records keep their meaning.

The same concern produces R2's deterministic write-shadow record: an add-only
candidate commit with the target revision as its only parent, exact planned paths,
file modes and raw-byte digests, a checked would-be publisher request, publication
explicitly withheld, and post-write verification digests. It records zero producer
invocations. The permitted write set stays within `ystack-evidence/<incident-id>/`
under R1's path restrictions. No existing target file is changed and nothing is
published. The request and admission contract can serve the later publisher;
this concern does not implement that publisher.

Success means offline contract and integration tests in disposable fixtures show
that two fresh runs of the same frozen tuple produce the same candidate tree,
write set and request. Valid controls accompany refusals for forged or mismatched
receipts, unauthenticated origin, missing or failed evidence, changed candidate or
evaluator bytes, invalid paths or existing files, changed records without withheld
publication, incomplete evidence and differing outputs. Old no-change behavior remains covered. The shipped
accepted set stays empty, the environment stays unproven, and no scope becomes
proposable. Documentation distinguishes fixture proof, native qualification and a
real write-shadow run.

## Affected users and systems

The operator and the shadow driver; the shipped verifier, preparation, launcher
and receipt components it consumes; and later scope-gate, real-gate, eval and
publisher work that reads the resulting evidence. Component documentation and the
restore manifest must cover any new consumer files.

## Constraints

- Tracks #506, using the manager's accepted intake revision recorded in comment
  `6026044143`. This is Step-8 child concern 5, not a new qualification standard.
- Risk is high. G1, G2 and a separately reviewed and merged high-risk plan precede
  code. The spec and plan name exact files, tests and any bounded implementation
  slices. Required CI and independent review remain mandatory.
- Reuse the preparation, verifier and supervisor contracts without duplicating or
  changing them. Limit new behavior to the shadow consumer and narrowly required
  helpers. New restore-critical files receive manifest entries.
- Preserve `scope/v1/**` behavior for child 6. Kill-register and real-gate work stay
  with children 7 and 9; durable telemetry with child 8; evals, publisher and
  enablement with children 10–12.
- Ship inactive. No acquisition, host installation, account or sudo changes, host
  store setup, native VM boot or qualification, real target execution, real
  write-shadow run, credential, new network scope, activation or publication.
  The first real write-shadow run remains a separate operator decision.
- CPU and wall enforcement remain `none`; production receipts remain refused.
  Synthetic receipts and test identities prove contracts only. They cannot alter
  the shipped accepted identities or grant native qualification.
- No config or policy authority expansion. A reserved code or policy change,
  wider authority, weaker acceptance or change to an upstream contract returns
  through its applicable gate instead of being absorbed into this concern.

## Open questions

- How should the consumer record receipt origin and retain the checked bytes so
  offline readers can verify integrity without claiming to authenticate origin?
- How should the write-shadow record and request admission checks fit beside old
  records while preserving their meaning and the later publisher boundary?
- Which exact consumer files and test fixtures are needed to prove the complete
  path without a native run or a production accepted identity?
