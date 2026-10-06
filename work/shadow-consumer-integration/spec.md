---
intent-blob: 6feb2ad7dd5f096bdd483ed9bace07cae2c24be5
risk: high
drafted: 2026-10-06
---
# Spec: inactive shadow-consumer integration

Tracks #506. Step-8 child concern 5. The amended intent was accepted at
`a3f5a822761ebe4e635baab3680b53fd38f79ecd`. This spec defines inactive code and fixture proof,
not installation, a native run or qualification. The VM spec R13.4 allows this work while CPU
and wall enforcement remain `none`.

`review_size: accepted-exception`, 450–500 lines for this G2 artifact. The coherent
origin, verifier-binding and deterministic-record contract needs this review range.
The exception changes only the soft size budget; it grants no scope or proof waiver.

## Requirements

### R1. Compatibility and ownership

1. Keep `reproduce.sh reproduce` and its existing argument count, read-only guards, output
   meaning and refusal behavior, byte-identically. The new entry scripts are explicit; old
   calls never select them by inspecting candidate content.
2. New consumer code lives in `shadow/v1/`. It calls the existing materializer, preparation,
   verifier, sandbox evaluator, receipt checker, seed converter and trace validator through
   their accepted interfaces, with R10's explicit bound evaluator/checker path. It does not
   copy their implementations, import supervisor runtime functions, or use qualification
   harness reads as receipt authentication.
3. The origin contract is enforcement-evidence-binding R2/R4/R7; launch framing, admission and
   payload are VM-launcher-supervisor R3/R4/R8/R10; verifier inputs and results are
   fixed-file-digest-verifier R2–R7. These contracts remain binding. Receipt validity,
   authenticated origin, enforcement satisfaction and environment qualification are four
   separate facts. No one fact stands in for another.
4. New records stay `activation_state: "inactive"`, `authority: "none"`, `deploy_authority:
   "none"`, `shadow: true`, with qualification unavailable. The shipped accepted set stays
   empty and the VM registry entry unproven.

### R2. Entry points, inputs and bounded workspace

1. Invoke `PYTHON -I -S -B SOURCE/shadow/v1/enforced-reproduction.py reproduce REQUEST WORK
   OUTPUT`, or the same prefix with `write-shadow.py prepare REQUEST BUNDLE WORK OUTPUT`.
   PYTHON is the trusted caller's identified physical Python >=3.11 interpreter, never PATH
   lookup; children use that same interpreter. These are additional drivers, not a change to
   the old command.
2. REQUEST is canonical JSON with envelope `{schema_version:1,kind,id,body}`.
   `shadow_enforced_request.body` has exactly `attempt_id`, `attempt_number`, `incident`,
   `claim`, `duty_evaluation`, `materialization_input`, `qualified_identity`,
   `source_git_dir`, `jq`, and `closure_helper`. The last eight fields are absolute physical
   paths; there is no payload-executable, store, supervisor, UID, configuration or acceptance
   override. Policy set and other component paths are fixed relative to the reviewed consumer
   source.
3. `shadow_write_request.body` has exactly the same fields plus `scope_id` and
   `allowed_paths`. Its materialization input is the original no-change input. All
   source/incident/profile fields must match the frozen BUNDLE. `scope_id` is an identifier,
   not scope authorization. `allowed_paths` is the sorted exact set of R7 target files, never
   a glob. Attempt ids obey the receipt identifier rule; number is 1. Write and reproduction
   attempt ids must differ.
4. The caller explicitly invokes reviewed consumer bytes, as preparation's trusted parent
   contract requires. Request documents carry data, never an approval flag. Validate incident
   and qualified identity with existing validators; validate the input through the
   materializer protocol and its core/profile relations. Bind every request/profile/reference
   digest to captured bytes before acting. Before processing REQUEST, the trusted parent
   independently provisions and accepts the helper from the reviewed committed
   `adapters/local-git-materializer/v1/object-closure.c`, with its exact source identity,
   reviewed build inputs and resulting executable identity. That accepted choice belongs to
   the trusted parent's invocation context, independently of REQUEST. The consumer must
   match the request's helper locator and captured executable bytes to that separately
   trusted choice before every direct or indirect helper invocation, including `version`
   inside the materializer. Missing acceptance or any mismatch refuses before execution.
   Neither a request-supplied digest nor measurement/version output from its selected file
   approves executable bytes. Preparation does not provision or approve this helper.
