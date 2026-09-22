# Intent: Restore the inactive materializer package bindings
Author: Codex (delegated intent author). Status: draft.

## Problem

PR #392 fixed the materializer's private Git index, changing its package tree.
Both inactive shipped profiles still name the previous tree. The release builder
correctly rejects this mismatch with `E_RELATION`, blocking target-packaging proof
in the required integration run for receiver PR #395. A bounded before-and-after
check confirms the regression; the receiver change did not cause it.

This is the separate dependency repair accepted in
[issue #397](https://github.com/yihanzhu/ystack/issues/397#issuecomment-5770827516).

## Proposed outcome

Both inactive profiles identify the corrected materializer package. Its manifests,
profile bindings, assembly expectations and derived shadow pins agree through the
existing canonical source-binding procedure. The actual source and profile
checkpoint remain independently fetchable for CI and restoration, with accurate
provenance. Packaging succeeds for the corrected bindings and still rejects real
drift. The private-index fix remains intact.

## Affected users and systems

This restores the Roadmap integration proof used by the manager and reviewers,
and the inactive default and alternative profiles used by packaging and shadow
assembly. It supports portable target packaging and complete restoration under
the current Roadmap program; it does not qualify or activate a real target.

## Constraints

- Keep the repair within these eight implementation paths:
  `profiles/default/v1/manifests/local-git-materializer.json`,
  `profiles/alternative/v1/manifests/local-git-materializer.json`,
  `profiles/default/v1/profile.json`, `profiles/alternative/v1/profile.json`,
  `scripts/test/default-profile-assembly.test.sh`,
  `scripts/test/alternative-profile-assembly.test.sh`,
  `shadow/v1/materialization-input.jq`, and `docs/replay-materialization-result.md`.
  The spec must limit changes to the affected identities, independent expectations
  and provenance. Other fields, bindings, grants, authority, boundaries, core
  selection and runtime behavior stay unchanged.
- Use the established package-to-manifest-to-profile-to-shadow identity chain.
  Preserve the builder's checks and all test assertions. Do not hide pins,
  substitute an old source in the positive packaging test, skip a failure, add a
  framework or add a redundant unit suite.
- This identity change is high risk. G1, G2 and a separately accepted high-risk
  plan precede implementation. Require complete relevant assembly, packaging and
  shadow proof, quick CI and independent exact-head/base review. Preserve the
  failed full-matrix evidence and rerun the blocked integration milestone after
  this dependency closes; quick CI does not establish full-suite success.
- Keep source and profile-checkpoint retention within existing authority. Prior
  permission to change branch retention for one merge does not apply here. No
  repository-setting or protection change, or new ref-write authority, is included.
- Preserve the separate #392 and #395 scopes and attempts. No live install,
  profile selection, activation, credentials, real target execution, release
  publication, deployment, history rewrite, direct-main push or destructive
  disposition is included.

## Open questions

The reviewed spec and plan must establish a durable, verifiable profile checkpoint
under squash-only publishing and automatic branch deletion, using existing
authority. They must bind its actual containing commit and prove isolated fetch
and canonical hash propagation. If no valid mechanism fits, preserve the attempt
and present the concrete additional authority needed before crossing that boundary.
