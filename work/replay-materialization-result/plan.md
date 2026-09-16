---
spec-blob: c67f2cf79953613986e777f2c1beab20e497b641
drafted: 2026-09-15
---

# Plan: Preserve real materialization results in the replay journal

Tracks #324.

Risk: high. Gate mode: `artifact-high`. Review size: `accepted-exception`.
This plan covers one concern: retaining and retrieving the actual response of
one keyed offline materialization in the existing replay journal.

The amendment source base is `ae5ea2af8711502bf815bb955f4147e37f28f8eb`,
containing the accepted remediation G2 amendment in PR #341. The accepted intent
remains `eb68c51f1a9866599c8662e967fba8375ccfbf3e`. The prior accepted plan is
`c9cb331662d232d18462d5d577ac6256ad7f4a73`. This separate plan amendment must
land before code resumes. The current Roadmap program delegation supplies the
named manager's acceptance process; this author does not accept the plan or appoint
a second manager.

Preserve `ystack/impl/replay-materialization-result` at clean local head
`45f306b3b7d8e6346393101e91005703adca58dc`, recorded remote checkpoint
`0b662b0c5317c8d27a0331f7204fbe7b62353363`, implementation PR absent, and old
base/plan-base `c332aaff66f116c2badf2adb408e39c887383697`. Intake #324 is paused
with `claimed` and `needs-human`, without `ready`. These are the manager's bound
handoff facts; reverify repository, branch, full heads, PR/base/claim and clean
worktree before resume. Never reset, rebase, force-push, recreate or silently replace
this attempt or its earlier commits.

The complete independent content review has SHA-256
`23286d26eb638f67023d96571532cfdb6fb53661d8fda1e326bfc71f6e71ec17` and
`Content-verdict: REVISE` / `VERDICT: FAIL`. It identified malformed journal types
and non-finite numbers, incomplete fixed receipt links, unbounded Git diff capture,
and missing accepted proof. All four must be corrected together. Preserve the
stopped native run at exit 143 and the earlier exit-142 full run, exit-1 shadow
continuation, other harness failures and individual passes. None is a complete
implementation pass. The old 32-file proof index remains SHA-256
`968d286c1498d48069fe97e13cee87271364704b9d879dfac3dbd5ed8a2c6621`.

## Files that change

The plan PR changes only `work/replay-materialization-result/plan.md` on
`ystack/plan/replay-materialization-result`. Its non-merge history must be
plan-only. Resume `ystack/impl/replay-materialization-result` only after the
protected plan amendment merge and the reconciliation below. The implementation
may change only these paths:

| Path | Change |
| --- | --- |
| `delivery/v1/replay.py` | Keyed journal dispatch, strict bounded validation and capture, atomic result storage, and read-only retrieval. |
| `adapters/local-git-materializer/v1/protocol.jq` | A pure validator for the supplied response and receipt using existing input, receipt and core result predicates. |
| `scripts/test/replay-materialization-result.test.sh` | New executable suite with real fixtures, crash/reopen, limits, negative relations, concurrency and scanner proof. |
| `scripts/test/local-git-materializer-protocol.test.sh` | Direct response-validator positives and relation failures. |
| `profiles/default/v1/manifests/local-git-materializer.json` | Only the materializer package tree ID and actual containing revision commit. |
| `profiles/alternative/v1/manifests/local-git-materializer.json` | The same exact materializer package reference update. |
| `profiles/default/v1/profile.json` | Only the materializer binding's matching package reference and linked canonical manifest SHA-256. |
| `profiles/alternative/v1/profile.json` | The same exact binding and manifest-digest update. |
| `scripts/test/default-profile-assembly.test.sh` | Add a fixed materializer commit expectation and isolated exact fetch; retain all existing object and unrelated-pin proof. |
| `scripts/test/alternative-profile-assembly.test.sh` | The same materializer proof, retaining the independent producer pin and every existing check. |
| `shadow/v1/materialization-input.jq` | Only `profile_pin`, `manifest_pins.forge` and the existing pinned-from header; all predicates and other pins stay unchanged. |
| `README.md` | Update the replay component entry and link the storage guide. |
| `docs/components.md` | Describe keyed storage and retrieval alongside the existing offline replay. |
| `docs/replay-materialization-result.md` | New invocation, limits, restoration and recovery guide. |
| `ci/required-files.txt` | Append the new test and guide paths; preserve every existing entry. |

Keep `scripts/test/delivery-replay.test.sh` byte-identical, including all 40
checks. Reuse its `local-git-materializer-fixtures.sh` builder without changing
that builder. `run-all.sh` discovers the new `*.test.sh` automatically. No scanner,
planner, core generation, materializer executable, workflow or constitution change
is needed. Shipped profile changes are limited to the four JSON files and fields
above, with corresponding maintenance in the two assembly tests. Leave packaging validation and `target-packaging.test.sh` unchanged.
All seven dependency files already exist, including the shadow module already
covered by the restore manifest. Only the two originally planned restore manifest
entries are appended. Keep both shadow suites and the shadow shell driver unchanged.

The accepted implementation envelope is 2,000–3,000 added plus removed lines
across these fifteen exact paths. Current head measures 1,171 additions plus
37 deletions, or 1,208 total, against its old base. That incomplete implementation
cannot meet the remaining proof inside the earlier 800–1,500 estimate.

| Area | Current measured | Estimated complete diff |
| --- | ---: | ---: |
| Replay driver, typed validation and bounded capture | 524 | 640–800 |
| Pure fixed response predicate | 49 | 85–125 |
| Receiver suite with complete named proof matrix | 410 | 1,050–1,450 |
| Direct protocol relation tests | 48 | 180–300 |
| README, components, recovery guide and restore entries | 141 | 141–165 |
| Four profile files, two assembly tests and shadow pins/header | 36 | 36–50 |
| Total | 1,208 | 2,132–2,890 |