5. Bound REQUEST to 64 KiB; apply each upstream component's tighter file, frame, JSON and
   output bounds. Snapshot with no-follow descriptor opens; reject non-regular files, links,
   duplicate JSON keys, noncanonical bytes and changed identities. WORK and OUTPUT are
   existing empty physical 0700 directories, pairwise disjoint and outside source, trusted
   inputs, installation and store. Never overwrite an existing file. Own temporary paths only
   may be cleaned.
6. All child commands use fixed absolute programs and argument arrays, a cleared environment,
   denied Git network/prompts/hooks/config and bounded output. No shell text, candidate
   program, model, socket or forge client is invoked. Jq uses the existing pinned 1.6
   identities; the helper must pass R2.4 before execution. Preserve its snapshot and identity
   rechecks across use, and reject substitution. Recheck captured
   source/tool/input identities before emitting a completed bundle. A failed recheck cannot
   leave a completion marker.
7. Usage/input errors exit 1 with one of `E_USAGE`, `E_RUNTIME`, `E_LIMIT`, `E_SHAPE`,
   `E_CANONICAL`, `E_RELATION`, `E_WORKSPACE`. An attempted reproduction may return an
   inconclusive record with preserved failure evidence. A write preparation refuses incomplete
   evidence. A final canonical `bundle.json`, written exclusively and fsynced last, is the
   only bundle completion marker.

### R3. Immutable host anchor and origin

1. The sole production installation anchor is
   `/usr/local/libexec/ystack-sandbox/v1/supervisor/`, already named by the VM plan's
   `vml-trust-root` decision package. Before reading any configured principal, walk from `/`
   by directory descriptors with `O_NOFOLLOW`; require root ownership, no group/other write
   and no ACL granting non-root modification on every ancestor, the anchor, `host-config.json`
   and `host-supervisor.py`. Unreadable ACLs refuse. Thus root ownership authenticates
   configuration; its claimed UID cannot authenticate itself. No caller path or environment
   variable changes the anchor.
2. Read the root-controlled canonical config through its checked descriptor, at most 1 MiB,
   using VM R10.1's exact shape. Require nonzero `principal_uid` distinct from the consumer's
   real/effective UID; require the consumer to belong to `consumer_gid`. The dedicated
   account/group arrangement remains a reserved installation precondition, not something this
   command creates or infers from a writable directory. Hold and recheck config and script
   descriptors throughout.
3. Only this authenticated config selects `store_root`, `store_id`, the supervisor principal
   and consumer group. Apply the accepted R10.1 ownership/ACL rules to its installed
   control/registry/accepted-set files and their ancestors. Their bytes must equal the
   consumer's reviewed snapshots. The interpreter is the consumer's physical trusted
   interpreter, checked by the same installation rules; its exact path must match the
   separately approved sudo rule.
4. Apply enforcement R2.3 literally to store root → attempt → receipt, opened relative to held
   directory descriptors. Directories are 0750, files 0440, supervisor-owned with the
   configured consumer group, no ACL; files have one link. Reject symlink components, wrong
   kinds and metadata changes across reads. Receipt reads stop above 1,048,576 bytes. Verify
   held descriptors and named entries still identify the same objects before accepting their
   snapshots.
5. Apply that same directory/file discipline to `payload/`, its fixed files and `evidence/`.
   Read only VM R10.2 names, with exact inventory and R8 size/digest checks. Retain a
   canonical `origin-observation.json`: store id, attempt id, metadata before/after by
   relative name, snapshot sizes/digests and observation result. Record no absolute host path.
   `origin` is exactly `{state,store_id, method:"controlled-storage.v1",observation_sha256}`;
   only full success gives `state:"authenticated"`. Every missing or uncertain check is
   unauthenticated.
