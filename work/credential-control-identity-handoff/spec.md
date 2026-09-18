---
intent-blob: 1e0cddd34f8c2a8218a3e2f40f4bc7d0f78fc5c9
risk: high
drafted: 2026-09-14
---
# Spec draft: Complete the private control identity handoff

Tracks #321. Source base: 2f757829f49031110a8f73e153d9cdcf10a253fd.
This is proposal v2 for independent review, not accepted G2 or implementation authority.

## Requirements

### R1. Preserve the existing test and product contract

Change only `scripts/test/control-credential-policy.test.sh` and its existing
entry in `docs/components.md`. Keep all 45 original assertions, all 54 added
controls, their real signal/lifecycle assertions, the three real evaluator input
mutations, three-attempt setup limit and 180-second suite alarm. New handoff
controls supplement those 99 cases. No case becomes a skip or synthetic replacement.

Keep the evaluator, decisions, policies, dependency identities and all existing
security/resource checks unchanged. In particular, retain original evaluator
bytes and decision-bound self identity. This repair changes private control startup,
not evaluator setup retries or the product's credential qualification claim.

Retain the original failed CI and first isolated reproduction. The old Linux log
shows failure after case 60 and an orphan at runner cleanup; it does not identify
the exact failed operation. The Darwin reproduction proves the isolated empty-file
read defect, not the historical cause or complete process-group cleanup.

### R2. Publish one complete identity and parse it strictly

Each control gets its existing fresh private case directory. The parent creates
the directory and startup capture locations before launch, with umask 077. The
child writes its actual PID and actual PGID to a distinct temporary identity file,
checks write completion and closure, then renames it to the final identity path.
Only the complete final pathname is advertised. Do not overwrite a previous case,
reuse a partial final file, or use an added sleep to make a write seem atomic.

The final record is exactly two canonical positive ASCII decimal fields separated
by one ASCII space and terminated by exactly one LF. Its total length is at most
64 bytes. No sign, leading zero, extra field/line, NUL, CR, alternate whitespace or
missing terminator is accepted. Both fields must equal the saved launched job PID;
the group must differ from the outer test's group. File existence is not validation.

Use the existing Perl dependency for a private bounded reader: open the final
path with O_RDONLY | O_NONBLOCK | O_NOFOLLOW, then fstat that opened descriptor
and require a regular file before reading. This rejects a FIFO without waiting
for a writer and rejects a directory before any content read. Do not replace the
descriptor check with a pathname precheck. Read at most 65 bytes, require clean
EOF and the exact grammar, and return only validated fields.
Every open/read/close/type/size/parser failure has a checked nonzero outcome. The
parent consumes that checked result in a guarded assignment/read; errexit cannot
bypass handoff retirement. Raw record bytes never become commands or signal targets.

Keep at most 100 publication observations with the existing 0.01-second polling
interval. Polling waits for atomic final publication; it does not make a partial
record valid. A present but invalid record fails immediately, rather than retrying
until its bytes become acceptable. Inspection failure differs from absence and
fails. No fresh control launch or evaluator attempt retries this handoff. These
counts are finite attempts, not a claim that command execution adds no elapsed time.

### R3. Own the parent operation before launching the control

Add one private outer-control context, separate from SETUP_CONTEXT and the real
managed evaluator lifecycle. Enter it before any launch-related operation. While
it is active, the outer HUP/INT/TERM handlers record the first signal and return;
they do not run the general scratch-deleting cleanup or launch another process.
At the next safe operation boundary, a recorded signal makes the case terminal.
Use the existing dispatch entry only to select this private context first; all
other callers retain their current dispatch semantics. Generated control copies
start with the outer-control context inactive.

Guard start-time capture, directory/capture/FIFO setup, FD opening, job-control
changes, asynchronous launch, publication inspection and record consumption.
No operation with an owned child may escape through unhandled errexit. Keep launch
and immediate `$!` capture in one small function. Between asynchronous launch and
saving `$!`, only the assignment and record-only traps may run: no command
substitution, background helper or diagnostic can change the last-job identity.
Record launch failure distinctly from an acquired job. Always restore the parent's
prior job-control setting, including failed startup.

