---
spec-blob: 32c003b7c92e0627b938daa27f01b6a5e9b093e6
drafted: 2026-09-14
---
# Plan: credential-control-identity-handoff

Tracks #321. This is a high-risk plan proposal, not permission to implement.
The accepted intent is `1e0cddd34f8c2a8218a3e2f40f4bc7d0f78fc5c9`.
The planning base is `d472cbd460280e88375e94897d76fbed87ca88c4`, containing
accepted G2 PR #326. Its earlier draft-status prose is historical; this plan uses
its complete merged requirements. A separate plan-only PR and independent review
must precede code. The implementation must not edit accepted artifacts.

## Files that change

Exactly two implementation paths:

| Path | Change |
| --- | --- |
| `scripts/test/control-credential-policy.test.sh` | Repair its private outer-control startup and retirement; add the full handoff proof matrix below alongside the existing 99 cases. |
| `docs/components.md` | Extend the existing credential-policy entry with the atomic identity handoff, bounded gate, preserved-failure behavior and limits of the evidence. |

The test at the planning base has blob
`63d5c79d5cf25dfee4d1a6272d394a6877a87960` and 1781 lines. The relevant existing
boundaries are `managed_dispatch`, `cleanup`, `setup_control_fail`,
`run_setup_controls`, its generated `control.sh`, and the launch/identity/release/
wait loop. Keep the inner managed functions and all existing assertion bodies.
No new shipped helper, manifest entry, dependency, workflow or test-runner change
is needed. Generated private files remain inside this test's owned scratch.

Propose `review_size: accepted-exception`, **900–1400 net changed lines**, for this
single concern. This is a planning estimate, not an accepted exception yet.
A readable implementation is estimated as 240–340 lines for parent state, guarded
operations, wait and diagnostics; 70–110 for child publication/gate and the bounded
Perl reader; 180–260 for reusable private fixture, acknowledgment and assertion
support; 400–620 for the explicit controls; and 10–20 documentation lines.
The sum is 900–1350 lines, with 50 lines of integration margin. Replaced unsafe
startup code can reduce the measured net total. Record additions, deletions and
per-path totals; a lower total is not permission to omit a case. An overrun must be
explained and separately reviewed before proceeding, without compressing source or
cutting proof to fit. No second concern is included in this range.

## Order of work

### 1. Preserve the baseline and establish the private test boundary

Before code, verify the accepted intent/spec/plan hashes and build claim against
fresh main. Record the exact branch/base/head and source identities. Preserve the
original PR #320 failed log and isolated empty-record reproduction as historical
evidence; neither establishes the unique cause of that CI failure.

Inventory the original 45 assertions and 54 controls by name and order. The latter
are 11 three-signal groups and 21 single controls. Keep their existing expected
launch, mutation, termination, reconciliation, event, status and actual descendant
checks. Keep the three real evaluator mutations, three-attempt setup limit and
original evaluator/decision/policy bytes. New controls do not replace a full
policy evaluation with a fixture.

Build the new regression fixture before repairing the boundary. Extract the
actual private handoff functions into generated files using the test's existing
`declare -f` convention. Run expected-failure cases in private Bash workers so a
terminal handoff failure can be asserted without continuing that failed worker.
The full suite counts a new proof only after checking the worker's actual failure
and evidence. The failed worker itself never increments a normal control pass or
admits a later case. Do not recursively run the whole suite or reset its alarm.

Reuse the generated control and real managed fixture for released cases. In
particular, use an existing actual-launch case such as `absence`, whose evaluator
fixture has a separate PGID and real managed termination/reap. Coordinator-only
synthetic cases cannot prove descendant completion. Generate only the narrow
operation overrides needed for a named new case; do not fork a second handoff
implementation. Retain the first reproducible red result and exact source tuple.

### 2. Publish and read the identity as a checked transaction

