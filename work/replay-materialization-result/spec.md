---
intent-blob: eb68c51f1a9866599c8662e967fba8375ccfbf3e
risk: high
drafted: 2026-09-14
---

# Spec: Preserve real materialization results in the replay journal

Tracks #324.

## Requirements

1. Support one planner operation: `dispatch-stage`, attempt number `1`, for the
   existing inactive `core.forge.materialize-candidate.v2` operation. Bind its
   delivery key to the exact supplied materialization input before execution.
   Reject other operations and attempts explicitly. Receiving this key grants no
   permission and does not authenticate a planner or a caller.
2. Retain the actual successful materializer response, including its typed
   `stage_result` and receipt bytes, in the existing replay journal. Validate
   content, digests and all relations before publication and again on reopen.
   Neither a phase nor a digest alone counts as retained result evidence.
3. A new process must retrieve the same stored response bytes and a scanner-ready
   pair containing the actual result. Retrieval does not execute materialization,
   resume workflow phases, consume review or publisher observations, or acknowledge
   a delivery. A waiting replay's exit code remains distinct from result storage.
4. Serialize delivery and retrieval with the existing journal lock. Same-key
   redelivery with the same frozen input returns the stored result without another
   materialization. Changed keys, input, tools, request/profile/attempt relations,
   source identities or stored result relations fail without replacing prior state.
5. Prove both crash windows separately. After result publication but before the
   outward reply, a new process retrieves the original bytes. After candidate
   materialization but before result publication, an existing candidate without
   retained bytes produces explicit missing evidence. Preserve its journal and
   candidate; do not rematerialize, manufacture a result or start another attempt.
6. Preserve all existing unbound replay behavior and its 40 focused checks,
   including deterministic candidate reconciliation. Older journals remain
   distinguishable from journals with retained original results. No conversion,
   new key, or recomputation promotes old state into original-result evidence.
7. Reject malformed, truncated, oversized, missing or conflicting evidence with
   bounded reads and ordinary diagnostics, never a traceback or partial success.
   A rejected read or redelivery must preserve existing journal, frozen input and
   candidate bytes. No cleanup may hide a missing-result window.
8. Feed retrieved actual results from real owned offline materializations through
   the existing scanner entrypoint and its result relation and digest checks.
   Keep scanner, planner, materializer and replay regression suites green. Preserve
   restore-manifest coverage and document the storage and recovery contract.

## Design

### Supported delivery and identity

Add optional `--delivery-key FILE` to `delivery/v1/replay.py`. Its file contains
only the planner's existing `delivery_key` object, with exact fields:

- `stage_key`: `initiative_id`, `workflow_id`, `stage_id`, `task_class_id`;
- `request_sha256`;
- `operation`: exactly `dispatch-stage`;
- `attempt_number`: the integer `1`.

Use the planner's ID and digest rules. Reject booleans, fractional numbers,
unknown fields, duplicate JSON members, and a key whose fields do not equal the
frozen request's four stage fields, request digest, and input attempt number.
The file is data, never a program, path template or source of commands. It carries
no delivery ordinal. A later transport ordinal would not change this logical key;
this interface neither accepts an ordinal nor creates another effect from one.

Validate the complete materialization input and its original canonical form, all
profile/resolved-profile/manifest/request document digests, payload byte digests,
and the existing protocol and core relations. Keep the fixed deterministic binding,
network-deny declaration and permissions unchanged. Bind the complete key into the
new journal's immutable identity before deriving `run_key`. Preserve every existing
identity component: exact frozen-input digest, request digest, source repository,
commit/tree/hash algorithm, verifier, loaded driver bytes, frozen materializer
package and core generation, jq and object-closure helper. The frozen input also
binds the resolved profile, manifest set, patch, contract and complete attempt,
including result ID and timestamps. Candidate commit, tree and parent remain checked
against the actual response and candidate repository.

One state directory holds one key and one attempt. A different key in that directory
is a conflict, even if a request or candidate tree matches. The caller must reuse
that directory and the same candidate boundary for redelivery. This provides no
cross-directory deduplication or global key lookup. A fresh journal still cannot
adopt an already populated candidate root. The feature does not allocate directories
or quietly choose new ones after a failure.

### Journal format and retained bytes

Unbound calls continue to use journal schema version `1`. Calls supplying a delivery
key create schema version `2` of the same `delivery_replay_state` in `run.json`.
Version 2 retains the existing phase, materialization, verification, observation,
authority and qualification meanings. Its immutable identity additionally contains
`delivery_key`, and it has one required `receiver_result` record. This is an explicit
version boundary, not a second inbox or attempt database.

