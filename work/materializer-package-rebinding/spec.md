---
intent-blob: 129f1bd0829df002d39f5d3cb0d8650dfb017853
risk: high
drafted: 2026-09-25
---

# Spec: Restore the inactive materializer package bindings

Tracks #397. Repair the consumers of #392's private-index correction so the
existing assembly, packaging and shadow proof can complete. G2 and a separately
accepted high-risk plan precede implementation.

## Scope

Implementation changes only these ten paths:

- `profiles/default/v1/manifests/local-git-materializer.json`
- `profiles/alternative/v1/manifests/local-git-materializer.json`
- `profiles/default/v1/profile.json`
- `profiles/alternative/v1/profile.json`
- `scripts/test/default-profile-assembly.test.sh`
- `scripts/test/alternative-profile-assembly.test.sh`
- `shadow/v1/materialization-input.jq`
- `docs/replay-materialization-result.md`
- `shadow/v1/assemble-materialization-input.sh`
- `scripts/test/shadow-assembler.test.sh`

Implementation `review_size: standard`. This is identity and provenance maintenance;
keep the existing checks and suites, with no new framework or redundant unit suite.
All unrelated fields, package/prompt pins, grants, capabilities, authority records,
Roadmap digests, model choices, boundaries and runtime behavior remain unchanged.

## Canonical source and binding chain

Use source commit S `fc1fc01ff9963f5b8ccab5b26d4d572b9c1a0203`, already in main's
history. At `adapters/local-git-materializer/v1` it contains mode `040000`, type
`tree`, object `5c3607a765cc5d95372a0146be08832ecf554bfc`. Verify its ancestry and
unchanged package bytes at the accepted implementation base. Independently fetch
exact S through the existing isolated, depth-one, no-tags history boundary and
verify revision, path, mode, type and object. Local object presence is insufficient.
If the package changed, stop and return to the affected artifact gate.

In each materializer manifest, change only `body.package_ref.object_id` and
`body.package_ref.revision.commit_id` to that tree and S. Canonicalize with the
existing frozen jq 1.6 `-S -c` framing and one final newline. In each profile's sole
`adapter.local-git-materializer.v1` binding, copy that package reference and change
only `manifest_ref.sha256` to the updated canonical manifest's SHA-256. Update each
assembly suite's independent `materializer_package_commit` expectation to S;
preserve its isolated fetch and exact checks, other common pins, and the alternative
suite's independent producer pin. Never derive expected values from tested input.

Commit those six files as profile checkpoint B on the implementation branch before
its dependent shadow update. Record B's actual full commit ID; never invent a
future squash ID. Publish by ordinary fast-forward push, verify the exact remote
head and S/B ancestry, then independently fetch exact B into a fresh depth-one,
no-tags repository. Verify all four profile files as `100644` blobs, their complete
canonical bytes and hashes, only the permitted field changes, and S's unchanged
package tree. The source push is preparation, not implementation acceptance.

Only after that proof, update `shadow/v1/materialization-input.jq`'s `profile_pin`,
`manifest_pins.forge` and pinned-from header to B's default profile digest,
materializer manifest digest and actual commit. Keep its other six document pins,
decision texts/digests and every predicate unchanged. Final HEAD must retain S's
package and B's four profile files exactly. No old/new pin alternatives, caller-
derived trust, resolver fallback or substitute old source in packaging proof.

## Source-span provenance

The assembler's copied executable bytes remain unchanged. Correct only copy-range
markers and the matching existing byte-equality assertions and temporary-filename
references. The former materializer span 271–332 is now 271–276 followed by 284–339;
333–347 is now 340–354; 348–360 is now 355–367. Verify these exact byte relationships
against S and the current source. The inserted private-index helper is not copied.

Preserve all anchor uniqueness, line-count and byte comparisons, including the
shared-span comparisons with `shadow/v1/reproduce.sh`. Splitting the first range
must still provide its complete original byte sequence to that comparison. Retain
the unchanged entry adaptations, other spans and all negative assertions. Do not
edit the materializer or reproduction driver, weaken an assertion or hide failure.

## Restore evidence and publishing boundary

Update the existing source-provenance section in `docs/replay-materialization-result.md`
with actual S/B IDs, package object, four document hashes, retaining branch and
isolated-fetch requirements. Recheck source ancestry, exact isolated fetches and
content before implementation publication and protected merge; preserve the raw
tuple/proof in the review evidence and eventual merge receipt.

B must remain reachable from the original published implementation branch while
the provenance names it. Squash-only publishing and automatic branch deletion do
not supply that retention; local objects, temporary server objects and observed PR
refs are insufficient. The concrete plan must use the established one-merge
retention procedure in `work/replay-materialization-result/plan.md`, section 6,
subject to a new direct operator decision. That decision must authorize changing
only `delete_branch_on_merge` from true to false for the single protected merge,
then restoring and verifying true, including failure cleanup. Reserve a single-
merge window, verify unchanged protection and exact branch/head/base/CI, and prove
B's ancestry and isolated fetch/content again after merge and setting restoration.
Uncertain results require reconciliation and restoration before any other merge;
an unverifiable restoration stops all merges and goes to the operator.

Drafting, review and authorized implementation preparation may proceed. The setting
write and implementation merge must wait for that separate approval after the
complete implementation, review and required green proof are concrete. Prior
retention permission and the two-path provenance authorization do not grant it.
No extra ref, protection change or branch recreation is a substitute. Without an
approved retention procedure, preserve the same attempt unmerged.

## Acceptance

Require all of the following on the complete implementation:

- Structural and byte comparisons show only the permitted field, pin, provenance
  and matching test-reference changes. Source/checkpoint fetch proof succeeds.
- Run the existing default and alternative profile-assembly suites, target-packaging
  suite, shadow-assembler suite and shadow-slice suite completely. Positive packaging
  uses actual corrected HEAD; existing drift and negative cases still reject.
- Preserve the failed full-matrix evidence. After this dependency closes, rerun the
  blocked dispatched integration milestone for #395 against its refreshed exact
  head/base. Quick CI alone is not full-suite or milestone acceptance.
- Required quick CI and fresh independent exact-head/base review pass before merge;
  the implementation receipt proves retention and restored settings as above.

Preserve #392 and #395 as separate attempts. No live install, profile selection,
activation, credentials, real target execution, release publication, deployment,
history rewrite, direct-main push or destructive disposition is included.
