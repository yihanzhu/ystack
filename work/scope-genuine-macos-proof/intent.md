# Intent: Provide the bounded macOS scope proof environment
Author: Codex (intent author). Status: draft.

## Problem

Scope-gate hardening (#541) needs real macOS consumer proof on a verified
disposable host. The host's preinstalled runtime fails the required trust checks.
Linux CI and local fixtures cannot supply this proof.

## Proposed outcome

Use the approved temporary runtime supply to run both complete original suites at
the exact reviewed implementation head. Produce source-bound evidence while
preserving the product and its acceptance standard.

## Affected users and systems

The ystack manager and reviewers, this repository's proof workflow, the existing
scope and native suites, and the disposable macOS runner and its owned fixture.

## Constraints

- Follow the [approved conditional package and accepted source review](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6180555883).
  Apply the [approved existing-parent supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6189713897).
  Use only the fixed official Python 3.14.7 and original pinned jq 1.6 bytes.
  Supply only the entirely absent `Versions/3.14` and `ystack-private-tools`
  trees under `/Library/Frameworks/Python.framework`. Authenticate the existing
  physical framework root, Versions directory and full parent chain first,
  including held identity, ownership, mode and actual empty ACL checks.
  Preserve old versions, top-level Current and root aliases. Do not traverse old
  version contents or use old objects as runtime dependencies. Do not repair an
  existing runtime, overwrite old objects, run package scripts, alter binaries
  or publisher links, or use another version, source, root or provider.
- Limit existing-parent writes to adding and removing the two fixed child names
  and their necessary directory metadata changes. Verify each exact change and
  record the resulting real metadata; do not backdate it. Clean up only new trees
  whose objects match the ownership journal. Extra, changed or unknown objects
  block deletion. Preserve the old child names and stable safety attributes.
- Complete this G1 amendment, G2 and a separate high-risk plan before implementation.
  The Mac workflow implementation changes only
  `.github/workflows/scope-genuine-macos.yml` and its `ci/required-files.txt` entry.
  Necessary fixed bootstrap/Python/jq bindings in #541's two test fixtures pass
  their own affected artifact gates within the original core paths.
- Keep the fixed repository, operator, manual event and sole #541 implementation
  ref. Bind the reviewed workflow and source before and after execution. The
  dispatch event SHA selects source; it does not grant approval.
- Keep the candidate host and all physical runtime, held identity, NOFOLLOW,
  owner, mode, actual ACL/UUID and complete runtime/module closure checks.
  Bind the exact startup images and paths through G2 and the high-risk plan.
  Source review alone does not prove host safety or choose an unreviewed startup path.
- Keep both complete original suites and the 100-minute outer limit. Product
  deadlines and caps stay unchanged. Supply and clean up within the approved
  temporary job and its original budgets. Preserve all failures and unknowns.
- Keep administrator actions within the two approved new trees, their permitted
  parent changes and the disposable fixture. Preserve distinct users and groups,
  the fixed anchor, derived owned root, supplementary-only checks, and verified
  cleanup of every owned resource.
  No VM, real publisher or production identity is allowed.
- Publish through a protected PR, merge that main into the same implementation
  branch normally, then review the exact resulting head and base. Complete Linux
  and Mac proof must match that source before protected implementation merge.
- Host or preflight refusal, suite failure and incomplete cleanup remain failures.
  Publication and source review do not close #541 or prove native or CPU/wall
  qualification. #544 receives no automatic ref or authority from this work.

## Open questions

Safe existing parents, both new trees' absence, complete authenticated startup and
the actual Mac result remain to be established within the approved gates and real
suites. A failed prerequisite does not authorize a replacement host, tool or proof.
