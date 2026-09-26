---
spec-blob: 3c1987d2815dc947ec0e5640f2427bae2d4874e1
drafted: 2026-09-21
---
# Plan: ci-test-shards

Increase CI from six test shards to ten using the existing runner and round-robin
assignment. The accepted spec is the contract. Risk remains high because the
workflow and `AGENTS.md` are constitution paths.

## Gate and order

1. Independently review and merge this plan-only amendment on
   `ystack/plan/ci-test-shards` before implementation. It changes only this plan and
   uses `Tracks #269`. The current operator-led delegation supplies the applicable
   acceptance and publishing authority; this plan grants none. The manager reads
   the complete independent verdict and verifies exact head/base and required CI.
2. Record the merged default OID as `plan-base`, verify both artifact hash links,
   and reconcile the implementation branch and claim before dispatch. Use
   `ystack/impl/ci-test-shards`; preserve any existing attempt. If default moves
   before code, use the existing high-risk base-reaffirmation gate with fresh
   independent acceptance. The implementation author does not edit the artifacts.
3. Make the four line edits below under the current operator-led scope. Run the
   focused proof and inspect the diff, then use one implementation PR with
   `Closes #269`. Complete fresh required CI and independent review before the
   authorized manager merges through the protected PR and records the receipt.

## Exact implementation changes

- `.github/workflows/ci.yml`: change the matrix list to
  `shard: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]` and the test invocation to
  `bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/10`.
- `AGENTS.md`: change “six parallel” to “ten parallel” in the CI sentence.
- `RESTORE.md`: change “six” to “ten” in the matching CI sentence, preserving
  its existing line wrapping and all surrounding text.

These are the only allowed implementation paths and edits. Keep the runner,
sharding proof, suite files, manifest, workflow triggers, permissions, checkout pin,
`checks` steps, aggregate `ci` job and branch rules unchanged. No tests, proposal
patch, temporary failing suite, red-test commits or initial-install sequence are
added. No installation, live sync or activation is part of this work.

## Validation

- Run `git diff --check` and inspect the complete implementation diff against its
  accepted base. Require exactly the four substitutions above in the three allowed
  paths. This also verifies that the runner, suites and aggregate gate remain
  byte-identical to that base.
- Run `bash scripts/test/run-all-sharding.check.sh` at the implementation head.
  Require exit `0`, the matrix/denominator check for ten, and
  `sharding proof: all checks passed`. This existing proof independently checks
  discovery, membership, ordering and partition coverage for every count from 1 to
  16, plus selector refusals and precedence. Do not duplicate it with new tests or
  run the full serial suite locally.
- Require the implementation head's complete CI run: `checks`, `test (1)` through
  `test (10)`, and the sole required aggregate `ci` all succeed. Read the sharding
  proof result in `checks`; retain the existing pinned shellcheck and other gates.
  Record the exact head/base, run link, results and actual wall-clock duration in
  the PR description. Measure from run start through completion, including runner
  wait and setup; the target is under 25 minutes. Report any miss as a miss, and
  return a needed count or scope change through the artifact gate.

The two workflow numbers must agree or suites could go unrun; the existing proof
checks this on every CI run. The spec's roughly 19.5-minute busiest-shard projection
is not measured wall time. Runner capacity and suite-name changes can affect the
result, so fresh complete CI supplies both correctness evidence and the timing.
