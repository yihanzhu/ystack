---
intent-blob: eb68c51f1a9866599c8662e967fba8375ccfbf3e
risk: high
drafted: 2026-09-15
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

Validate the typed journal structure before comparisons or phase dispatch. Journal
and receiver schema versions are actual integers, never booleans. Phase, receiver
status and source hash algorithm are strings before membership checks. Apply the
same complete shape/type rules to supplied and stored delivery keys, including the
four stage fields and integer attempt number. Dictionary equality alone cannot
establish these types. Pending and stored records keep their exact separate shapes;
unknown fields, invalid nested containers and missing required fields are errors.
A pending record is valid only in `materializing`. A stored record always requires
its matching materialization summary and candidate identities, even when a separate
workflow failure set the phase to `failed`; a damaged stored record cannot become
pending or trigger another execution.

Validate optional version 2 fields whenever present, even if retrieval will not
consume them. `recoverable` is boolean; `reason` and `recovery` are strings.
Materialization, verification, review and publisher records retain their existing
field meanings and exact typed shapes. Preserve valid stored-result retrieval after
a separate workflow failure. Malformed nested data returns an ordinary diagnostic,
never an uncaught indexing, membership, type or encoding exception. Reuse the
existing validation boundaries; add no second schema framework or migration.

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
| Read-only candidate changed-path inventory | 2 MiB |

The larger journal ceiling accommodates JSON escaping of bounded response bytes;
there is no repeated history or append-only response list. Keep the old version 1
ceiling even though version 2 needs more space. A bounded version-discriminating
read may inspect up to the version 2 ceiling before applying the correct limit.
Reject unknown journal versions. Stream response capture with the stated ceiling;
checking length only after an unbounded `subprocess.run(..., PIPE)` is insufficient
for this new path. Drain or stop excessive diagnostic output without retaining it
unboundedly. Any stdout byte beyond the materializer response ceiling makes capture
fail; truncated bytes can never support a stored result. Excess stderr may be
drained and discarded beyond its diagnostic ceiling without changing an otherwise
successful materialization into a failure.

Apply an actual bounded subprocess capture boundary to the fixed read-only Git
tree-diff command before splitting, decoding, sorting or canonicalizing changed
paths. Reject nonzero exit and any byte beyond the 2 MiB ceiling. A length check
after unrestricted `subprocess.run(..., PIPE)` or `communicate()` is insufficient.
Reuse one private bounded capture boundary for the fixed materializer and Git
callers. Retain at most each stdout ceiling plus one over-limit sentinel byte,
with bounded chunks and capped diagnostics. Drain concurrent pipes without deadlock;
on failure drain/discard remaining bytes or stop the child while preserving existing
cleanup semantics, close descriptors and reap the child. Overflow remains failure
regardless of which cleanup route is used. No generic execution API, product fault
flag, new retry policy or changed materializer cleanup contract is introduced.

Strictly decode UTF-8 and one JSON document, without BOM, duplicate members,
non-finite numbers or trailing data. Reject non-finite parsed floats produced by
exponent overflow, such as `1e999`, as well as named NaN/Infinity tokens. Do not let
a non-finite value survive inside an unused optional journal field. Reject invalid
Unicode, excess nesting above 32, and malformed nested field types. Apply existing core parsed limits to typed
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

The fixed materializer checks must be stricter than the generic core where the
core deliberately admits other producers. Bind `reported_by` and execution facts
to the existing request projection, and accept only the fixed successful result
fields, completed status, permitted outcome and empty diagnostics. Construct the
expected receipt reference only from its fixed content ID, `application/json`
media type and verified raw receipt digest. A changed result has exactly one output
with the requested output ID and that complete ref; no-change outputs are empty.
Evidence is exactly one `evidence.local-git-materialization` item with deterministic
kind, passed verdict and that complete `proof_ref`.

Execution metadata is exactly deterministic. Provider, model, snapshot, effort,
prompt and skills have the fixed not-applicable shapes. Tools is exactly recorded,
with empty value and the same complete receipt `source_ref`; core-valid computed
or unavailable alternatives are not this materializer's output. Reject different
IDs, media types, digests, cardinalities and extra fields in all these fixed facts.
Retain core result and receipt/input relation validation. Compare supplied facts;
never call a result/receipt constructor to regenerate missing execution evidence.

