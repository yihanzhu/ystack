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

- Follow the [approved fixed 3.15 supplement and accepted source review](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6203606687).
  Apply the [approved existing-parent supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6189713897).
  Use only the fixed official Python 3.15.0 and original pinned jq 1.6 bytes.
  Supply only the entirely absent `Versions/3.15` and `ystack-private-tools`
  trees under `/Library/Frameworks/Python.framework`. Authenticate the existing
  physical framework root, Versions directory and full parent chain first,
  including held identity, ownership, mode and actual empty ACL checks.
  Preserve old versions, top-level Current and root aliases. Do not traverse old
  version contents or use old objects as runtime dependencies. Do not repair an
  existing runtime, overwrite old objects, run package scripts, alter binaries
  or publisher links, or use another version, source, root or provider.
- Apply the [approved fixed Versions-mode supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6205434290),
  decision SHA-256 `399d3a10cac7add2bf2e77da613235fac353e7f9473f1d3cdbdff303ad9afa93`.
  Only `/Library/Frameworks/Python.framework/Versions` may change from exact
  UID 0 and mode 0775 to 0755 after held identity and actual empty ACL checks and
  a durable journal of its original metadata. Restore 0775 only after the original
  cleanup of both new trees and safe identity checks. Each of the two fixed chmod
  commands may run at most once per job, within the original 256 administrator
  command limit. Unsafe restoration leaves 0755 and fails the job. Record actual
  ctime changes; never backdate them.
  Otherwise limit existing-parent writes to adding and removing the two fixed
  child names and their necessary directory metadata changes. Verify each exact
  change and record real metadata. Clean up only new trees whose objects match the
  ownership journal. Extra, changed or unknown objects block deletion. Preserve
  the old child names and all other stable safety attributes.
- Complete this G1 amendment, G2 and a separate high-risk plan before implementation.
  The Mac workflow implementation changes only
  `.github/workflows/scope-genuine-macos.yml` and its `ci/required-files.txt` entry.
  Necessary fixed bootstrap/Python/jq bindings in #541's two test fixtures pass
  their own affected artifact gates within the original core paths.
- Keep the fixed repository, operator, manual event and sole #541 implementation
  ref. The mode supplement covers only the already approved #541/#559 and #544
  complete Mac proof and their original bounded revisions. #544 requires its own
  closed-ref and authority binding through independent artifact acceptance.
  Add no rounds, diagnostic runs, CI dispatches or rerun allowance.
  Bind the reviewed workflow and source before and after execution. The dispatch
  event SHA selects source; it does not grant approval.
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
