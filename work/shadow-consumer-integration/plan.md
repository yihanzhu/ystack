---
spec-blob: 740ef2bcf1b198a28ff4aab9675b3897cba6c026
risk: high
drafted: 2026-10-06
---
# Plan: inactive shadow-consumer integration

Tracks #506. This implements Step-8 child 5 under the accepted spec. The authoring
base is `95b54c142f6ad242e0a36b2a92fa51d7606255fb`; base movement is external
context, not permission to change the artifact's meaning. The intent blob is
`6feb2ad7dd5f096bdd483ed9bace07cae2c24be5`.

Plan PR: `review_size: accepted-exception`, 400–550 lines. The helper trust channel,
fixed control references, descriptor reader and materialization field map need one
coherent implementation brief. This changes only the soft size budget.

## Files that change

Only `work/shadow-consumer-integration/plan.md` changes in the plan PR. The following
five implementation PRs land in order. Each uses its exact set below, with tests
in the same PR. The first four track #506; only the fifth closes it.

| Slice | Exact implementation paths, excluding the common documentation set |
| --- | --- |
| 1 — bound evaluator/checker | `control/v1/sandbox-bound-policy.json`, `control/v1/sandbox-bound-decision.json`, `control/v1/control-policy-set-sandbox-bound.json`, `control/v1/evaluate-bound-sandbox.sh`, `control/v1/sandbox-bound.jq`, `enforcement/v1/check-sandbox-receipt.sh`, `enforcement/v1/sandbox-receipt.jq`, `scripts/test/control-sandbox-bound.test.sh`, `scripts/test/sandbox-receipt.test.sh`, `scripts/test/portable-core-schema.test.sh` (only the spec R10.9 expected-path addition) |
| 2 — trusted dependencies and origin reader | `shadow/v1/_consumer.py`, `scripts/test/shadow-enforced.test.sh` |
| 3 — enforced reproduction | `shadow/v1/_consumer.py`, `shadow/v1/enforced-reproduction.py`, `scripts/test/shadow-enforced.test.sh`, `scripts/test/shadow-slice.test.sh` (compatibility assertions only) |
| 4 — add-only materialization | `shadow/v1/_consumer.py`, `shadow/v1/write-shadow.py`, `shadow/v1/write-materialization-input.jq`, `scripts/test/shadow-write.test.sh` |
| 5 — withheld request and complete integration | `shadow/v1/_consumer.py`, `shadow/v1/write-shadow.py`, `scripts/test/shadow-write.test.sh`, `scripts/test/shadow-enforced.test.sh` |

The common documentation set is exactly `docs/components.md`, `RESTORE.md`, and
`ci/required-files.txt`. Each slice may change only its own component descriptions
and manifest entries. Add each new shipped file and test to the restore manifest
when it first lands. Keep shell drivers/tests executable. Intermediate entry points
refuse operations whose remaining checks are not implemented; they cannot emit a
completed write bundle early. No other source or accepted artifact changes.

| Slice | Classification | Net-line range | Evidence for the estimate |
| --- | --- | --- | --- |
| 1 | Accepted exception | 850–1050 | Closed R10 evaluator with bounded snapshots and full refs; shared checker preserving legacy outputs; paired binding and compatibility tests, fixed data and restore docs |
| 2 | Accepted exception | 450–750 | Bounded dependency/store reads, platform ACL observations, race and provenance tests |
| 3 | Accepted exception | 550–850 | Preparation/frame/expectation orchestration, closed records and failure tests |
| 4 | Accepted exception | 450–750 | Exact input transformation, patch construction and real materializer controls |
| 5 | Standard | Up to 400 | Withheld admission, complete two-attempt proof and final documentation |

If the complete readable change cannot fit its accepted slice, stop before an
unexplained overrun and return through the plan gate. Do not remove proof or create
extra parallel initiatives. No bootstrap, workflow, installation or policy-authority
change is included.

## Order of work

### 1. Fixed bound control tuple

Implement spec R10 before any consumer entry point. The new fixed files are the
normal path for this complete declaration; do not normalize claims into legacy
placeholder claims or import an executable legacy jq program as a module.

- Start the bound policy from the legacy policy's exact fields. Replace only the
  tool's `sha256` with R10.2's closed `identity_binding` object. Keep the logical
  policy/decision IDs and all non-sandbox policy-set sections unchanged. Give the
  bound set its specified separate ID.
