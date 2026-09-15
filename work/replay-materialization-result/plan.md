---
spec-blob: 466079bb084b8b58bd5d09bdca322d0b03d6ce15
drafted: 2026-09-15
---

# Plan: Preserve real materialization results in the replay journal

Tracks #324.

Risk: high. Gate mode: `artifact-high`. Review size: `accepted-exception`.
This plan covers one concern: retaining and retrieving the actual response of
one keyed offline materialization in the existing replay journal.

The amendment source base is `f7bc0dc641041e568b76dcb8185ec094d5730df3`,
containing the accepted G2 amendment in PR #335. The accepted intent blob remains
`eb68c51f1a9866599c8662e967fba8375ccfbf3e`; the spec links to that exact blob.
The separate plan amendment must land before implementation resumes. The current
Roadmap program delegation in `work/roadmap-program-authorization/decision.md`
supplies the named manager's acceptance process. This draft neither accepts itself
nor authorizes a second manager.

The preserved implementation is `ystack/impl/replay-materialization-result` at
`db685b5c7f38f4f105d2ac727e4934f6535a3c9b`, with a clean worktree and old
base/plan-base `70d1a6a06f701514d56628653d48d59043b8672c`. Its recorded PR state
is absent; intake #324 is paused with `claimed` and `needs-human`, without `ready`.
These are the preserved facts, not a substitute for the manager's fresh server
and worktree check. Keep this same attempt. Do not discard, recreate or rewrite it.

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
| `README.md` | Update the replay component entry and link the storage guide. |
| `docs/components.md` | Describe keyed storage and retrieval alongside the existing offline replay. |
| `docs/replay-materialization-result.md` | New invocation, limits, restoration and recovery guide. |
| `ci/required-files.txt` | Append the new test and guide paths; preserve every existing entry. |

Keep `scripts/test/delivery-replay.test.sh` byte-identical, including all 40
checks. Reuse its `local-git-materializer-fixtures.sh` builder without changing
that builder. `run-all.sh` discovers the new `*.test.sh` automatically. No scanner,
planner, core generation, materializer executable, workflow or constitution change
is needed. Shipped profile changes are limited to the six dependency paths and
fields above. Leave packaging validation and `target-packaging.test.sh` unchanged.
All six dependency files already exist; only the two originally planned restore
manifest entries are appended.

The accepted implementation envelope remains 800–1,500 added plus removed lines
across these fourteen exact paths. The preserved implementation measures 1,172
lines across the original eight paths: replay 524, protocol 49, new receiver tests
410, direct protocol tests 48, documentation 139 and restore manifest 2. These are
measurements of the paused attempt, not proof that its unfinished work passes.

| Work | Added plus removed lines |
| --- | ---: |
| Preserved implementation across the original eight paths | 1,172 measured |
| Four canonical one-line JSON replacements | 8 expected |
| Two explicit materializer commit/fetch test updates | 16–60 estimated |
| Remaining receiver corrections and proof, if needed | 0–260 estimated |
| Expected complete diff within the accepted envelope | 1,196–1,500 estimated |

The remaining allocations explain how the necessary dependency work fits the
accepted upper bound. They are not per-file quotas or permission to trim proof.
The source baseline remains an 875-line replay, 435-line protocol, 1,152-line
unchanged replay suite and 356-line protocol suite. The response validator, crash
boundary, scanner proof and package consistency must land together to prove this
one persistence contract. Measure the complete implementation diff against fresh
main before review, excluding artifact changes already on that base. If complete,
readable work needs more space, pause for a separately authored and reviewed
amendment. Do not compress code or remove tests to fit an estimate.

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
An unexpected identity or dirty state stops this attempt.

Merge the newly accepted main into that same implementation branch without reset,
rebase or force-push. Record the resulting actual head and verify a clean worktree,
unchanged accepted artifact links and the current base. Before coder work, record a
fresh matching build claim with `artifact-high/high/plan-refresh`, PR absent and
this reconciled exact tuple; require `claimed` present and `needs-human` and `ready`
absent. The coder does not edit the artifact chain. Prior implementation review
evidence is stale. A later base move requires renewed exact-base checks and
independent review; changed artifact meaning returns through the affected gate.

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

### 4. Capture and publish once at the existing atomic boundary

Give the keyed materialization path bounded streaming stdout/stderr capture.
Drain both pipes concurrently with fixed read chunks to avoid pipe deadlock.
Retain no more than 1 MiB stdout and 64 KiB stderr; detect one byte beyond each
ceiling. Excess stdout makes capture fail. Excess stderr may be drained and
discarded beyond the diagnostic ceiling. Always reap the child, close pipes, and
honor existing interruption handling. Use no retry policy or product fault flag;
leave the fixed materializer's cleanup semantics unchanged. Keep the legacy
`run_materializer`/reconciliation contract usable by the unchanged 40-check suite.

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

### 6. Publish a real package source before synchronizing inactive bindings