Counts describe the final complete diff against the accepted base, not edit churn
or quotas. The receiver suite allocation covers real fixture/source setup,
private invocation/mutation/snapshot helpers, typed and relation cases, byte/stream
boundaries, and process-crash/I/O/restart/scanner proof. Reorganize shared setup for
readability without omitting named assertions. Keep helpers inside the two allowed
test files; do not modify the existing fixture-builder file or create a new testing
framework. Its existing algorithm/commit/tree arguments already support the needed
fixtures; extend only this suite's local source/setup helpers for ancestry and cases.

Measure the final diff excluding artifacts already on current main. Preserve the
unchanged 1,152-line legacy suite and all 40 checks. If complete readable work needs
more space, another path or a changed concern, pause for the affected separately
authored amendment. Never compress code, split off required correctness/proof or
drop tests to fit. This remains one persistence boundary.

## Order of work

### 0. Reconcile the preserved attempt after the separate plan merge

Keep implementation paused while this plan-only amendment receives fresh independent
review and all required CI, followed by the named manager's protected merge. Record
the actual fetched default commit containing the plan as the new plan-base; never
write a guessed merge commit into this plan. Recheck intent/spec/plan blobs and both
hash links at that base.

Before resume, the manager verifies exact repository, branch, local and remote head,
PR state, old/current base and clean worktree against the preserved handoff. Resolve
the existing pause and claim on #324 through the current program's recovery sequence.
An unexpected identity or dirty state stops this attempt. Require the prior native
run owner to confirm the stopped run and its exit-143 logs are fully preserved and
no old test process remains active before any writer resumes.

Merge the newly accepted main into that same implementation branch without reset,
rebase or force-push. Record its actual head, clean state, current base and unchanged
accepted artifact hash links. Verify the old package/profile checkpoints remain
ancestors and the current package/profile/shadow bytes match the preserved handoff.
Those old values are historical starting evidence; section 6 deliberately replaces
them after protocol correction under the accepted staged procedure.

Before coder work, the manager records the matching build claim with
`artifact-high/high/plan-refresh`, PR absent, exact local/remote heads and current
base; require `claimed` present and `needs-human` and `ready` absent. The coder does
not edit the accepted artifact chain. A dirty or unexplained identity/state change
stops. Base moves invalidate affected review evidence; reconcile and recheck hashes
through the existing rules. Design/scope/safety changes return to their artifact gate.

### Work checkpoints and one writer

Resume with one implementation writer. Finish and commit each bounded group below
with its focused proof and a concise exact-head case inventory before moving on.
The manager inspects each checkpoint and coordinates read-only substantive review
where needed; checkpoints cannot reset review rounds or evade an unresolved finding.
Any review of a checkpoint names that exact immutable commit. No reviewer edits code
or controls the writer's running tests.

1. Correct journal/key typing and finite-number parsing; add pending/stored type,
   parser and preservation cases. Run those focused cases and legacy regression.
2. Correct fixed result/receipt relations; add direct and persisted fully rehashed
   mutation cases with independent fixed-fact assertions. Run both protocol and
   receiver relation groups, keeping real changed/no-change positives.
3. Reuse one genuinely bounded subprocess capture boundary; prove exact limits,
   concurrent streams, child cleanup and the fixed Git caller with full snapshots.
4. Finish every remaining named proof row: source algorithms/ancestry, restart and
   format transitions, identity mutations, byte/depth limits, full crash/I/O/reply
   oracles, read invariants and scanner negatives. Record a case-to-requirement
   inventory. A count of passing groups alone does not establish coverage.
5. Complete section 6's actual source checkpoints and shadow repair. Run unchanged
   assembly, packaging and shadow proof to establish a coherent candidate. Do not
   describe expected intermediate stale bindings as passing packaging evidence.
6. Freeze that clean coherent head. The single test owner runs the full native
   proof while a separate read-only reviewer performs the substantive exact-head/
   base content and matrix review. This parallelism is review plus execution, not
   concurrent writers. No edit, new commit or source update on this implementation occurs during the
   run. If review requires a correction, have the owner finish or safely
   stop the run and record full output/exit before further edits. Retain its actual
   result and repeat affected checks on the corrected frozen candidate. Required
   remote CI and final independent review still follow the normal PR gates.

Steps 1–5 below retain the full receiver contract and specify the concrete fixes.
The later proof section supplies every checkpoint's named acceptance cases. Existing
working behavior is retained; this is a continuation of the same implementation.

### 1. Separate keyed state from legacy replay before changing execution

Add optional `--delivery-key FILE` and `--read-materialization-result` arguments.
Keep the existing normal identity arguments required. Read mode rejects review
and publisher observations before touching state. It opens only existing state
and the permanent existing `replay.lock`; it must not create that lock, an
execution bundle, a journal, or a frozen input.

Keep one private journal-format dispatch boundary in `replay.py`. Unbound new
runs use schema version 1 and the current phase/recovery behavior. Keyed new runs
use schema version 2. A supplied key cannot attach to version 1; version 2 cannot
be read or resumed without its saved key. Reject unknown versions and malformed
version types. The compatibility branch links to this plan and the accepted spec.
It exists because version 1 has no original response bytes and its established
offline recovery must remain usable. It exposes no migration API. Re-evaluation
requires a separately accepted version 1 retirement or migration change.

Use the existing exclusive lock for both delivery and retrieval, from validation
through capture/publication or final read. Preserve the lock inode. Validate it
as a regular no-follow file before locking, so a FIFO or device cannot stall read
mode. No new inbox, history list, database, cross-directory lookup or generic
storage interface is introduced.

### 2. Add strict bounded reads and complete input/key validation

