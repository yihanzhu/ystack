# Intent: enforcement-evidence binding for the real sandbox receipt
Author: Claude (yshifu, intent author at the operator's direction). Status: draft.

## Problem

The accepted step-8 decision makes a real sandbox receipt mandatory before any
write scope can be proposed (`work/step8-bounded-write-readiness/spec.md:267-281`,
R7). A write scope's shadow record must carry that receipt (R2.2, `spec.md:82`),
and later attempts rebind fresh receipt refs per revision (R3.4, `spec.md:137`).
But no such receipt kind exists. There is nothing to require.

Today the only sandbox evidence is a declaration check:

- `control/v1/evaluate-sandbox.sh` evaluates three caller documents: a policy set,
  a duty evaluation and an execution-environment claim
  (`evaluate-sandbox.sh:131-137`, `:189-197`). Nothing observes a real run.
- `control/v1/sandbox.jq:256` returns `satisfied` with the single reason
  `sandbox.declaration-satisfied` when the claim matches the policy. The output
  says `enforcement_proof: "declaration-only"`, `authority_effect: "none"` and
  `qualification_effect: "none"` (`sandbox.jq:263-272`), and the decision record
  pins that meaning (`evaluate-sandbox.sh:174`).
- The policy's verifier identity is demonstration data: the all-ones digest
  (`sandbox.jq:179-182`, `control/v1/sandbox-policy.json` tool `sha256`).
- `shadow/v1/reproduce.sh:436-440` turns a `satisfied` declaration into
  `environment.satisfied`, and `scope/v1/scope-gates.jq:462-479`
  (`environment_evaluation_ok`) accepts exactly that as environment evidence.
- The candidate-preparation record says the same gap out loud:
  `authenticated_receipt: false` and `supervisor_handoff: "required"`
  (`preparation/v1/prepare-candidate.py:1928-1929`).

The real sandbox boundary decision names this gap as its first child concern
(`work/real-sandbox-boundary/spec.md:155-157`). It must define authentic receipt
provenance, exact byte identities and consumer checks, keep old declaration-only
records as they are, and resolve accounting semantics before any runtime is chosen.
Its R5 and R6 (`spec.md:45-61`) set the identity and origin rules. Step-8 R8 lists
it as child concern 2, with no dependency
(`work/step8-bounded-write-readiness/spec.md:292`). Child concerns 3,
4, 5 and 6 all consume this kind, so they cannot be specified without it.

## Proposed outcome

One inactive contract defines the real sandbox receipt kind, and one pure consumer
check validates it. Nothing produces a real receipt yet; the launcher and supervisor
(child concern 4) do that later.

The contract fixes:

- **Provenance.** A receipt is owned by the host supervisor and bound to the
  supervisor's controlled channel and storage. The verifier's own output, a caller
  document, or a JSON claim whose fields happen to match is never a receipt
  (sandbox spec R6). The contract states how a consumer authenticates that origin.
- **Byte identities it must bind.** Host and runtime, guest kernel and configuration,
  guest init, image, supervisor, verifier, toolchain and verification-instruction
  digests. Also the policy, decision, evaluator, policy-set, source and candidate,
  incident, environment and attempt identities (sandbox spec R5). Version names,
  mutable tags and the all-ones demonstration digest are refused as identities.
- **Accounting semantics.** For each fixed limit in sandbox spec R2 (CPU, wall time,
  memory, output, tasks) and the scratch bound: what is counted, over which task
  tree, by which trusted observer, and what the receipt records (configured bound,
  observed value, observation limits). Unknown, unavailable or exceeded never reads
  as satisfied (sandbox spec R7). No limit is raised or given a weaker meaning.
- **Outcomes.** Satisfied, violated, and a bounded failure receipt for runtime
  failure, refusal, timeout and teardown failure. A failure never becomes
  satisfaction.
- **Consumer checks.** The check refuses a forged, replayed, mismatched, stale or
  unsupported receipt, and a receipt whose attempt, candidate, environment or policy
  identities differ from the record it is attached to (step-8 R7.1).
- **Old records.** Declaration-only evaluations stay readable and keep their exact
  meaning. Nothing reinterprets them as enforcement.

Success means: contract and unit tests with synthetic fixtures show each refusal
with a paired positive control; restore-manifest entries cover the new paths; and
every existing gate, policy and test behaves exactly as before.

## Affected users and systems

The operator, who reviews the contract and owns every reserved decision. The
sandbox control documents in `control/v1` (read, not changed). The later verifier
(#437), launcher and supervisor, shadow-consumer integration and scope-gate
hardening work, which all consume this kind. The shadow slice and scope gates,
whose behaviour does not change here. CI, which runs the new tests.

## Constraints

- Risk: high. This is a security and identity boundary. G1 intent, then G2 spec,
  then an operator-merged high-risk plan come before any code, each with
  independent review and required CI. Tracks #436.
- Ships nothing enabling: no runtime selection, installation, VM, supervisor
  implementation, native probe, credential, network, activation or write.
- `control/v1` policy and evaluator behaviour and `config/**` stay byte-identical
  unless the G2 spec names one exact, reviewed change.
- No signing credential is selected or authorized by this intake. If the design
  needs one, it stops and returns to the operator.
- Nothing enables before step 7 (#426) closes. Drafting may run in parallel now.
- Reserved decisions per step-8 R8 row 2: none beyond review.
- A digest detects changed bytes; it does not authenticate who produced them. The
  design must not present a digest match as proof of origin.
- Core records stay model-, harness- and provider-neutral.
- Non-goals: the verifier itself (#437, child concern 3); the launcher, supervisor
  and native qualification (child concern 4); wiring the receipt into the shadow
  driver (child concern 5); the `scope-gates.jq` consumer change and
  `scope.sandbox-receipt-missing` (child concern 6); any change to the ceiling, the
  demonstration policy or step 7.

## Open questions

- With no signing credential, how does a consumer authenticate that a receipt came
  from the supervisor's controlled storage and not from a matching copy? If no
  credential-free answer holds, what exact question goes to the operator?
- What binds a receipt to one attempt strongly enough to refuse replay into a later
  attempt or another environment?
- Where does the receipt kind live, and does it sit beside
  `sandbox_policy_evaluation` or reference it? How does a consumer tell the two
  apart without guessing?
- For each limit, what accounting rule and observation limit can the contract state
  before a runtime exists, without implying a mechanism is already chosen?
- Which identities may be recorded as "not yet available" in synthetic fixtures,
  and how is that kept from ever passing a real consumer check?
- How does the receipt relate to the environment registry's native-qualification
  state that step-8 R7.1 also requires?