- `evaluate-bound-sandbox.sh evaluate DUTY CLAIM OBSERVATION` has four arguments.
  Its paths are fixed relative to its reviewed package, including the accepted set
  and registry. Snapshot canonical documents, reject duplicate keys, and use the
  existing pinned jq identities before executing jq. Fixed inputs are at most
  1 MiB each; existing depth/member/string caps remain in force.
- `sandbox-bound.jq` checks the complete claim, duty and observation shapes. Reuse
  the generic policy-set validator; retain the claim and duty predicates' exact
  semantics from `control/v1/sandbox.jq`. Compare the complete fixed declaration,
  substituting only measured verifier digest d in the expected tool object.
  Unsupported/partial values cannot satisfy the bound evaluator.
- Validate the same-bound-set duty refs, core contract, policy/decision refs, exact
  duty document digest and claim-to-duty stage-result relation. The observation
  envelope and five body fields are exactly spec R10.3. Its environment equals
  claim.id; entry hash, target repository and accepted-set hash identify one
  unambiguous registry/accepted entry. Require measured d = claim tool digest =
  observation verifier digest and d in that entry's verifier list.
- Emit the unchanged `sandbox_policy_evaluation` schema-1 envelope and existing
  body fields, plus `verifier_binding` containing the observation body and hash.
  Use the spec's closed satisfied/refused reason IDs. Malformed references or
  fixed-byte drift fail without output; a valid incomplete declaration is
  inconclusive. This remains declaration-only with both effects `none`.

Build hashes in this order: evaluator driver/program and policy; then the new
fixed decision, including unchanged validator driver/program refs; then the bound
policy set; finally checker pins. Compare full refs, including IDs/media types.
Do not make a source file pin its own final digest. The trusted consumer/checker
closure pins the tuple; the evaluator checks its measured source pair against the
fixed decision and its fixed validator dependencies before producing a result.

Add `check-bound RECEIPT EXPECTATION EVALUATION OBSERVATION` as the only new checker
verb. The shell driver selects the fixed bound files and passes an explicit internal
mode to jq; caller documents never choose that mode. Factor shared receipt shape,
accounting and outcome predicates in the existing checker, retaining `check`'s
original output bytes for original inputs. The bound branch validates the additional
observation/result relation and the fixed bound tuple, without relaxing legacy pins.
Require receipt verifier `{state:"observed",sha256:d}`, not just membership. Preserve
all existing subject, attempt, store, accepted-set, mechanism, limit and verdict checks.
The checker continues to report no origin authentication.

### 2. Trusted parent context and dependency snapshots

Keep the spec's CLI argument lists unchanged. The trusted parent supplies the helper
acceptance context on inherited descriptor 3, opened read-only before launching the
consumer. It is not a REQUEST field, environment lookup, candidate file or runtime
approval prompt. The descriptor is a channel from the already trusted caller, not
independent authentication of an arbitrary caller. An untrusted party able to launch
a different consumer or forge its parent's context is outside this invocation trust
boundary; candidate/request data must never obtain that ability.

The context is canonical JSON, at most 16 KiB, with exact envelope
`{schema_version:1,kind:"shadow_consumer_parent_context",id:"shadow.parent",body}`.
The body has exactly `helper_source_sha256`, `helper_build_record_sha256`,
`helper_executable_sha256`, `helper_executable_size`, and `helper_path`.
All hashes are lowercase SHA-256; size is a positive integer at most 16 MiB;
helper_path is the physical absolute locator independently chosen by the parent.

Before starting the consumer, the trusted parent reviews the committed
`adapters/local-git-materializer/v1/object-closure.c`, the compiler/build inputs and
the resulting executable. Its retained build record binds source bytes, compiler
identity, argument vector and resulting bytes; the parent supplies the accepted
record digest and executable identity. Tests compile the existing source using the
existing fixture build recipe. Product execution does not compile, fetch, provision
or approve a helper. Real provisioning still needs its separate authority.

`_consumer.py` consumes descriptor 3 before opening REQUEST. Require an ordinary
read-only file descriptor, bounded stable contents and exact context shape; reject
missing or writable descriptors. Close it after capture and do not inherit it in
children. Pin the reviewed helper source digest from this plan's accepted source
base in the implementation:
`f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27`.
Independently verify the package source equals that pin. A different build may be accepted by the trusted parent only from this source.
The context's result digest is an acceptance input; recomputing a request-selected
binary digest does not create acceptance.