For the new keyed and result-read paths, build on `read_bytes`'s nonblocking,
no-follow, regular-file boundary. Strictly decode UTF-8 without BOM. Reject
duplicate members, multiple documents, trailing data, non-finite numbers, invalid
Unicode including escaped lone surrogates, malformed nested types, and depth above
32. Catch parse/type/encoding/recursion failures as ordinary diagnostics. Do not
allow Python's bool/int equality to accept booleans in integer fields.

Extend the existing parsed-value walk to reject every non-finite float, including
`1e999` and `-1e999`, not only named NaN/Infinity tokens. Keep finite JSON values
subject to their field-specific type rules. Share the delivery-key shape/type
predicate between supplied and saved keys; separately bind a well-typed key to
frozen input and classify a valid mismatch as conflict. Check the input attempt's
integer type before equality as well.

Before any journal membership, equality, regex or nested lookup, require the
expected type. This includes journal version/phase, source algorithm, receiver
version/status, saved key and its stage fields, and nested identity records.
Version 1 and 2 are true integers; receiver version is integer 1. A pending receiver
has exactly its version/status fields and is valid only in `materializing`. A stored
record always requires its exact response fields, materialization summary and
candidate identities, including when the workflow later failed.

Validate every present version-2 optional record even if the read path will not
consume it: recoverable is boolean, reason/recovery are strings, and materialization,
verification, review and publisher retain their exact field sets and typed values.
Check phase-required records are present and relations agree. Reject unknown fields.
Preserve valid failed-workflow retrieval and every valid legacy state. Diagnose
malformed data at these boundaries; do not substitute a broad late TypeError catch
for typed validation or accidentally convert a programming error into success.

The byte ceilings are inclusive:

| Data | Ceiling |
| --- | ---: |
| Supplied and frozen materialization input | 8 MiB |
| Delivery-key file | 4 KiB |
| Captured response | 1 MiB |
| Canonical extracted stage result | 256 KiB |
| Receipt UTF-8 bytes | 64 KiB |
| Encoded version 2 journal | 8 MiB |
| Version 1 journal and each review/publisher observation | 64 KiB |
| Retained materializer stderr | 64 KiB |
| Read-only Git changed-path inventory | 2 MiB |

A journal read may inspect at most 8 MiB plus the over-limit sentinel byte to
identify its version, then apply the 64 KiB limit to version 1. Check the fully
encoded version 2 journal before every atomic replacement, including later phase
updates. Keep response and receipt envelope limits separate from typed core
document limits; the raw receipt string is not subject to the core's 8 KiB string
limit. Apply `schema::parsed_limits_ok` to each typed core document.

Validate original input canonical bytes using frozen jq 1.6 `-S -c` plus one
newline, with byte comparison against the supplied/frozen input. Recheck each
profile, resolved-profile, manifest and request content pair's canonical digest,
every raw payload digest and its verified-payload relation, the canonical contract,
`input_ok`, and core profile/request relations. Run fixed validators only, with
bounded private temporary data outside the candidate, scratch and journal trees.
Use the frozen module generation and dependencies under the existing cleared
execution environment. No candidate code or input-derived command is executed.

The key is exactly `{stage_key, request_sha256, operation, attempt_number}`;
`stage_key` has exactly the four planner stage ID fields. Use
`reconciliation-plan.jq`'s ID/digest rules, require operation `dispatch-stage`
and integer attempt number `1`, and compare all fields with the frozen request
and attempt. Reject additional fields, including a delivery ordinal. The key is
data and does not authenticate the caller or grant execution permission.

Add the complete key to `input_identity` before deriving `run_key`. Retain all
current immutable fields: exact input/request hashes, source repository and
commit/tree/algorithm, verifier, loaded driver bytes, frozen materializer package
and core generation, jq and object-closure helper. The full input digest also
binds manifests, profile, patch, contract and attempt ID/result ID/timestamps.
Check saved identity against current source/tool bytes and supplied arguments on
every reopen. A same-directory key or input change is a conflict, even when the
candidate tree matches. A fresh journal cannot adopt a populated candidate root.

### 3. Validate the supplied response without constructing a replacement

Add a `validate-response` operation to `protocol.jq`. Pass frozen input, parsed
actual response, and the verified receipt `{content,sha256}` pair as data files
to the fixed jq invocation, avoiding large JSON command arguments. Import the
existing `result_truth` module and reuse `input_ok`, `receipt_relations_ok`,
`receipt_outcome_ok`, and `result::stage_run_ok`. The new operation returns a
validation outcome only; it must not call the `receipt` or `stage-result`
generation operations to provide missing evidence.

Require the exact response envelope and sole payload from the spec: schema 1,
`local_git_materialization_response`, authority `none`, qualification
`{state:unavailable,reason_id:adapter.unqualified}`, and the single
`caller-disposable-candidate-repository` effect. The payload has only its content
ID, media type, SHA-256 and raw data fields; its ID is
`candidate.materialization.receipt` and media type is `application/json`.

Replay hashes the original response bytes and raw receipt UTF-8 bytes, parses
the receipt strictly, and supplies the checked receipt pair. The validator checks
the full receipt reference, adapter/status, request and resolved-profile refs,
selected manifest, patch and contract refs, attempt ID/number, source identity,
candidate bare kind/algorithm/commit/tree/parent, changed-path count/digest, and
changed/no-change relation. Check complete refs, not digest fields alone.

Check the actual typed result's ID, attempt ID/number and all three timestamps
against the frozen attempt. Require completed change outcome and all core
request/profile/execution relations. Check the fixed performer, binding,
environment, capability, deterministic metadata, empty diagnostics and exact
evidence/receipt/output links. Reject extra claims, metadata, outputs or optional
fields that the fixed protocol does not produce. A no-change result has no
candidate output entry but retains its receipt and evidence links.

