# Intent: keep the full-test CI jobs on Ubuntu 24.04

Tracks #720. Status: G1 proposal.

## Problem

The six full-test shards use `ubuntu-latest`. Recorded runs show that this label
moved from Ubuntu 24.04 to Ubuntu 26.04 without a workflow change. An unchanged
construction-gate source and fixture passed on the former and failed on the
latter. The failing predicate's exact cause remains UNKNOWN.

The repository needs an explicit OS baseline for its existing Linux CI proof.
Changing the selected OS release does not fix or explain the Ubuntu 26 failure.
A named release can still receive image and package updates.

## Proposed outcome

Keep all six full-test shards on the previously exercised Ubuntu 24.04 release.
Maintain the same tests, judgments and acceptance gates.

| Item | Exact boundary |
| --- | --- |
| Implementation | Change only `jobs.test.runs-on` in `.github/workflows/ci.yml` from `ubuntu-latest` to `ubuntu-24.04`. |
| Other CI | Keep checks and aggregate runner labels and all other workflow bytes unchanged. |
| Test behavior | Preserve all scripts, fixtures, assertions, guards, six shards, suite inventory and genuine skip boundaries. |

This is a separate CI environment concern. It does not use #709's allowlist or
change its credential repair. It adds no probe, workflow, installation step or
diagnostic framework.

## Success criteria

After accepted G1, a high-risk G2 and a separately reviewed, protected-merged plan,
make the one-line change. Require independent exact-source review, automatic
required CI and one new exact-head dispatched full matrix. Retain actual runner
image identities, complete job and suite output, exits and honest skips. Any new
failure blocks acceptance. Old Ubuntu 24 results cannot accept the new head.

Preserve all Ubuntu 26 failures, including run `40200295104`, as FAIL with the
predicate cause UNKNOWN. Do not relabel them as fixed, passed or waived.

After normal protected merge, integrate actual main into the original #701
carrier. Rebind and review that carrier, then complete its separately required
proof. This CI change alone accepts no feature or incomplete implementation.

## Constraints

No production code, profile, configuration, credential, network scope, native
window, installation, activation, release or real-target permission changes.
Preserve old attempts and worktrees, frozen PR #183 and parked PR #412.
Keep all #558/#541/#544/#681/I1, Mac and same-head Linux, restoration,
genuine/native and final G3 obligations. CPU wall stays NONE, native BLOCKED,
production EMPTY and automation PAUSED.
