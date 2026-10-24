---
spec-blob: d128e7841f85ec2fbf9b3f99b6f8d22acd0bcd52
risk: high
drafted: 2026-10-24
allowed-paths:
  - work/ci-readonly-checkout/plan.md
---
# Plan: stop retaining checkout credentials for read-only CI

Tracks #709. This plan needs independent acceptance, required CI and protected
merge before code. The accepted intent blob is
`f8cacc6bf48def691fb27e47e17b81ebe889d714`. Spec E1–E6 remain normative in full.
Implementation review_size: standard. The implementation is exactly two added
lines in one workflow. No new test or diagnostic code is needed.

## Exact change

This plan PR changes only its frontmatter path. The implementation may change
only `.github/workflows/ci.yml`. Its baseline at
`618a9570c5224dbd0a4e016500ea33ea401a51c4` is blob
`8ed4a153805c6d268a5652e4850712949d850fb6`, raw SHA-256
`a7d3effe4307ae3ea3fe608ecaeaab293a0c4bdf6663392ac6baba61be24f883`.

Under the existing `jobs.test` checkout, add only:

```yaml
        with:
          persist-credentials: false
```

Keep the action SHA `3d3c42e5aac5ba805825da76410c181273ba90b1` and comment unchanged.
Preserve every other byte: triggers, `contents: read`, repository/ref selection,
default shallow checkout, runner, job condition, fail-fast, six shards, original
suite command, `checks` checkout and required aggregate. No other workflow changes.

## Order of work

1. The manager records this plan's protected merge, accepted artifact blobs and
   actual `plan-base`. Recheck current main before code. If it moved, preserve the
   attempt and obtain fresh independent base acceptance under the normal rules.
   Confirm the pinned workflow bytes are unchanged; a changed baseline stops for
   reconciliation. Keep the original G1/G2 worktrees and all unrelated attempts.
2. After the normal exact claim gate, use one clean implementation branch from
   that recorded base. Add the two lines at the sole `jobs.test` checkout. Keep
   accepted artifacts unchanged. Commit normally; never amend published history,
   reset, rebase, force or create a replacement attempt.
3. Compare the full workflow with the pinned baseline. Removing exactly the two
   added lines at that step must restore the original bytes and hashes. Check
   the diff is one path, +2/-0, and run `git diff --check <plan-base> HEAD`.
   Record the full candidate workflow, blob, SHA-256, exact head/base and diff.
4. Have a separate source reviewer inspect that exact change. Publish through the
   normal protected PR process. Obtain automatic PR CI on the exact candidate.
   Its test job is skipped by design; this is only the quick gate.
5. Run the existing `ci.yml` workflow_dispatch on the same implementation branch
   and exact head. Record the selected ref and actual run head before accepting
   results. Use the existing six-shard `run-all.sh --shard N/6` matrix unchanged.
   No new workflow, step, runner, download, local native execution or diagnostic
   framework is authorized. Existing CI's own unchanged setup remains in scope.
6. Collect complete raw logs and results for `checks`, all six test jobs and `ci`.
   Build the finite evidence table below from those existing records. A separate
   reviewer reads the full relevant raw evidence, not only an aggregate or summary.
7. The manager reads the complete independent source/proof verdicts, resolves all
   Important findings, and rechecks exact head/base and both CI gates. Only then
   merge through the protected PR and record the actual receipt. A changed head
   or base invalidates prior evidence and needs fresh review and applicable CI.

## Finite proof and refusal

For each job, retain run/attempt/job IDs, head, complete log bytes/SHA-256, step
order, exits and conclusions. Use only existing masked lifecycle commands and key
names. Do not read or print credential files, token values or auth-bearing URLs.

| Proof | Actual source and required result |
| --- | --- |
| E1 | Local full diff and byte comparison: only the specified two lines; all original workflow bytes match. |
| E2 | Each checkout's own log: pinned action and false input, intended repository/ref, actual checked-out candidate commit. |
| E3 | Each checkout's own fetch/checkout records: original shallow depth and source identity; no alternate Git view or new remote. |
| E4 | Each checkout's authentication lifecycle records affirm no retained authentication before its Test suite begins. Any temporary setup must have a corresponding completed cleanup before that boundary. |
| E5 | Exact-head dispatched run: all six shards actually run their unchanged suites and succeed; `checks` and `ci` also succeed. Retain complete suite output. Automatic exact-head PR `ci` must separately pass. |
| E6 | Bind each E2–E4 row to that same job's checkout and timing. Retain separate rows for shards 1, 2, 3, 4, 5 and 6; no borrowed job evidence. |

For E4, identify actual setup/removal events and their order when the action logs
temporary authentication. If it logs that authentication was not retained, keep
that affirmative record and applicable existing predicate output. A declared false
input, no printed include name, no error, or post-job cleanup alone cannot pass.
Do not assume how the action implements false before seeing its actual records.
If the existing logs/predicates do not prove the state, record incomplete evidence
and return to the plan/evidence gate. Add no probe or exception to fill the gap.

The following are evidence refusals, not new runtime tests: wrong candidate SHA;
missing job/log; shallow or repository mismatch; incomplete authentication lifetime;
cleanup only after tests; skipped test job; failing suite; or cross-job evidence.
Each leaves the relevant row nonpassing. NOTRUN, timeout and partial output are
never success. Preserve the original failure and round history; do not retry on a
consumed GO. Any required correction follows the existing bounded review process.

Existing fixture tests keep their existing limited CI principal and setup scope.
Their success is no native/genuine qualification, new recording, installation,
real target execution or #558 window. Do not start the private macOS proposal.
No local product test or new tool download is required for this two-line change.

## Closure and preserved work

Keep the strict provenance reader unchanged, including include/includeIf refusal,
fixed origin, bounded read count and actual object/byte checks. No manual config
unset, HOME replacement, credential reader, alternate Git view or fallback. New
credential, host, remote or access needs stop that dependency.

This repair's CI cannot close #701 P07, shared admission or its source checkpoint.
After the repair lands, normally merge fresh main into the original #701 carrier.
Preserve source `1a04df91eac6cad16ff372d41fefaca3d72c375e`, failed run
`40076448634`, all failures and rounds. Rebind its artifacts/source/head/base,
obtain fresh independent review and its separately authorized full CI. Do not
change #701 or include #681's separate sandbox-receipt policy-set problem here.

Retain #558/#541/#544/#681, I1, final caller, final-head Mac and same-head Linux,
restoration, native/recording, G3 and protected-foundation obligations. Keep all
old attempts, the dirty credential-export plan, frozen PR #183 and parked PR #412.
No activation, production, admin action or wider authority follows from this plan.
CPU wall stays `NONE`, native `BLOCKED`, production `EMPTY`, automation `PAUSED`.