Under the existing umask 077, have the parent create each case directory, scratch,
startup stdout/stderr and event locations before launch. Refuse pre-existing case
paths. The child no longer creates that same directory. Keep each case's identity
temporary and final paths distinct and private. Obtain the child's real PID and
PGID, check the canonical values, open the temporary record, write the complete
line, close it successfully, then rename it to the final path. Guard each operation;
publication failure exits through the installed child startup handling without
entering its managed evaluator case. No added delay makes publication safe.

Put a private reader in an inline Perl function in this same test. Use `Fcntl`
constants for O_RDONLY, O_NONBLOCK and O_NOFOLLOW, `sysopen`, then descriptor `stat`
and S_ISREG. A pathname `-f` test is not the reader. Loop over checked `sysread`
results with a total budget of 65 bytes; require clean EOF, successful close,
length at most 64 and the exact two-positive-decimal/one-space/one-LF grammar.
Reject NUL, signs, leading zero, CR, alternate whitespace and trailing bytes.
Return only validated fields, never the original bytes. Compare both with the
captured job handle and reject the outer PGID. Guard the parent's command capture
and field consumption independently so an error cannot escape through `set -e`.

Retain the 100 publication observations and existing 0.01-second polling interval.
Distinguish absent final path from an inspection failure. Once a final path is
present, perform one strict read: an invalid final record is terminal, not another
poll or another launch. Include dangling symlinks in the present-invalid path.

### 3. Enter ownership before setup; use one release attempt

Add parent-only outer context, phase, first failure, first signal, acquired-job,
wait-active/interrupted/status, possible-release and retain-scratch fields. Keep
these separate from SETUP_CONTEXT. `managed_dispatch` selects this context first;
its HUP/INT/TERM branch only records state and returns. Every signal during active
wait sets the interruption flag, even when the first cause was already recorded.
Generated inner controls initialize the outer context inactive. All other dispatch
paths keep their existing behavior.

Enter the context before time capture or any directory/capture/FIFO/descriptor/
job-control operation. Check each result explicitly and consult pending signal
state at safe boundaries. Use one small launch function with asynchronous launch
immediately followed by assignment of `$!`; no command substitution, diagnostic
or background helper may intervene. Distinguish no acquired job from a real saved
job. Save and restore the actual prior monitor-mode setting on success and error,
rather than always forcing `set +m`. Restoration failure remains a terminal cause.

Install child startup failure handling before publication. After publication,
perform exactly one guarded Bash `IFS= read -r -t 3` on FD7. Require successful read and
exact `verified`; close FD7 on both outcomes. Abort, partial/other tokens, timeout
and read failure exit nonzero before evaluator launch. Install the original
managed traps before entering the original case. Do not infer EOF from either
O_RDWR endpoint closing or the FIFO pathname being removed.

Advance parent phases monotonically. Before the first verified write, set
possibly-released; it stays true even if the write reports failure. Check write,
FD close and FIFO removal separately and preserve the first failure. Before that
phase, a terminal case can attempt one actual abort token, then close its endpoint.
Failed abort relies on the child's independent finite gate for exit, not a second
token or PID signal. After possible release, send no other token or signal: enter
wait-only and let the existing managed case finish. A later successful control
cannot turn the outer failure into success.

### 4. Reconcile the same Bash job and preserve evidence

Remove the outer `setup_control_fail` numeric KILL/wait fallback. The saved job is
used only for the same parent's actual builtin wait and evidence. Do not introduce
kill-zero/ps checks, jobs parsing, a cancellation protocol or a per-case completion
clock. Keep the one original 180-second alarm unmodified across workers, setup,
wait and all interrupted re-entry; no worker rearms it or claims to inherit a new
independent alarm.

Before waiting, retain scratch as unresolved. Execute guarded builtin wait in the
same shell that launched this job, with no second wait consumer. Clear the
interruption flag immediately before each wait. Repeat only that same wait when
an actual trapped signal marked interruption. Natural status above 128 alone is
not interruption. Once completion is established, retire job authority before
elapsed-time capture, file inspection or formatting. Unexpected 127 or failed
status capture remains unconfirmed. A late signal can cause a repeated wait on the
same saved Bash job, never a signal to its numeric PID.

