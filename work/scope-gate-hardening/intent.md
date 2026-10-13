# Intent: harden scope qualification evidence
Author: Codex (intent author at the operator's direction). Status: draft.

## Problem

The inactive scope gate still accepts a declaration as satisfied environment
evidence. A declaration can describe enforcement, but it cannot prove that the
required environment actually enforced the attempt.

The gate also accepts only the existing no-change materialization record. It cannot
recognize the complete withheld, add-only write record produced by the finished
shadow-consumer work.

Qualification evidence is tied to one exact target revision. The gate cannot prove
that old evidence still covers a later revision on the target default branch. It does
not authenticate the first-parent history, the source of intervening changes, or the
continued protection of configuration, CI, and branch rules.

These gaps let a well-shaped record say more than its authentic evidence proves.
Missing evidence must refuse qualification instead of falling back to a declaration
or a supplied claim.

## Delivery boundary

Child 6 has two mandatory, ordered deliveries. Issue #541 is the nonterminal core.
It authenticates required-environment receipts and native-qualified identities,
accepts the complete no-change and withheld-write record forms, and keeps every
scope on the existing exact-revision rule. It does not complete later-revision
coverage and cannot complete child 6.

Issue #544 must then implement the complete parent R3 later-revision coverage result.
It authenticates the default branch, first-parent history, own-publisher changes,
protected configuration, CI and branch rules, closed coverage identity, fresh
revision-derived binding, and the 30-day limit. Both #541 and #544 must pass their
artifact, plan, implementation, proof and review gates before child 6 is complete or
child 7 starts. This split changes delivery order only. Every outcome and safety
standard below remains required.

## Proposed outcome

### Nonterminal core outcome — #541

Every required environment has an authentic satisfied receipt. The receipt is bound
to its attempt, candidate, environment, and policy. Its registry identity is genuinely
native-qualified. Declaration-only records remain readable, but they refuse.
They refuse with `scope.sandbox-receipt-missing`.

The existing no-change result keeps its current meaning. A changed result qualifies
only when it is the complete withheld-publication form and exactly matches the
add-only write set accepted from the shadow consumer. The gate checks the source,
candidate, parent, tree, blob, mode, publisher-request, and verification relations.

The #541 core keeps exact-revision and full-identity matching for read-only and write
scopes. Evidence from another revision refuses. No core result claims revision
coverage or satisfies the mandatory #544 outcome.

### Mandatory follow-up outcome — #544

Older evidence covers a later revision only when authentic facts prove default-branch
first-parent descent. Changes under `ystack-evidence/` come only from this scope's
own verified publisher pull requests. The target's `.ystack/`, CI workflow files,
and branch rules stay unchanged.

The coverage identity uses the accepted closed fields. Evidence derived from the
revision, request, profile, and materialization is freshly rebuilt and rebound.
Qualifying evidence is no more than 30 days old. Any missing or unauthentic fact
refuses qualification.

The existing `scope.enablement-stale` reason remains assigned to this concern. This
outcome does not enable a scope or grant tip-reading or publisher authority.

## Affected users and systems

Future operators and reviewers get a scope decision that distinguishes authentic
enforcement from a valid-looking declaration.

The inactive workflow-scope qualification evaluator consumes the hardened evidence.
The existing shadow-consumer write record becomes an accepted input shape without
becoming a real publication.

Development uses disposable fixtures to prove the code paths. Target repositories,
live publishers, credentials, and production configuration remain untouched.

## Constraints

This is one security-control concern under the accepted Step 8 child 6 boundary.
Each delivery must define its exact trusted inputs and provenance in G2. A separate
high-risk plan must land before each implementation.

Current CPU and wall enforcement remain `none`. Native qualification remains
`BLOCKED`, and the accepted production identity set remains empty. Fixture success
cannot claim real VM qualification.

No network access, credential, real publisher, target installation, target write,
activation, enablement, configuration bootstrap, or new production authority is
included. Existing no-change behavior remains compatible.

The work does not change frozen or diagnostic attempts and does not dispose of any
dirty worktree. It does not weaken the parent receipt, write-shape, revision-coverage,
freshness, or fail-closed requirements.

## Open questions

- Which exact authenticated sources and byte contracts will prove receipt, registry,
  native qualification, and their binding to the evaluated attempt?
- Which exact sources will prove default-branch history, the introducing publisher
  pull request, protected configuration, CI workflows, and branch rules without adding
  new network or publisher authority?
- What is the closed coverage identity, and which revision-derived fields must be
  recomputed for each evaluation?
- How will G2 express the complete withheld-write relation and the 30-day boundary so
  malformed, foreign, rewritten, protected, or stale cases fail unambiguously?
