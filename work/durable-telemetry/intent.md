# Intent: durable telemetry — sealed traces outside execution scratch
Author: Claude (yshifu, intent author at the operator's direction). Status: draft.

## Problem

Session evidence does not survive the disposal of execution scratch. The roadmap
asks for a durable append-only session record outside every disposable execution
sandbox (`ROADMAP.md:260-261`). Today nothing keeps one.

- The trace-ledger validator checks one caller-supplied sealed bundle and returns
  a receipt with `storage_effect: "none"` (`telemetry/v1/trace-ledger.jq:110`).
  It works in its own temporary directory and deletes it on exit
  (`telemetry/v1/validate-trace-ledger.sh:102-108`). It retains nothing.
- The receipt carries a session, attempt and final-digest replay key "for a later
  state store to consume once" (`trace-ledger.jq:114-115`,
  `docs/components.md:508-509`). No such store exists. The component doc says a
  later unit must provide durable append, retention, access and recovery
  (`docs/components.md:519-521`).
- The shadow driver seals its ledger inside its scratch and copies it to a
  caller-supplied state directory (`shadow/v1/reproduce.sh:602`, `:683-687`). The
  eval dashboard reads supplied files. Neither is stored session evidence.

The accepted step-8 decision records this as the boundary-map row "Attempts are
durable and auditable: sealed traces outside scratch; today scratch-bound"
(`work/step8-bounded-write-readiness/spec.md:343`) and as child concern 8
(`spec.md:298`). The real short-lived publisher, concern 11, depends on it
(`spec.md:301`). So a passing validation is not evidence of durable storage, and
no later write attempt could be audited after its scratch is gone. Parked issue
#307 already specified this concern; #438 subsumes it.

## Proposed outcome

An inactive, bounded, local Git-backed store for complete canonical trace
bundles, exactly as #307 proposed, and one read-back consumer of it. Concretely:

- **The sealed store contract.** An explicit caller appends one bundle. The store
  validates the captured bytes through the real, unchanged validator; it never
  accepts a caller-supplied validation receipt as proof. Each record keeps the
  exact bundle bytes and the exact validator identity, is immutable, and is
  committed with a storage receipt. Appends use expected-tip compare-and-swap.
  A lost reply is recovered by an identical replay that returns the same receipt
  and adds no second record. The store refuses, explicitly, a conflicting replay,
  corrupt stored data, a stale writer and exhausted capacity. The contract
  defines whether distinct sealed records for the same session and attempt are
  allowed and how they are told apart. It never silently overwrites, reseals old
  bytes, joins separate chains or calls the newest record authoritative.
- **Its consumer.** Bounded read and list that return the exact committed bytes
  after the original scratch has been removed, re-checked against the storage
  receipt and the validator. This is the interface a later concern (the concern
  11 publisher and post-write check) binds to by storage receipt. Wiring any
  caller into it is that later concern's work, not this one.
- **Physical store.** A dedicated store outside every source and target checkout
  and outside the scratch being disposed. It ignores ambient Git configuration,
  hooks, filters and credential helpers, and uses no network. Input, object,
  history, record, output and listing sizes are all finite. Capacity exhaustion
  refuses; there is no silent eviction, pruning, automatic GC, destructive repair
  or history rewrite.

Success means #307's done-signal: real append, read and replay in disposable
local Git stores, with the original source deleted, and #307's deterministic test
list passing in required CI: byte-exact recovery, identical replay, conflicting
replay, stale concurrent writers, interruption around the committed ref update,
invalid input leaving state unchanged, corrupt stored data, capacity exhaustion
and forbidden store or configuration boundaries. Tests use deterministic barriers
and private test controls, never guessed sleeps or retry-until-green. The stored
facts stay supplied and unqualified.

## Affected users and systems

The operator, who reviews and merges each gate. `telemetry/v1`, whose validator
the store calls unchanged. The shadow driver and the maintenance scanner, which
produce sealed ledgers today but are not wired to the store here. The later
concern 11 publisher and the step-8 audit trail, which will read from it.
`RESTORE.md`, `docs/components.md` and `ci/required-files.txt`, which gain the
new restore-critical files.

## Constraints

- Risk: high. G1 intent, then G2 spec, then an operator-merged high-risk plan
  come before any code, with independent review and required CI at each gate.
  Tracks #438.
- Ships nothing enabling. No live event collection, incremental event editing,
  dashboard integration, model execution, credential, provider transport,
  scheduling, activation or target write. The store grants no authority and never
  turns an unavailable metric into a value.
- Nothing enables before step 7 (#426) closes. Drafting may proceed now.
- Landing dependency per R8 row 8: none. Reserved decision: none beyond review.
  Concern 11 lands after this one.
- `telemetry/v1/trace-ledger.jq`, `telemetry/v1/validate-trace-ledger.sh` and the
  receipt's semantics stay unchanged. No core document kind, role, capability,
  generation identity or profile is added or changed. If the design needs one, it
  returns through that surface's own gates instead of widening this concern.
- One persistence concern. It does not merge schemas with the delivery ledger
  (#297, `delivery/v1/replay.py`) or add a generic storage framework, though it
  may reuse that work's proven Git safety lessons.
- Proof is limited to process-crash recovery for the chosen contract. It is not
  proof of producer authenticity, hostile-admin rollback detection, power-loss
  durability, a complete session service or live environment qualification, and
  must not be described as such.
- No real credential, provider call, real target or runtime installation is
  involved in any test.

Non-goals: live telemetry collection, wiring the shadow driver, scanner or eval
dashboard to the store, retention or deletion policy beyond refusal at capacity,
signing, remote replication, and any change to what the validator accepts.

## Open questions

- What exact keys identify a record, and are two distinct sealed records for one
  session and attempt allowed? If so, what distinguishes them?
- Where does the physical store live, how is its identity fixed, and how does a
  caller prove it is not inside a checkout or the scratch being disposed?
- How is the validator and its jq runtime bound into each record, so a record
  made by one validator revision is never read as another's?
- What are the capacity and history limits, and what exactly does each refusal
  return?
- What do the commit and replay receipts contain, and is the storage receipt a
  `telemetry/v1` package document rather than a core kind?
- What crash states can exist around the ref update, and how does each recover
  or refuse?
- What read and export safety applies to bytes handed back to a caller?