Reopening checks the stored response and extracted result hashes, raw receipt hash,
all these relations, complete saved identity and frozen input, current execution
source identity, and current candidate commit/tree/parent. It does not trust a
previous `stored` label. Use read-only candidate identity checks during retrieval;
a fixed-content verifier failure remains a separate replay workflow fact, not a
reason to fabricate a different materializer result. Regular replay still performs
all existing fixed-content verification and candidate-ref/observation guards.
A later driver or dependency change remains stale under the current identity rule;
this work adds no migration or tool-identity waiver.

### Inactive materializer package bindings

The response validator changes the Git tree of the existing materializer package.
Keep both shipped profiles bound to that exact package through a bounded dependency
update. In each profile's local materializer manifest, change only
`body.package_ref.object_id` and `body.package_ref.revision.commit_id`. The tree
must contain the accepted protocol implementation at the existing package path;
the revision must be an actual, independently verified commit containing that tree.
It must remain fetchable through the existing repository source for CI and restore.
Do not invent a future commit ID or leave the new tree paired with the old revision.

In each profile's sole `adapter.local-git-materializer.v1` binding, copy that exact
package reference and update only its `manifest_ref.sha256` to the SHA-256 of the
updated canonical manifest bytes. Keep jq 1.6 `-S -c` framing with one final newline.
All other manifest and profile fields remain unchanged, including authority refs,
Roadmap digests, capabilities, permissions, roles, execution boundaries, models,
prompts and other package bindings. No selected or installed profile is changed.

The two profile-assembly suites currently pin the materializer to an older common
package commit. Give the materializer its own exact expected commit and fetch that
commit using their existing isolated, shallow, no-tags history boundary. Preserve
exact revision, path, object type, mode and object ID checks; retain the old pins
for other packages and prompts. Do not derive the expected commit from the profile
under test or permit any commit with matching-looking data. Packaging's unchanged
checks must still reject stale trees, manifest hashes and binding relations.

This is required consistency maintenance for the same inactive receiver result
contract. It does not add a package format, resolver fallback, qualification,
capability, release, installation or activation. The existing owned disposable
packaging test fixtures remain development proof only.

### Shipped-default shadow digest bindings

The default profile also has a direct byte-identity consumer in
`shadow/v1/materialization-input.jq`. Update only its `profile_pin` constant,
`manifest_pins.forge` constant, and the existing pinned-from provenance header.
The two constants must equal SHA-256 of the final canonical default profile and
local materializer manifest bytes. Retain the other six document pins, all decision
text and digest pins, `digest_mismatch`, `config_pins_ok`, profile graph checks and
every other predicate unchanged. The same fixed constants must continue to check
both supplied document bytes and any corresponding resolved config source.
Do not derive trusted pins from caller input, accept old and new digests
interchangeably, replace exact equality with shape checks, or add a resolver fallback.

This is the keep-in-sync update required by requirements 3 and 13 of the accepted
`work/shadow-input-assembler/spec.md`. Its original digest table records its source
baseline; that spec expressly requires later profile changes to move these live
pins in the same implementation PR. Its driver, test suite and accepted artifacts
do not need changes for this update.

The earlier package checkpoint `529069b731eb5738646928f6c6c07fe5bd61d927`
contains materializer tree `efa85d8f51cb4ac6523f2db5e1418e5c9cb6f8ff`. Its child,
profile checkpoint `15476b92860608f640a3d480170fd878af3f4b48`, contains default
profile digest `0d1c815783529ad4d4fc285f2966942fedddb087db4cc7703aa137bb30046179`
and local materializer manifest digest
`4f7219f25de07df9112fb39f0aa4eac63e8af13ef6f24528a49a8d31d148f065`.
These remain historical facts in the preserved history. A corrected protocol
changes the package tree and requires new source checkpoints and derived bindings;
these old identities cannot describe the corrected implementation.

The separately accepted high-risk plan binds the preserved starting attempt and
the following staged procedure. Future source OIDs are recorded only after their
commits exist; the plan does not guess them. `S` and `B` below are explanatory
labels for actual commits, not branch names, refs or product fields.

1. After that plan lands and the manager reconciles the same paused attempt,
   commit the corrected protocol as package checkpoint S on its existing history.
   Record its actual full commit ID and package path, mode, type and tree object.
   Publish by ordinary fast-forward push on the existing implementation branch.
   The manager verifies remote head/ancestry and independently fetches exact S
   into a fresh isolated history repository with depth one, no tags and unchanged
   source/auth handling. Verify the exact commit and package object before use.