The record has `schema_version: 1` and one of two exact shapes:

- `status: pending`, with no response fields, until result publication;
- `status: stored`, with `response_utf8`, `response_sha256`,
  `stage_result_sha256` and `receipt_sha256`.

`response_utf8` round-trips every UTF-8 byte actually received on successful
materializer stdout, including the final newline. It retains the complete response
and the exact receipt string in its sole payload. Do not independently regenerate
or replace these bytes. The stored hashes bind the original response, the canonical
extraction of its actual typed result, and the receipt's UTF-8 data respectively.
The pre-existing materialization digest fields must agree with this record.

The materializer returns the result as an object inside its response; it does not
return a separately framed stage-result file. For the scanner pair, serialize that
actual object with the frozen jq 1.6 `-S -c` form and one final newline, then hash
those bytes. This is extraction of retained data. It is not reconstruction of an
execution result from a candidate, expected values, replay phase or reexecution.
Do not claim the extracted framing was a separately observed output file.

Use these inclusive byte limits; check encoded journal size before replacing it:

| Value | Maximum |
| --- | ---: |
| Materialization input and frozen input | 8 MiB, unchanged |
| Delivery-key file | 4 KiB |
| Actual materializer response | 1 MiB |
| Canonical extracted stage-result document | 256 KiB |
| Receipt UTF-8 data | 64 KiB |
| Version 2 journal, including escaped response | 8 MiB |
| Version 1 journal and review/publisher observations | 64 KiB, unchanged |
| Materializer stderr retained for a diagnostic | 64 KiB |

The larger journal ceiling accommodates JSON escaping of bounded response bytes;
there is no repeated history or append-only response list. Keep the old version 1
ceiling even though version 2 needs more space. A bounded version-discriminating
read may inspect up to the version 2 ceiling before applying the correct limit.
Reject unknown journal versions. Stream response capture with the stated ceiling;
checking length only after an unbounded `subprocess.run(..., PIPE)` is insufficient
for this new path. Drain or stop excessive diagnostic output without retaining it
unboundedly. Do not add a retry policy or change materializer cleanup semantics.

Strictly decode UTF-8 and one JSON document, without BOM, duplicate members,
non-finite numbers or trailing data. Reject invalid Unicode, excess nesting above
32, and malformed nested field types. Apply existing core parsed limits to typed
core documents; the response/receipt envelope has its own byte limits because it
contains a raw receipt string. Use the existing nonblocking, no-follow,
regular-file read boundary for journal, frozen input and key. Reject links, FIFOs,
devices and missing files without following or rewriting them.

### Validation at capture and reopen

Add a pure response-validation operation to
`adapters/local-git-materializer/v1/protocol.jq`, using its existing input and receipt
relation predicates and the existing core result validator. Its inputs are frozen
materialization data, the actual response, and the receipt content/digest pair
whose bytes the replay has checked. The operation validates supplied data; it cannot
materialize, repair or generate replacement evidence. Existing protocol operations
and the materializer executable's output remain unchanged.

Require the exact response envelope, `local_git_materialization_response` version
1, authority `none`, unavailable qualification with `adapter.unqualified`, and the
sole `caller-disposable-candidate-repository` effect. Require exactly one JSON
receipt payload with content ID `candidate.materialization.receipt`, its matching
SHA-256, and no extra payloads or envelope fields.

Recheck receipt adapter identity/status, full request and resolved-profile refs,
selected manifest, contract and patch refs, attempt ID/number, source repository,
algorithm, commit/tree, candidate kind/algorithm/commit/tree/parent, changed-path
count and digest, and the changed/no-change relationship. Verify each full document
reference, not just its digest. Require the result's ID, attempt ID/number and all
three timestamps to equal the frozen attempt. Validate its request/profile refs,
performer, binding, environment, capability, deterministic execution metadata,
evidence and output links through the core relation plus the fixed materializer
protocol. It must be the supported completed change outcome; no-change still retains
its receipt despite having no candidate output entry. Diagnostics, metadata and
receipt references must match this fixed protocol, with no added evidence claims.

Reopening checks the stored response and extracted result hashes, raw receipt hash,
all these relations, complete saved identity and frozen input, current execution
source identity, and current candidate commit/tree/parent. It does not trust a
previous `stored` label. Use read-only candidate identity checks during retrieval;
a fixed-content verifier failure remains a separate replay workflow fact, not a
reason to fabricate a different materializer result. Regular replay still performs
all existing fixed-content verification and candidate-ref/observation guards.
A later driver or dependency change remains stale under the current identity rule;
this work adds no migration or tool-identity waiver.