6. Origin fails before any content can be called enforcement evidence. Archived copies keep
   the original observation and its digest; offline checks verify integrity and relations,
   never claim fresh authentication. A compromised supervisor principal or host administrator
   remains the accepted trust residual.

### R4. Reproduction and launch sequence

1. Capture and validate R2 inputs, then call the unchanged materializer for the no-change
   incident candidate. Check response through its protocol; call `prepare-candidate.py
   prepare` and `inspect` with the exact accepted input and response digests. Preserve source
   and candidate identities; do not rebuild or reinterpret its manifest/export. The source
   repository is never modified.
2. Generate the fixed verifier instruction from the incident's file-digest path and expected
   SHA-256, under verifier R3/R4. A named check is not runnable. Authenticate R3’s
   installation and measure R10’s verifier observation before running the fixed bound
   evaluator on captured inputs. Retain its actual output and both evaluator source files;
   caller-supplied evaluations are not accepted. A declaration is necessary input to a launch,
   never enforcement proof.
3. Generate a fresh 256-bit OS nonce and VM R3 launch request from the consumer's verified
   preparation/source/incident/control/environment identities. Construct and persist the R4
   receipt expectation from those same inputs and the request's digest **before** launching.
   Neither is reconstructed from a returned receipt.
4. Frame the existing preparation export, instruction, incident and evaluation in VM R3 order
   within its 88,080,384-byte ceiling. A precheck failure, unsatisfied declaration, missing
   trusted installation or absent accepted environment stops before launch. Otherwise call
   only `/usr/bin/sudo -n -u #<principal_uid> --` followed by the fixed interpreter, installed
   `host-supervisor.py`, and `launch`. This ships an inactive invocation path; invoking it on
   a real host remains reserved. No shell, interactive prompt, install or fallback launch is
   allowed.
5. Supervisor exit 0 means a receipt was written, not success; 65 means phase-A refusal
   without a receipt; 70 or a missing final receipt means incomplete. Never retry an attempt
   id. Cancellation stops new work and requests supervisor cancellation; no timeout or lost
   response is called confirmed teardown. A 180-second consumer deadline triggers TERM to its
   owned sudo child and a further 10 seconds of bounded waiting; no success is reported on
   exhaustion. Never kill unrelated processes or claim a killed wrapper proves VM teardown.
   This deadline is an observation, not a substitute for the VM's bounds.
6. Read origin and payload under R3, then run `check-bound RECEIPT EXPECTATION EVALUATION
   OBSERVATION` with the pre-launch expectation, actual evaluation and measured observation.
   Retain its output even when refused. Only authenticated origin + `valid` + enforcement
   `satisfied` permits a completed check. Failed/violated receipts remain evidence of failure.
7. Require payload exit 0, empty stdout/stderr and exactly the fixed verifier's
   `file-digest-result.json`, canonical and at most 16,384 bytes. Verify its manifest
   name/size/digest and receipt payload digests. Instruction SHA-256, path/expected digest,
   observed size/digest and match relation must agree with the instruction and prepared
   candidate manifest. Accept only fixed-file-digest-verifier R6’s closed verifier
   outcomes/reasons; mismatch is a completed comparison, not an escape.

### R5. Record forms and retained reproduction bundle

1. Keep envelope kind `shadow_reproduction_record`, schema 1, for references used by later
   children. New bodies add the mandatory discriminator `record_form`:
   `enforced-reproduction.v1` or `withheld-write.v1`. Absence denotes only the unchanged
   legacy form. Never infer a form by a receipt-shaped field.
2. Start from the existing driver's body fields and relations, including incident, revision,
   qualified identity, environment evaluation, materialization, check and trace refs. New
   forms add exactly `record_form`, `sandbox`, `producer_invocations` (0), and
   `consumer_provenance_ref`; the write form also adds R8's `write`. Completed check tool is
   `tool.verifier`, bound to receipt verifier identity; top-level outcome stays `no-change`
   for match, `reproduced` for mismatch, otherwise `inconclusive`. Materialization outcome is
   separate.