On ordinary released success, retain all original expected status and descendant
assertions before clearing scratch retention. On a terminal path, report direct
wait status separately from actual available descendant evidence. Missing or
malformed events cannot prove absence. A handoff failure always retains suite
scratch, including subsequent EXIT. An uncertain child or descendant also forbids
removing its files or starting another case. Hard alarm termination remains a
failed run, not a promised cleanup success.

Use a fixed handoff diagnostic prefix and enumerated phase/outcome values. Format
the first operation failure, trapped signal, job-acquired flag, wait status or
unconfirmed state and possible-release flag. Read at most 256 source bytes from
each identity/event/stderr excerpt, escape them and cap the entire emitted record
at 2048 bytes. Keep full files private. Formatting/read errors must not revive
ownership, replace the first cause or bypass the retention flag. Avoid unbounded
`cat` on this failure path. These diagnostics do not dump environment or arbitrary
process information.

### 5. Complete the new proof matrix through real operations

Use named cases and a separate new-case summary. The inventory below has 68 new
proof invocations, in addition to the original 99. Each comma-separated variant
is a distinct invocation unless explicit sharing is stated. Assert actual worker
status, phase/event sequence, release count, launched-job identity, real direct
wait and required descendant evidence. Do not infer cleanup from parent variables
alone. Expected failure of a private worker is evidence for a successful outer
negative test only after those assertions pass.

| Group | Invocations | Required operation and observations |
| --- | ---: | --- |
| Publication | 2 | Hold the actual producer after temporary open; separately after a real strict partial write. At each acknowledgment, final identity is absent and release count zero. Complete that same write/close/rename and require exactly one normal release and real completion. |
| Final-record refusal | 18 | Empty, strict partial, missing LF, extra field, extra line, NUL, oversize, symlink, FIFO without writer, directory, real failed read, leading zero, signed number, CR, alternate separator, PID mismatch, PGID mismatch, outer-group record. Real abort or actual gate expiry and same-parent wait must finish each child; no evaluator, normal pass or next admission. FIFO/directory controls must finish by the actual nonblocking reader refusal, not by a killed hung reader. |
| Launch signals | 9 | HUP/INT/TERM at each of before launch, after real asynchronous launch before owner publication, and after capture. Require respectively zero or one actual child, correct retained job, no verified release and actual ordinary retirement. |
| Gate/write failures | 5 | Actual abort write failure, actual gate expiry, verified write failure before bytes, after a real strict prefix, and after delivery of the full line. Distinguish child non-release from possible release. Full delivery must run an actual managed case and prove its descendant completion while retaining the outer failure. |
| Release signals | 15 | HUP/INT/TERM at each of before first release write, after that write, after complete delivery before caller processing, during FD close, and during FIFO removal. Use actual released managed cases where release may have occurred; never kill their outer control as a substitute for evaluator completion. |
| Wait and retirement | 11 | Three signals interrupt a genuinely pending wait; three arrive after real return before retirement; three cases have natural signal exit without an outer trap; then a real final reap followed by file error and by diagnostic error. Verify same-job wait re-entry, no repeated token/signal, proper natural-status classification and no revived authority. |
| Unconfirmed evidence | 5 | Inject status 127, failed wait-status handling, observation error, missing cleanup events and malformed cleanup events. Require named terminal failure, retained scratch and no later launch. Injected errors prove these refusal paths only; they never replace real ordinary-error reaping above. |
| Timing and re-entry | 3 | Acknowledged delayed final publication followed by successful release during its post-publication gate; actual gate read failure; a second real signal interrupting a later wait re-entry after the first cause was saved. Share the actual expiry observation with the gate/write group. Require no restarted gate/alarm and real ordinary completion. |

For actual read failure, use a private override of the reader operation which
opens a real descriptor and makes the actual read fail; a fabricated reader
return alone is insufficient. For failed writes, use a closed endpoint for
pre-byte error or call the saved real write on the specified bytes before returning
failure. Do not claim a shell success/failure value identifies bytes delivered.
A no-release case can use actual abort; it need not consume the whole timeout.
Use integer one-second gates in private expiry/failed-abort/prefix controls where
needed; ordinary generated controls retain three seconds. No negative gate is
longer than the operational gate. Normal successful/abort controls exit promptly.