A saved `$!` is a Bash job handle for wait and evidence, not a promise that the OS
has reserved that numeric PID. Bash can reap asynchronously before explicit wait.
This design therefore never sends TERM, KILL, CONT or a group signal to the outer
control using the saved number. Do not add kill-zero or ps followed by kill as a
supposed PID-reuse guard. Existing signals inside the original control/evaluator
matrix are unchanged and retain their own accepted ownership requirements.

### R4. Make abort and possible release explicit

Keep the existing private start FIFO and inherited FD7. Both sides currently open
it read/write; parent close or pathname removal does not prove child EOF. Do not
use that false assumption as a cleanup mechanism.

Install the child gate and its failure handling before publishing identity. After
successful final publication, use one checked builtin `read` with an integer
three-second timeout. No evaluator work happens between publication and this read.
This gives the parent's existing roughly one-second publication polling scale
additional time for strict parsing and release; the gate does not share an equal
one-second expiry with that polling loop. The timeout is never restarted after a
partial token, signal or read failure. An already expired gate cannot be revived.

The three seconds are a finite ordinary admission budget, not a guarantee that
arbitrary scheduling delays succeed. A delayed or failed handoff must take the
real non-release exit and be waited for, rather than retrying. The parent stops
publication observation at its existing attempt cap, checks any recorded signal
before release, and preserves write/close failures. A write which races gate expiry
is still possibly-released until actual child evidence resolves it. The unchanged
180-second suite alarm covers setup, gate and direct wait without reset. No new
clock dependency, jobs observer or per-case completion deadline is introduced.
Private negative controls may use a shorter gate timeout, never a longer one.

The gate accepts only a complete `verified` line with successful read status.
`abort`, partial input, read failure, timeout or another token exits nonzero before
any evaluator launch. The child closes its gate descriptor on either outcome.
Before the identity is published, child startup installs private failure handling
and completes the ordinary setup needed for this gate. No evaluator launch occurs
before successful gate validation and installation of the existing managed traps.
A partial failed token write never counts as successful delivery merely because
some bytes reached the FIFO.

The parent has these monotonic phases: preparing, launched, identity-verified,
possibly-released, wait-only, retired-confirmed or retirement-unconfirmed.
Record possibly-released *before* attempting the first `verified` write. From that
point, even a write error may mean the full token arrived; never revert to a
pre-release cleanup assumption. Do not publish a second token after that point.
Guard token write, descriptor close and FIFO removal independently and preserve
any first failure while still proceeding to ownership reconciliation.

Before possibly-released, a terminal condition may send one checked `abort` token
through the existing gate, then close its endpoint. An abort write error still
fails; the child's finite gate read supplies the independent non-release exit
path. This does not depend on EOF. The final control record must not authorize
signal delivery, and no malformed identity is repaired or normalized to continue.

After possibly-released, the control may already own an evaluator in another PGID.
The outer parent must not kill the control or its original group and call that
reaping the evaluator. Record the terminal condition, stop admission of later
cases, and wait for this control to finish its original case and managed cleanup.
Do not forward the outer parent's pending signal into the original signal matrix:
that could replace the case's own intended signal or alter its existing budgets.
The overall test remains failed even if that control subsequently completes.

### R5. Wait without reviving retired identities

After gate handling, use the existing direct builtin `wait` for the exact saved
job, in the same parent Bash which launched it. Do not use a command-substitution
subshell, a new shell, ps or job-list parsing to manufacture completion evidence.
Bash may have collected the kernel status already; builtin wait reconciles its
saved child status. No other helper may consume this job's wait status.

Preserve the existing 180-second suite alarm across this wait and every interrupted
re-entry. It is the finite whole-test failure boundary; no additional ten-second
completion observer or timeout starts. The released control continues its original
finite case and managed cleanup. A stalled wait exhausting the suite alarm is a
failed run with retained evidence, not a successful cleanup result. Before a wait,
mark scratch as owned by an unresolved child so a signal/EXIT path cannot delete it.
Normal passing controls clear that retention only after actual reconciliation and
required descendant checks. Guard wait/status handling so errexit cannot discard
the first handoff failure or the saved job.