After reading REQUEST, require its helper locator to equal the context locator.
Open the helper with held no-follow ancestors and compare metadata before/after
reading. Compare the captured bytes and size to the independently accepted tuple
before any helper execution, including the adapter's `version` probe. Copy only
those checked bytes into an exclusive file in WORK's private dependency directory;
set file mode 0500 and directory mode 0500 before use. Pass this snapshot, never
the request path, as materializer argument seven. Recheck snapshot bytes/identity
before each adapter invocation and after use; recheck the original held/name tuple
before invocation and before completion. A failed check refuses without starting
that child. Changes to the original after the last check cannot replace the
separate executable snapshot. Same-principal malicious modification of private
consumer memory/storage is outside the trusted-parent boundary, not solved by a
post-execution hash. Document that residual without granting candidate access.

Apply the same bounded-copy-before-version sequence to jq, whose expected digest
is the existing fixed platform pin. Python is the physical trusted interpreter
from the invocation; `/usr/bin/git` is the fixed Git. Load `_consumer.py` through
its verified absolute sibling location under isolated Python, not user module
search paths. Keep helper/context provenance hashes in the record; never retain
helper_path or other local host paths in published evidence.

### 3. Immutable installation and controlled store

Implement one private held-path reader in `_consumer.py`, used for dependencies,
installed observations and store snapshots with separate explicit rule sets. It
uses `os.open` with `dir_fd`, `O_NOFOLLOW` and directory flags, plus `fstat` and
named-entry checks. Hold ancestor descriptors until the operation finishes.
Compare device, inode, kind, uid/gid, mode, link count, size and nanosecond change
metadata before/after each read; bound bytes while reading, not after allocation.

For the production anchor, walk from `/` to the exact spec R3 path. First require
root ownership and no non-root write grant for config/script and their ancestors.
Only then parse config and trust principal_uid, consumer_gid, store_id and store_root.
Check real/effective consumer UIDs, supplementary group membership, and nonzero
separate supervisor UID. There is no caller/test environment override of this path.
Validate installed files and verifier path under R10.1, permitting only root or the
already authenticated supervisor principal where that contract allows it.

On macOS use the fixed system C library's descriptor ACL interface through ctypes,
with the ACL constants/semantics used by `sandbox/v1/host-supervisor.py`. Do not
import its runtime functions or execute it to inspect ACLs. On Linux use fd-based
POSIX ACL xattr reads and fail on unsupported/unreadable observations. Accept no
ACL on store objects. Root-only anchor checks reject every grant permitting another
principal to modify it; later installed-object checks follow VM R10.1 exactly.

Open store_root, attempt directory, receipt and payload descendants relative to
held descriptors. Enforce spec R3's uid/gid, 0750/0440, no-ACL and single-link rules.
Use the existing fixed payload names/inventory; reject extra/missing/aliased names.
The reader returns immutable bytes and an observation, never an unverified path.
Record only relative names, metadata, sizes/digests and result in the observation.
Failures remain unauthenticated, even if receipt contents happen to pass the checker.

The installed verifier's observed bytes supply d. Build the exact spec R10.3
observation from this read, registry entry and accepted set, and compare all three
environment/target/set relationships before evaluating or launching. Empty shipped
accepted identities refuse. Tests substitute the private OS-observation functions
in-process; production CLI, environment and accepted files contain no fixture mode.

### 4. Component calls and bounded execution

Let S be the reviewed physical source root, P the physical Python interpreter, J the
checked jq snapshot, H the accepted helper snapshot and G the selected core module
directory derived from the existing core wrapper/registry. I and R are captured
materialization input/response; C is the candidate root; W contains fresh private
scratch children. Use argument arrays and no shell command strings.