2. Using that verified S, update only the permitted package fields in both
   manifests, their linked profile bindings and canonical manifest hashes, and
   the two independent assembly-test expectations. Commit the resulting profile
   bytes as checkpoint B on the same history. Record its actual full commit ID.
3. Publish that history and independently fetch exact B with the same isolation.
   The manager verifies all four profile files' complete bytes and regular blob
   modes, their canonical hashes, the unchanged S package tree, and the permitted
   structural differences only. Record the exact S/B tuple, retaining branch and
   complete fetch proof before the shadow update uses them.
4. Set the two shadow constants to the verified canonical default file hashes
   from B and its existing pinned-from header to actual B. Commit on the same
   history. The shadow module lies outside the package and profile trees, so this
   final dependent update changes neither source checkpoint's bytes.
5. Before implementation PR publication and protected merge, require fresh exact
   source fetch proof, ancestry and final package/profile/shadow consistency.
   Retain both containing commits on the existing branch under the accepted
   source-retention procedure. Do not depend on a dangling commit or invent a
   future squash/merge ID. An intermediate source push is not green implementation
   evidence, a release or permission to merge.

This procedure records the actual downstream source tuple within an already
accepted plan; it needs no extra plan amendment solely to learn the resulting
commit IDs. A later same-scope protocol/profile change repeats the affected
checkpoint and dependent checks before reuse, retaining the prior history and
invalidating affected review/CI evidence. A change to design, allowed fields,
paths, review size or safety boundaries returns through the affected artifact gate.
No source checkpoint may substitute for final independent exact-head/base review.

Keep the existing separate direct operator gate for the bounded repository-setting
procedure needed to retain the branch after squash merge. This spec grants no
setting write, new ref or weaker protection. The required single-merge window,
raw setting/state evidence, restoration and failure recovery remain in force.

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
- `profiles/default/v1/manifests/local-git-materializer.json`;
- `profiles/default/v1/profile.json`;
- `profiles/alternative/v1/manifests/local-git-materializer.json`;
- `profiles/alternative/v1/profile.json`;
- `scripts/test/default-profile-assembly.test.sh`;
- `scripts/test/alternative-profile-assembly.test.sh`;
- `shadow/v1/materialization-input.jq`, only the two pins and provenance header above;
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

The proof below is required, not a choice of examples. Keep real changed and
no-change materializations, root and ancestor source commits, and both SHA-1 and
SHA-256 through owned disposable fixtures. Positive persistence/retrieval proof
must use actual fixed materializer output. Use separate processes for reopen and
explicit synchronization with watchdogs for crash and concurrency tests.

