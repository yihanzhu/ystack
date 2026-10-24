# Intent: do not retain checkout credentials for read-only CI tests
Author: Codex (intent author). Status: draft.

## Problem

| Needed outcome | Current gap |
| --- | --- |
| Read-only tests start without retained checkout authentication | The test checkout leaves credential includeIf entries |
| Preserve strict provenance checks | Those entries correctly stop the accepted reader before its object read |
| Prove the repair in its actual environment | The candidate setting has no accepted execution evidence yet |

Tracks #709. The current manager's verified brief binds the proactive
[intake acceptance](https://github.com/yihanzhu/ystack/issues/709#issuecomment-6382026896)
to title SHA-256 `2206844d1fccb2d729b77a8c3cc5e4ece7fad581e569f05d12afbc9dfd380863`
and body SHA-256 `2d59958bdbf23e4a929272ffa5456db6eb6bfdd9dc23ec81ef94ac2d05eee852`.

In full CI run `40076448634`, test shard 6 at source head
`1a04df91eac6cad16ff372d41fefaca3d72c375e` failed before P07 inspected or fetched
the original-plan object. The pinned checkout retained authentication through
credential includeIf entries. The accepted reader refused them. Preserve that
failure and its raw receipts. It is not a transient network failure.

## Proposed outcome

Stop retaining checkout authentication before the existing read-only tests start.
The bounded candidate adds `persist-credentials: false` to the existing `jobs.test`
checkout step in `.github/workflows/ci.yml`. It affects the checkout shared by the
six test shards. Keep the existing action and test behavior under the same gates.

Accept the repair only from actual candidate CI evidence. Later G2 and the separate
high-risk plan must define proof that authentication is not retained when tests
start, while the original checkout identity, shallow state and all tests remain
correct. Preserve complete raw results from the existing full CI. Automatic quick
CI skips this test job and cannot establish that behavior. A setting name or an
unexecuted private proposal is not proof of its effect.

This repair does not complete #701, P07, shared admission or G3. After it lands,
normally merge fresh main into the original #701 carrier. Preserve its source,
history, failures and round counts. Rebind source and artifact pins, then obtain
fresh independent review and complete exact-head CI proof on that carrier.

## Affected users and systems

The operator, independent reviewers and the six test jobs in the existing CI
workflow. The change supports the accepted provenance reader's input boundary.
It grants no product, publisher or target authority.

## Constraints

- This G1 writes only `work/ci-readonly-checkout/intent.md`. G2 must record high
  risk because the future change touches a workflow. A separately reviewed and
  protected high-risk plan must land before code. Keep exact hashes, independent
  source review, required CI and protected merge at each applicable gate.
- Limit the implementation concern to the one existing `jobs.test` checkout input.
  Keep action SHA `3d3c42e5aac5ba805825da76410c181273ba90b1`, triggers, repository
  identity, shallow checkout, `contents: read`, six shards, all tests and the
  required aggregate unchanged. Other checkout steps and workflows stay outside
  this concern. Do not start the private macOS proposal workflow.
- Preserve the reader's refusal of include/includeIf, fixed origin, bounded read
  count and actual object/byte checks. Do not read or expose credential config or
  tokens, unset configuration, replace HOME, create an alternate Git view, add a
  downloader/fallback, skip a case or weaken a security predicate.
- The existing public repository's fixed same-origin read adds no token model.
  Its actual success still needs proof. Missing facts or a need for another host,
  remote, credential or wider access stops that dependency.
- Keep the separate #681 sandbox-receipt policy-set failure outside this concern.
  Preserve all #701 failures and all #558/#541/#544/#681, I1, final caller,
  final-head Mac and same-head Linux, restoration, native/recording, G3 and
  protected-foundation obligations. No CI result here satisfies those debts.
- Keep the work inactive. No installation, activation, real target, new network
  or credential scope, native qualification, new recording, admin action or #558
  window is authorized. Preserve the old dirty credential-export plan and all
  other attempts; PR #183 stays frozen and PR #412 parked. CPU wall remains
  `NONE`, native qualification `BLOCKED`, production `EMPTY`, automation `PAUSED`.

## Open question

Which exact candidate CI observations establish that the pinned checkout leaves
no retained authentication before the tests, while preserving its source identity,
shallow state and complete existing test behavior without reading credentials?