| Operation | Exact argv after expanding these validated paths |
| --- | --- |
| Materialize | `/bin/bash -p S/adapters/local-git-materializer/v1/materialize.sh materialize I TARGET SOURCE_GIT C W/materializer H J` |
| Validate input | `J -L G -e --arg command validate-input -f S/adapters/local-git-materializer/v1/protocol.jq I` |
| Validate response | `J -L G -e --arg command validate-response -f S/adapters/local-git-materializer/v1/protocol.jq RESPONSE_CHECK_BUNDLE` |
| Prepare | `P -I -S -B S/preparation/v1/prepare-candidate.py prepare --input I --input-sha256 IH --response R --response-sha256 RH --candidate-repository C/repository.git --output PREP --scratch W/preparation --jq J` |
| Inspect | Same preparation argv with operation `inspect`, same output and a fresh empty scratch directory |
| Evaluate | `/bin/bash -p S/control/v1/evaluate-bound-sandbox.sh evaluate DUTY CLAIM OBSERVATION` |
| Check receipt | `/bin/bash -p S/enforcement/v1/check-sandbox-receipt.sh check-bound RECEIPT EXPECTATION EVALUATION OBSERVATION` |
| Trace | `/bin/bash -p S/telemetry/v1/validate-trace-ledger.sh validate INCIDENT_ID ATTEMPT_ID LEDGER` |
| Convert seed | `/bin/bash -p S/maintenance/v1/incident-to-eval.sh convert INCIDENT FROZEN_SHADOW EMPTY_SEED_DIRECTORY` |

Fixed script calls receive only `PATH=DEPENDENCY_BIN:/usr/bin:/bin`, `LC_ALL=C`,
`LANG=C`; DEPENDENCY_BIN contains the checked jq. Clear inherited Git configuration,
hooks, prompts, loader/Python variables, functions and network/proxy settings.
All children close inherited descriptors except their declared stdio. Use a new
process group per ordinary component. Each ordinary child has a 120-second deadline,
64 KiB stderr cap and its upstream output cap (1 MiB where no tighter cap exists).
Preparation/inspect have 300 seconds, matching their existing operation bound.
On expiry stop that owned child group, wait at most 10 seconds and record failure;
never call a truncated output successful. Consumers have a 1,200-second overall
budget; a deadline only removes opportunities for work, never relaxes admission.

The only future native argv is `/usr/bin/sudo -n -u #UID -- P ANCHOR/host-supervisor.py
launch`, with stdin the complete frame and UID/config/P already checked. The
consumer's 180-second deadline and 10-second cancellation observation follow spec
R4.5. Do not infer teardown from wrapper termination. Tests never invoke this argv;
they substitute the private launch function while running the real remaining path.
No plan acceptance authorizes an actual native call.

### 5. Reproduction, pre-launch expectation and frozen record

Validate all captured input relations before materialization. Require no-change
response and exact incident source revision for reproduction. Build the protocol's
response-check object with exactly `input`, `response`, `verified_receipt`,
`receipt_utf8`, and `stage_result_sha256`; hash actual canonical nested documents,
not caller-supplied digest strings. Require the protocol's true result and validate
the actual candidate via preparation followed by inspect.

Generate exactly verifier R3's three instruction lines: magic, `path PATH`, and
`sha256 EXPECTED`, each LF-terminated. Retain these raw bytes in provenance. Refuse
named checks. Verify supplied qualified identity with the existing jq predicate;
its profile/request/target and instruction refs must match captured real bytes.

Execute the bound evaluator and retain its output; never accept REQUEST's claimed
satisfied document. Require the exact same-bound-set DUTY from a prior stage. For
fixtures, first run the real materializer on an acyclic prerequisite input with its
own earlier environment declaration, obtain request/profile/result, then execute
`control/v1/evaluate-duty.sh evaluate BOUND_SET PRE_REQUEST RESOLVED PRE_RESULT`.
That evaluator accepts the bound set through unchanged generic set validation.
Build the complete claim afterward with this duty's actual digest/stage refs and
measured fixture verifier. The consumer's input can then bind this claim without a
claim→request→duty→claim cycle. Never relabel an evaluation made for the legacy set.
The fixture harness retains that prerequisite tuple and verifies the consumer’s
retained duty bytes and refs against it. These declarations still supply no real
child-9 duty authority.

Build request and expectation in this order:

1. Subject environment id/hash and target come from the authenticated config,
   selected registry entry and incident. Source repository/hash/commit/tree and
   candidate commit/tree come from the verified materialization/preparation record.
   Candidate preparation_record_sha256 and manifest_sha256 hash retained raw bytes;
   incident_sha256 hashes the captured incident.
2. Control has exactly `policy_sha256`, `decision_sha256`, `policy_set_sha256`,
   `evaluator_driver_sha256`, `evaluator_program_sha256`, and
   `sandbox_evaluation_sha256`, all computed from the fixed retained bytes.
3. Launch envelope is schema 1, kind `sandbox_launch_request`, id ATTEMPT_ID. Body
   has attempt `{attempt_id,attempt_number:1}`, control, instruction_sha256, fresh
   64-hex OS nonce, authenticated store_id and subject. Serialize canonically.