| Boundary | Required cases and observable result |
| --- | --- |
| Key and journal types | All four stage fields, request hash, operation, attempt, missing/extra fields and ordinal; supplied and saved keys; wrong nested containers, bool versions/attempts and malformed phase/status/algorithm. Check exact ordinary-error versus valid-conflict exit, no traceback and no scanner-ready result. |
| Strict JSON | Duplicate members, BOM, invalid UTF-8 and lone surrogates, truncation, trailing data/extra documents, non-finite spellings and exponent overflow, fractions in integer fields, depth 32/33. Exercise pending/stored journals and response/receipt parsing, including unused optional journal fields. |
| Byte limits | Every inclusive ceiling above and one byte beyond, at the actual file read, stream capture, extracted-document or encoded-journal boundary. If a maximum-sized value cannot have a valid fixed semantic shape, prove the boundary separately and do not call it a valid materialization. |
| Subprocess capture | Real finite subprocess pipes at and above the stdout limit, more-than-pipe-buffer stderr, concurrent stdout/stderr pressure, nonzero exit and injected read failure. Check retained-byte bounds, no deadlock, closed descriptors and reaped child. Include a rejected keyed Git-inventory overflow with full state preservation. |
| Identity | Each saved identity field and frozen input/request/profile/manifest/payload, source repository/commit/tree/algorithm, verifier path/digest, loaded driver, materializer package/generation/files, jq and closure helper. Changed valid identity fails stale/conflict; malformed identity fails ordinarily. |
| Result and receipt | Schema, full refs, IDs, all timestamps, attempt, source/candidate/parent, changed-path count/hash, performer/binding/environment/capability, outcome/output/evidence/metadata and extra claims. Test both raw digest corruption and fully rehashed relation mutations at direct protocol validation and persisted reopen. |
| Pre-effect restart | A pending attempt with empty candidate/scratch roots may perform its first materialization once. Partial candidate or scratch content produces missing evidence without execution. Repeated unavailable reads/redeliveries preserve all bytes. |
| Before-publication crash | After actual materializer return with a candidate present, pause before journal result publication; SIGKILL and wait for death. Reopen reports missing evidence without reconciliation, deletion, new attempt or invocation. |
| After-publication crash | Pause after publication and before any outward response, record the actual captured response independently, assert stdout empty, SIGKILL and wait. Fresh retrieval must equal those original bytes, not merely have a stored status or result shape. |
| Atomic I/O and reply | Inject stored-result publication write, flush, file-fsync, rename and post-rename directory-fsync failures; separately break outward output after successful publication. No failed writer claims stored success. Pre-replacement failures preserve prior usable bytes; after rename a fresh process validates actual state. Cover keyed interruption exit 75. |
| Compatibility | Version 1 unavailable read and key-retrofit refusal; omitted key for both pending/stored version 2 delivery and read; legacy recovery never gains original-result evidence. Keep all unchanged legacy checks. |
| Read and redelivery | Same-key and concurrent callers under one permanent lock cause one real materialization. Retrieval and matching redelivery preserve original bytes; retrieval leaves phase, bundle and lock inode unchanged, creates no missing state/lock/bundle, rejects observations, and works after a separate fixed-verifier failure. |
| Scanner | Actual changed/no-change results classify terminal. Result-ref, digest and rehashed attempt-relation mutations fail through the real scanner. Do not modify scanner code or fabricate execution evidence. |

For every missing, malformed, corrupt, conflicting or stale read/redelivery, snapshot
journal, frozen input, execution bundle and candidate refs/objects before and after;
include candidate/scratch contents in prepublication and capture failures. Inventory
relative entries, types, modes, file bytes and link targets without following links.
Verify the permanent lock inode separately. Exclude access timestamps and test logs
outside the evidence roots, not durable evidence. Take the baseline after deliberate
test mutation so the assertion detects product writes. No cleanup hides a failure.

Keep an independent original-response oracle outside the state being tested. For
relation mutations, recompute the full enclosing hash chain, including journal
materialization summary hashes, not only receiver hashes. Receipt mutations also
update payload hash and every unaffected receipt link. Leave only the intended
semantic relation wrong; separate cases intentionally retain stale digests. Check
fixed expected refs/facts independently rather than using the new response validator
or a regenerated stage_result as its own expected-value oracle. Each table-driven
case has a clear name and its own assertion, even when setup is shared.

Fault injection is private to the existing test-only loaded-driver wrapper pattern.
Target publication faults after real response capture, not incidental earlier
snapshot writes. Synthetic stream children prove capture behavior only. Positive
materialization still delegates to the real fixed implementation. No runtime flag,
new fixture framework, copied exception or production testing interface is added.

Run the new suite, all 40 replay checks, protocol and adapter suites, scanner and
planner suites, both profile-assembly suites, the unchanged target-packaging,
shadow-assembler and shadow-slice suites, the complete existing test runner,
structure validation and pinned Shellcheck 0.11.0.
Compare the four profile files structurally and require only the package revision,
tree and linked manifest-digest changes described above. Verify that both manifests
and both bindings name the same exact materializer package and that every other
field is unchanged. Required CI and separate exact-head/base review remain mandatory.
Run the unchanged shadow-assembler suite against the final real shipped default
files. Require all eight live-pin assertions, canonical output and repeatability,
SHA-1 and SHA-256 source cases, self-consistent lookalike refusal, config-source
mismatch refusals, and its real assembler-to-shadow-driver run to pass. Verify the
shadow module diff contains only the two constants and provenance header, with all
six other profile pins and every validator unchanged. Preserve the failed proof
from the paused head, including the real `E_PROFILE profile.json` refusal and the
separate full-run timeout. Neither continuations nor focused passes turn that
failed full run into a pass. Obtain fresh complete runner and required CI evidence
for the final exact implementation head/base; do not skip a suite, relax a digest
check, widen a timeout or replace real assembly with a synthetic fixture to pass.

