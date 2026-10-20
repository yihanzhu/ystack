---
spec-blob: 5465e033f0d0730a0106dc2ec5f91f1d571b6c92
risk: high
drafted: 2026-10-19
---
# Plan: delivery-guard-pipe-cleanup

Tracks #666.

## Files that change

| File | Change |
| --- | --- |
| `delivery/v1/replay.py` | Preserve the guard rejection when input close raises the expected broken-pipe error. |
| `scripts/test/delivery-replay.test.sh` | Add the fixed cleanup regression and retain held-lock failure output and status. |

Implementation PR review_size: standard.

Only these two implementation paths may change. This plan lands separately before
code. Use the normal high-risk plan gate and recheck the accepted artifact hashes
against the implementation base. Do not edit accepted artifacts during coding.

## Order of work

1. Add the regression and diagnostics to the existing test first. Keep the driver
   unchanged for the old-code proof. Put the fixed regression before the longer
   replay cases so its intended failure is reached directly.
2. Use the test's Python wrapper pattern to load the driver. Replace only its
   `Popen` boundary with a controlled child. Run the real `hold_candidate_ref`
   and `await_guard_prepared`; do not copy or replace their logic.
3. Make the initial prepare write and flush succeed. Give the real acknowledgement
   reader an output descriptor at EOF before `prepare: ok`. Record that cleanup
   observes `poll()` returning `None`, writes abort, and encounters broken pipes
   on the abort flush and then input close. Record calls to wait and output close.
   Assert the original `ReplayError` type and exact guard rejection message,
   protected-body non-entry, child reaping and output closure. The fixture must
   release its own test descriptors even when the old driver fails.
4. Reuse that fixture with a different input-close error and require that error
   to remain visible. This checks that the repair does not swallow unrelated
   close errors. Do not add retries or timing dependencies to either case.
5. In the real held-lock case, save the original `wait` status in its success or
   failure branch before any diagnostic command. When replay or its checks fail,
   print that saved status and copy the full captured output to the test log
   before calling the existing failure path. Do not derive the status from a
   negated command or a later logging command. Preserve every existing assertion,
   holder handshake, release and same-attempt resume.
6. Run the test with the unchanged driver. Save the exact driver and test hashes,
   raw stdout, raw stderr and exit status. Require failure at the new regression
   because the close error replaced the rejection or prevented cleanup. A setup
   error is not proof. Keep the same test bytes for the repaired-driver run.
7. In `hold_candidate_ref`, catch only the expected `BrokenPipeError` from input
   close. Keep the original rejection propagating and continue into the existing
   wait and output-close steps. Leave unrelated close errors visible. Keep the
   existing abort behavior, ownership acknowledgement, wait limits and termination
   behavior. Add no generic cleanup helper or new exception boundary.
8. Run the complete test with the repaired driver and perform the checks below.
   If the regression changes, renew the old/new comparison with the same fixture;
   preserve the original proof rather than replacing its logs.

## Risks

This is high risk because it touches the candidate identity guard. A broad error
catch could hide a different failure. Catching only the expected broken pipe and
checking a different close error bounds that change. Keep the protected body
unentered when preparation fails. Never delete a foreign lock.

A fixture that fails the initial flush would test the wrong path. Require the
initial write and flush to succeed, then let the real reader observe EOF. The
fixed child-status and cleanup failures remove scheduling from the regression.
The real Git contention test remains necessary to prove actual lock ownership.

A longer timeout or retry could conceal the failure. Neither repairs an exception
that escapes cleanup, so both are rejected. A shared cleanup abstraction would
expand a local fix and is also excluded.

The old Linux job did not retain its actual replay error. Its cause stays unknown.
A later pass cannot establish that cause. Keep the original evidence; diagnose any
new real failure from its preserved bytes and status. No weaker assertion, new
permission, activation or unrelated repair is authorized.

## Proof

Before and after the driver repair, from the implementation checkout, record:

```sh
git rev-parse HEAD
git diff -- delivery/v1/replay.py scripts/test/delivery-replay.test.sh
shasum -a 256 delivery/v1/replay.py scripts/test/delivery-replay.test.sh
bash scripts/test/delivery-replay.test.sh
```

Capture each command's raw stdout, stderr and exit status outside the test's
temporary directory. The old-driver invocation must fail at the fixed regression.
The repaired-driver invocation must pass the complete suite with the identical
test hash. Record the unchanged pre-fix driver blob and repaired driver hash, plus
the committed implementation head for final proof. Do not claim a clean Git head
alone identifies uncommitted test bytes.

The fixed cases prove error preservation, reaping, output closure, non-entry and
unrelated-error visibility. The complete real Git case must prove nonzero status,
exact guard rejection, no traceback, unchanged `publish-wait` journal without a
publisher, and `completed-offline` after release. Review the diagnostic branch to
verify that it saves the original status before logging, copies the captured file
without filtering, and still fails. Do not claim that a passing invocation exercised
that failure-reporting branch.

Use the pinned shellcheck executable on PATH and verify its version before linting:

```sh
shellcheck --version
test "$(shellcheck --version | awk '/^version:/ {print $2}')" = 0.11.0
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x -S style
```

The repair PR requires the complete delivery suite, the checks above, required
quick CI and fresh independent G3 review at its exact head/base before protected
merge. Do not run an unrelated full matrix as a substitute for this targeted proof.

After that protected merge, reconcile the preserved #558 attempt and merge updated
main into its existing branch through the normal process. Then run #558's original
complete Mac/Linux verification and obtain fresh independent G3 review and required
CI before its merge. A base move invalidates earlier acceptance for that tuple.
This downstream milestone is not a prerequisite for merging the repair PR.
No reset, rebase, force push, duplicate attempt or historical-evidence replacement
is included.
