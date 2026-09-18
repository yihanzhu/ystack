---
intent-blob: 5a0f933c1209a96e975af1ce5b46db50559e539b
risk: high
drafted: 2026-09-13
---

# Spec: first read-only self-host shadow run

Two runs examine real ystack history on the operator's local macOS machine.
The repository keeps their unchanged inputs, outputs and a replay recipe.
This is evidence of deterministic file-digest reproduction, with no model call,
workflow qualification, activation, target write or deployment authority.

## Requirements

1. The accepted implementations of `resolver-trusted-parent` and
   `shadow-input-assembler` must be merged and their required proof green before
   either real run. Use their supported public interfaces. No test launcher,
   fabricated resolved profile or copied resolver implementation may replace them.
   Preparation of incident documents and verification instructions can precede them.

2. This first run requires no real sandbox and claims none. It uses the shipped
   declaration-only evaluation exactly as shipped: `control/v1/evaluate-sandbox.sh`
   with `control/v1/sandbox-policy.json` and `control/v1/sandbox.jq`. The evidence
   retains that evaluator's raw result bytes together with its fixed,
   machine-checkable declaration-only marker in the emitted
   `sandbox_policy_evaluation` body: `enforcement_proof: "declaration-only"`,
   `authority_effect: "none"` and `qualification_effect: "none"`. The evaluator
   compares declarations only, so its verdict — including `satisfied` with the
   single reason `sandbox.declaration-satisfied` — records that the claim matched
   the declared policy and leaves enforcement `unproven`. It is never enforcement
   proof, qualification or a substitute for a real sandbox.
   The environment must already be registered as `env.local-macos-ystack-self`,
   bound to `repo.ystack` and root `7908b159c0a2d24ce6ccdde6ee0f501acc483e75`.
   Verify the registry and source history before running. Registration and its
   `unproven` state establish no sandbox guarantee. This evidence task changes
   none of those boundaries.
   The consumers must classify the run in their own shipped vocabulary: the scope
   evaluator emits `outcome: "not-proposable"` with `qualification: {state:
   "unavailable", reason_id: "scope.enablement-requires-operator-pr"}`, the
   maintenance consumer's generated skeleton carries `qualification: {state:
   "unavailable", reason_id: "maintenance.no-adapter-exists"}`, and each shadow
   record keeps `qualification: {state: "unavailable", reason_id:
   "shadow.unqualified"}`. No consumer output, evidence document, component
   documentation or README may describe this run as sandbox-enforced, qualified
   or proposable.
   Committed evidence must refuse the fixture placeholder digests: the
   repeated-character values the shadow slice harness builds its control policy and
   decision references from (`scripts/test/shadow-slice.test.sh`, `("2" * 64)` and
   `("b" * 64)`) are not real bytes; any such digest in a committed reference stops
   the run rather than being retained.

3. Both target revisions use their native SHA-1 Git object identities. File-byte
   digests and content references use SHA-256. The driver's current registry check
   accepts 40-hex root commits; this task does not broaden it. A SHA-256 repository
   would require the separately accepted registry/driver follow-up before use.
   That follow-up is not required merely because file digests are SHA-256.

4. The failing check is `file-digest` at `config/construction-mode.json`.
   The post-transition revision is `0427390224c25147650f1bd3b6e43ed6911b97a7`
   (operating-mode transition, PR #261). Its first parent, the pre-transition
   baseline, is `d3f6d525328838b9c2de819699e53d8909ab7a3f`.
   Recompute the parent relation and raw blob digests from Git before execution.

5. Both incident records expect the pre-transition file's raw-byte SHA-256:
   `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93`.
   The post-transition file's observed digest must be
   `5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda`.
   Do not hash reserialized JSON or change expected bytes to match an outcome.
   A provenance mismatch stops the run and requires reconciliation.

6. Write separate canonical `shadow_incident_record` documents with distinct ids
   `incident.ystack-transition.post` and `incident.ystack-transition.pre`.
   Each names its exact revision, `repo.ystack`, the same check and expected digest,
   and `deploy_authority: none`. The baseline is explicitly a control observation,
   not a second reported outage. The symptom text distinguishes these roles.

7. Use `reporter_actor_ref: actor.operator` and document that this names Yihan Zhu,
   who reported the transition incident in the accepted intent. Record the actual
   UTC observation time when each revision's digest is checked for this exercise.
   Do not pretend a newly chosen timestamp is the original outage time. Freeze
   those input timestamps for replay; record execution date separately in the README.

8. The post-transition run must return `reproduced` with
   `check.failed-at-revision`; the pre-transition control must return `no-change`
   with `check.passed-at-revision`. An `inconclusive` response is retained for
   diagnosis but cannot stand in for either required result or close the intake.
   The pair demonstrates this one changed-file condition, not the entire old CI suite.

9. Use a disposable, scrubbed bare copy of existing local ystack history.
   Preserve authentic commits and objects; do not rebuild commits or rewrite history.
   The copy must contain both incident revisions, their ancestors and every Git
   object needed to resolve the selected profile's references. Require the existing
   source-purity and closure checks to pass. No remotes, credentials, alternates,
   replacement refs, active hooks, shallow boundary or external object dependency.
   Scrubbing applies only to the disposable copy, never the user's original repository.

10. Source preparation and execution use no network and no credentials. Supply fresh,
   private, disjoint candidate, scratch and state directories outside the source.
   The materializer may write its disposable candidate and evidence only. Compare
   source refs and object inventory before and after; retain the comparison result.
   Use supported clean entry forms and the shipped dependency pins and resource limits.

11. Resolve the real, assembler-pinned default profile through the accepted trusted
   parent. Record its source revisions, request provenance, runtime and helper
   identities, and the exact output document. Verify supplied profile/manifests
   against their real bytes. The request recipe may use caller-selected local roots;
   the durable record binds the actual Git/content identities, not invented fixtures.

12. Construct each `qualified_identity` from the real resolved profile and that run's
   assembled stage request. Both references must equal the assembler's emitted
   `resolved-profile-ref.json` and `stage-request-ref.json` exactly. Target revision
   must equal the incident. Derive config references, model request, prompt refs
   and skill refs from the real selected bindings and verify their referenced bytes.
   Do not substitute this Codex session's model for the selected producer settings.

13. The currently pinned producer config names provider `anthropic`, model
   `claude.sonnet`, effort `high`. These are recorded configured settings, not evidence
   that a model executed. The selected prompt is its versioned `routines/coder.md`
   reference; resolve its exact object and bytes. An empty skill list is valid only
   when the selected profile requests none. No placeholder digests or fixture models.

14. Add `shadow/evidence/self-host-transition/v1/verification-instructions.md`.
   It describes only reading the named blob at the incident revision, hashing raw
   bytes, comparing the recorded expectation and interpreting the three outcomes.
   Bind its exact bytes as the identity's `verification_instructions_ref`.
   Retain the assembler's own instruction output unchanged too; document which
   reference serves each role rather than rewriting an accepted assembler output.

15. Add `scripts/test/shadow-self-host-evidence.test.sh`. CI verifies the committed
   evidence offline: inventory and digests, canonical JSON, incident validation,
   identity/reference equality, exact revisions and outcomes, empty patch in both
   input locations, network deny, successful no-change materialization, trace seal
   and materialization-result reference, plus the retained sandbox evaluation
   bytes and their recorded reference. It also asserts that every retained
   evaluation carries the declaration-only marker of requirement 2 and that no
   committed document claims a satisfied sandbox boundary, enforcement proof or a
   qualified workflow. Missing or altered evidence must fail.
   CI does not perform a real self-host run, obtain credentials or invoke a model.

16. Both unchanged shadow records must pass the step-8 consumer's complete shape
   and reference checks. Exercise the shipped scope evaluator with a clearly marked
   inactive compatibility harness, carrying the actual records and exact identities;
   distinguish other missing gate evidence from malformed shadow evidence. The test
   must not edit or copy a weaker shadow validator, create live scope authority or
   claim that compatibility alone produces a qualified workflow.

17. Feed each incident and its matching unchanged shadow record to the real
   `maintenance/v1/incident-to-eval.sh`. Require the stale-moved-artifacts family,
   post expectation `{accepted, stale}`, pre expectation `{accepted, completed}`,
   and provenance digests equal to the supplied documents. Cross-pairing the records
   must fail. Generated seed skeletons are test outputs, not new live eval cases;
   no seed set is modified by this task.

18. Run each fixed tuple twice in fresh disposable directories under the same pinned
   tools, source and environment. Require byte-identical assembler and driver outputs
   and intact source state. This proves repeatability for these inputs and environment,
   not portability across operating systems or future dependency versions.
   CI can recheck durable bytes without possessing the whole historical repository.

19. Final proof names the exact implementation head, dependency heads, commands,
   both outcomes and reason ids, reference checks, repeatability comparisons and
   consumer results. Required CI and independent review must pass on the final head.
   The records retain `authority: none`, `deploy_authority: none`, `shadow: true`,
   `activation_state: inactive` and unavailable qualification exactly as emitted.
   No registry proof-state change, automatic write permission or Roadmap completion
   beyond this bounded self-host observation follows from the evidence.

20. Completion means both real outcomes, repeatability and offline/consumer proof
   are committed together and reviewed. An environment declaration, fixture run,
   fabricated identity or draft spec alone meets none of those completion conditions.

## Design

Store the result under `shadow/evidence/self-host-transition/v1/`.
Shared files are `README.md`, `verification-instructions.md`, `checksums.json`,
the resolved profile, environment claim, control policy set and duty evaluation.
`pre/` and `post/` each hold the incident, identity, all seven assembler outputs,
and the driver's four state outputs: `shadow-record.json`, `trace-ledger.json`,
`trace-receipt.json`, `materialization-result.json`. Preserve native names in
`assembled/` and `state/` subdirectories; all JSON remains canonical producer output.
Also retain each case's declaration-only `sandbox-evaluation.json` beside its
assembled and state directories. The driver exports only its four state files
before cleaning scratch. Obtain the sandbox evaluation through the shipped
evaluator's supported public interface, with identical claim, policy-set, duty and
dependency bytes to the driver's call. Require its raw-byte digest to equal that
run's recorded sandbox evaluation reference before retaining it, and keep the
declaration-only marker of requirement 2 visible in the retained bytes and in the
README's description of them. Do not intercept scratch or bypass driver cleanup.
If the shipped evaluator cannot reproduce matching bytes, stop and reconcile; do
not fabricate the document or weaken the reference.

Keep the raw bytes of every referenced evidence document recoverable from this
directory or an exact committed Git object named in the README. Record a finite
relative-path inventory and SHA-256 for each bundled input/output in
`checksums.json`; exclude that checksum file itself to avoid a self-reference.
Do not commit the disposable bare repository, candidate, scratch, binaries,
credentials or machine-specific absolute paths. Do not redact or normalize an
emitted hashed document; stop if its contents cannot be committed safely.

The README gives the two input tuples, real dependency commits and digests,
environment observations, selected identity provenance, output digests and
outcomes, and a replay recipe using caller-supplied scratch paths. It distinguishes
observations from guarantees and lists any unsuccessful attempt used for diagnosis.
Store only the accepted pair as final evidence; failed attempts are never relabeled.

Append every committed evidence file and the new focused test to
`ci/required-files.txt`, so a missing restore-critical document fails CI.
Add a short component-documentation entry, README index row and RESTORE block.
Restoration preserves evidence and verification instructions; it executes no run
and does not register, activate or qualify an environment.

## Out of scope

Keep the driver, materializer, registry, profile, core contracts and consumers
unchanged. An incompatible accepted dependency returns to its own artifact gate;
no local patch, weakened claim, fabricated reference or alternate private entry
may make this run pass. The evidence stays inactive and repo-only.

No model evaluation, external-target proof, workflow activation, live eval seed
change, registry proof-state change or broader Roadmap completion is included.

## Areas of concern

This is high risk because it moves a security-sensitive workflow from fixtures
to real repository history and records execution and identity claims. G2 accepts
this spec; a separate independently reviewed, operator-merged high-risk plan
must precede implementation. This spec authorizes no execution by itself.

A real execution boundary is a prerequisite of step 8 (bounded autonomous writes),
not of this run. The shipped policy fixes demonstration `/sandbox/*` roots and a
verifier SHA-256 of 64 ones, and the evaluator checks declarations only; no real
binary can be bound truthfully by copying that placeholder. This run therefore
produces no sandbox evidence: its retained evaluation states declaration-only,
`unproven` enforcement, and nothing here qualifies an execution boundary, relaxes
one or lets a declaration stand in for enforcement. `work/real-sandbox-boundary/spec.md`
is the record of why real sandboxed execution is blocked and of what the separate
initiative must bind — actual tool bytes, policy and evaluator identities, and the
proven restrictions — before any task consumes it. That initiative's accepted
outputs must remain compatible with this task's unchanged driver, and step 8 must
be sized against the evidence this run produces.


One concern: the first real self-host evidence pair and its durable verification.
Estimated 250-450 net lines: roughly 100-170 for the focused test, 80-130 for
instructions/replay/provenance, 35-65 canonical document and inventory lines,
and 35-85 documentation and manifest lines. Canonical JSON can be wide; review
also inspects expanded documents and bytes, not line count alone.
`review_size: accepted-exception` waives only the soft line signal. Complete
evidence, readability, security boundaries, CI, independent review and operator
merge remain required. The plan must refine this estimate against real dependency
interfaces; an unexplained overrun or required scope change returns to its gate.
