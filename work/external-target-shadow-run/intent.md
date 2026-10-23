# Intent: first read-only external-target shadow run
Author: Yihan Zhu (operator). Status: draft.

## Problem

Step 7 of the roadmap asks for the narrow read-only shadow workflow to be proved
separately in every execution environment where it will run, on real self-host
and external-target changes. Intake #264 and PR #373 proved only the self-host
half: a real ystack incident, reproduced on ystack itself. That spec excluded
external-target proof on purpose. So step 7 is still half done.

The self-host run alone is not proof of portability. A control plane can quietly
special-case itself. We do not yet know whether the resolver and the assembler
bind a qualified identity whose target repository is not `repo.ystack`.

There is a real incident to use. The earlier team loop on
`yihanzhu/ystack-dummy-target` changed `src/greet.sh` at
`e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e`, whose single parent is
`413a2f02a46ababa987039be65089e95c1916765`. That is a plain file-digest
incident at a known revision, on a repository that shares nothing with ystack.

## Proposed outcome

The same narrow read-only workflow is proved in a second execution environment,
the external dummy target, without special-casing ystack. Concretely:

- The environment `env.local-macos-dummy-target` is registered for
  `yihanzhu/ystack-dummy-target` (history root
  `c1cacf5a1dbcc5030d66ecd300bf0b115c792e99`) in
  `shadow/v1/shadow-environments.json`, in its own reviewed PR, with a new
  `external-target` evidence scope, `proof_state: "unproven"`, and the matching
  byte-pin update in `scripts/test/shadow-slice.test.sh`.
- On my Mac, against a disposable scrubbed bare copy of the target, the incident
  reproduces at `e7da8f7b` and gives `no-change` at `413a2f02`. Both runs go
  through the unchanged #373 pieces: the driver `shadow/v1/reproduce.sh`, the
  trusted-parent resolver, the shadow-input assembler, the local-git materializer,
  the declaration-only sandbox evaluator, and the scope and maintenance consumers.
- The evidence is committed under `shadow/evidence/external-dummy-target/v1/`
  with an offline integrity test in the #373 pattern.

Success means both recorded outcomes match the expected ones, every recorded
reference names real bytes, the recorded identity's target is the dummy target
and not ystack, and the offline test passes in CI without network.

## Affected users and systems

Me, as the operator who confirms the registry entry and the frozen incident
inputs. The manager session that runs it on my machine. The dummy target repo,
only as the thing examined; nothing is written to it. The ystack repo, as the
place the registry entry, evidence and test live. The shadow slice pieces listed
above, used unchanged. The later step-8 scope evaluator and the maintenance loop,
which read the evidence.

## Constraints

- Risk: high. G1 intent, then G2 spec, then an operator-merged high-risk plan
  come before any code or run.
- DR-6 on #426 is the authority for this first real external-target use, and it
  covers this intake only.
- Read-only against the target: no writes and no forge mutations. No network
  inside the run boundary. No credentials, no model calls, no qualification, no
  activation.
- DR-4's declaration-only sandbox boundary applies to this run as it did to
  #373. The retained evaluation is declaration-only and never enforcement proof.
- The manager may run it on my machine under the plan-recorded delegation rule
  from #375. My own confirmations of the registry entry and the frozen incident
  inputs are quoted in the evidence README.
- No change to the driver, resolver, assembler, materializer, evaluator or
  consumers. If they cannot handle a non-ystack target, that goes back to their
  own artifact gates; no local patch or ystack special case may make this pass.
- Normal component conventions apply: required-files entries, a documentation
  entry, an index row and a restore note.

Non-goals: no write to the external target; no `proof_state` change beyond what
this run's own evidence supports once it passes review; no claim that the
broader roadmap, or step 8 onward, is complete.

## Open questions

Does the registry entry's `target_repository_id` follow a fixed naming pattern
(for example `repo.ystack-dummy-target`), and where is it recorded that the
`external-target` scope is allowed? Does registering the environment and running
it need two PRs, or can the evidence PR follow the registry PR directly under one
plan? Should `proof_state` change in this intake at all, or stay `unproven` as in
#373?
