---
intent-blob: b0a9fa194218778a555dd4c34ea37faa265caf31
risk: high
drafted: 2026-09-27
---

# Spec: step 8 bounded-write readiness decision

Tracks #427. This is a decision-only record. It ships no runtime, policy, credential,
activation or write. The accepted intent was read at main
`c7ea7022049f97ece84b08118463e69b897cbc5c`. DR-7, accepted on #427, fixes three
inputs: the first workflow is a deterministic non-model write; DR-4 is reaffirmed, so
a real sandbox receipt is mandatory before any write scope is proposable; and the
operator owns the kill switch.

Today no write scope is proposable, and this record makes none proposable. Its job is
to say exactly what evidence would change that, and in what order it must land.

## Requirements

### R1. The first bounded-write workflow

1. **Workflow.** `workflow.shadow-evidence-commit`, task class
   `task.commit-shadow-evidence`, risk tier `routine`. It commits one finished
   shadow-evidence bundle and the incident-to-eval seed skeleton generated from it
   into the target repository whose incident was reproduced.
2. **First target.** The external dummy target `yihanzhu/ystack-dummy-target`, in
   execution environment `env.local-macos-dummy-target`, using the evidence of the
   step-7 external-target run (intake #426). ystack itself is not the first target:
   control-plane self-modification is always high risk (`ROADMAP.md`, self-host
   section), and `scope/v1/scope-policy.json` proposes only `routine` scopes.
3. **Deterministic, non-model.** Every written byte is produced by shipped
   deterministic components: the shadow driver's outputs, the retained sandbox
   receipt, and `maintenance/v1/incident-to-eval.sh`. No model is invoked at any
   point of the write workflow. The scope's evidence must show zero producer
   invocations. Model-driven writes (#329) stay off this path.
4. **Write boundary.** One attempt writes at most one new branch and one pull request
   in the target, and nothing else:
   - Paths: add-only under the single root `ystack-evidence/<incident-id>/`, where
     `<incident-id>` is the scope's one recorded incident id. The scope's
     `allowed_paths` are exact directory names with at most a leaf wildcard (for
     example `ystack-evidence/<incident-id>/*.json` and
     `ystack-evidence/<incident-id>/README.md`), as `glob_ok` and the protected-glob
     check in `scope-gates.jq` already require. No directory wildcard, no `**`.
   - The root is outside every entry of `protected_path_prefixes`,
     `protected_path_segments` and `protected_root_files` in `scope-policy.json`,
     outside the target's `.ystack/` directory, and outside the forbidden set of
     `config/construction-mode.json`. A child that cannot keep all of that true stops.
   - No existing file is modified, renamed or deleted. A path that already exists in
     the target refuses the write.
   - Branch: exactly `ystack/evidence/<incident-id>`, created new. The default
     branch and every protected branch are never pushed. A target ruleset, not only
     the publisher, must refuse such a push.
   - One pull request per scope: at most one open publisher pull request for the
     scope at any time, and `max_attempts: 1` per incident. The workflow never
     merges, approves, labels, or comments beyond the pull request body. The merge
     stays a human decision (control objective 3).
5. **Why this one.** Its bytes are already reviewed evidence, its outcome is
   checkable by digest, and a wrong write is visible and reversible by closing one
   pull request. It exercises every step-8 boundary without needing a model.

### R2. Shadow evidence for a write scope

1. A read-only scope keeps today's contract: a `no-change` materialization with an
   empty patch (`scope-gates.jq`, `materialization_ok`). Old records keep their
   meaning and are never reinterpreted.
2. A write scope is shadowed by performing the whole write inside the disposable
   copy and withholding only publication. Its shadow record must carry, beyond
   today's sections:
   - a materialization with outcome `changed` whose candidate commit has the target
     revision as its only parent and whose patch is exactly the planned write;
   - the planned write set: every path, file mode and raw-byte SHA-256, marked
     add-only, and the check that each path matches `allowed_paths` and none exists
     at the target revision;
   - the would-be publisher request (target repository, branch name, base revision,
     candidate tree id, pull request title and body digest), validated by the same
     checks the real publisher runs before a write;
   - a publication section with `state: "withheld"` and reason
     `shadow.write-not-published`, so no reader can mistake it for a write;
   - the post-write verification plan: the exact tree and blob digests the verifier
     will compare after a real publish;
   - the real sandbox receipt of R7 and zero producer invocations (R1.3).
3. The same tuple run twice in fresh directories must give byte-identical candidate
   trees, write sets and publisher requests. Attempt times may differ.
4. Proof without a live write comes only from the withheld record, its repeat, and
   the offline test of the committed bundle. Nothing is pushed, and no credential
   is present, during a shadow run.
5. `scope-gates.jq` accepts outcome `changed` only together with a `withheld`
   publication section and a matching write set. A `changed` materialization
   without them is malformed. That consumer change belongs to child concern 6.

### R3. Revision coverage

Exact-revision binding (`scope-gates.jq:846`) is replaced for write scopes by a
recorded coverage rule. Each execution environment qualifies separately.

1. The scope records `coverage_base`: the target revision its shadow evidence used.
2. A later target revision R is covered only when all hold:
   - R is a first-parent descendant of `coverage_base` on the target default branch;
   - between `coverage_base` and R, nothing changed under `ystack-evidence/` except
     commits merged from this scope's own publisher pull requests;
   - between `coverage_base` and R, nothing changed under the target's `.ystack/`,
     its CI workflow files, or its branch rules;
   - the coverage identity of R3.3 is byte-identical to the qualified one;
   - the attempt carries fresh per-attempt evidence for R itself (R3.4);
   - the qualifying shadow evidence is at most 30 days old.
3. **Coverage identity** (the only closed set; byte-identical across every covered
   revision): scope id, `workflow_id`, `task_class`, `model_request`,
   `adapter_config_refs`, `prompt_refs`, `skill_refs`,
   `verification_instructions_ref`, the resolved profile's `profile_ref`,
   `profile_source`, `selection_ref` and `bindings`, the execution environment id
   and its registry entry bytes, the control policy set ref and the sandbox and
   scope policy bytes the evidence bound, and the coverage anchor (`coverage_base`
   and rule version).
4. **Revision-derived evidence and the binding rule.** Everything in an attempt's
   evidence outside the coverage identity is revision-derived. It is produced fresh
   for every attempt and may change, subject to one rule: each derived field must be
   recomputed from, and verified against, the attempt's actual revision R and its
   actual request, resolved profile and materialization. The checks that verify it
   are the existing ones: the core stage-request relation checks
   (`stage_request_resolved_relation_ok`, `stage_request_resolved_ref_ok`), the
   request and incident checks in `shadow/v1/reproduce.sh`, the materialization
   relations in `scope-gates.jq` (`materialization_ok`), and its `$gates_bound`
   checks, which bind the risk, duty and kill evaluations to the request, the stage
   result, the resolved profile and each other by digest. The evaluator refuses when
   any coverage-identity field differs or any derived field fails its binding. It
   never accepts a derived field because it matches the qualifying evidence, and
   never because it merely differs.

   Revision-derived fields include, as an illustrative list (the rule governs, not
   the list): `target_revision`; the materialization's `source.commit_id`,
   `source.tree_id`, `candidate.commit_id`, `candidate.parent_commit_id` and
   `candidate.tree_id`; the publisher request's base revision; the stage request's
   target revision, source-tree refs, `repository_context_ref` and
   `resolved_profile_ref`; the resolved profile's `repository_context_ref`; the three
   `gate_evidence_refs`; and the attempt's shadow record, materialization result,
   `stage_result_ref`, sandbox evaluation and sandbox receipt refs.

   *Reusable qualification evidence* is the coverage identity plus the qualifying
   shadow records and eval results the scope names. It is fixed at qualification.
5. A change in the coverage identity returns to the shadow gate. Revision-derived
   changes that pass the binding rule are the normal per-revision rebinding that
   coverage exists for, and need no new qualification.
6. Anything else invalidates the qualification and returns to a named gate:

| Change | Returns to |
| --- | --- |
| Any coverage-identity field: profile selection or bindings, adapter config, model request, prompt, skill or verification instructions | Shadow gate: new shadow evidence for this scope |
| Scope policy, control policy, sandbox policy or eval catalog | Eval gate, then the shadow gate |
| Execution environment, runtime, image or verifier bytes | That environment's own qualification, then the shadow gate |
| History rewrite, non-descendant R, or a foreign change under the covered paths | Shadow gate |
| Evidence older than 30 days | Shadow gate |
| Risk tier, task class, allowed paths or target | A new scope: its own G2 and its own enablement pull request |

7. `model_request` stays in the coverage identity as recorded configuration, even
   though the workflow invokes no model. A change to it still invalidates.

### R4. The enablement record

1. **Where.** `config/scope-enablement.json`, one document of kind
   `scope_enablement`, listing at most one enabled scope at a time.
2. **Schema.** Each entry binds: the scope document ref (id and SHA-256); the
   proposable scope qualification evaluation ref; the shadow evidence refs; the
   coverage base and rule version of R3; the kill-switch register id of R5; the
   publisher identity id of R5; and the operator decision request id. `enabled:
   true` and `push_allowed: true` appear only inside this entry.
3. **Who sets it.** Only an operator-merged enablement pull request sets `enabled:
   true` or `push_allowed: true`, or changes `allowed_live_writes` in
   `config/construction-mode.json` from `"none"`. RC-1 reserves exactly this. No
   agent merges it, and no other file can turn a scope on.
4. **Consumer.** The scope evaluator (at attempt start and again immediately before
   the write) and the publisher (immediately before the write) each fetch the
   current tip of the ystack default branch and read the record there, never from a
   working copy, a branch or a pinned commit. The exact enablement entry must be
   present and identical at that tip: scope id and scope digest, the R3 coverage
   anchor (`coverage_base` and rule version), `enabled`, `push_allowed`, and the
   `allowed_live_writes` value in `config/construction-mode.json`. Each check
   refuses, and nothing is written, with `scope.enablement-stale` when the fetch
   fails, the entry is missing or differs, the record is unparseable, a named scope
   or evaluation digest does not match, the revision is outside R3 coverage, or
   `allowed_live_writes` disagrees. A pinned or historical read never satisfies R4:
   a commit that once enabled the scope stays in history after the operator disables
   or replaces it. Child concern 6 adds `scope.enablement-stale` to
   `scope-policy.json` `reason_ids`. The authentic operator merge of the introducing
   pull request is checked from forge records; how is fixed by child concern 12.
5. Until that pull request merges, `workflow-scope.jq:185-188` keeps refusing an
   enabled or push-allowed scope and qualification stays `unavailable`.

### R5. Publisher and kill switch

1. **Publisher boundary.** A separate publisher with no model access and no candidate
   code execution. It uses one short-lived identity, minted per attempt, scoped to
   the one target repository, able only to push the R1.4 branch and open its pull
   request, and invisible to the producer, the verifier and the reviewer. Before the
   write it re-checks the enablement record, the kill switch, the coverage rule and
   the write set against the shadow record. After the write, a separate read-only
   check (#304 observations) compares the pull request's head tree and diff with the
   planned digests. A mismatch fails the attempt with
   `publisher.post-write-mismatch` and stops the scope until the operator reviews.
2. **Credential decision is reserved.** Which identity, installation, permissions,
   lifetime and storage are the operator's decision (RC-1 item 2). This record
   selects none and grants none. `adapters/dormant-publisher/v1` stays dormant.
3. **Kill-switch owner.** The operator. No agent may clear a stop. An agent may
   propose a stop, never a clear.
4. **Kill-switch state document.** `config/kill-switch.json`, kind
   `kill_switch_register`, committed on the ystack default branch, so every change
   is operator-merged. Body: `revision` (strictly increasing), `authority_epoch`,
   and `entries` for the `global`, `repository` and `workflow` scopes of
   `control/v1/kill-switch-policy.json`, each `cleared` or `stop`, plus
   `write_entries`: one per workflow scope, `cleared` or `stop`. A write needs both
   the matching `entries` cleared and the scope's own write entry `cleared`; an
   absent write entry means `stop`. Observation (shadow runs and gate evaluations)
   reads only `entries`. The shipped per-attempt `kill_switch_state`
   (`control/v1/kill-switch.jq`) becomes a deterministic projection of the register
   for one attempt: it binds the register's SHA-256 and revision and adds the
   `stage` and `attempt` entries.
5. **How a workflow checks it.** At attempt start, immediately before the publisher
   write, and in the post-write check. Each reads the register from the default
   branch tip at that moment, never a cached copy. A missing, unreadable, malformed,
   rolled-back or ambiguous register counts as `stop` (fail closed, matching the
   policy's `fail_mode: closed`). A `stop` at any matching scope, or a write entry
   that is absent or `stop`, refuses the write.
6. **Bootstrap before use.** The register is committed by child concern 7, before
   any gate evaluation reads it (concern 9). Its first state has `entries` cleared
   for observation and no write entry for any scope, so nothing can write. Writes
   stay disabled until concern 12; concern 12 only flips the one scope's write
   entry to `cleared`, in the same operator-merged pull request as the enablement
   record.

### R6. Evals

1. Before enablement, all nine families in `evals/v1/eval-catalog.json` are `seeded`
   and `passed` for the scope, including `malicious-instructions` and
   `reviewer-severity-false-positive-negative`, which are only `declared` today.
   Seeds come from real work, not invented fixtures.
2. **`malicious-instructions`.** A deterministic grader is acceptable for this
   non-model workflow. At least the catalog's 3 trials, seeded from real target and
   incident content. Each trial plants instructions on one surface. The grader does
   not diff the trial against its control. It checks closed invariants, then
   recomputes every other field from the trial's actual inputs with the same
   shipped components and checks the recorded value equals the recomputed one. A
   broken invariant or any field that differs from its recomputed value fails the
   trial.

   The invariants on every surface are: the authorization decisions (scope, gate
   verdicts, kill-switch and enablement results, publisher admission); the
   permitted effects (the same scope, allowlisted paths, branch and pull request
   shape, and no additional command); and the written path set, with no path added
   or removed. A surface that does not touch the target's Git objects also keeps
   the target source tree ids invariant.

   | Surface | Touches target Git objects | Expected derived changes (illustrative; the recompute rule governs) |
   | --- | --- | --- |
   | Incident symptom text | No | Incident digest and its repetitions, dependent evidence refs, seed provenance and digest, committed bytes and write candidate tree |
   | Checked file bytes (a planted blob, so a new tree and commit) | Yes | Observed digest and match flag, outcome and reason, seed `case.expectation.status` (for example `completed` to `stale`), `git_revision_ref`, incident digest, stage request, resolved repository context, source and candidate commits and trees, dependent evidence refs, seed revision, provenance and digest, committed bytes |
   | Commit message at the incident revision | Yes | Commit id, `git_revision_ref`, incident digest, stage request, resolved repository context, candidate commit, dependent evidence refs, seed revision, provenance and digest, committed bytes and write candidate tree |
   | Forge text the workflow does not read (issue, pull request and review comments, other branches) | No | None. The pull request title and body are generated from the bundle, never from forge text |
3. **`reviewer-severity-false-positive-negative`.** The catalog lists only human and
   model graders. A human-graded set is acceptable: at least the catalog's 5 trials,
   built from real recorded independent-review verdicts with operator-labelled
   ground truth. Pass requires zero missed Important findings; false-positive rate
   and severity agreement are recorded. Further thresholds are fixed in the seeding
   child's spec with operator acceptance.
4. **Reserved.** Model graders for both families. Adding a grader kind or changing a
   trial policy is an eval policy change and follows its own high-risk gates.

### R7. Scope-gate hardening

1. Today `environment_evaluation_ok` (`scope-gates.jq:462-478`) accepts a
   `satisfied` verdict whose only reason is `sandbox.declaration-satisfied`. A child
   initiative must change the qualification predicate so that:
   - a record whose environment evidence is declaration-only still passes the shape
     check, so old records stay readable, but it yields the new refusal
     `scope.sandbox-receipt-missing`, added to `scope-policy.json` `reason_ids`;
   - `proposable` requires, for every required environment, a real sandbox receipt
     of the kind defined by child concern 2, whose verdict is satisfied and whose
     attempt, candidate, environment and policy identities equal the record's;
   - the required environment's registry entry records native qualification from
     child concern 4, not `unproven`.
2. The same child adds R2.5's write-form materialization and R3's coverage rule.
   No satisfied declaration ever counts as enforcement or qualification.

### R8. Ordered child concerns

Each concern gets its own intake, intent, spec, plan gate, exact paths and tests.
Accepting this record accepts no child code. The order is the landing order;
drafting may run in parallel where no dependency is listed.

| # | Concern | Depends on | Reserved decision |
| --- | --- | --- | --- |
| 1 | Step-7 external-target run (intake #426, in flight) | — | Already under DR-6; step 7 closes only with it |
| 2 | Enforcement-evidence binding: authentic receipt kind, exact byte identities, consumer checks | — | None beyond review; no signing credential selected |
| 3 | Fixed file-digest verifier (subsumes #314; preparation in #396) | 2 | None beyond review |
| 4 | VM launcher and supervisor | 2, 3 | Installation and native qualification on the operator's machine |
| 5 | Shadow-consumer integration: real receipt in the driver; R2 write-shadow record | 1, 2, 3, 4 | First real write-shadow run |
| 6 | Scope-gate hardening: R7, R2.5, R3 | 2, 5 | None beyond review |
| 7 | Kill-switch register bootstrap: commit `config/kill-switch.json` (R5.4, R5.6), operator as owner, observation cleared, no write entry | 4, 6 | The operator commits the register; operator merge of `config/**` |
| 8 | Durable telemetry (subsumes #307) | — | None beyond review |
| 9 | Real gate evidence: risk, duty and kill evaluations bound to the scope's own `stage_request_ref`; kill projection of R5.4 | 5, 7 | None beyond review |
| 10 | Eval seeding: R6 | 5, 9 | Model graders; any grader or trial-policy change |
| 11 | Real short-lived publisher and post-write check (#304) | 6, 8, 9 | Credential, identity, network scope, first real write |
| 12 | Enablement pull request: `config/scope-enablement.json`, the scope's write entry in `config/kill-switch.json`, `allowed_live_writes` | 1-11 closed | Activation; operator merge of `config/**` |

Concerns 2, 3, 8 and the deterministic part of 10 may be drafted now. Concern 12
strictly follows every other concern and step 7's close.

### R9. Exclusions

1. This record ships nothing that runs. `scope/v1`, `control/v1`, `config/**`,
   `adapters/dormant-publisher/v1`, `evals/v1`, `shadow/v1` and `ROADMAP.md` stay
   byte-identical, and no gate, policy or test behaves differently.
2. Nothing enables before step 7 closes, including its external-target run.
3. No credential, network scope, installation, activation, real target execution,
   model-driven write, review-fix loop, target packaging, deployment, rollback or
   production action. Each reserved decision is asked where R8 names it.

### R10. Review size

- Plan-only pull request (`work/step8-bounded-write-readiness/plan.md` only):
  `review_size: standard`.
- Implementation pull request (discoverability only: `docs/components.md`,
  `RESTORE.md`, `ci/required-files.txt`, in the `work/real-sandbox-boundary/`
  pattern, about 20-40 lines): `review_size: standard`.
- This spec pull request: `review_size: accepted-exception`. One concern, this one
  file, 370-410 added lines. The size comes from ten settled decisions plus the
  coverage and child tables; splitting them would scatter one contract. It waives
  only the soft line signal.

## Design

The plan stage makes this decision discoverable and restorable, as
`work/real-sandbox-boundary/plan.md` did: one paragraph in `docs/components.md` near
the scope evaluator, one in `RESTORE.md`, and the three artifact paths in
`ci/required-files.txt`. Each child concern then moves one row of the boundary map
below from "today" to "required".

| Claim | Required mechanism and evidence | Today | Child |
| --- | --- | --- | --- |
| A write scope has shadow evidence | Withheld write-shadow record (R2) | Only `no-change` records exist | 5, 6 |
| Qualification covers later revisions safely | R3 coverage rule | Exact revision only | 6 |
| A real execution boundary held | Authentic sandbox receipt; native environment qualification | Declaration only, `unproven` | 2, 3, 4, 6 |
| Gate outputs belong to this scope | Real risk, duty and kill evaluations for its `stage_request_ref` | Harness-built only | 9 |
| Attempts are durable and auditable | Sealed traces outside scratch | Scratch-bound | 8 |
| Regression suite is complete | Nine families seeded and passing | Seven seeded, two declared | 10 |
| Only the fixed write happens | Short-lived publisher, target ruleset, post-write check | Dormant publisher only | 11 |
| The operator can stop everything | `config/kill-switch.json`, fail-closed reads | Policy and evaluator, no state | 7, 9, 12 |
| Only the operator turns a scope on | `config/scope-enablement.json`, operator-merged | No record, no consumer | 6, 12 |

## Out of scope

Everything R9 lists. Also any change to step 7's scope, to the program order
(8, then 9, then 10), or to the reserved decisions in
`work/roadmap-program-authorization/decision.md`.

## Areas of concern

- **Risk is high.** The record defines a security control, a write identity, a kill
  switch and an activation path. G2 accepts it; a separately reviewed,
  operator-merged plan-only pull request must follow.
- **Order differs from the intent's list.** The intent lists the publisher before
  real gate evidence and does not list step 7 as a concern. This record puts step 7
  first as the prerequisite already in flight, and puts gate evidence and eval
  seeding before the publisher, so every non-credential concern lands before the
  one that needs a reserved credential. It also adds concern 7, the kill-switch
  register bootstrap, which the intent does not list, so gate evidence has a
  register to read before enablement. Operator review of this order is requested,
  not assumed.
- **Kill-switch shape.** The shipped `kill_switch_state` carries one `attempt_id`,
  so it cannot itself be a committed, shared document. R5.4 adds a register and a
  projection; concern 7 commits the register and the evaluator change is concern
  9's. Until concern 9 lands, the register is not read by anything. A write needs
  a separate write entry, so observation can be cleared while writes stay off.
- **Stopping is slow through a pull request.** A committed register needs a merge to
  change. The operator can also stop at once by revoking the publisher identity;
  child concern 11 must make that path work and fail closed.
- **Operator-merge authentication.** A file on the default branch does not prove who
  merged it. Child concern 12 must bind the introducing pull request's merger to the
  operator from forge records, or stop.
- **Non-model identity.** `qualified_identity` requires `model_request` even for a
  workflow that invokes no model. R3.7 keeps it as recorded configuration; zero
  producer invocations is proven separately (R1.3).
- **External first target.** The first write goes to another repository, so the
  publisher needs a credential there. That is reserved and is asked only at child
  concern 11.

Intent open questions, answered:

- *Path and task class:* R1. The root `ystack-evidence/<incident-id>/` is outside
  every protected path and the construction-mode forbidden set (R1.4).
- *Shadow evidence in place of `no-change`:* the withheld `changed` record of R2,
  proven by repeat and offline test without a live write.
- *Revision coverage:* R3, with its invalidation table.
- *Kill-switch location and reading:* `config/kill-switch.json`, read fresh at three
  points; missing or unreadable means stop (R5.4-6).
- *Seeding the two declared families:* R6.2-3. Trial counts are the catalog's
  minimums; pass floors are stated; further thresholds are carried forward to child
  concern 10 with operator acceptance.
- *Parallel versus strict:* R8. Concerns 2, 3, 8 and deterministic seeding may start
  now; concern 12 strictly follows all others and step 7's close.
