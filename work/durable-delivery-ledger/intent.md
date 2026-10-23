# Intent: Persist the reconciliation planner's delivery ledger
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #297.

## Problem

The reconciliation planner depends on a caller-supplied delivery ledger. It can
recognize pending, failed and acknowledged deliveries, but no shipped orchestrator
component persists that state or safely records an acknowledgment. If the caller
loses its state, the planner loses that history. Concurrent updates can also lose
facts unless stale writers are detected.

The existing planner tests construct ledger entries directly. They prove planning
rules, not durable recovery. This is a known implementation gap, not a claim of a
production incident. The boundary is documented in `docs/components.md:250–280`
and used by `orchestrator/v1/reconciliation-plan.jq`.

## Proposed outcome

The existing planner can recover its delivery history from a dedicated local
Git-backed store after a process stops. Reopening it preserves pending and failed
redelivery keys and acknowledged suppression. It exports canonical ledger bytes
and the exact digest reference the unchanged planner consumes.

An update identifies the exact prior state it extends. Conflicting or stale
updates cannot silently overwrite it. Repeating an identical recorded update does
not count it twice, even if the previous process committed but stopped before
replying. Reusing that update's identity with different content is refused.

An interrupted update leaves either the complete prior state or the complete new
state, never a partial ledger. Invalid inputs preserve the usable committed state.
Retained history explains the current view, and an old pending or failed event
cannot silently reopen an acknowledged delivery.

## Affected users and systems

Maintainers and later orchestrator consumers need reliable delivery state for
Roadmap step 3. This initiative serves the current reconciliation planner. The
scanner, planner and core schema remain compatible. Tests use synthetic scratch
Git repositories; no real target or operational store is used.

## Constraints

Preserve the current delivery key, ordering and states. The key contains the stage
key, request digest, operation and attempt number. States remain pending,
acknowledged and failed. Keep the limits of 128 current entries and 1,000 deliveries
per entry. Bounds fail explicitly; do not evict history or silently expand capacity.

Use only a caller-selected dedicated local store, separate from target checkouts,
target branches and ystack's source repository. Bind store identity and expected
tip. Reject ambiguous identities and configuration that could invoke hooks,
credential helpers, filters, external commands or network access.

Stored facts are not authenticated external effects. An acknowledgment grants no
execution authority and proves neither dispatch nor exactly-once behavior. The
future trusted dispatcher must establish who may supply those facts.

Exclude scheduling, event listeners, workers, dispatch, retry execution, remote
Git, forge projections, credentials, models, installation, activation and real
target execution. Also exclude source-snapshot assembly, attempt/result storage,
telemetry/session storage, a general storage framework, other database backends,
migrations, pruning and automatic cleanup. Do not change recovery actions, the
selected core generation or its allowlist. No qualification, merge or publishing
capability is added.

Keep the work inactive. Preserve existing checks and add meaningful restart,
concurrency and interrupted-update tests with deterministic scratch coordination.
A missed window or retry-until-green is not proof. New restore-critical files and
documentation join the manifest. Process-crash proof must not imply protection
against power loss.

## Open questions

Design must define the permitted state transitions, delivery counts and timestamp
rules, including how identical replay is distinguished from a conflicting update.

What precise storage and filesystem assumptions support the recovery guarantee?
How will tests prove interruption before and after a committed update, refusal of
stale concurrent writers, and unchanged planner behavior after reopening the store?