3. `sandbox` has exactly `state`, `reason_id`, `launch_request_ref`, `expectation_ref`,
   `receipt_ref`, `check_ref`, `origin`, `payload_ref`; each unavailable ref is null. State is
   `satisfied`, `refused`, or `incomplete`. The first requires every R4 check and reason
   `shadow.sandbox-satisfied`. Otherwise reason is `shadow.sandbox-` plus the first failed
   boundary in this order: `unavailable`, `launch-refused`, `receipt-missing`,
   `origin-unverified`, `receipt-refused`, `enforcement-failed`, `payload-refused`.
   Unavailable or missing evidence is incomplete; an observed refusal is refused. Refs name
   exactly retained files, otherwise null. Preserve original checker/supervisor reasons in
   their unchanged evidence documents; never manufacture a sandbox verdict.
4. Seal a trace with the existing trace-ledger shape and validator. The environment fact
   distinguishes declaration evaluation from receipt satisfaction, the tool fact names
   `tool.verifier` only when executed, and missing metrics remain unavailable. Provenance
   records source/interpreter/jq/helper digests and every executed command’s fixed role and
   argument digests; never local path strings. Retain the exact UTF-8 verifier instruction and
   R10 observation inside this provenance document, with their digests, so the closed
   inventory is sufficient.
5. A completed reproduction bundle contains exactly the following 29 evidence files plus
   `bundle.json`. Each is a bounded snapshot, with an entry `{name,size_bytes,sha256}` sorted
   by name in `bundle.json.body.files`: `incident.json`, `claim.json`, `duty-evaluation.json`,
   `materialization-input.json`, `materialization-response.json`, `qualified-identity.json`,
   `preparation-record.json`, `preparation-manifest.json`, `sandbox-evaluation.json`,
   `sandbox-request.json`, `sandbox-expectation.json`, `sandbox-receipt.json`,
   `sandbox-check.json`, `origin-observation.json`, `payload-stdout.txt`,
   `payload-stderr.txt`, `evidence-manifest.json`, `file-digest-result.json`,
   `evaluator-driver.txt`, `evaluator-program.txt`, `policy.json`, `decision.json`,
   `policy-set.json`, `accepted-identities.json`, `registry.json`, `consumer-provenance.json`,
   `shadow-record.json`, `trace-ledger.json`, `trace-receipt.json`. All must exist for a
   completed bundle; failed attempts may retain a partial directory but cannot write this
   completion marker.
6. `bundle.json` is kind `shadow_consumer_bundle`, id `bundle.` plus the first 32 hex digits
   of the incident document’s SHA-256, schema 1; body exactly `activation_state:"inactive"`,
   `record_form`, `incident_sha256`, `target_revision`, `files`. It excludes itself from
   files. A consumer verifies exact directory inventory, every digest and cross-document
   relation; a valid self-authored checksum inventory alone proves no origin.

### R6. Freeze first, then prepare a separate write attempt

1. BUNDLE is one completed enforced reproduction, not a legacy declaration-only bundle.
   Validate its complete R5 inventory and all R3/R4 bindings, current accepted-set/control
   bytes and same incident/revision/profile. Reopen its original attempt through R3 and
   require receipt/payload snapshots identical to the frozen bundle. Rerun the fixed bound
   evaluator and checker on its retained inputs and require identical results. An archived
   origin observation alone cannot admit a write. Keep this fresh observation outside the
   candidate in the write attempt’s provenance. The reproduction must have satisfied
   enforcement and a completed match or mismatch; failed, stale or simulated production
   bundles cannot be upgraded by supplying them to this command.
2. The write commits only that already finished bundle and the seed generated by unchanged
   `incident-to-eval.sh convert`. Its own launch request, receipt, record, trace and
   verification plan stay outside the candidate. Consequently no receipt needs to hash a tree
   containing itself. Reproduction and write attempts have separate identities and receipts;
   both subjects remain explicit.
3. The frozen tuple is the exact BUNDLE bytes, request input bytes other than write attempt
   id, and source revision. Repeat it in two fresh directories. Candidate tree, write set and
   publisher request must be byte-identical. Fresh write nonce/timing belongs only to outer
   attempt evidence, never the written bundle, candidate tree or would-be publisher request.