The generic core intentionally accepts broader producers, so it cannot supply the
fixed adapter's remaining facts. In `response_ok`, require the exact successful
result envelope/body fields and completed status, and compare `reported_by` plus
execution facts with the existing request projection. Define only the expected
receipt content reference from fixed content ID `candidate.materialization.receipt`,
media type `application/json` and verified raw receipt SHA-256. Changed outputs equal
one requested output ID with that entire ref; no-change outputs equal an empty list.
Evidence equals one fixed `evidence.local-git-materialization` item, deterministic,
passed, with that entire proof_ref. Check exact array sizes and field sets.

Require exactly deterministic metadata: provider/model/snapshot/effort/prompt/skills
are their fixed not-applicable records; tools is recorded with empty value and that
same complete source_ref. Reject computed/unavailable alternatives and different
IDs, versions, media types, digests or extra claims, even when generic-core-valid.
Retain all generic predicates and existing receipt relations. Compare these supplied
facts directly; never invoke stage-result/receipt construction as a validator oracle.
Raw receipt parsing and digest verification remain the Python boundary's job.

Extract only the actual response's `stage_result` object with frozen jq 1.6
`-S -c` and one newline; enforce its 256 KiB ceiling and hash that framing. No
separately emitted stage-result file was observed. Validate candidate
commit/tree/parent with read-only Git checks. For no-change, retain the existing
source-as-parent convention even for a root source commit. Check source algorithm
and object identities, and compare the receipt's changed paths with a bounded
read-only tree diff using the materializer's sorted unique path-list framing.
Reuse the materializer's 2 MiB changed-path inventory ceiling and accepted path
rules; hash the canonical list and compare count/digest. This checks saved facts,
without executing a patch or reconstructing a result.

### 4. Bound both fixed subprocesses and publish once

Refactor the existing keyed streaming capture into one private process-capture
boundary used only by the fixed materializer command and fixed read-only Git diff.
Callers provide their already fixed argument vector/environment and byte ceilings;
there is no new public runner, shell interpretation or configurable product command.
Leave legacy materializer/reconciliation behavior unchanged.

Use fixed bounded read chunks and concurrent pipe draining. Retain at most stdout's
limit plus one sentinel byte: 1 MiB for materializer response, 2 MiB for Git paths.
Retain at most 64 KiB diagnostic stderr; further diagnostic bytes can be discarded.
A stdout sentinel irreversibly marks the call failed; never truncate and accept.
The normal overflow path may continue draining/discarding finite output with bounded
retention until the fixed child exits, then report the overflow. Draining further
bytes never appends to retained stdout or clears the overflow failure.
On interruption or I/O exception, stop/reap the owned child and close its pipes;
on every path close descriptors and reap it. Keep existing interruption handling
and cleanup semantics. No timeout increase, retry policy, runtime bypass or new
process-tree guarantee is introduced.

For Git, reject nonzero exit or overflow before splitting or decoding stdout. Then
check the existing sorted, unique, valid-path list and its canonical count/hash
against the receipt. Do not leave an unrestricted `subprocess.run(..., PIPE)` or
`communicate()` at this caller. Materializer stdout overflow likewise cannot publish
a result. Excess diagnostic stderr alone need not reject successful materialization.
The focused tests must exercise real pipes, the helper bounds and the actual fixed
Git call wiring; a helper test alone cannot prove the production call is bounded.

Before first execution, atomically save exact input bytes and a version 2
`materializing` journal whose required `receiver_result` is exactly
`{schema_version:1,status:pending}`. After successful capture and all validation,
publish one replacement containing `receiver_result` with exactly
`schema_version`, `status:stored`, `response_utf8`, `response_sha256`,
`stage_result_sha256`, and `receipt_sha256`; the materialization summary;
candidate identity fields; and phase `verifying`. Preserve the actual UTF-8
response including its trailing newline. Existing summary hashes must agree.

Reuse `atomic_json`/`atomic_bytes`: write, flush and fsync the temporary file,
rename, then fsync the parent directory. No sidecar response pointer or second
publication exists. Emit stored success only after this call returns. An I/O
failure, including directory fsync after rename, is not a successful publication
receipt. A later process may read what is actually present. Do not overwrite a
failed capture with a recoverable failure suggesting fresh roots.

On reopening pending keyed `materializing` state, inspect candidate and scratch
roots without changing either. Empty valid roots allow the same pre-effect
attempt's first materialization. Any content, partial effect, link or ambiguity
produces missing evidence and preserves the journal, frozen input, candidate and
scratch bytes. Never call `reconcile_materialization`, inspect transient scratch
as original-response evidence, delete state, or allocate another attempt. A
damaged stored record is an error, never pending and never a reexecution cue.

Validate stored response bytes, hashes, full input and result relations and
candidate identities before ordinary phase handling. A same-key redelivery
reuses the stored record without invoking the materializer. Existing replay
receipts include that record; read mode supplies the scanner-ready envelope.
Normal replay keeps fixed-content verification, candidate-ref guards and offline
observation guards. All later phase writes preserve the response string and
hashes exactly. A verifier failure is a separate workflow fact and must not
invalidate or replace a valid materializer result.

### 5. Return stored facts without advancing the workflow

Read mode holds the existing lock, validates existing execution-source identity,
frozen input, journal and candidate, then emits one deterministic JSON envelope.
It never builds an execution snapshot, materializes, reconciles, verifies candidate
content against the replay verifier, consumes observations, writes a phase or
acknowledges delivery. Temporary validator files are bounded and private; they
are not persistent result storage.

For valid stored version 2 data with its matching key, return
`delivery_replay_materialization_result`, schema 1, `status:stored`, authority
`none`, qualification `unavailable`, `offline_simulation:true`, saved key and
run key, exact `response_utf8`, extracted `stage_result:{content,sha256}` and the
actual receipt payload. Repeated output is byte-identical. Its exit is 0.