4. Expectation is schema 1, kind `sandbox_receipt_expectation`, id ATTEMPT_ID. Its
   body contains store_id, subject, control and attempt extended with
   `launch_request_sha256` hashing the completed request. Persist and fsync both
   before the launch function is entered; test that ordering directly.
5. Construct YSFRAME1 exactly as VM R3: fixed records request.json, evaluation.json,
   incident.json, record.json, manifest.json, instruction, then candidate/%05d in
   manifest file order; hash framed headers/content and append the end record.
   Stream checked preparation export files; do not reconstruct an export from Git.
   Enforce each upstream cap and the complete 88,080,384-byte frame ceiling.

Only R3-authenticated receipt/payload bytes reach the completed-evidence path.
Run check-bound, validate the result and exact request/expectation/evaluation/store
relations. Require exact d equality in receipt, observation and claim even with two
accepted verifier values. Require payload exit 0, empty stdout/stderr, the one fixed
result file and its canonical bound shape. Match instruction/path/expected/observed
bytes against preparation manifest and evidence/receipt hashes. Mismatch is a
completed comparison; refusal, unavailable limits or incomplete teardown is not.

Build new records using spec R5's discriminated forms and the existing record's
field names, media types and inactive/effect/qualification values. Set check.execution
from the actual fixed-verifier result; set tool identity to tool.verifier only when
executed. Map match→no-change and mismatch→reproduced; preserve the spec's failure
precedence and original upstream reasons. Seal the existing trace event shape by
hashing each event without record_digest, then validate the ledger with its exact
incident session and current attempt. Do not introduce a trace→shadow-record cycle.

Provenance retains instruction and observation raw bytes, trusted parent context
hashes without host paths, component/tool source hashes and fixed command-role/argv
hashes. Keep evaluator raw driver/program bytes, all 29 spec R5 evidence files and
all their cross-document bindings. Write exclusive canonical bundle.json last,
fsync file and output directory, and enforce the exact inventory. Partial failures
keep evidence without a completion marker. JSON canonicalization is UTF-8 sorted
keys, compact separators, one trailing LF, no nonfinite numbers or duplicate keys;
prove agreement with pinned jq on all generated documents.

### 6. Deterministic write materialization field map

Before preparing a write, verify the completed frozen reproduction inventory and
reopen its original controlled-store attempt. Require identical receipt/payload
snapshots and repeat the fixed evaluator/checker checks. Keep this fresh observation
only in outer write provenance. The committed reproduction bundle never changes.
Run the existing converter and require its sole output
`eval-seed-case-stale-moved-artifacts.json`; copy those exact bytes as eval-seed.json.

Create exactly spec R7's 32 files under the absent `ystack-evidence/<incident-id>/`.
Use its exact README bytes. Require allowed_paths sorted and exactly equal to this
set, with unchanged scope/config protected-path rules. Build an add-only Git text
patch in sorted path order with mode 100644, `/dev/null` old files and exact new
bytes, including the no-final-newline marker where needed. Compute Git blob IDs
using the source hash algorithm. Refuse binary/invalid UTF-8, existing paths, path
aliases, unsafe segments, any deletion/change and patches above 1,048,576 bytes.

`write-materialization-input.jq` transforms the captured no-change input with only
the following replacements. `_consumer.py` supplies actual byte hashes as explicit
jq args after constructing the bytes; jq checks shapes/relations using existing
core modules. No payload hash is inferred from its textual representation.