Acknowledgment helpers are started and their handles captured before the tested
control launch. Each helper and endpoint is private and finite; close unrelated
ends, record ownership before use and actually wait for helpers. No helper consumes
the tested job's wait. Use finite checked reads for test coordination, never sleep
as evidence that a boundary has been reached. Failure retains unresolved fixtures;
there is no broad process search or numeric-PID cleanup fallback.

Use two distinct DEBUG boundaries in private instrumented copies of the same
functions. Each worker is a fresh separately exec'd Bash, not a `( ... )` subshell.
Before installing the observer,
bind its actual own PID and PGID to the launcher's captured job and distinguish
them from the suite and coordinator. Never use a subshell-inherited `$$` as the
self-signal destination. Keep extdebug disabled, prevent observer recursion and
remove the observer after its single boundary. A coordination interruption must
resume the specified original operation safely or fail visibly, never skip it.

For launch-to-owner capture, observe before the original immediate `$!` assignment.
Capture the incoming real asynchronous child identity as a trap-entry argument
before any observer operation. Acknowledge and hold this boundary using pre-opened
channels and the prestarted coordinator, then signal the verified live worker.
The observer and record-only signal handlers must start no background process,
consume no child wait and leave `$!` unchanged. Resume the original assignment
and verify that it saved that same real child. This proof does not depend on the
observer preserving an incoming wait status; no wait occurred at this boundary.

For after-wait/pre-retirement signals, first let the original genuine builtin
wait and its original status assignment complete. Observe the next retirement
operation before it executes. Acknowledge that exact boundary and deliver the
selected real signal to the verified live worker. The record-only handler and
observer must not alter the saved wait-status scalar. Resume the original
retirement operation without substituting a wait result. After observer removal,
check the actual saved scalar against the independently known nonzero and natural-
signal outcomes of the already listed real child cases; accidental status zero
cannot pass. Check actual interrupted-wait classification separately, and retain
all genuine pending-wait interruption controls in the matrix. This observation
must not rely on preserving pending `$?` through nested DEBUG/INT handling.

For both boundaries, verify the signal event names the actual worker, never the
suite or coordinator, and that no observer consumes a second wait or restores
retired numeric signal authority. Record this as instrumented proof, not unchanged
execution.
Separately compare the uninstrumented launch function and run the original 54
controls through it. The observer is not added to ordinary handoff code and does
not expand the permitted production launch/capture operations. If supported Bash
cannot preserve these facts, retain the failed proof and return the concrete
mechanism problem for review; do not relabel a later signal as this boundary.

Keep the old 99 case names and relative order available as a mechanical ledger,
even if appended new cases change the final total. Require 99 old plus 68 new
successful proof results, with no duplicate or missing name and all original
control summaries. A failed ordinary worker's normal pass counter must remain
unchanged; only its separate, fully checked negative proof gets a new result.
Use bounded diagnostics controls to check escaping and caps within these failure
cases, including an oversized raw record and retained full stderr. Do not add a
second independent process framework merely to exercise this repair.

### 6. Document and assemble exact-head proof

Update only the existing components entry. Explain what was repaired and that
wait-only failure retirement, real descendant evidence and retained uncertainty
are distinct. Do not claim this fixes the unique historical CI cause, grants
credential qualification or changes the evaluator. Review the two-path diff and
ensure all accepted artifacts and protected product bytes remain unchanged.

## Risks

The highest risk is a signal crossing ownership or release state. A saved Bash
job is not a kernel PID reservation, and both FIFO ends being O_RDWR prevents an
EOF cleanup argument. The design deliberately uses real same-job wait and the
existing managed control completion. It does not add cancellation, job-table
polling or a generic supervisor. Post-release failures remain terminal even when
the original control succeeds. Unknown death state must remain visibly unknown.