For valid pending data, return an unavailable diagnostic envelope with reason
`replay.materialization-result-missing`; for valid legacy data read without a
key, use `replay.legacy-result-unavailable`. Both exit 3 and contain no
result/receipt fields. Legacy reads still perform their applicable identity
checks. Key/identity conflicts exit 2; malformed or unavailable files exit 1;
existing interruption handling retains 75. No failure output includes a
scanner-ready result. Result storage, a waiting replay exit and workflow
completion remain distinct facts.

### 6. Record actual source checkpoints, then update their consumers

The preserved package checkpoint `529069b731eb5738646928f6c6c07fe5bd61d927`
contains tree `efa85d8f51cb4ac6523f2db5e1418e5c9cb6f8ff` at
`adapters/local-git-materializer/v1`, mode `040000`, type `tree`. The preserved
profile checkpoint `15476b92860608f640a3d480170fd878af3f4b48` contains default
profile SHA-256 `0d1c815783529ad4d4fc285f2966942fedddb087db4cc7703aa137bb30046179`
and materializer manifest SHA-256
`4f7219f25de07df9112fb39f0aa4eac63e8af13ef6f24528a49a8d31d148f065`.
These are historical starting facts. Correcting `protocol.jq` changes the package
tree, so they cannot remain the corrected package/profile/shadow claims.

`S` and `B` below name two observed source checkpoints, not literal OIDs, branches,
refs or product fields. The accepted spec permits this plan to bind the exact
starting attempt and procedure, then record real derived IDs after commits exist.
Learning those resulting IDs alone does not require another plan amendment.

1. Once the current protocol correction and its focused tests are coherent, commit
   or select the actual corrected protocol-containing commit S on this same history.
   Prefer the completed correction/proof checkpoint after groups 1–4, so later
   ordinary test edits do not churn source pins. Read S's full OID and exact package
   path/mode/type/tree; require the current package bytes equal that tree. The
   manager records S as an observed source fact, never a guessed future merge SHA.
2. The manager coordinates an ordinary fast-forward push of the existing
   implementation branch. Verify actual remote head and S ancestry. Independently
   fetch exact S into a fresh isolated history repository through the assembly
   suites' existing history-fetch boundary: depth one, no tags, unchanged source
   repository/auth handling. Verify exact fetched commit, count one, no tags and
   package path/mode/type/object. Preserve raw proof. Local object existence or a
   remote-tracking ref is insufficient. This source push does not claim full green
   packaging or implementation acceptance.
3. Only after S is recorded and verified, change `body.package_ref.object_id` and
   `body.package_ref.revision.commit_id` in both materializer manifests to its exact
   tree/revision. Canonicalize with frozen jq 1.6 `-S -c` plus one newline and hash
   those bytes. In each profile's sole `adapter.local-git-materializer.v1` binding,
   copy that package reference and update only `manifest_ref.sha256`. Give both
   assembly suites the independently verified fixed S expectation and preserve
   their isolated fetch, depth/no-tags and path/mode/type/object checks. Do not
   derive expected commits from the profile under test. Retain other common
   package/prompt pins and the alternative suite's independent producer pin.
4. Commit these six dependency files as profile checkpoint B on the same history.
   Read B's actual full OID. Publish by ordinary fast-forward push and verify the
   new remote head, S/B ancestry and unchanged S package tree. Independently fetch
   exact B into another fresh isolated depth-one, no-tags history repository.
   Verify all four profile files as regular `100644` blobs, their complete bytes
   and canonical hashes against the current checkout, and only the permitted
   structural differences from the accepted base. All authority records, Roadmap
   digests, roles, principals, boundaries, capabilities, permissions, qualification,
   models and unrelated package/prompt/config fields must match that base.
5. Before the shadow repair, the manager records the actual verified S/B tuple,
   package object, four document hashes, retaining branch and raw fetch proof.
   Change precisely three lines in `shadow/v1/materialization-input.jq`:
   `profile_pin` equals B's default profile SHA-256; `manifest_pins.forge` equals B's
   default materializer manifest SHA-256; the existing pinned-from header names B.
   Retain the six other document pins, all decision text/digest pins,
   `digest_mismatch`, `config_pins_ok`, profile graph checks and every other predicate
   byte-for-byte. Commit this dependent repair on the same branch before packaging
   proof that reads actual HEAD. No old/new alternative pin acceptance or fallback.
6. Verify final HEAD still contains S's exact materializer tree and B's exact four
   profile files. The shadow module is outside both trees and has no downstream
   byte pin, so its update introduces no recursive dependency. Run unchanged real
   assembly, packaging and both shadow suites. Repeat fresh source ancestry and
   exact fetch/content proof for S and B before implementation PR publication and
   before protected merge; keep the complete final tuple with implementation proof.

S precedes the canonical bindings; B contains those bindings and precedes its shadow
header. No file names its own future commit. Later same-scope protocol changes
repeat S and every dependent step; a profile change repeats B and its downstream
steps after rechecking S. Preserve previous history and invalidate affected review/
CI evidence. A replay-only or test-only change that leaves both source trees and
profile bytes unchanged need not churn those pins, but still needs applicable
fresh content/behavior proof. Changed design, allowed fields, paths, size or safety
returns to the corresponding artifact gate. Source records never replace final
independent exact-head/base review.

Retain the published implementation branch after squash merge, with both final S/B
containing commits still reachable; do not delete or rewrite it while package or
profile provenance references them. The prior fresh repository inspection reported
`delete_branch_on_merge: true`; re-read it before the setting boundary. Omitting a
CLI deletion option does not prevent server deletion. A squash merge does not retain these original source commits in
main's history, and a temporarily dangling object is not a restoration guarantee.