| Location | Required value or replacement |
| --- | --- |
| profile, resolved_profile, manifests | Keep complete pairs byte-identical; validate their full graph |
| stage_request.content.id | `request.shadow-write.` plus first 32 hex digits of SHA256(write attempt id UTF-8 bytes) |
| body.initiative_id | `initiative.shadow-consumer-integration` |
| body.workflow_id / task_class_id / stage_id | `workflow.shadow-evidence-commit` / `task.commit-shadow-evidence` / `stage.materialize` |
| requested_by, source, base, target_repository_id, target_revision | Keep original validated values |
| selection_ref, repository_context_ref, resolved_profile_ref | Keep original refs and revalidate against retained resolved profile |
| environment_ref | Environment id and SHA256 of the write request's captured same-environment bound claim |
| operation | Retain forge binding, materialize capability, four existing candidate/evidence/scratch/read permissions, source-tree/output IDs, network deny |
| attempt | write attempt id, number 1, result id with `result.shadow-write.` plus the same 32-hex suffix; timestamps copied from original requested_at |
| body.requested_at | Original requested_at; all three attempt times equal it |
| risk | Routine tier; reason_ids `["shadow.evidence.candidate-only"]`; new fixed policy ref; required_gate_refs `[]` |
| gate_decision_refs / prior_evidence_refs | `[]` / `[]`; no invented real gate evidence |
| finish_condition / verification_instruction / operation.arguments.materialization_contract | Keep existing scope-ref shapes and input IDs; replace corresponding decision/subject/scope digests from the new bytes below |
| inputs | Keep source-tree ref; replace finish, verify, materialize and producer-patch content refs; sort by input_id |
| payloads / trust_context.verified_payloads | Exactly materialize JSON and producer-patch text, same IDs/media and exact raw strings; verified content/hash agree with input refs |
| stage_request.sha256 | Hash the completed canonical stage_request.content after all replacements |

The materialization contract has schema 1 and unchanged kind/settings, exact 32
allowed paths, max_changed_paths 32, max_patch_bytes 1048576 and required
allowed_modes `["100644","100755"]`. Actual additions are separately constrained
to 100644; never replace that protocol field with a singleton.

Define four LF-terminated plain-text records, retained in outer provenance:
finish: `Finish after all planned evidence files exist in the disposable candidate.`
verify: `Verify every planned path, mode and byte digest, then run the fixed incident check.`
output-contract: `Add only the listed evidence files; preserve all existing target files.`
policy: `Routine candidate-only evidence preparation. Network and publication are denied.`
Use existing decision/content IDs and media types from materialization-input.jq;
replace each actual digest everywhere it appears. The contract subject hash is the
canonical contract hash; its scope/decision hash is the output-contract text hash.
Patch data is exact UTF-8 diff bytes; its hash appears in the producer-patch input
and verified payload. Validate generated input before invoking the unchanged adapter.

Validate response, then independently compare the actual candidate tree to source:
exactly 32 added paths, each expected blob/mode, no other delta, one commit parent
equal to target revision. Prepare and inspect that candidate and run the same R4
incident check. Generate the outer qualified identity from retained profile/config/
model/prompt/skill refs, the new request ref, original target and actual instruction
ref; validate it using the unchanged predicate. Never reuse a stale request hash.

### 7. Withheld admission and completion

Derive write_set from verified candidate facts, sorted by path. Each row has exactly
path, mode, raw SHA-256, git_blob_oid and add_only:true. Hash the canonical array.
Create the spec R8 publisher request with id equal to the incident id, exact body
keys, fixed branch/title/body bytes, base revision and candidate tree. Use the
specified neutral schema-1 kind; retain publisher-body.txt outside the candidate.

Implement one private admission function comparing request/body/write_set hashes,
source/parent/tree, allowed paths, completed authenticated write verification and
frozen bundle refs. Its only success is checked/effect:none. Publication is always
withheld with the exact reason; no branch creation, push, forge call or transport
is present. Post-write verification is a data object with exactly `target_revision`,
`candidate_tree_id`, `write_set`; its values equal the checked request and write set.
The write form's workflow_id and task_class equal the generated stage request IDs;
bundle_ref is a content ref to the frozen bundle.json bytes.

Seal the outer record/trace/completion bundle only after these checks. Its inventory
is the spec R5 set plus publisher-body.txt, using the generated write input/response
and separate write receipt. No outer nonce, timing, receipt, provenance or request
enters the candidate. Repeat preparation with the same frozen bundle and source,
varying only outer attempt identity and fresh nonce/timing. Require equal candidate
tree IDs, canonical write sets, publisher request bytes and post-write digests.

## Risks

- Helper trust is established before its version probe. The inherited context is
  meaningful only under the trusted-parent precondition. The separate checked
  executable snapshot removes a request-path replacement race; a self-hash or
  post-execution check would not. Private tests must prove the malicious marker
  never executes, including replacement during snapshot preparation.
- Store origin is the highest-risk boundary. Preserve descriptor/ACL checks and
  fail on unreadable state; no path-only reader, caller UID or archived observation
  replaces it. A compromised administrator/supervisor remains the accepted residual.
- Bound evaluation is necessary but not enforcement. Fixed hashes, same-set duty,
  actual evaluator execution and exact verifier equality are separate assertions.
  The receipt checker remains integrity/accounting validation, not origin proof.