### R7. Deterministic add-only materialization

1. Let ROOT be `ystack-evidence/<incident-id>/`. Require the incident id to be one safe path
   segment under the scope glob rules. Refuse if ROOT already exists in any form at the source
   revision. Every target path is directly under ROOT: the 29 R5 evidence filenames,
   `bundle.json`, `eval-seed.json`, and `README.md`. Copy BUNDLE bytes unchanged.
   `eval-seed.json` is the converter's sole output, renamed without byte changes. README is
   exactly `Shadow evidence. Publication is withheld.\n` on one line. Every new file is mode
   100644.
2. Require `allowed_paths` to equal those 32 exact paths. Check each against the unchanged
   scope policy's protected prefixes/segments/root files, the mode record's forbidden
   paths/prefixes and the target `.ystack/` boundary. Reject path aliases, symlinks,
   binary/non-UTF-8 content, modifications, deletes and renames. Names are data; no shell or
   Git pathspec interpretation is permitted.
3. Produce one deterministic textual add-only patch in sorted path order. Refuse above
   1,048,576 patch bytes; never truncate, omit evidence, split this incident's publication, or
   use a direct Git write to bypass the materializer. Its contract has exactly those allowed
   paths, 32 changed paths, that patch ceiling and the existing
   no-binary/no-symlink/no-submodule/bare-repository settings.
4. The new input builder starts from the validated no-change input. Keep its
   profile/manifests, resolved profile, repository/source and requester unchanged. Bind the
   write request’s validated claim and duty to their actual bytes; require the same
   environment and bound policy set as the reproduction, without copying a stale request/claim
   ref or fabricating duty evidence. Create new request/attempt ids from the write attempt and
   bind the real patch, contract, finish, verification and policy text bytes throughout
   inputs, payloads, verified payloads and decision refs. Use workflow
   `workflow.shadow-evidence-commit`, task `task.commit-shadow-evidence`, stage
   `stage.materialize`, routine risk and candidate-only permissions with network deny. No
   target-write, publish or gate authority is added. The plan fixes the short decision texts
   and field mapping, then the existing core/protocol validators must accept the generated
   input before the materializer runs.
5. Call the unchanged materializer, verify its complete response and actual tree, and require
   all 32 paths added with exact mode/blob bytes and no other change. The candidate commit's
   only parent is the requested target revision. Run the unchanged preparation component and
   R4 verification on this write candidate, using the original incident check, which still
   names the unchanged source file. Derive the new qualified identity from the generated
   request/profile/instruction bytes; never copy the old request ref onto the new run.

### R8. Withheld request, admission and post-write plan

1. `write` is exactly `{bundle_ref,scope_id,workflow_id,task_class,write_set,
   publisher_request,admission,publication,post_write_verification}`. `write_set` is sorted
   `{path,mode:"100644",sha256,git_blob_oid,add_only:true}`. Values come from verified
   materialization, never from a supplied write manifest.
2. Publisher request is a neutral schema-1 `shadow_publisher_request`, body exactly
   `target_repository_id`, `branch`, `base_revision`, `candidate_tree_id`, `title`,
   `body_sha256`. Branch is `ystack/evidence/<incident-id>`; title is `Shadow evidence:
   <incident-id>`; body bytes are `Shadow evidence for ` plus the incident id plus `.
   Publication is withheld.\n`. Retain those body bytes outside the candidate. No URL,
   credential, command, merge, comment or label is present.
3. Admission is `{state:"checked",effect:"none",request_sha256,write_set_sha256}` only when
   R3–R7 and every request equality pass. It means offline request validation, never authority
   to publish. Put these checks in one private function that the later publisher concern can
   adopt through its own gates. No transport or publisher implementation ships here.
4. Publication is exactly `{state:"withheld",reason_id:"shadow.write-not-published"}`.
   Post-write verification is exactly target revision, candidate tree id and the same
   path/mode/Git-blob/raw-byte digest list; it describes later read-only checks, performs
   none, and records no verified publication. Missing withholding or mismatched
   write/request/verification fields makes the form malformed.