The response validator changes the bound materializer tree. At the preserved head,
`adapters/local-git-materializer/v1` is mode `040000`, type `tree`, object
`efa85d8f51cb4ac6523f2db5e1418e5c9cb6f8ff`. The old profile tree is
`277863b98b49e54e2cd826b3f32913fd49c51abf` at commit
`a637451d4b3fbef6b516a9c08f68c0dde46a7059`. Packaging correctly refuses this
mismatch. Update the ordinary bindings; do not weaken that refusal or move the
validator to hide the package change.

After reconciliation and any protocol corrections, select an actual commit on the
preserved implementation history containing the final materializer tree. The paused
head may supply it only if that exact tree remains correct. Otherwise commit the
corrected protocol first and record the resulting real containing commit. Read its
exact path, mode, type and object ID from Git and verify that the implementation's
package tree equals it. This source commit predates the binding update, so no file
needs its own commit ID or a future squash/merge ID.

The manager coordinates publication through the existing implementation branch in
the existing source repository, using only an ordinary push of the preserved history.
Record the exact published head and prove the selected source commit is reachable
from it. Before accepting it as a binding, fetch that exact commit from the source
into a fresh isolated history repository using the assembly suites' existing
`history_fetch` boundary: depth one, no tags, unchanged source/auth handling. Verify
the fetched commit ID and exact package path/mode/type/object. Local object existence
or a remote-tracking ref alone does not prove source fetchability. An intermediate
source push is not a green implementation or permission to merge it.

Then change only `body.package_ref.object_id` and
`body.package_ref.revision.commit_id` in each materializer manifest. Use the same
verified tree and containing commit for both. Serialize final manifest bytes with
frozen jq 1.6 `-S -c` and one newline; hash those exact bytes. In each profile's sole
`adapter.local-git-materializer.v1` binding, copy the identical package reference
and update only `manifest_ref.sha256` to that manifest digest. Preserve canonical
profile framing. All other package, prompt and config pins, manifest/profile fields,
authority records, Roadmap digests, roles, principals, boundaries, capabilities,
permissions, models and qualification behavior stay unchanged.

Give both assembly suites one fixed `materializer_package_commit` value taken from
the independently checked source commit. Fetch it explicitly into their disposable
history repositories and assert its exact commit, depth one and absence of tags.
In each manifest loop, use that expectation only for
`adapter.local-git-materializer.v1`; retain exact revision/path/mode/type/object
checks. Preserve the common `package_commit` for all other applicable packages and
prompts, and the alternative suite's independent `producer_package_commit`. Never
read an expected commit back from the candidate manifest/profile or weaken checks
to permit an arbitrary revision.

Commit the completed bindings and test maintenance on the same implementation
branch before the unchanged packaging suite runs, because that suite packages actual
HEAD. Verify the final HEAD's materializer tree still equals the recorded source
and both profiles. Any subsequent materializer change requires another actual
containing commit, publication/fetch verification and recomputed binding/digest/test
links in this same order before fresh proof.

Retain the published implementation branch after squash merge, with the selected
source commit still reachable; do not delete or rewrite it while bindings reference
that source. The manager's fresh repository inspection reports
`delete_branch_on_merge: true`. Omitting a CLI deletion option does not prevent
server deletion. A squash merge does not retain this original source commit in
main's history, and a temporarily dangling object is not a restoration guarantee.

The necessary retention procedure below requires the operator's separate direct
approval for this new repository-setting write. It is not supplied by the Roadmap
delegation or this draft. The manager obtains independent review of the concrete
procedure before requesting that approval. Drafting, review and authorized
implementation preparation can continue; the setting mutation and implementation
merge wait for this decision. Do not add another ref, change merge protection or
use an unproved retained-PR-ref guarantee as a substitute.

1. Prepare the complete exact-head/base implementation review and required green
   CI. Record the source commit/tree, implementation branch and exact remote head.
   Verify source ancestry and a fresh isolated exact fetch. Obtain operator approval
   to change only `delete_branch_on_merge` from true to false for this one protected
   implementation merge and restore true afterward, including failure cleanup.
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
   implementation branch head, source ancestry and fresh isolated exact fetch of
   the source commit/tree. Record complete raw evidence and the retaining branch
   in the implementation receipt. Restore `delete_branch_on_merge` to true, read
   it back, and verify protection/rules unchanged. Recheck the branch and exact
   source fetch after restoration. Restoring this event-triggered setting does
   not issue a deletion for an already merged branch; the fresh checks establish
   that this particular branch and source remain available.
5. If any step fails or returns an uncertain result after the setting write, stop
   other merges, preserve the branch and record the exact partial state. Reconcile
   the server PR/main/branch before any merge retry; do not duplicate an uncertain
   merge. Restore true and verify it even when the merge did not happen or source
   verification failed. Capture the recovery evidence. If restoration cannot be
   verified, notify the operator and keep all merges stopped; do not claim completion
   or retry unrelated writes. A lost branch/source requires explicit disposition,
   never silent branch recreation or reliance on an unreferenced commit.

The source commit, tree, retaining branch and fetch proof belong in the implementation
evidence and merge receipt. Restoration needs this published history as well as the
profile bytes. No tag, release, retention service, installation or activation is
introduced. If the operator does not approve the bounded setting procedure, or the
existing source cannot retain and serve the commit, keep implementation unmerged
and preserve the attempt for a separately accepted alternative.