- Complete evidence can exceed the text patch budget. Refuse rather than trim,
  split or bypass the materializer. A later publisher needs its own accepted work.
- All success controls here are simulated fixture proof. Empty accepted identities,
  unproven registry entries, CPU/wall enforcement `none` and blocked native
  qualification stay unchanged. No native installation, sudo, real target,
  credentials, scope gate, policy widening, publisher or activation is authorized.

## Proof

Every negative case has a positive control and asserts the last completed boundary,
absence of later effects and absence of a completion marker. Test changed linked
values with their dependent hashes recomputed, so rejection proves relations rather
than merely a stale checksum. Tests use the real unchanged component interfaces;
only private OS identity/ACL/launch observations are substituted in-process.

| Suite | Required assertions |
| --- | --- |
| control-sandbox-bound | Valid complete same-set duty/claim/observation; actual evaluator execution; full-ref/source pins; altered role/argv/root/limit/partial claim; legacy-set duty; wrong entry/target/set; zero/ones/unlisted digest; two accepted unequal verifier digests; shipped empty set refusal |
| sandbox-receipt | Original check results byte-identical; explicit mode cannot be auto-selected; bound observation digest and exact d; all six control fields; retained legacy shape/accounting/mechanism/limit/outcome refusals; CPU/wall none cannot satisfy |
| shadow-enforced | Parent-context absent/writable/malformed/request-forged; helper source/result mismatch; unapproved and raced helper leaves no execution marker; pinned jq before version; root/config principal bootstrap; every directory/file mode/owner/ACL/link/alias/read-race boundary; no native call after precheck failure |
| shadow-enforced | Actual materializer/preparation; pre-launch fsync ordering; nonce/request/subject/expectation equality; copied receipt; wrong candidate/evaluator/payload; success, mismatch, refusal, missing/partial evidence, timeout/cancel and unconfirmed teardown; raw instruction retention; exact 29-file inventory and marker-last behavior |
| shadow-write | Reauthenticate frozen receipt/payload; regenerate evaluation; missing/extra/modified evidence; seed converter refs; original profile graph unchanged; exact protocol input/response; altered payload/ref digests; required allowed_modes plus actual100644; add-only/single-parent/protected/existing/binary/oversize failures |
| shadow-write | Separate original/write attempt subjects; identical two-run tree/write_set/request despite nonce/time differences; zero producer/model/publisher calls; exact withholding/admission/post-write equality; source/store digests unchanged; no committed outer-attempt bytes |

Run the slice's new suites and affected compatibility suite before its review:
`bash scripts/test/control-sandbox-bound.test.sh`,
`bash scripts/test/sandbox-receipt.test.sh`,
`bash scripts/test/control-sandbox-policy.test.sh` (slice 1 legacy compatibility),
`bash scripts/test/shadow-enforced.test.sh`,
`bash scripts/test/shadow-write.test.sh`, as each becomes available.
Each test script must be runnable directly and discovered by the existing test
runner without editing its bootstrap or CI workflow.

For slice 1, add only `control/v1/control-policy-set-sandbox-bound.json` to the
existing corrective-v2 generation tracked-path expected list in
`scripts/test/portable-core-schema.test.sh`, preserving every other entry and check.
Run `bash scripts/test/portable-core-schema.test.sh` after all candidate files are
staged or committed. Verify the tested Git index contains their exact candidate bytes;
untracked-file runs cannot prove this guard. Keep legacy bindings and authority unchanged.

At slices 3 and 5 run the existing integration suites with `bash scripts/test/NAME`:
`shadow-slice.test.sh`, `shadow-assembler.test.sh`, `shadow-self-host-evidence.test.sh`,
`file-digest-verifier.test.sh`, `candidate-content-preparation.test.sh`,
`local-git-materializer-protocol.test.sh`, `local-git-materializer-adapter.test.sh`,
`maintenance-loop.test.sh` (converter coverage), and `scope-qualification.test.sh`.
Confirm the unchanged scope evaluator refuses the new record form until child 6.
Use the existing pinned jq 1.6 fixture cache; a system jq with a different version
cannot substitute. No new tool installation is needed. Use shellcheck 0.11.0 with
`-x -S style` on changed shell files and the repository’s required quick CI.
Before dependent work treats the complete child as a runnable milestone, record
the dispatched six-shard full matrix under the existing CI-minimum decision.
No automatic quick-green run claims that matrix passed.