5. Preserve the full outer R4/R5 evidence with this write-form record, its generated
   input/response and preparation records. Its completion marker inventories those files plus
   `publisher-body.txt`; no outer file is added to ROOT. The existing scope evaluator
   continues refusing this form until child 6 lands.

### R9. Proof, files and landing slices

1. Tests use disposable sources and stores, synthetic identities, the real checker,
   materializer, preparation, converter and locally built fixed verifier. Descriptor and ACL
   failures use deterministic positive/negative controls. Private in-process test substitution
   may emulate OS identity/launch calls; no production CLI, environment override or shipped
   accepted identity enables fixture trust. Label that proof simulated. Never run sudo, create
   accounts, install, boot a VM or touch the real fixed anchor during tests.
2. Prove every R3 metadata/ACL/alias/read-race refusal; wrong attempt/nonce-derived request
   digest/subject/control/accepted identity; copied receipt; changed
   evaluator/candidate/payload; missing, partial, refused, timed-out and cancelled evidence;
   exact expectation-before-launch ordering; valid mismatch versus refusal; positive controls
   for each boundary. Prove no launch after precheck failure and no completion marker after
   identity drift. With an independently accepted helper as the positive control, prove that
   an unapproved locator or substituted executable is rejected without executing any helper
   entry point, including `version`. A negative helper that would emit the expected version
   and an execution marker must leave no marker. Rechecking only after execution cannot pass.
3. Prove the two-attempt separation, exact inventory, converter provenance,
   add-only/protected/existing-path/mode/binary/oversize refusals, single parent, two-run
   determinism, no nonce/time leakage, zero producer calls, withheld-only publication and no
   source/store writes. Production-shaped tests must refuse the shipped empty accepted set and
   CPU/wall `none`. Preserve old shadow suites.
4. New files: `shadow/v1/enforced-reproduction.py`, `shadow/v1/write-shadow.py`,
   `shadow/v1/_consumer.py`, `shadow/v1/write-materialization-input.jq`; the five exact R10
   control files; `scripts/test/shadow-enforced.test.sh`, `scripts/test/shadow-write.test.sh`,
   `scripts/test/control-sandbox-bound.test.sh`. Changed files:
   `enforcement/v1/check-sandbox-receipt.sh`, `enforcement/v1/sandbox-receipt.jq`,
   `scripts/test/sandbox-receipt.test.sh`, `scripts/test/shadow-slice.test.sh` (compatibility
   only), `docs/components.md`, `RESTORE.md`, `ci/required-files.txt`. Add new
   restore-critical entries once.
5. Five sequential implementation PRs, each with its tests and restore/doc entries: (1) R10
   fixed binding tuple/evaluator/checker; (2) private origin/payload reader; (3) enforced
   reproduction and launch/record integration; (4) deterministic write input/materialization;
   (5) withheld record/admission and two-attempt integration. The first four track #506; only
   the last closes it. Each stays inactive and green.
6. Planned implementation review budgets are below. The plan must verify estimates against
   its field map; no compressed code or omitted proof may be used to fit a range.

| PR | Classification | Net-line range | Reason |
| --- | --- | --- | --- |
| 1 | Accepted exception | 500–850 | Closed evaluator, checker branch, fixed refs and tests |
| 2 | Accepted exception | 450–750 | Descriptor/ACL/payload reader and paired tests |
| 3 | Accepted exception | 550–850 | Framing, expectation/bundle orchestration and tests |
| 4 | Accepted exception | 450–750 | Input/patch construction and materializer tests |
| 5 | Standard | Up to 400 | Withheld admission, final integration and docs |

### R10. Closed verifier-byte binding

1. Add a fixed bound tuple under `control/v1/`: `sandbox-bound-policy.json`,
   `sandbox-bound-decision.json`, `control-policy-set-sandbox-bound.json`,
   `evaluate-bound-sandbox.sh`, `sandbox-bound.jq`. Keep all legacy policy, decision,
   policy-set, evaluator and generic validator bytes unchanged. Files distinguish versions by
   exact digest; logical ids remain `control-policy.sandbox` and `control-decision.sandbox`,
   as the unchanged policy-set validator requires.