The necessary retention procedure below requires the operator's separate direct
approval for this new repository-setting write. It is not supplied by the Roadmap
delegation or this draft. The manager obtains independent review of the concrete
procedure before requesting that approval. Drafting, review and authorized
implementation preparation can continue; the setting mutation and implementation
merge wait for this decision. Do not add another ref, change merge protection or
use an unproved retained-PR-ref guarantee as a substitute.

1. Prepare the complete exact-head/base implementation review and required green
   CI. Record both containing commits, the package tree and profile digests,
   implementation branch and exact remote head. Verify both source ancestors and
   fresh isolated exact fetches with their respective tree/document checks. Obtain
   operator approval to change only `delete_branch_on_merge` from true to false for
   this one protected implementation merge and restore true afterward, including failure cleanup.
2. Before changing the setting, reserve a single-merge window: the named manager
   starts no other merge until the setting is restored and verified. Capture fresh
   repository identity and deletion-setting evidence, exact branch/head/base/PR
   state, required CI, and unchanged protection/rules. Require the expected setting
   true. An unexpected value or concurrent merge stops before the write.
3. Set only `delete_branch_on_merge` to false and read it back. Retain raw request
   and response evidence without credentials. Recheck exact review, head/base and
   all required CI, then perform only the authorized protected squash merge with
   no branch-deletion request. No ruleset, protection, merge-method or permission
   change is allowed. The temporary setting alone never grants merge authority.
4. Read the actual merge receipt and verify main, closed/merged PR, unchanged remote
   implementation branch head, both source ancestors and fresh isolated exact fetches
   with package tree and profile document checks. Record complete raw evidence and
   the retaining branch in the implementation receipt. Restore
   `delete_branch_on_merge` to true, read it back, and verify protection/rules unchanged. Recheck the branch and exact
   source fetches and content checks after restoration. Restoring this event-triggered
   setting does not issue a deletion for an already merged branch; fresh checks
   establish that this particular branch and both sources remain available.
5. If any step fails or returns an uncertain result after the setting write, stop
   other merges, preserve the branch and record the exact partial state. Reconcile
   the server PR/main/branch before any merge retry; do not duplicate an uncertain
   merge. Restore true and verify it even when the merge did not happen or source
   verification failed. Capture the recovery evidence. If restoration cannot be
   verified, notify the operator and keep all merges stopped; do not claim completion
   or retry unrelated writes. A lost branch/source requires explicit disposition,
   never silent branch recreation or reliance on an unreferenced commit.

Both containing commits, the package tree, profile digests, retaining branch and
exact fetch proofs belong in the implementation evidence and merge receipt.
Restoration needs this published history as well as the profile bytes. No tag,
release, retention service, installation or activation is introduced. If the operator does not approve the bounded setting procedure, or the
existing source cannot retain and serve both commits, keep implementation unmerged
and preserve the attempt for a separately accepted alternative.

### 7. Finish documentation and restore coverage

Document the exact key file and retrieval command with the normal identity
arguments, both journal versions, limits, exit meanings, missing-result recovery
and the two crash windows. Explain that restoration needs the complete state
directory including frozen execution and permanent lock, plus the same source,
candidate and scratch boundaries and exact dependency/driver identities. Restored
paths still must satisfy privacy, ownership and disjointness checks. Include the
materializer and profile containing-commit retention and exact-fetch requirements
above. Partial copies and changed tools cannot be promoted to original-result evidence.

State the limits visibly: one key/attempt per state directory; no cross-directory
deduplication; no new ordinal effect; no acknowledgement; inactive offline
simulation; no provenance or authority from digest consistency; process-crash
proof does not establish power-loss or external exactly-once guarantees.

## Risks

The riskiest change is dispatching recovery before any old reconciliation or
failure-state rewrite runs. Keep that decision at one private boundary and test
pending/stored/version-1 states through both keyed and unkeyed invocations.
Retaining only the old summary or regenerating a deterministic result would hide
the lost-evidence window, so both alternatives are rejected.

Strict parsing must precede jq, which can discard duplicate JSON members or
normalize malformed framing. Python canonical JSON is not interchangeable with
the frozen jq framing used for core pair hashes. Bound raw receipt strings
separately and check each embedded typed document's own parsed limits.

Read mode must branch before `create_execution_snapshot`, candidate verification
or phase writes. Restoring a missing bundle would mutate the evidence under
inspection. A separate response file would add a pointer/bytes crash window;
inline retention avoids it. No new storage service or supervisor is warranted.

Caller-owned storage can be forged, and a journal lock does not constrain another
owner process mutating a candidate directly. Recheck current identities and keep
the existing ordinary replay guards, without claiming hostile-owner protection.
No new authentication, qualification, retry, sender, ledger update, dispatch loop,
model execution, installation, activation, target execution or deployment follows
from this work. Preserved #271 work, #297/#307 storage, frozen #183 and unresolved
dirty attempts remain outside this plan.

## Proof

Use the existing fixture builder, fixed real materializer, owned disposable bare
repositories and private state/scratch roots, pinned native jq 1.6 and the compiled
existing object-closure helper. Support the existing Linux and macOS environments.
Do not change `local-git-materializer-fixtures.sh` or the legacy replay suite. This
suite's local `make_source` helper can accept algorithm/ancestry and pass the resulting
commit/tree to the existing builder. Remove the redundant intentionally failed
mktree attempt while retaining valid fixture construction and proof.

Keep test helpers private within the allowed receiver/protocol test files. Share
one loaded-driver test wrapper for invocation counting, synchronized pauses, targeted
faults and isolated boundary calls. It loads actual driver bytes through the existing
`_REPLAY_DRIVER_BYTES` pattern. Positive materialization delegates to the real fixed
implementation. Do not copy its validators into a test oracle, add a shipped helper
or install a runtime environment flag. Protocol tests retain their own small pure
input/response bundle helper; this is not a second integration framework.

### Shared preservation and mutation rules