Portable DEBUG observation and trap/wait ordering need actual Darwin Bash 3.2 and
Linux Bash proof. Instrumentation can observe an actual boundary but cannot by
itself prove untouched startup; keep the original uninstrumented matrix and
source checks separate. An inability to demonstrate the required ordinary
retirement is a blocker, not a reason to accept only synthetic status controls.

The complete old suite took 122.38 and 124.74 seconds through exit in retained
Darwin runs. Linux log header-to-terminal spans ranged from 122.75 to 130.52
seconds and exclude final EXIT cleanup. These are observations of the unchanged
test, not a guaranteed spare budget. Cold jq setup, scheduling and all permitted
real setup retries were not separately bounded by those logs. The new 68 controls
have no measured runtime yet. No plan arithmetic establishes that they fit.
Measure the complete suite under its unchanged alarm; preserve the first failure.
If the full required proof cannot fit, pause and return that evidence through the
artifact process. Do not enlarge 180 seconds, remove a case, mask failure or rerun
unchanged code until green.

This plan keeps the evaluator and existing managed lifecycle unchanged. If an
ordinary case exposes a required change outside the private outer boundary, stop
with its exact source/log evidence. No runtime install, credentials, activation,
real target, workflow change, #271 continuation or cache exception is authorized.

## Proof

Run proof on the actual implementation commit; record complete commands, tool
identities, source hashes and return statuses. Keep first red logs and later
changed-source results separately. A development subset is not full native proof.

1. Run `bash -n scripts/test/control-credential-policy.test.sh`. Check the generated
   private Bash files with the same parser during the focused test. Compile-check
   the actual inline Perl reader and diagnostic programs as part of their controls,
   without adding a downloaded interpreter or standalone shipped helper.
2. Run `bash scripts/test/control-credential-policy.test.sh` on existing native
   Darwin Bash and supported Linux CI. Do not set the bounded-wrapper variable to
   bypass the original alarm. Capture stdout/stderr and actual final process wait;
   record monotonic whole-process elapsed time in the external evidence harness,
   not as a new product or per-case clock. Record Bash/Perl/jq identities, 99 old
   plus 68 new results, all original control summaries and each new proof name.
   Record group time including its setup, assertions and cleanup, not only inner
   control timers. Confirm no owned child/endpoint remains unresolved before
   calling a run green. Preserve retained scratch for any failed run.
3. Independently compare the original 99-case ledger and unchanged evaluator,
   decision, policy, core/dependency files against the planning base. Review the
   actual launch/capture adjacency, no outer numeric-signal path, all guarded
   setup/release/close/wait failures, same-parent wait consumer, diagnostic bounds
   and EXIT retention. Check the instrumented function copies differ only by their
   declared observation/negative-operation overrides. Source review supplements,
   and never replaces, the real process and refusal controls.
4. Run `bash scripts/test/portable-core-schema.test.sh` with the implementation
   files staged so indexed-source checks see the candidate; report index/HEAD
   identity accurately. Run `bash scripts/check-rename.sh` and
   `bash scripts/test/run-all-sharding.check.sh`. The existing manifest paths
   remain present and executable; no new entry is needed.
5. Verify ShellCheck is exactly 0.11.0, then perform the existing repository sweep
   in an evidence Bash shell with `set -o pipefail` explicitly enabled:
   `find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x -S style`.
   Record both pipeline members' actual statuses immediately from PIPESTATUS,
   before another command overwrites them, and require both zero. The focused
   test's own shell options do not configure this external proof shell. No lint
   suppression may conceal a signal, descriptor or unchecked-status bug.
6. Require all current protected CI jobs and a substantive independent exact-head/
   base review. Linux focused evidence comes from that full required CI; no local
   subset substitutes for it. A base refresh requires fresh CI/review and honest
   attribution of any reused unchanged-source native evidence. The implementation
   PR alone may use the terminal closing reference for #321. This plan PR tracks
   the issue and cannot close it or authorize live behavior.
