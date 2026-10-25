---
spec-blob: a5fa0cdd1b9ea74d45edcfe928fab6058031bdc6
risk: high
drafted: 2026-10-25
allowed-paths:
  - work/ci-test-os-baseline/plan.md
---
# Plan: fix the full-test CI OS baseline

Tracks #720. The accepted spec governs in full. This plan changes no code.
Plan PR review_size: standard, expected 50–100 added lines. Implementation is
one changed line, with all required source review and CI retained.

## Exact scope and pins

The only implementation path is `.github/workflows/ci.yml`. Change only
`jobs.test.runs-on` from `ubuntu-latest` to `ubuntu-24.04`.
Keep file mode and every other byte unchanged, including checks/ci runner labels,
checkout, credential cleanup, triggers, permissions, six shards and gate logic.
Scripts, fixtures, guards, manifest, suite inventory and skip rules stay unchanged.

At base `3f7ebf9f61c242b97f4b11137fc8c835b9128e29`, that workflow is mode 100644,
blob `67807c9b55569a6f0d851eb83a43d14bdb84a618`, 6,905 bytes, SHA-256
`fe6aada85c87d0564ed25150e730d51d766bda2172f1d3d1fe15458b83162df8`.
The sorted repository-relative `scripts/test/*.test.sh` paths, each ending LF,
number 76 and hash to `0d7103a58837119e2ba029986eaaf46d5e1f34fc7bca55679d8ccb0789c3343c`.
Rebind actual base, workflow and inventory before code and CI; never silently
assume a moved base has these bytes or omit a suite to retain this count.

## Ordered work and evidence

1. The manager checks local/remote branch and worktree state before using
   `ystack/plan/ci-test-os-baseline`. Every non-merge commit above its accepted
   base changes only this plan. A base update may only merge prior plan head
   first and fresh base second, with a plan-only residual diff; rerun review/CI.
   Obtain independent plan acceptance, required CI and protected merge.
2. Record the actual plan-containing main as plan-base, all artifact hashes,
   risk, intake claim and the sole source carrier. Recheck main immediately
   before code. A move requires the normal fresh non-author base gate; no stale
   acceptance. Keep old attempts intact. Only the designated source author may
   make the one-line change on the one authorized implementation branch.
3. Run `git diff --check`. Verify the implementation name/status/numstat shows
   only this workflow line and no mode change. In memory or owned temporary
   data, restore only the test job's new label to its original value. Require
   exact equality to every byte of the bound base workflow, including final LF.
   Reject multiple edits or a match in another job. Keep the raw diff, original
   and candidate blob/SHA/mode/size and equality result. Add no test or probe.
4. Freeze the clean source head and push only that same candidate branch. Open
   a normal implementation PR with `Closes #720`. A non-author reviews the entire one-line diff and
   original-byte proof against exact head/base. The manager reads the complete
   verdict; unresolved Important findings block. No reset/rebase/force or bypass.
5. Require automatic required CI and one new `workflow_dispatch` full matrix on
   this exact frozen head. Preserve the workflow/ref/head/base, run and attempt
   IDs, all eight job IDs/results and complete raw logs. All six test shards
   must actually run on Ubuntu 24.04; record each one's actual image identity.
   Checks, six test jobs and aggregate ci must all pass. Missing, skipped,
   cancelled or failed test jobs cannot be hidden by aggregate success.
6. Reconcile actual sorted suite inventory and existing shard selections with
   complete per-suite outputs, assertion totals, stdout/stderr and exits.
   Retain genuine in-suite skips with their exact reasons and classifications.
   Missing output/unstarted suites are not passes or platform skips. Use only
   existing workflow outputs; no new instrumentation. A quick green or older
   Ubuntu 24 run cannot replace this exact-head full proof.
7. If Ubuntu 24 fails, preserve all actual results and stop acceptance. No
   automatic retry, fixture repair, relaxed guard or diagnostic probe belongs
   to this plan. Any further correction needs its own bounded factual gate.
   Keep run40200295104 and all Ubuntu 26 failures as FAIL/UNKNOWN; this change
   does not establish their predicate cause or pin package/image bytes.
8. Only after complete exact-head/base review and every required proof passes,
   merge through the protected PR and record the actual receipt. A changed
   head/base invalidates stale proof; never combine runs from different heads.

## Separate integration and limits

Normally merge the resulting actual main into the preserved #701 carrier.
Rebind its own head/base, independently review it and run its separately required
79-suite full proof, freezing its actual inventory. #720's 76-suite proof cannot
accept #701 or replace its admission/provenance/actual-publisher proof.

No production/profile/config, credential/network scope, native window, install,
activation, release, real-target action or destructive disposition is added.
Do not borrow #709's allowlist. Preserve old worktrees, frozen #183 and parked #412.
All #558/#541/#544/#681/I1, Mac and same-head Linux, restoration, genuine/native
and final G3 debts remain. CPU wall NONE; native BLOCKED; production EMPTY;
automation PAUSED. An OS baseline change grants no runtime qualification.
