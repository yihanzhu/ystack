# Intent: real sandbox boundary decision
Author: Codex (intent author at the operator's direction). Status: draft.

## Problem

I cannot run the first real read-only self-host check with honest sandbox evidence.
The current evaluator checks declarations against a demonstration policy. Its verifier
hash is a placeholder, and no shipped launcher proves that the claimed network,
filesystem and resource restrictions held during verification. Copying the fixture
claim would make the declaration pass without resolving the problem.

The current policy and its limits are visible in `control/v1/sandbox.jq`.
`docs/components.md` distinguishes declaration checks from enforcement proof and
requires a separately qualified launcher and fixed verifier. The shadow driver
checks the declaration and then invokes the materializer directly.

## Proposed outcome

One reviewed architecture decision identifies a feasible local execution boundary,
real tool identities and the evidence needed before a self-host run. It maps each
required claim to what enforces it, what can be observed and who produces trusted
evidence. If the platform cannot meet a requirement, it names the blocker and
leaves the real run unavailable.

The decision separates source preparation and materialization from verification.
It states which process may read source history, which may write disposable
candidates and evidence, and when the candidate becomes read-only. It names
bounded implementation concerns and their dependencies. This work ships no runtime.

## Affected users and systems

The operator waiting for self-host proof; the sandbox policy and evaluator; the
future launcher and fixed verifier; and the shadow driver that consumes their
evidence. Later implementation must protect source history, host data and unrelated
work from the verifier.

## Constraints

- Decision only. No install, probe, execution, configuration change, system change,
  runtime activation or replacement of the demonstration policy in this work.
- High risk. Independent review, required CI and operator acceptance remain required.
- No target writes, network, credentials, model calls, deployment or authority grants.
- Preserve the current ceiling: a cleared environment, restricted roots, denied
  network, fixed limits, no credential exposure and no host access outside the
  explicitly accepted runtime boundary. Unknown enforcement blocks the real run.
- Cover CPU, wall time, memory, output and process limits, child-process containment,
  cleanup on success and failure, source immutability and repeatability.
- Specify later denied-access probes with synthetic fixtures and bounded resources.
  No actual secrets or unrelated host data are probe material.
- Bind actual runtime, policy, decision, evaluator, verifier and evidence identities.
  Reject missing, forged, stale or mismatched identities. A satisfied declaration
  alone proves neither enforcement nor workflow qualification.
- Keep author, verifier, reviewer and publisher capabilities separate. Core records
  stay model-, harness- and provider-neutral; platform details belong in adapters.
- Each later implementation concern needs its own accepted scope, complete tests
  and dependencies. Nothing here broadens the self-host evidence change.

## Open questions

- Which local runtime can meet every required restriction and limit with observable
  proof? Finding `sandbox-exec` alone does not establish that it can.
- Which boundary separates source preparation from candidate-only verification,
  including child processes and cleanup?
- How should actual tool bytes, fixed verifier arguments, policy bindings and
  enforcement observations be authenticated and checked again?
- Which policy-binding, launcher, verifier and consumer changes need separate gates,
  and what must land before the first real self-host run?
