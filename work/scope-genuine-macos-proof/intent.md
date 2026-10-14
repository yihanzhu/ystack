# Intent: Publish the bounded macOS scope proof workflow
Author: Codex (intent author). Status: draft.

## Problem

Scope-gate hardening (#541) needs a real macOS consumer proof on a verified
disposable host. The approved workflow is still a private proposal. Linux CI and
local fixtures cannot supply that proof, so the manager cannot complete acceptance.

## Proposed outcome

Publish a bounded manual route to run the two complete original suites at the exact
reviewed implementation head. Preserve the approved workflow meaning and produce
source-bound evidence without changing the product or its acceptance standard.

## Affected users and systems

The ystack manager and reviewers, this repository's proof workflow, the existing
scope and native suites, and the disposable macOS runner and its owned fixture.

## Constraints

- Preserve the [package approved on 2026-10-14](https://github.com/yihanzhu/ystack/issues/541#issuecomment-6167260870).
  Implementation changes only `.github/workflows/scope-genuine-macos.yml` and its
  `ci/required-files.txt` entry, after the normal spec and high-risk plan gates.
- Keep the fixed repository, operator, manual event and sole #541 implementation
  ref. Bind the reviewed workflow and source before and after execution. The
  dispatch event SHA selects source; it does not grant approval.
- Keep the candidate host, physical runtime checks, existing pinned jq cache,
  both original complete suites and the 100-minute outer limit. Product deadlines
  and caps stay unchanged. Do not install runtimes or use a fallback provider.
- Keep administrator actions within the approved disposable fixture: distinct
  users and groups, fixed anchor, derived owned root, supplementary-only and UUID
  checks, and verified cleanup. No VM, real publisher or production identity.
- Publish through a protected PR, merge that main into the same implementation
  branch normally, then review the exact resulting head and base. Complete Linux
  and Mac proof must match that source before protected implementation merge.
- Host or preflight refusal, suite failure and incomplete cleanup remain failures.
  Workflow publication alone does not close #541 or prove native or CPU/wall
  qualification. #544 receives no automatic ref or authority from this work.

## Open questions

Provider availability and the complete Mac result remain to be established by the
approved preflight and actual suites. A failed prerequisite stays a failure; it does
not authorize a replacement host, tool or proof.
