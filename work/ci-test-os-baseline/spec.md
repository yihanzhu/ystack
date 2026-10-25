---
intent-blob: 6eb21f713e4ab2bdebc567939997190e82582d35
risk: high
drafted: 2026-10-25
allowed-paths:
  - work/ci-test-os-baseline/spec.md
---
# Spec: fix the full-test CI OS baseline

Tracks #720. G1 is PR #721. This G2 permits planning, not implementation.
A separate high-risk plan must pass independent review and protected merge first.

## Scope

Change only `jobs.test.runs-on` in `.github/workflows/ci.yml` from
`ubuntu-latest` to `ubuntu-24.04`. All six existing test shards use that label.
Keep `jobs.checks` and aggregate `jobs.ci` runner labels unchanged. Preserve every
other workflow byte, including checkout, credentials cleanup, permissions,
triggers, matrix, commands and required-gate logic. Preserve all scripts,
fixtures, assertions, guards, suite inventory, manifest entries and skip rules.
No new test entry, probe, workflow or tool-installation step is permitted.

This fixes the selected OS release. It does not pin image or package bytes,
qualify a runtime, or prove why an unchanged fixture failed on Ubuntu 26.
Keep that failure and its exact predicate cause UNKNOWN. Do not use #709's
allowlist or edit #701 to implement this separate concern.

## Acceptance

| Gate | Required evidence |
| --- | --- |
| Exact change | Freeze the actual implementation base and workflow blob/SHA. The only implementation diff is the one test-job runner line. Restoring that line to its base value must reproduce the entire original workflow byte for byte, including final LF and file mode. All other repository paths outside accepted stage artifacts remain unchanged. |
| Independent source review | A non-author reviews the complete diff against the exact head/base and verifies the unchanged boundaries above. A moved head or base requires fresh binding and review. |
| Automatic CI | All existing required automatic checks pass on that exact candidate. A green automatic gate does not replace the full matrix. |
| Dispatched full matrix | Require one new run on the exact candidate head with all eight existing jobs: checks, test shards 1–6, and aggregate ci. Every shard must actually run on Ubuntu 24.04 and succeed; the aggregate cannot conceal missing, skipped, cancelled or failed test jobs. |
| Complete receipts | Retain run/attempt/head/base, workflow identity, all eight job results, actual image identities for each test shard, complete stdout/stderr and exits, and each selected suite's outcome. Preserve real in-suite skips with their original reasons and classifications. Missing output or an unstarted suite is not a pass or a platform skip. |

Freeze the actual sorted `scripts/test/*.test.sh` inventory and existing shard
selection before the run. The G1 base has 76 suites; the bound candidate's actual
inventory governs, without dropping any suite. Reconcile the six shard outputs
against it. Keep all original assertion counts, full failures and skip boundaries.
Do not add instrumentation to obtain evidence; use the existing workflow outputs.
Any missing required evidence leaves acceptance pending.

Preserve run `40200295104` and all original Ubuntu 26 results as FAIL/UNKNOWN.
Old Ubuntu 24 successes cannot accept this candidate. If the new Ubuntu 24 run
fails, retain the actual failure and stop acceptance. Do not retry automatically,
change fixtures, relax guards or introduce a probe. Any necessary correction must
follow its own bounded, evidence-based artifact gate; this one-line scope does
not authorize it. Required CI and independent review precede protected merge.

## Integration and retained limits

After protected merge, normally merge actual main into the original #701 carrier.
Bind and independently review its new exact head/base, then run its separately
required complete source proof and full matrix. Its 79-suite source inventory
must be frozen and reconciled separately. Never combine #720's head or 76-suite
proof with #701's different head or source inventory to claim either passed.
Keep all admission, provenance, actual publisher-caller and final acceptance gates.

No production code, profile, config, credential, network scope, native window,
installation, activation, release, real-target action or destructive disposition
is added. Preserve old attempts, frozen PR #183 and parked PR #412.
All #558/#541/#544/#681/I1, Mac and same-head Linux, restoration, genuine/native
and final G3 obligations remain. CPU wall is NONE, native BLOCKED, production
EMPTY and automation PAUSED. This G2 writes only its frontmatter path.