Build valid baseline states from actual materializations and restore separate owned
case fixtures between mutations. Snapshot the evidence immediately after deliberate
test setup/mutation, before the operation under test. Inventory relative entry names,
types, modes, complete file hashes/bytes and symlink targets without following them
for journal, frozen input, execution bundle, candidate refs/objects and applicable
scratch contents. Record the permanent lock inode separately. Exclude access times
and test logs outside the evidence roots, not durable data. Apply comparison to every
missing, malformed, corrupt, conflicting or stale read/redelivery. Fault cases use
the correct pre/post-publication oracle described below, not unconditional rollback.

For semantic response/result/receipt mutations, recompute the entire enclosing hash
chain using the pinned jq framing and independent SHA-256: receipt raw data/payload
hash and unaffected receipt refs where relevant; extracted stage-result digest;
response digest; receiver fields; and journal materialization summary digests.
Leave only the targeted relation wrong. A stale materialization.response_sha256
must not mask a missing validator check. Separate digest-corruption cases intentionally
leave the relevant digest stale. Assert the single intended change from a valid
baseline. Independent expected receipt refs/facts come from fixed protocol constants,
actual input and captured receipt bytes, never the new validator or a regenerated
stage_result. Each case has a descriptive name and its own assertion/report.

### Named case matrix

The identifiers below group related cases; they are not one assertion per row.
Maintain a case-to-requirement inventory with actual case names and outcomes. Neither
an aggregate count nor older unbound checks substitute for the required keyed cases.

| ID / group | Required cases and oracle |
| --- | --- |
| P01 real source variants | Changed and no-change for SHA-1/SHA-256 and root/ancestor sources. Verify source commit/tree/algorithm, actual candidate commit/tree/parent, retained response/receipt bytes and canonical result digest. For no-change, require source-as-parent convention even at a root source. Every positive uses the fixed real materializer. |
| P02 retention/read/lock | Separate-process repeated retrieval equals independently captured original response, including final newline and raw receipt. Same-key redelivery and concurrent callers yield one counted real invocation; stored reopen adds none. Read leaves phase, execution bundle and lock inode unchanged, consumes no observation, and remains usable after a separate fixed-verifier failure. |
| P03 supplied/stored keys | Each of four stage IDs, request digest, operation and integer attempt; omitted/extra/malformed fields, unknown ordinal, unsupported operation/attempt, nested null/list/object, booleans/fractions and valid conflicting values. Reuse strict rules for saved keys. Malformed returns 1, a well-typed binding conflict 2, with no traceback, scanner-ready result or evidence mutation. |
| P04 typed journals | Pending and stored discriminators/version/phase/source algorithm, saved identities, optional recoverable/reason/recovery and each optional record; malformed nested types and unknown/missing fields. Pending only materializing; stored requires summary/candidates even in failed phase. Cover true versus integer 1 and false versus integer 0. Validate every present unused field and preserve valid failed-workflow reads. |
| P05 strict parser | Duplicate members, BOM, invalid UTF-8, lone-surrogate escapes, truncation, trailing/extra documents, NaN/Infinity and positive/negative exponent overflow, invalid integer fractions, depth 32/33. Exercise keys, pending/stored journals and actual response/receipt boundaries, including otherwise unused optional data. No uncaught parse/type/encoding/recursion traceback. |
| P06 byte ceilings | Inclusive maximum and +1 for supplied/frozen input 8 MiB, key 4 KiB, response 1 MiB, extracted stage 256 KiB, receipt 64 KiB, encoded/read v2 journal 8 MiB, unchanged v1/observations 64 KiB, retained stderr 64 KiB and Git paths 2 MiB. Test actual helper/caller wiring. If semantic shapes cannot attain a ceiling, test that boundary separately without claiming a valid materialization. |
| P07 identity drift | Every saved input/request/run/driver/materializer/helper/jq digest; source repository/commit/tree/algorithm; verifier ID/path/expected digest; materializer package generation/file set/file digests/aggregate; frozen profile/resolved-profile/manifest/payload/attempt identities. Cover actual source-tool byte drift and corresponding saved-record mutations. Rehash to reach targeted relations where needed. Malformed is ordinary error; valid changed identity is stale/conflict. |
| P08 fixed response/result/receipt | Direct protocol and stored reopen cases for envelope version/kind/authority/qualification/effects/payload count and fixed fields; complete document/content refs (version/kind/ID/media/digest as applicable); all attempt/time/result fields; source/candidate kind/algorithm/commit/tree/parent and changed-path count/hash; changed/no-change outcome; reported performer/binding/environment/capability; output ID/full ref; evidence ID/kind/verdict/full proof ref; every metadata fact, tools state/value/full source ref; extra/absent fields and cardinalities. Include core-valid wrong receipt refs and computed tools facts. Rehash all unaffected enclosing links; retain separate raw digest failures. |
| P09 restart/missing effect | Synchronize a pending pre-effect state with empty candidate/scratch and prove same first attempt runs once. Partial/nonempty candidate and partial scratch never materialize or reconcile; repeated unavailable read/redelivery retains complete evidence. A damaged stored record cannot fall back to pending. Fresh journal cannot adopt a populated candidate. |
| P10 both SIGKILL windows | Wrapper records actual captured materializer stdout to an independent test-owned oracle outside evidence roots. Pause after real effect before stored journal replacement, SIGKILL and wait; full snapshots remain unchanged on repeated missing-result reopen. Separately pause after stored replacement before outward response, assert empty stdout, SIGKILL and wait; a fresh process returns exact oracle bytes, not merely matching result shape. Use explicit ready/release synchronization and watchdogs. |
| P11 publication/reply/interruption | Inject write, flush, file-fsync, rename and directory-fsync failures only during stored-result publication after real capture. No outward stored success. Before replacement, compare prior pending journal/input/candidate/scratch; after rename, fresh read may establish valid stored bytes and must equal original response. Break the outward pipe after successful publication and retrieve original bytes later. Exercise keyed signal/interruption exit 75 separately. |
| P12 bounded process capture | Real finite subprocesses at stdout limit/+1, long stderr before stdout and interleaved pipe pressure, nonzero exit, early EOF and injected read failure. Check retained lengths, overflow failure, no deadlock and reaped/closed child. Keep a genuine fixed-Git integration case and exercise the actual Git caller via test-only command-checked overflow injection plus a full keyed-reopen snapshot; reject an unbounded run/communicate fallback. Synthetic streams prove bounds only. |
| P13 format/read refusal | Version-1 unavailable read and retrofit-key refusal; no key on pending/stored v2 for both read and delivery; legacy remains version 1. Missing journal/lock/bundle/frozen input cannot be created by read. Review and publisher observations are refused. Missing/linked/nonregular key, input and journal files fail promptly without following or rewriting; owned FIFO fixtures use watchdogs. Run all unchanged legacy checks. |
| P14 scanner | Canonical one-item snapshot from frozen request/resolved-profile and actual retrieved result pairs; absent active attempt, compatible retry limit/time and exact source revision under current core pins. Call the real scanner. Changed/no-change classify terminal; wrong result refs, wrong digest and fully rehashed attempt mismatch are rejected. Scanner/planner code stays unchanged. |
| P15 source/binding closure | Actual S/B published ancestry and fresh isolated exact fetches; four JSON structural comparisons permitting only the stated fields; independent assembly expectations and unchanged unrelated pins; exact three-line shadow diff, all eight live pins, canonical/repeatable assembly, both Git formats, same-ID lookalike and config-source refusals, and genuine assembler-to-driver run. Unchanged packaging and shadow suites must pass. |
| P16 complete candidate | Frozen clean final head/base: all named focused cases, full unchanged legacy suite, complete non-PTY closed-stdin native runner, structure and pinned Shellcheck, full original required remote CI logs and independent content/final review. Retain every stopped/failed attempt; require actual final successful exit and complete tracked suite coverage. |

