---
spec-blob: 572dc1b0aa8a9564af15531210a9ac231a867171
drafted: 2026-09-21
---
# Plan: ci-test-shards

Increase CI from six test shards to ten and prepare their existing jq prerequisite
before suite execution. Keep the runner and round-robin assignment unchanged. The
accepted spec is the contract; risk remains high because the workflow and
`AGENTS.md` are constitution paths.

## Gate and order

1. Independently review and merge this plan-only amendment on
   `ystack/plan/ci-test-shards` before further implementation. It changes only this
   plan and uses `Tracks #269`. The current operator-led authorization supplies the
   applicable acceptance and publishing authority; this plan grants none. The
   manager reads the complete independent verdict and verifies exact head/base and
   required CI.
2. Record the merged default OID as `plan-base` and verify both artifact hash links.
   Reconcile the clean paused PR #381 on `ystack/impl/ci-test-shards`, round 0, at
   `db4b03c246fda5491656d68ff011343811faff7b`. Merge updated main into that same
   branch without reset, rebase or force-push. Verify the resulting local/remote
   head, open PR, current base, clean worktree and accepted artifacts; invalidate
   previous review evidence. An unexpected identity or state change stops resume.
3. Record the matching fix claim and round under the existing claim rules before
   the same implementation author resumes. Keep `Closes #269` on PR #381; do not
   create a replacement PR. The implementation author does not edit the artifacts.
   Fresh required CI and independent review must pass before the authorized manager
   merges through the protected PR and records the receipt. A later base move
   requires fresh exact-base review under the existing rules.

## Exact implementation changes

- `.github/workflows/ci.yml`: use
  `shard: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]` and
  `bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/10`.
  Between checkout and `Test suite`, add one prerequisite step in each test job.
  Use fail-fast shell execution to create the existing cache directory
  `${TMPDIR:-/tmp}/ystack-portable-core-jq16` and download
  `https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64`
  into a temporary file there, requiring HTTPS and failing on HTTP errors.
  Verify SHA-256
  `af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44`
  before executing or publishing the file. Make it executable, require exactly
  `jq-1.6` from its version check, then move the verified file to `jq-linux64` in
  that cache directory. Clean up the temporary download on failure. A download,
  digest or version failure must fail the job before any selected suite runs.
  Download on each job; do not depend on earlier suites or runner cache state.
- `AGENTS.md`: change “six parallel” to “ten parallel” in the CI sentence.
- `RESTORE.md`: change “six” to “ten” in the matching CI sentence, preserving
  its existing line wrapping and all surrounding text.

These are the only allowed implementation paths and edits. Keep the runner,
sharding proof, suite files, manifest, workflow triggers, permissions, checkout pin,
`checks` steps, aggregate `ci` job and branch rules unchanged. The prerequisite step
runs no suite and changes no system installation or PATH. Add no helper, framework,
unit tests, temporary failing suite or red-test commit. No local installation,
live sync, activation or broader CI-policy change is part of this work.

## Validation

- Run `git diff --check` and inspect the complete implementation diff against its
  accepted base. Require only the four count/doc substitutions and prerequisite
  step above in the three allowed paths. Verify the runner, proof, suites and
  aggregate gate remain byte-identical. Check that the digest precedes execution
  and cache publication and that setup failures cannot reach suite execution.
- Run `bash scripts/test/run-all-sharding.check.sh` at the implementation head.
  Require exit `0`, the matrix/denominator check for ten, and
  `sharding proof: all checks passed`. This proof checks discovery, ordering,
  partition coverage for counts 1–16, selector refusals and precedence. Do not add
  duplicate tests or run the full serial suite locally.
- Require the implementation head's complete CI run: `checks`, `test (1)` through
  `test (10)`, and the sole required aggregate `ci` all succeed. Retain the pinned
  shellcheck and every other gate. Confirm prerequisite setup succeeds in all ten
  jobs and both unchanged producer suites pass their file, digest and version
  checks. Their failures in run 35660956979 supply the existing failing evidence;
  the complete successful run supplies the regression proof.
- Record exact head/base, run link, all job results and actual wall-clock duration
  in the PR description. Measure from run start through completion, including
  runner wait and setup. The target remains under 25 minutes for the successful
  complete run. Report a miss as a miss; do not substitute a projection, partial
  run or silent target relaxation. Return any needed count, scope or acceptance
  change through the applicable artifact and operator gates.