2. The bound policy keeps every legacy policy field/value except its sole tool's placeholder
   `sha256`, replaced by exactly `identity_binding` with
   `{accepted_set_id:"sandbox.accepted-identities.v1",environment_source:"claim.id",
   slot:"verifier"}`. No alternate tool, selector, executable, argv, root, role, capability or
   limit is admitted. The policy-set changes only its document id to
   `control-policy-set.sandbox-bound.v1` and sandbox section byte refs; other sections and
   core contract are identical. The decision binds the new policy and evaluator sources and
   the unchanged validator driver/program by complete byte references. Its input contract is
   `control-policy-set+duty-evaluation+execution-environment-claim+verifier-observation.v1`;
   authority/qualification effects and output kind remain unchanged.
3. The consumer hashes the installed guest verifier through the R3 authenticated config's held
   `identity_paths.verifier` descriptor, bounded to 16 MiB, and rechecks its identity. Its
   canonical schema-1 `sandbox_verifier_observation` has id `sandbox.observation.verifier` and
   body exactly `{environment_id,
   environment_entry_sha256,target_repository_id,accepted_set_sha256,verifier_sha256}`. These
   values are derived from captured trusted bytes, not a request's proposed SHA or verifier
   path. Preserve this observation within `consumer-provenance.json`; provenance also binds
   the observed bytes to R3.
4. `evaluate-bound-sandbox.sh evaluate DUTY CLAIM OBSERVATION` uses fixed package paths for
   the bound tuple, accepted set and registry, pinned jq, bounded canonical snapshots, exact
   source hashes and unchanged rechecks. It calls the unchanged policy-set validator. Its
   dedicated jq program accepts only the complete fixed declaration: existing closed
   claim/duty shapes; exact policy
   environment/filesystem/isolation/limits/network/resources/sensitive-material values; both
   effects false; verifier role; one tool with the fixed fields and actual observed digest.
   Preserve the existing claim/duty/stage-result reference and duty-policy-set relations. Duty
   must be satisfied under this bound set. Require the duty’s exact document digest,
   core/policy/decision refs and stage-result relation as in `control/v1/sandbox.jq`’s
   `duty_binding_ok` and claim binding. A legacy duty result cannot be relabelled. This
   declaration is not child 9's missing real scope-gate evidence.
5. Require unique registry and accepted entries for this environment, unchanged
   accepted-set/registry shapes, current entry/set digests, and equality of the actual
   measured verifier digest, claim tool digest and observation verifier digest, with that
   exact value present in the same environment’s accepted verifier list. Observation
   environment id equals claim id and launch-subject environment id; its registry-entry hash,
   target repository and accepted-set hash equal the selected registry/accepted entries and
   launch subject’s corresponding identities. Placeholders, missing/duplicate entries, empty
   lists, stale digests, wrong environment or mismatched values refuse. The consumer's
   descriptor measurement supplies the candidate value; membership constrains it. This never
   admits a new identity or derives one from a local test build.
6. Output remains exactly kind `sandbox_policy_evaluation`, schema 1. Keep the existing body
   fields and add only `verifier_binding`, equal to the observation body plus
   `observation_sha256`. Policy, decision and policy-set refs name the bound fixed tuple.
   Preserve `enforcement_proof:"declaration-only"`, authority and qualification effects
   `none`. Valid complete input yields `satisfied` with reason
   `sandbox.verifier-binding-satisfied`; incomplete or differing declared values yield
   `inconclusive` with `sandbox.verifier-binding-refused`. Malformed inputs, fixed-byte drift
   and inconsistent references exit 1 without evaluation. A bound evaluation alone is never
   evidence that a process was contained.