### Publication and the two crash windows

Hold the existing permanent `replay.lock` across journal validation, delivery,
capture and publication. For a new keyed run, publish its frozen input and version 2
`materializing` journal with pending result before invoking the materializer.
After successful response capture and validation, publish `receiver_result: stored`,
the materialization summary, candidate identities, and phase `verifying` together
in one `atomic_json` replacement of `run.json`. That replacement keeps the current
write, file flush/fsync, rename, and directory fsync sequence. There is no separate
response file whose visibility can disagree with a pointer in the journal.

Only the published record can support an outward `stored` result. Later phase
updates preserve its exact response string and hashes. Fresh-process reopen is the
proof after publication, including when the outward write fails or the process is
killed before replying. Read and matching redelivery validate and return the same
record without invoking the materializer again. Ordinary replay phase progress may
still wait for review or an offline publisher; storage never advances those gates.

If a keyed journal remains `materializing` with a pending result on reopen, inspect
the existing candidate boundary without adopting it. Any candidate or partial
materialization content makes the result unavailable with reason
`replay.materialization-result-missing`. Preserve the journal, frozen input,
candidate and scratch state byte-for-byte. Do not run deterministic reconciliation
or consult transient materializer scratch files as original response evidence.
Even a matching candidate or recomputed digest cannot fill the record.

If candidate and scratch roots are still empty and all original checks pass, the
same pending attempt may perform its first materialization. This is the existing
pre-effect restart case, not a new attempt. Ambiguous or nonempty roots fail closed.
Malformed or oversized output after execution likewise cannot publish a result;
retain the last valid journal and whatever candidate state the fixed materializer
left. Do not turn a capture failure into a recoverable instruction to create fresh
roots. A stored-but-damaged record fails validation rather than falling back to
pending or reexecution. Atomic publication failures never report stored success.
After rename, a later fresh read may establish what is actually present; an I/O
error in the writing process itself is not a successful publication receipt.

These guarantees concern process crashes on the existing local filesystem boundary.
They do not establish power-loss durability, hostile-owner storage protection or
exactly-once effects outside that boundary. The same caller owns the journal and
can forge its contents; digest agreement is consistency evidence, not provenance.

### Retrieval and compatibility

Add `--read-materialization-result` to the same replay entrypoint. It uses the normal
identity arguments and optional key, opens only existing state, and refuses review
or publisher observation arguments. It must not create an execution bundle,
materialize, reconcile, modify the journal or change a workflow phase. Reuse the
existing permanent lock, which must already exist for this read mode. Validation
may use bounded private temporary files for fixed validators, never candidate code.

For a valid stored version 2 record and matching supplied key, emit one
`delivery_replay_materialization_result` envelope with schema version 1,
`status: stored`, `authority: none`, `qualification: unavailable`,
`offline_simulation: true`, saved delivery key and run key, exact `response_utf8`,
`stage_result: {content, sha256}`, and the actual receipt payload. Its exit is `0`.
The receipt data and response string reproduce the journal's stored bytes. The
result pair's content comes only from the retained response. Emit no acknowledgement
or workflow-completed claim. Repeated retrieval has identical output.

A valid pending or legacy journal emits the same diagnostic envelope with
`status: unavailable`, no result/receipt fields, and reason
`replay.materialization-result-missing` or `replay.legacy-result-unavailable`;
exit `3`. A key/identity change returns stale/conflict with exit `2`, and malformed
or unavailable files return an ordinary error with exit `1`. Existing interruption
handling retains exit `75`. No failure output contains a scanner-ready result.
For a legacy read without a key, apply its existing identity checks before reporting
unavailable. A supplied key cannot attach to a legacy journal. Version 2 requires
its saved key on delivery and retrieval; omitting it cannot enter legacy recovery.

Unbound calls keep their current CLI, version 1 journal, phases, exits, fixed
verification and deterministic reconciliation. Their recomputed summary can support
only that existing offline replay behavior. They never emit the new stored-result
record. This narrow compatibility branch is private to replay journal dispatch;
there is no migration API. Its constraint is preservation of existing version 1
behavior while original bytes are absent. Re-evaluate it only through a separately
accepted retirement/migration change. Tests must cover both formats and prevent
cross-format promotion. A historical version 1 journal with a changed driver still
fails stale as today; compatibility does not promise upgrades across pinned tools.

### Proof, paths and review size

The G2 PR changes only `work/replay-materialization-result/spec.md`. A separate
high-risk plan PR later changes only `work/replay-materialization-result/plan.md`.
Implementation may change only:

- `delivery/v1/replay.py`;
- `adapters/local-git-materializer/v1/protocol.jq`;
- `scripts/test/replay-materialization-result.test.sh` (new);
- `scripts/test/local-git-materializer-protocol.test.sh`;
- `README.md`, `docs/components.md`, `docs/replay-materialization-result.md` (new);
- `ci/required-files.txt`, appending the two new restore-critical files.

The existing `scripts/test/delivery-replay.test.sh` remains unchanged and runs all
40 checks. The new suite reuses its fixture builder and real fixed materializer.
It generates one canonical scanner snapshot from the frozen request/profile and
retrieved result pair, with absent active attempt, compatible retry limit/time and
source revision, then calls `orchestrator/v1/scan-state.sh scan`. Both changed and
no-change materializations must classify terminal through actual validation.
Tampered result refs, digest or attempt relations must be rejected by the real
scanner, not merely by a test double. The scanner and planner product files do not
need modification or special handling for replay receipts.

Use real separate processes and explicit synchronization around journal publication
to prove SIGKILL before publication with an existing candidate and after publication
before any outward response. Also prove same-key redelivery, concurrent callers
under the same lock, pending pre-effect restart, byte-identical retrieval, and no
extra materializer invocation after storage. At each missing/corrupt/conflict case,
compare journal, frozen input and candidate state before and after. Include changed
and no-change candidates, root and ancestor source commits, and both supported Git
object formats through owned disposable fixtures.

Cover key shape and every binding field; frozen-input and tool drift; result and
receipt schema/digest/ref/attempt/source/candidate/outcome mismatches; duplicate
members, invalid UTF-8, truncation, extra documents, unknown fields, missing payloads,
booleans in integer slots, depth and every byte ceiling. Exercise oversized stdout
and stderr while checking bounded capture. Validate legacy no-key behavior and
refusal to retrofit a key; pending and stored version 2 records cannot escape via
no-key invocation. Test publication I/O failure and response-write failure without
losing prior usable state. Fault injection is test-only, following the existing
loaded-driver wrapper pattern; no product environment flag bypass is added.

Run the new suite, all 40 replay checks, protocol and adapter suites, scanner and
planner suites, the complete existing test runner, structure validation and pinned
Shellcheck 0.11.0. Required CI and separate exact-head/base review remain mandatory.
Documentation must explain full-directory restoration, format distinction, fixed
limits, unavailable evidence, supported key scope, retrieval and inactive status.

`review_size: accepted-exception`. Plan for an estimated 800–1,500 added plus
removed implementation lines across these exact paths, including tests and docs.
This is a planning estimate, not a measured future diff. The source baseline is an
875-line replay, 435-line protocol, 1,152-line unchanged replay suite and 356-line
protocol suite. Bounded capture, versioned validation, two process-crash proofs,
negative relation cases and real scanner integration belong to the same persistence
contract; splitting them would leave an unproved result boundary. The high-risk
plan must allocate and justify that range using the actual design and later review
must compare actual size. An overrun returns through the separate amendment gate;
never shorten tests or compress code to meet it.

## Out of scope

No sender, automatic acknowledgement, ledger update, second inbox, general database,
generic dispatcher, scheduler, full scan/plan/pending/receiver/ack loop, new retry
semantics, retry-stage or stranded-attempt execution. No model/harness execution,
provider transport, cancellation service, credential access, installation, profile
selection, activation, real-target run, release or deployment. No claim of mechanical
network isolation, runtime qualification or authorization from stored output.
Existing offline publication remains simulation with no publish or merge capability.

No adoption or rewriting of #271 or other preserved delivery-loop-first work,
#297's separate delivery-ledger boundary, or #307's telemetry store. Frozen PR #183
and unresolved dirty attempts remain excluded. No core generation, scanner/planner
schema, constitution, workflow, shipped profile or materializer executable change.

## Areas of concern

Risk is high because this changes persistent recovery state and result identity
validation at the receiver boundary. G2 accepts the design and risk only. A separate
accepted high-risk plan must precede code; the current session's recorded Roadmap
delegation preserves independent review, exact hashes, stage order and CI.

All three intent questions are resolved above: initial materialization dispatch and
its checked key; actual full-response/receipt retention with bounded atomic journal
publication; and explicit versioned compatibility plus read-only scanner-ready
retrieval. No change to the accepted outcome or authority boundary is needed.

The supported path deliberately stops when original response bytes were lost after
an effect. Reliable candidate recomputation is insufficient execution evidence.
Storage reuse across arbitrary directories or upgraded tool packages also remains
outside the guarantee. These limits must stay visible in tests and restoration docs.
