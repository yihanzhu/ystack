# Intent: step 8 bounded-write readiness decision
Author: Claude (yshifu, intent author at the operator's direction). Status: draft.

## Problem

Roadmap step 8 enables one low-risk qualified workflow scope with bounded autonomous
writes, in its own independent PR, after that scope's own shadow evidence passes
(`ROADMAP.md`, step 8; control objective 8 at lines 90-97). Current main cannot
express such a scope. Five structural gaps stand in the way:

1. Shadow evidence is write-free by construction. `scope/v1/scope-gates.jq:486-510`
   accepts only a `no-change` materialization, so no record can show a write.
2. Scope identity is bound to one exact target revision (`scope-gates.jq:846`).
   Nothing says which later revisions or conditions a qualification still covers.
3. No scope can be enabled. `scope/v1/workflow-scope.jq:185-188` requires
   `enabled: false` and `push_allowed: false`, and qualification is always
   `unavailable` (`scope-gates.jq:953-980`). No enablement record or consumer exists.
4. Nothing can write. Only `adapters/dormant-publisher/v1` exists,
   `config/construction-mode.json` keeps `allowed_live_writes: "none"`, and
   `control/v1` holds a kill-switch policy and decision but no committed kill-switch
   state document.
5. Sandbox evidence can be a declaration. `scope-gates.jq:462-478` accepts
   `sandbox.declaration-satisfied` as environment evidence. DR-4 made a real sandbox
   boundary the step-8 prerequisite, and the program record says the self-host run
   claims no execution boundary. Today the gate would still accept a declaration.

The eval suite the roadmap requires before bounded writes (`ROADMAP.md:266-280`) is
also incomplete: `evals/v1/eval-catalog.json` lists nine families, and two of them
(`malicious-instructions`, `reviewer-severity-false-positive-negative`) are still
`declared` with no seeds.

Without one agreed decision, each gap would be closed piecemeal, in an unclear order,
and the first write scope could be proposed on weaker evidence than the roadmap asks.

## Proposed outcome

One reviewed, decision-only record fixes the enablement contract for step 8 and the
ordered child concerns that must land before any write scope is enabled. It follows
the `work/real-sandbox-boundary/` shape: this intent, then a spec that is the
decision record, then a plan limited to making that decision discoverable and
restorable. It ships nothing that runs.

The decision record must settle:

- **First workflow.** Per DR-7, the first bounded-write workflow is a deterministic,
  non-model write, such as committing shadow evidence plus the incident-to-eval seed
  to an unprotected path. The record names the exact workflow id, task class, risk
  tier and allowed paths. Model-driven writes (#329) stay off the critical path.
- **Shadow evidence for a write scope.** What a write scope's own shadow evidence
  must show, given that today's records are `no-change` only.
- **Revision coverage.** What target revisions or conditions a qualification covers,
  which changes invalidate it, and which gate each change returns to (control
  objective 8). Each execution environment qualifies separately.
- **Enablement record and consumer.** The committed record that turns one scope on,
  what reads it, and how the consumer refuses a missing, stale or mismatched record.
- **Publisher boundary.** What the real short-lived publisher may write, with which
  identity, and how the result is verified after the write.
- **Kill switch.** The committed state document, its scopes and fail-closed reading.
  Per DR-7, the operator owns the kill switch; no agent may clear it.
- **Evals.** All nine catalog families must be seeded and passing for the scope
  before enablement, including the two that are `declared` only today.
- **Ordered child concerns**, each with its dependencies and its reserved decision:
  1. enforcement-evidence binding;
  2. the fixed file-digest verifier (subsumes #314; preparation delivered by #396);
  3. the VM launcher and supervisor (installation and native qualification on the
     operator's machine are reserved);
  4. shadow-consumer integration;
  5. scope-gate hardening: refuse declaration-only environment evidence and require
     a real sandbox receipt (DR-4 reaffirmed by DR-7);
  6. durable telemetry (subsumes #307);
  7. a real short-lived publisher (credential and network decision reserved; #304
     supports post-write verification);
  8. real gate evidence bound to the scope's own `stage_request_ref`;
  9. the enablement PR, which touches `config/**`, is operator-merged, and whose
     activation is reserved.

Success means: the record is merged through G1, G2 and the high-risk plan gate; each
of the five gaps maps to at least one child concern; every child concern has an
explicit order, dependency and reserved decision; a reader can tell from the record
alone why no write scope is proposable today and what exact evidence would change
that; and no existing gate, policy or test behaves differently.

## Affected users and systems

The operator, who decides every reserved step and owns the kill switch. Scope
qualification (`scope/v1`), the control policies (`control/v1`), the dormant
publisher, the construction-mode record, the eval catalog, the shadow slice and its
consumers, and the later launcher, verifier and publisher work. Step 9 (safe
review-fix loop) and step 10 (target packaging) follow this step in the program
order and depend on its boundaries.

## Constraints

- Tracks #427. Risk: high. Independent review, required CI and operator acceptance
  are required at every gate; the enablement PR stays operator-merged.
- Decision only. No runtime, policy change, credential, network scope, installation,
  activation, release or write ships from this initiative. `scope/v1`, `control/v1`,
  `config/**`, the publisher and the eval catalog stay byte-identical.
- A real sandbox receipt is mandatory before any write scope can be proposable. A
  satisfied declaration never counts as enforcement or qualification.
- Nothing in the record enables anything before step 7 closes, including its
  outstanding external-target run on `yihanzhu/ystack-dummy-target`. The record may be
  drafted in parallel with that run.
- The reserved operator decisions stay reserved (see
  `work/roadmap-program-authorization/decision.md`): new credential, network or write
  scope, installation, activation, first real target execution and production action.
  The record names where each is asked; it grants none.
- Each child concern needs its own intake, artifacts, plan gate, exact paths and
  tests. Accepting this record accepts no child code.
- Core records stay model-, harness- and provider-neutral. Author, verifier, reviewer
  and publisher capabilities stay separate.
- Non-goals: model-driven writes, the review-fix loop, target packaging, deployment,
  rollback, and any change to step 7's scope or to ROADMAP.md.

## Open questions

- Which exact path and task class does the first deterministic write use, and is it
  outside every protected path and the construction-mode forbidden set?
- What does a write scope's shadow evidence record in place of `no-change`, and how
  is that proven without a live write?
- What revision-coverage rule replaces exact-revision binding without letting a
  qualification drift onto unreviewed target changes?
- Where does the kill-switch state document live, how does every consumer read it,
  and what happens when it is missing or unreadable?
- How are the two `declared` eval families seeded from real work, and what trial
  counts and pass thresholds apply?
- Which child concerns can proceed in parallel, and which must strictly precede the
  enablement PR?