The later full native run at paused head
`45f306b3b7d8e6346393101e91005703adca58dc` was safely stopped with exit 143
and preserved; it is not a pass. Keep its full output alongside the earlier
exit-142 run and exit-1 shadow continuation. Run the complete final native runner
without a PTY, with stdin closed and no inherited shard selector, retaining original
logs, tool identities, head/base and actual exit. Require complete suite coverage
and its successful terminal total without timeout increases or command shims.
Final remote proof includes checks, all six test shards and aggregate CI with
original logs, checkout parent/tree identity and complete tracked suite coverage.
Artifact-only CI, focused passes and a green badge do not replace this proof.

Documentation must explain full-directory restoration, format distinction, fixed
limits, unavailable evidence, supported key scope, retrieval and inactive status.

`review_size: accepted-exception`. Plan for 3,300–4,200 added plus removed
implementation lines across the same fifteen exact paths, including tests and docs.
The earlier 800–1,500 and 2,000–3,000 estimates did not account adequately for the
complete accepted proof. The earlier paused head
`45f306b3b7d8e6346393101e91005703adca58dc` measured 1,171 additions and
37 deletions, or 1,208 total, against
`c332aaff66f116c2badf2adb408e39c887383697`; it remains preserved history.

The current clean paused head `528feae88dbbb45b3100f00d58085168f3254d4d`
measures 2,423 additions and 59 deletions, or 2,482 total, against
`adf57b2394a7dbd1451202d15a3a57590d74d374`. Its remote checkpoint remains
`0b662b0c5317c8d27a0331f7204fbe7b62353363`, with implementation PR absent.
Checkpoint 1 and checkpoint 2 fixes have independent acceptance for their bounded
validation and proof changes. Bounded Git capture and the remaining complete proof
are still open; checkpoint acceptance is not final implementation acceptance.
The same attempt is paused for this size amendment and the later separate high-risk
plan amendment. Preserve and freshly reconcile it before resume.

| Area | Current added plus removed | Estimated complete diff |
| --- | ---: | ---: |
| Replay driver, typed validation and bounded capture | 626 | 686–736 |
| Pure fixed materializer response validator | 115 | 115 |
| Receiver suite with complete proof matrix | 1,206 | 2,026–2,486 |
| Direct protocol relation tests | 358 | 358 |
| Documentation, restore entries, four profile files, two assembly tests and shadow pins/header | 177 | 177–201 |
| Total | 2,482 | 3,362–3,896 |

The remaining allocation includes actual source/outcome variants and original-byte
retention; all byte ceilings and bounded stream/caller proof; complete saved and
actual source/tool identity drift; pre-effect restart, both crash windows, atomic
publication failures, broken reply and interruption; filesystem/format refusals;
and scanner negatives. It retains the typed key/journal/parser and direct/persisted
relation cases already implemented. Source checkpoint, packaging, full native and
remote CI proof remain required even where their completion adds no repository
lines. No accepted proof group is deferred to another implementation.

The estimate adds 970–1,469 lines to the current diff and allows only 55–90 lines
of duplicate setup removal. Reuse scanner snapshot construction, CLI invocation
and private wrapper loading without removing distinct cases, preservation checks
or independent oracles. The 3,300–4,200 envelope rounds the lower estimate and
allows 304 lines above the upper forecast for uncertainty in the remaining process
and boundary tests. Even if none of the estimated simplification is safe, the
upper forecast before that saving is 3,951, still below the envelope. This allowance
changes neither scope nor acceptance requirements; it is not work to fill a quota.

Counts are final additions plus removals against the accepted base, not accumulated
edit churn or per-file quotas. The new receiver suite's final length counts once.
Reuse its private helpers and existing fixtures for named cases; introduce no
duplicate test framework or product injection seam. Keep the unchanged 1,152-line
legacy suite and all 40 checks. Recheck the full final diff and exact path set.
The high-risk plan must allocate this range; final review must compare actual size
and full proof.

Bounded capture, exact result/journal validation, separate process-crash windows,
atomic I/O failure proof, negative relations, preservation, real scanner integration
and source binding consistency prove one persistence contract. Splitting off the
missing checks would leave that boundary unproved. An overrun or changed concern
returns through the separate amendment gate; never shorten tests, suppress cases,
compress code or weaken evidence to meet the estimate.

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
schema, constitution, workflow or materializer executable change. Shipped profile
changes are limited to the inactive materializer package references and their
manifest digests specified above; no other profile change is allowed.

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