For P11, scope monkeypatches to the stored `run.json` publication call, not earlier
execution-bundle/frozen-input writes or temporary validator files. Identify the
file-fsync and directory-fsync separately. Before replacement an injected error
must preserve the prior usable journal; after replacement do not require rollback
or label the writer successful. Preserve and inspect what the fresh process sees.
For P10/P11, the response oracle is captured from the real subprocess return before
journal serialization, never read back from the result being asserted.

For P06/P12, large but semantically invalid bounded values test the read/capture
primitive only; pair them with actual caller wiring assertions and valid smaller
end-to-end cases. Do not weaken semantic validators to manufacture a maximum-sized
valid result. Use finite child streams, fixed test deadlines and process cleanup;
observe retained buffer lengths rather than flaky whole-process RSS thresholds.
The keyed Git overflow refusal compares all prior evidence bytes. No test injects
candidate code or changes the product's command/environment selection.

Run these commands from the implementation checkout and retain output tied to its
exact head/base:

```sh
bash scripts/test/replay-materialization-result.test.sh
bash scripts/test/delivery-replay.test.sh
bash scripts/test/local-git-materializer-protocol.test.sh
bash scripts/test/local-git-materializer-adapter.test.sh
bash scripts/test/orchestrator-state-scanner.test.sh
bash scripts/test/orchestrator-reconciliation-plan.test.sh
bash scripts/test/default-profile-assembly.test.sh
bash scripts/test/alternative-profile-assembly.test.sh
bash scripts/test/target-packaging.test.sh
bash scripts/test/shadow-assembler.test.sh
bash scripts/test/shadow-slice.test.sh
bash scripts/test/run-all.sh
git diff --check
```

Run the complete native `bash scripts/test/run-all.sh` in the existing authorized
development environment without a PTY, with stdin closed and the existing tools,
timeouts and suite inventory unchanged. Ensure no inherited shard selector limits
this full run. Capture its entire stdout/stderr, actual process exit, head/base,
tool identities and start/end times. The non-PTY invocation avoids the prior
interactive cleanup prompts; it does not waive a timeout, add a command shim or
turn a continuation into a complete run. Require all discovered suites and the
runner's successful terminal total. If a harness or product failure recurs, preserve
its complete output and diagnose it; do not claim completion or change files beyond
this plan to hide it. Do not skip tests, increase timeouts, relax digest checks or
substitute synthetic assembly for the genuine shipped-profile run.

The safely stopped exit-143 native run stays incomplete; the earlier exit-142 full
run and exit-1 shadow continuation stay failed in their saved records. New focused passes and the plan-only PR's CI do not supersede those
facts. Obtain fresh complete required remote CI for the final implementation
head/base: checks, all six test shards and aggregate ci. Retain the original logs,
verify the checkout parent/tree identity and full tracked suite coverage, and do not
substitute a green badge or unrelated check for that evidence. A head/base change
invalidates affected proof and requires the current program's fresh review gate.

Run the exact manifest loop in `.github/workflows/ci.yml`'s “Check required files
exist” step; require every listed file and executable `scripts/*.sh`. Verify
`shellcheck --version` is 0.11.0, then run the repository-wide pinned check:

```sh
find . -name '*.sh' -not -path './.git/*' -print0 |
  xargs -0 shellcheck -x -S style
```

Use a verified existing pinned binary or the workflow's pinned release/digest;
do not substitute a different version. Before completion, check the diff for
clear redundancy, the exact allowed paths, unchanged legacy suite, appended
manifest entries and actual added-plus-removed size. Preserve all meaningful
tests and evidence. The manager reads the complete separate independent review,
resolves Important findings and verifies all required CI on the exact head/base
before a protected merge and receipt. A moved base or changed artifact requires
fresh acceptance under the current program rules.