7. Add only the explicit verb `check-bound` to `check-sandbox-receipt.sh` and its jq program.
   It selects the new tuple's closed schemas and separate fixed pins; `check` still selects
   the old tuple and retains its outputs. Neither accepts caller policy paths or auto-detects
   a permissive mode. Preserve all receipt fields, accepted-set admission, accounting, limits
   and verdict derivation. Snapshot and validate OBSERVATION, recompute its digest and require
   exact equality to the evaluation’s complete verifier binding. Require the same
   environment/entry/target/set relations in expectation, request and receipt, and
   `receipt.identities.verifier == {state:"observed",sha256:d}`, where d is the
   measured/claim/observation digest. Membership alone is insufficient even when two verifier
   values are accepted. All six control hashes, including the actual evaluation digest, must
   agree with the pre-launch expectation. Use `receipt.control-mismatch` for a binding
   disagreement. Production enforcement still requires R3 origin and satisfaction.
8. Pin in dependency order: new evaluator sources and policy → decision refs → bound
   policy-set refs → checker bound-mode fixed pins. Validate complete refs, not only SHA
   strings. Consumer snapshots and receipt control fields bind these actual bytes. Installed
   `control_policy`, `control_decision`, `control_policy_set`, `evaluator_driver` and
   `evaluator_program` must match the bound tuple for this path; legacy installed values
   refuse. Selecting/installing those files on a real host remains the separate reserved VM
   decision.
9. Test the actual fixed driver/checker with synthetic set copies: a positive control,
   unlisted and placeholder digest, cross-environment identity, swapped installed executable,
   stale observation/policy/program/decision/set, false duty, alternate tool/argv/root/limit
   and partial declaration. Mutate linked values while recomputing dependent hashes: forged
   satisfied labels, legacy-set duty, target/entry mismatch and unequal verifier values when
   both are accepted must still refuse. Assert the consumer actually executes the fixed
   evaluator. Require old evaluator and checker outputs unchanged on original canonical cases,
   and the shipped empty set to refuse. Keep old accepted-set and native qualification tests.
   Compose with generic validators; do not duplicate the entire legacy evaluator, rewrite
   claims into placeholder claims, or introduce an unapproved exception.

## Design

`_consumer.py` owns only shared bounded snapshots, origin/payload reading, fixed component
calls and record validation for these two entry scripts. It is private to this package.
`write-materialization-input.jq` reuses the core profile/schema modules and unchanged
materializer protocol; the old assembler remains read-only.

The high-risk plan maps each required assertion to a test, names exact subprocess argv,
deadlines and field mappings, and records relevant integration commands. At minimum run new
suites plus shadow-slice, shadow-assembler, shadow-self-host-evidence, sandbox-receipt,
file-digest-verifier, candidate-content-preparation, local-git-materializer protocol/adapter,
incident-to-eval and scope-qualification coverage. Required quick CI is not a claim that the
full matrix ran.

## Out of scope

Scope-gate acceptance/coverage (child 6), kill register (7), durable-store wiring (8), real
risk/duty/kill evidence (9), eval seeds/graders (10), real publisher (11), enablement (12),
host acquisition/install/trust-root/native runs, credentials, network expansion, target
execution, model calls, activation and deployment. No change to preparation, verifier, VM,
receipt fields/accounting, accepted-set admission or qualification rules is granted. R10 is
the sole upstream acceptance change; no legacy policy, evaluator or canonical decision changes
with it.

## Areas of concern

- High risk: this is receipt-origin authentication and evidence consumed by future write
  gates. Separate plan acceptance, independent review and all relevant safety tests are
  required before code or completion claims.
- Native R7.2 remains blocked. Fixture satisfaction is not native satisfaction; installing the
  existing VM still cannot qualify CPU or wall under its spec.
- The immutable root-owned anchor resolves the intent's origin question without trusting
  caller metadata. Its actual installation and group setup remain reserved.
- The two immutable attempts and closed inventory resolve the record/publisher question; exact
  new paths and R9 controls resolve the fixture-design question.
- R10 completes VM R1.5's binding machinery without choosing a native identity. Its same-kind
  evaluation preserves the supervisor interface; its distinct fixed tuple preserves legacy
  declaration behavior. An empty accepted set still blocks actual use. Fixture binding success
  cannot close native qualification.