Clear the wait-interrupted flag immediately before each actual wait. While that
wait is active, every trapped HUP/INT/TERM marks it interrupted, even after the first
terminal cause was retained. Preserve the first cause separately. A natural status
above 128 does not by itself mean interruption; use the actual trap flag.
An interrupted wait may repeat only that same job wait, under the original
unrefreshed suite alarm; it cannot resend a signal, republish a gate token or start
another case. Once actual wait completion is
established, retire the live job authority before any elapsed-time computation,
file inspection or diagnostic. A signal between real wait return and retirement
may request another wait on that same Bash job, never a numeric PID signal.
An unexpected status 127 or failed wait is unconfirmed, not successful retirement.

A confirmed direct-child wait does not by itself establish descendant cleanup.
For a valid released control, keep all existing event assertions and actual final
checks for its recorded evaluator/local child identities. Require the original
control's expected status and evidence for a normal passing case. On a terminal
handoff path, report direct wait status separately from available descendant
absence evidence; no missing/malformed event record becomes proof of absence.

An uncertain wait or unconfirmed descendant state produces a named nonzero
failure and preserves the entire case/suite scratch. The existing suite alarm
may terminate the shell without a new diagnostic; its actual timeout status/log
and already retained scratch remain failed evidence, never confirmed retirement.
Neither may trigger numeric-PID fallback, later case admission or cleanup
of a directory still possibly used by a live process. Do not report full retirement
when only the control was reaped. Uncatchable termination of the harness itself is
not a promised cleanup success. Ordinary handoff controls must nevertheless
prove actual retirement; injected observer/wait errors cannot stand in for that proof.

### R6. Keep failures named, bounded and preserved

Use one fixed handoff diagnostic prefix and fixed phase/outcome names. Record the
first operation failure, trapped signal if any, whether a job was acquired, actual
wait status or unconfirmed outcome, and whether release was possible. An observed
failure must never increment the existing control's pass count.

Bound diagnostic excerpts to 256 input bytes per identity/event/stderr source and
at most 2048 emitted bytes for the new handoff failure record. Escape raw bytes;
do not concatenate unbounded files, environment values or arbitrary process data.
Preserve full files inside private scratch for review. Successful existing control
records keep their existing evidence and pass counters. The general outer cleanup
must retain scratch after a handoff failure or uncertain retirement, including
later EXIT, and must never delete it while the control could still be using it.

### R7. Prove the real handoff boundaries

Keep the existing 99-case matrix and add readable private controls for:

1. Pausing the real producer after opening its temporary identity and after a
   strict partial write: the parent cannot observe a valid final record or release
   the control. Completing the same write/rename then permits one normal release.
2. Empty, partial, missing-LF, extra field/line, NUL, oversized, symlink, FIFO,
   directory and failed final-record reads. Each fails with a named diagnostic,
   no evaluator launch, no pass increment, and actual direct-child wait completion. These ordinary
   pre-release failure cases cannot pass by reporting uncertainty instead of
   demonstrating the finite abort/gate-timeout exit. Use a real FIFO with no writer
   and a real directory to prove rejection without blocking on open or content
   read, under the same bounded private control and unchanged suite alarm.
3. HUP/INT/TERM before launch, immediately after real asynchronous launch before
   saved-owner publication, and after capture. Verify the actual job retained;
   no intervening background helper may supply `$!`. Zero/one launch as appropriate,
   no unverified release, terminal suite status and confirmed expected cleanup.
4. Actual failed abort write, child gate timeout, and failed `verified` writes
   before bytes, after a real strict prefix, and after the complete real line was
   delivered but before the wrapper returns failure. Distinguish no release from
   possible release using real child events, not only a parent's phase variable.
   Each ordinary failed-write control must demonstrate actual direct-child wait
   completion; a possibly released evaluator also requires its real managed
   completion and existing descendant checks.
5. HUP/INT/TERM immediately before/after first release write, after full delivery
   before parent state processing, and during descriptor close/path removal.
   Include a released real control which owns its separate evaluator PGID. Verify
   the outer parent does not signal a stale control or claim group cleanup from
   killing that control. Its terminal status survives real managed completion.
6. A signal interrupting the real parent's pending wait once, plus a signal after
   actual wait return before retirement and a natural signal exit status. The
   controlled child uses an owned acknowledgment/release protocol and finite exit;
   the parent uses the same real builtin wait/status path as ordinary controls.
   Require no signal/token repetition and no false interrupted-wait classification.
   A genuine final reap and later file/diagnostic error cannot restore numeric
   signal authority.
