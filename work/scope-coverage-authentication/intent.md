# Intent: authenticate complete later-revision coverage
Author: Codex (intent author at the operator's direction). Status: draft.

## Problem

Issue #541 is the nonterminal core of Step 8 child 6. It authenticates required
environment receipts and native-qualified identities, accepts the complete
no-change and withheld-write record forms, and keeps the existing exact-revision
rule. It does not prove that qualifying evidence remains valid at a later target
revision.

The mandatory remaining work is issue #544. A later-revision decision needs
authentic forge facts for the target default branch, its first-parent history,
publisher pull requests, protected configuration, CI workflows, and branch rules.
It also needs an independently held current request so evidence cannot be replayed
or rebound by a caller. Git facts, caller-supplied facts, matching digests, or a
well-shaped receipt do not authenticate those facts by themselves.

The source contract and current-request relation attempted in the unaccepted PR
#543 specifications did not close these boundaries. Those drafts are diagnostic
evidence only. They are not an accepted protocol for this concern.

## Proposed outcome

The scope gate may cover a later target revision R only when authentic evidence
proves every condition below for that execution environment:

- The scope records `coverage_base`, the target revision used by its qualifying
  shadow evidence.
- R is a first-parent descendant of `coverage_base` on the authenticated target
  default branch.
- Between `coverage_base` and R, changes under `ystack-evidence/` come only from
  this scope's own verified publisher pull requests.
- Across that complete interval, nothing changes under the target's `.ystack/`,
  its CI workflow files, or its branch rules. A temporary change followed by a
  restoration does not pass.
- The closed coverage identity is byte-identical to the qualified identity.
- The attempt carries fresh revision-derived evidence for R and binds every such
  field to the actual current request, resolved profile, materialization, and R.
- The original qualifying shadow evidence is no more than 30 days old. Reading or
  observing it again does not refresh its qualifying time.

The closed coverage identity remains exactly: scope id; `workflow_id`;
`task_class`; `model_request`; `adapter_config_refs`; `prompt_refs`; `skill_refs`;
`verification_instructions_ref`; the resolved profile's `profile_ref`,
`profile_source`, `selection_ref`, and `bindings`; the execution environment id
and its registry entry bytes; the control policy set ref; the sandbox and scope
policy bytes bound by the evidence; and the coverage anchor, consisting of
`coverage_base` and the coverage rule version. `model_request` remains part of the
identity even when the workflow invokes no model.

Everything outside that closed identity is revision-derived. Each attempt
recomputes and verifies it against its own revision and request. This includes the
target and materialization revisions and trees, candidate parent and tree,
publisher base revision, stage-request source and repository references, resolved
profile repository reference, gate-evidence references, stage result, shadow
record, sandbox evaluation, and receipt references. Equality with old qualifying
evidence is neither required nor sufficient.

The consumer accepts coverage facts only through a fixed, non-caller-controlled
source that authenticates the original facts, the complete query interval, and
their relation to the evaluated repository and revision. The evaluator holds and
checks its current request independently. Missing, ambiguous, incomplete,
unauthenticated, caller-selected, or replayed source facts refuse coverage.

Invalidation keeps the parent R3 result:

| Change | Returns to |
| --- | --- |
| Any coverage-identity field | Shadow gate for new evidence for this scope |
| Scope, control, or sandbox policy, or the eval catalog | Eval gate, then shadow gate |
| Execution environment, runtime, image, or verifier bytes | That environment's qualification, then shadow gate |
| History rewrite, non-descendant R, or a foreign covered-path change | Shadow gate |
| Original qualifying evidence older than 30 days | Shadow gate |
| Risk tier, task class, allowed paths, or target | A new scope with its own G2 and enablement pull request |

Success requires real positive and negative proof through the same authenticated
consumer contract. A dormant source, an empty production identity set, fixture
metadata, or permanent fail-closed behavior cannot be reported as completion.

## Affected users and systems

Operators and reviewers get a later-revision decision whose provenance is explicit
and fail-closed. The inactive workflow-scope evaluator consumes the authenticated
coverage result after the #541 core has accepted the record and exact-revision
relations.

The target's authenticated Git and forge history, fixed coverage identity, scope
evaluation, and per-attempt evidence are in scope. Publishers, credentials,
production installation, target writes, enablement, and activation remain outside
this concern.

## Constraints

- This is the mandatory second delivery of Step 8 child 6. Issue #541 remains the
  nonterminal core. Both #541 and #544 must pass their own artifact, high-risk plan,
  implementation, proof, and independent-review gates before child 6 completes or
  child 7 begins.
- Preserve the complete parent R3 standard. Do not replace it with exact Git facts,
  supplied JSON, matching digests, a trusted boolean, a named source, or a refusal
  that can never produce a real authenticated success.
- G2 must close two known design questions: the fixed source capability that
  authenticates the complete facts and interval, and the evaluator-owned current
  request relation that prevents replay while allowing a legitimate reread of the
  original qualifying evidence. G1 selects no schema, nonce algorithm, provider,
  credential, network operation, host responsibility, or production identity.
- Keep all per-attempt derived relations and the full protected-rule history. Do
  not collapse them into the closed identity or compare the baseline and current
  revision against one shared Git fact.
- Current CPU and wall enforcement remain `none`. Native qualification remains
  `BLOCKED`, and the accepted production identity set remains empty. A disposable
  fixture cannot claim real VM or production qualification.
- No credential, new network access, real publisher, target installation, target
  execution, target write, activation, enablement, configuration bootstrap,
  production action, or wider authority is included. Any such need returns to its
  reserved decision before implementation.
- The output stays inactive and fail-closed. Preserve the #541 receipt,
  native-identity, record-form, and write-shape safety rules. Read-only scopes keep
  #541's exact-revision and full-identity checks. Only the fixed write workflow and
  task pair named by the parent may replace those checks with the complete R3
  coverage rule. Only that fixed pair may claim revision coverage. A partial or
  mixed pair refuses; a scope matching neither field keeps its existing read-only
  checks. This concern does not change public workflow inputs, enable a scope, or
  grant tip-reading authority.

## Open questions

- What fixed, finite source capability authenticates the original forge bytes,
  complete `coverage_base`-to-R query interval, producer identity, and repository
  relation without accepting caller facts or adding an unreviewed trust root?
- How does the evaluator independently create or hold the current request and bind
  it to the authenticated source result, while allowing a lawful reread of fixed
  qualifying evidence without refreshing its age?
- Which bounded normalizations and completeness checks prove the default branch,
  own-publisher pull requests, and every protected rule state, including an
  A-to-B-to-A change?
- What same-contract fixture and production evidence prove one real positive and
  all foreign, incomplete, rewritten, stale, replayed, and unauthenticated negative
  cases without claiming unavailable native or production qualification?