### 7. Finish documentation and restore coverage

Document the exact key file and retrieval command with the normal identity
arguments, both journal versions, limits, exit meanings, missing-result recovery
and the two crash windows. Explain that restoration needs the complete state
directory including frozen execution and permanent lock, plus the same source,
candidate and scratch boundaries and exact dependency/driver identities. Restored
paths still must satisfy privacy, ownership and disjointness checks. Include the
materializer source-commit retention and exact-fetch requirement above. Partial
copies and changed tools cannot be promoted to original-result evidence.

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

Add tests alongside each behavior. Use the existing fixture builder and real
fixed materializer for execution proof, owned disposable bare repositories,
private state/scratch directories, pinned native jq 1.6 and the compiled existing
object-closure helper. Tests must work on the existing supported Linux and macOS
paths. Cover changed/no-change, root/ancestor source commits and SHA-1/SHA-256.

1. Capture and retrieve actual response/receipt bytes in separate processes;
   compare exact strings including newline and canonical result hashes. Assert
   same-key redelivery and concurrent callers under one lock cause one logical
   materialization. A test-only loaded-driver wrapper counts invocations and
   delegates to the real materializer. Reopen must not invoke it again.
2. Use the existing `_REPLAY_DRIVER_BYTES` wrapper pattern with explicit ready and
   release synchronization, watchdogs and separate processes. Stop immediately
   after real materializer return while candidate exists but before `atomic_json`;
   SIGKILL and wait for death. Reopen reports missing evidence and retains all
   state. Separately stop after successful result publication and before any
   outward response; SIGKILL and retrieve the original bytes in a fresh process.
   Prove stdout was empty at the latter pause. Test an empty pending pre-effect
   restart, partial/nonempty scratch roots, and repeated missing-evidence reopen.
3. Snapshot file bytes and candidate refs/objects before every missing, malformed,
   corrupt, conflicting or stale read/redelivery. Compare them afterward,
   including frozen input and journal; compare scratch state in the prepublication
   failure cases. Verify read mode preserves the execution bundle, lock inode and
   phase, creates no missing state, rejects observations, and remains usable after
   a separate fixed-verifier failure.
4. Exercise every key field and shape, omitted/wrong key, unsupported operation or
   attempt, new ordinal, input/source/tool drift and each saved identity binding.
   Corrupt response, result and receipt hashes and all full-ref, attempt/time,
   source/candidate, output/evidence/metadata/outcome relations. Rehash corrupted
   contents in relation tests so rejection is not merely a digest mismatch.
   Cover both direct protocol validation and persisted-record reopening.
5. Cover duplicate members, BOM, invalid UTF-8 and escaped Unicode, truncation,
   trailing data, extra JSON documents, unknown fields, missing payloads, booleans
   in integer fields, fractions/non-finite numbers, depth 32/33 and each inclusive
   byte ceiling plus one. Where fixed shapes cannot produce a semantically valid
   maximum-size value, test the read/capture boundary separately from semantic
   rejection. Oversized stdout/stderr tests exercise the actual streaming capture
   path with test-only subprocess output and verify retained byte bounds and no
   deadlock. No runtime bypass flag or fake positive materialization is added.
6. Inject publication write/fsync/rename failures and post-rename directory-fsync
   failure through the loaded-driver wrapper. Assert no outward stored success,
   prior usable bytes survive failures before replacement, and a fresh process
   judges actual state after rename. Inject broken outward output after successful
   publication and prove subsequent retrieval. Keep interruption exit 75 covered.
7. Prove version 1's unavailable result read and refusal of retrofit keys, and
   version 2's refusal of missing keys in both pending and stored states. Assert
   legacy recovery remains version 1 and never creates original-result evidence.
   Run the unchanged 40-check suite in full.
8. Build a canonical one-item `orchestrator_state_snapshot` from the frozen
   request/resolved-profile pairs and the retrieved actual result pair. Use the
   scanner's current pinned core contract, absent active attempt, retry limit at
   least 1, observed time at/after the actual result and request, and matching
   source repository/algorithm/commit. Call
   `orchestrator/v1/scan-state.sh scan fixture.target "$source_commit" "$snapshot"`.
   Changed and no-change results must classify terminal via the real scanner.
   Tamper result refs, digest and attempt relations and require scanner rejection;
   recompute the result pair digest for relation mutations. Do not modify scanner
   or planner code or generate a replacement result for this proof.
9. Run both assembly suites with their independent materializer commit expectation
   and fresh isolated exact fetch. Compare each changed JSON file structurally with
   the accepted base after excluding only the permitted revision/tree/digest fields;
   require every other field to match. Verify canonical framing, both manifests'
   package equality, both binding links and their recomputed manifest hashes. Check
   the source commit and final HEAD resolve the same exact package tree. Run the
   unchanged target-packaging suite, preserving its stale-tree, manifest and binding
   refusals. These owned disposable fixtures are development proof, not a release.

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
bash scripts/test/run-all.sh
git diff --check
```

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
