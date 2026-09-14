---
spec-blob: 73476a70853322564ea7c922e4ae64b9aaa7060e
drafted: 2026-09-14
---

# Plan: Preserve real materialization results in the replay journal

Tracks #324.

Risk: high. Gate mode: `artifact-high`. Review size: `accepted-exception`.
This plan covers one concern: retaining and retrieving the actual response of
one keyed offline materialization in the existing replay journal.

The source base is `385251830aa45e72269420f7562f4484041ee485`, containing G2 PR
#332. The accepted intent blob is `eb68c51f1a9866599c8662e967fba8375ccfbf3e`;
the spec links to that exact blob. The separately reviewed plan must land before
implementation. The current Roadmap program delegation in
`work/roadmap-program-authorization/decision.md` supplies the manager's acceptance
process; this draft neither accepts itself nor authorizes a second manager.

## Files that change

The plan PR changes only `work/replay-materialization-result/plan.md` on
`ystack/plan/replay-materialization-result`. Its non-merge history must be
plan-only. Implementation uses `ystack/impl/replay-materialization-result` after
the protected plan merge and fresh plan-base check. The implementation may change
only these paths:

| Path | Change |
| --- | --- |
| `delivery/v1/replay.py` | Keyed journal dispatch, strict bounded validation and capture, atomic result storage, and read-only retrieval. |
| `adapters/local-git-materializer/v1/protocol.jq` | A pure validator for the supplied response and receipt using existing input, receipt and core result predicates. |
| `scripts/test/replay-materialization-result.test.sh` | New executable suite with real fixtures, crash/reopen, limits, negative relations, concurrency and scanner proof. |
| `scripts/test/local-git-materializer-protocol.test.sh` | Direct response-validator positives and relation failures. |
| `README.md` | Update the replay component entry and link the storage guide. |
| `docs/components.md` | Describe keyed storage and retrieval alongside the existing offline replay. |
| `docs/replay-materialization-result.md` | New invocation, limits, restoration and recovery guide. |
| `ci/required-files.txt` | Append the new test and guide paths; preserve every existing entry. |

Keep `scripts/test/delivery-replay.test.sh` byte-identical, including all 40
checks. Reuse its `local-git-materializer-fixtures.sh` builder without changing
that builder. `run-all.sh` discovers the new `*.test.sh` automatically. No scanner,
planner, core generation, materializer executable, workflow, constitution or
shipped profile change is needed.

The estimated implementation size is 800–1,500 added plus removed lines. This is
a work allocation, not a measurement of a future diff:

| Work | Estimated added plus removed lines |
| --- | ---: |
| Replay validation, bounded capture, journal dispatch and retrieval | 300–560 |
| Pure protocol response validation | 100–190 |
| New process, persistence, limit and scanner tests | 280–500 |
| Direct protocol test additions | 40–70 |
| README, component text and storage guide | 78–178 |
| Two manifest entries | 2 |
| Total | 800–1,500 |

The inspected baseline has an 875-line replay, 435-line protocol, 1,152-line
unchanged replay suite and 356-line protocol suite. Reusing current predicates,
fixture construction and table-driven negative cases makes this range plausible.
The response validator, crash boundary and scanner proof must land together to
prove the one persistence contract. Compare the actual diff with this range before
review. If complete, readable work needs more space, pause and obtain a separately
authored and reviewed plan amendment. Do not compress code or remove proof.

## Order of work

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

### 6. Finish documentation and restore coverage

Document the exact key file and retrieval command with the normal identity
arguments, both journal versions, limits, exit meanings, missing-result recovery
and the two crash windows. Explain that restoration needs the complete state
directory including frozen execution and permanent lock, plus the same source,
candidate and scratch boundaries and exact dependency/driver identities. Restored
paths still must satisfy privacy, ownership and disjointness checks. Partial
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

Run these commands from the implementation checkout and retain output tied to its
exact head/base:

```sh
bash scripts/test/replay-materialization-result.test.sh
bash scripts/test/delivery-replay.test.sh
bash scripts/test/local-git-materializer-protocol.test.sh
bash scripts/test/local-git-materializer-adapter.test.sh
bash scripts/test/orchestrator-state-scanner.test.sh
bash scripts/test/orchestrator-reconciliation-plan.test.sh
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
