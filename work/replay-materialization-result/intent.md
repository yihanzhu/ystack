# Intent: Preserve real materialization results in the replay journal
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #324.

## Problem

The local delivery replay freezes its input and saves a resumable journal, but
retains only digests and candidate identities from the materializer's response.
It discards the actual typed stage_result and receipt bytes. A later caller cannot
recover those execution facts from a digest or phase name for the state scanner.

The replay also lacks a checked binding to the planner's delivery key. A successful
exit can mean waiting for review, not a finished workflow. Maintainers cannot treat
that exit as durable receiver acknowledgment. This is a source-identified gap,
not a reported production incident.

## Proposed outcome

Retain the actual validated materialization result and required receipt bytes in
the existing replay journal, bound to one supported planner delivery key and the
exact frozen input. A fresh process can reopen and return the same persisted
result after checking its content and identities. Reusing a key with a conflicting
input or result relation fails explicitly.

Once actual result bytes reach durable journal storage, losing the outward reply
must not lose that result. If materialization completed but the actual result was
lost before storage, preserve the candidate and journal and report missing evidence
unless actual retained bytes can be established. Never reconstruct the old result,
silently create another attempt, acknowledge delivery or delete state to hide the gap.

The done-signal is real local persistence and reopen behavior, including separate
crash tests on both sides of publication and duplicate delivery without a new logical
effect where supported. Tests feed the retained actual typed result into the existing
scanner's validation path. They also reject mismatched identities and malformed,
truncated, oversized or missing result evidence while preserving prior usable state.

## Affected users and systems

This serves maintainers connecting local reconciliation to the existing fixed
offline materialization slice. It advances Roadmap step 3 by making a receiver's
real result recoverable. The existing replay journal is the storage boundary;
#297's delivery ledger and #307's telemetry storage remain separate.

## Constraints

Keep one receiver-result persistence concern. Reuse the existing journal and atomic
persistence boundary; add no second inbox, general attempt database or generic
storage API. This work does not implement the sender, automatically acknowledge
delivery, or complete the scan/plan/pending/receiver/ack loop.

Preserve existing replay behavior, complete tests, and candidate, tool, request,
profile, attempt and source checks. Older journals must not be silently accepted
as result evidence or destructively converted. No automatic deletion or cleanup
hides missing records. The old delivery-loop-first plan and preserved attempts
are context only; this initiative does not adopt or rewrite them.

Stored materializer output is evidence, not execution provenance, freshness,
permission or qualification merely because its digest matches. Do not synthesize
a stage_result from a phase, expected values or digest alone. A new delivery ordinal
must not silently create another logical effect. Process-crash proof does not
establish power-loss durability or exactly-once external effects.

Keep this inactive and repo-only. Execution proof uses owned disposable local
fixtures through the existing fixed materializer and journal. Exclude scheduling,
generic dispatch, model/harness execution, provider transport, cancellation services,
new retry semantics, credentials, installation, profile activation, real targets
and deployment. Existing offline publication remains simulation and grants no
publish or merge capability.

Keep scanner, planner and all replay tests green. Preserve restoration documentation
and manifest coverage. Exact paths, limits and proof belong in the specification;
independent G2 and a separately accepted high-risk plan precede implementation.
Complete implementation proof, independent review and CI remain required.

## Open questions

Which materialization operation and planner key are supported, and how are request,
profile, attempt, source, tool and frozen-input identities bound to that key?

What exact result and receipt bytes are retained, with what limits and validation?
Where is their durable publication boundary, and how are earlier incomplete captures
distinguished from a stored result whose outward reply was lost?

How are older journals and incomplete states reported without changing existing
replay behavior, fabricating evidence or overwriting preserved state? How does a
later caller retrieve the exact typed result for scanner validation?