7. Failed/uncertain completion and missing/malformed cleanup evidence. These are
   terminal non-success with retained directories and no later launch. Controlled
   status/observer/wait errors supplement real process cases; they are not actual
   death proof or a substitute for the ordinary-error retirement proofs above.
8. Delay real final publication using acknowledgments and prove the gate has its
   separate post-publication interval. Cover actual gate expiry, read failure and
   signal-interrupted wait/status reconciliation. Use actual native
   Bash waits for ordinary completion controls; a forced status 127 or observation
   error tests retained failure only. Confirm that interrupted re-entry does not
   reset the suite alarm or admit another case.

Private controls may wrap the same real operations and signal their own test
process at the named boundary. Write-failure controls perform the real indicated
bytes first when testing postwrite uncertainty. A guessed sleep, fabricated PID,
stubbed successful wait or synthetic completion record cannot prove actual cleanup.
Use private acknowledgment channels to hold exact producer/write/wait boundaries;
keep their descriptors and children owned and bounded. Do not modify the evaluator.

Run the complete focused suite on the supported Linux CI and existing Darwin Bash
host. Record exact source/tool identities, original and new case counts, actual
statuses, elapsed time and retained failure logs. All new controls fit the same
180-second alarm; shorter private negative-control deadlines may make a timeout
observable without extending any operational budget. Missing proof fails, never
skips. Required CI, ShellCheck 0.11.0, schema and rename checks remain required.

## Design

Keep the change behind the private outer-control handoff in the existing test.
Parent-only state handles admission, bounded record parsing, possible release,
wait retirement and preserved diagnostics. The generated control publishes the
complete identity and uses a finite gate read before its existing managed case.
The original evaluator lifecycle functions and signal matrix retain their behavior.
The components entry explains this test repair and its evidence limits.

No new restore-critical path or external helper file is shipped. Small generated
private fixtures remain inside the focused test. Reuse existing Bash, Perl and
system utilities; no new download, interpreter installation or dependency selector.
The plan must inventory complete added controls and estimate readable source size;
this draft does not grant a size exception or implementation authority.

## Out of scope

Evaluator/policy/decision changes, setup retry changes, workflow changes, generic
supervision, process-tree killing, credentials, installation, host configuration,
activation, real targets, #271 continuation and the pending resolver cache exception.
Do not change accepted artifacts from other initiatives to make this repair pass.

## Areas of concern

Risk is high: private test code exercises process identity and real signal cleanup.
The current continuing Roadmap authority covers an in-scope repair, but independent
G2 and a separately accepted high-risk plan still precede code.

This draft deliberately does not promise that Bash's saved numeric PID remains
reserved until explicit wait, nor that closing an O_RDWR FIFO produces EOF. Avoiding
parent-side numeric signals prevents those claims from becoming unsafe cleanup.
A possibly released child may own an evaluator outside its original group, so its
normal managed completion remains necessary evidence.

The selected design is wait-only after possible release. A normal generated control
already has a finite original case path and managed evaluator cleanup. An outer
handoff failure does not interrupt or replace that path: stop further admission,
preserve its first cause and wait for the actual control and descendant evidence.
Before release, checked abort or the independent finite gate deadline supplies the
ordinary child exit. This is smaller than adding a cancellation marker and avoids
changing the 54 controls' signal placement or lifecycle behavior.

The required proof is for ordinary malformed records, actual failed writes and
single controlled signals. Those cases must really retire their owned children.
A deliberately injected wait/observation error must fail and retain evidence; it
cannot truthfully claim death. Arbitrary kernel stalls, uncatchable harness death
or indefinitely repeated external signals are not promised recoverable outcomes.
The unchanged suite alarm remains a failure boundary, never cleanup evidence.
No ordinary path found in this source analysis requires an additional cancellation
channel; if actual ordinary-case proof exposes one, return to design with that
specific failure rather than accepting unconfirmed retirement or adding a supervisor.

The current source's returning outer signal cleanup and the release-before-state
window are addressed above. Actual portable wait/status behavior and all deterministic
boundary controls still require implementation proof. If they cannot meet the
specified ownership and time bounds, preserve the result and return to design.
There is no demonstrated conflict with the north star's inactive, portable and
capability-separated goals. This source-based design is not implementation proof
or independent acceptance.
