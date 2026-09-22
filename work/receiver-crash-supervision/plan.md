---
spec-blob: 72fdbc04d18bd5e9b434087c79e8c7bac29c1605
drafted: 2026-09-21
---

# Plan: Own the receiver's crash-test child until cleanup is complete

Tracks #347. Risk: high. Gate mode: `artifact-high`.
G1 intent blob: `ae56dfd965dd4fb2a5b2cf726769954d2a5052cc`.

This plan changes only `work/receiver-crash-supervision/plan.md` on the preserved
`ystack/plan/receiver-crash-supervision` branch. Independent review and the
protected plan merge precede implementation. The manager records the accepted
artifact tuple, current plan-base and claim under AGENTS.md. A moved base before
first code needs fresh independent base acceptance. Preserve existing attempts;
do not reset, rebase, replace or claim acceptance as the author.

## Scope and work allocation

Implementation changes only `scripts/test/replay-materialization-result.test.sh`.
Generate one private Python helper in its existing temporary directory, containing
the coordinator and small control-fixture modes. Adapt the loaded wrapper's
`pause` mode and the early `before`/`after` launch pair. Keep the other concurrent
and later CP4c launch paths unchanged. Add no keeper, process framework, public
interface, product change, fixture-builder change, pin update or workflow change.

Implementation `review_size: accepted-exception`, forecast **600–900 added plus
removed lines**, allocated to readable work as follows:

| Work | Added or removed lines |
| --- | ---: |
| Direct-child coordinator, deadlines, capture and evidence | 230–330 |
| Wrapper admission/observations and Bash ownership handoff | 90–140 |
| Shared real-process fixtures and expanded control assertions | 240–350 |
| Replaced early polling, kill/wait and unconditional cleanup code | 40–80 |

Shared fixtures exercise several outcomes in one launch. The real delayed pair
also proves the two crash windows. These are estimates, not compression targets:
pause for a separate amendment if complete readable work exceeds them or needs a
new path or guarantee. The implementation author cannot amend accepted artifacts.

## 1. Freeze the original proof and containment boundary

Before edits, retain the complete source and ordered named proof inventory:
all 13 original outer assertions, all 654 later cases, and their oracle bodies.
Keep the early pair's missing-before/stored-after recovery checks, candidate
preservation and zero-output assertion. New controls get separate names and do
not replace, reorder or renumber away original coverage.

Record exact source blobs and executable identities at the implementation base.
Read the called route through `delivery/v1/replay.py`, materialize.sh,
object-closure.c, `scripts/core-contract.sh`, the selected core ingress and its jq
modules, materializer protocol, registry and profile resolution. Resolve the
selected generation through existing selection; introduce no new generation pin.
Include shell pipelines/substitutions and actual Python, Bash, Git and pinned jq.
Verify that this fixed route inherits the group: no setsid/setpgid, new-session
launch, enabled job control, daemon or disown. Candidate content stays data.
System binaries are trusted fixed tools, not arbitrary-program containment.
A changed route needs renewed review; an escape fails, never name-based killing.

Keep historical failed runs and preserved attempts, including #346's original
failure, frozen #183 and unresolved dirty work. Their evidence is context, not a
pass for this repair. Do not infer the old timeout's internal location.

## 2. Implement one direct owner and irreversible signal retirement

Use one single-threaded coordinator loop. Before child launch, create private
channels, install INT/TERM handlers that only save the first signal, explicitly
set SIGCHLD to SIG_DFL and unblock INT/TERM with pthread_sigmask. This restores
real child-status retention on the supported CPython; add no waitid, ctypes,
subreaper or dependency upgrade. Use a first-failure setter and separate cleanup
and diagnostic error lists so later faults cannot replace the original cause.

Launch the wrapper directly with `start_new_session=True`, DEVNULL stdin and
separate stdout/stderr pipes. Retain its Popen object and publish direct ownership
immediately on return, before any logging or other fallible action. Its admission
read occurs before importing/executing product code and cannot create descendants.
Verify positive PID=PGID=SID using the handle and OS getpgid/getsid; exclude the
coordinator's own group. Record verified ownership before any admission attempt.

| State | Permitted action |
| --- | --- |
| No child | Await Bash permission within the admission budget; cancellation forbids launch. |
| Gated direct child | Keep the child unreaped. Verification failure or known unreleased cancellation permits one exact positive-PID SIGKILL, retirement and authentic reap; no group signal. |
| Verified, release attempted | Mark possible admission before the one-byte write. Retain group ownership even if the write result is uncertain. No poll or reap. |
| Cleanup entered | Record the first cleanup deadline and one signal attempt. For possible admission, call raw os.killpg once while the leader remains unreaped. |
| Retired | Clear all signal authority in a finally path even after signal error. Only exact wait, stream draining and read-only absence checks remain. |
| Evidence complete or failed | Publish bounded facts and handoff; unresolved facts forbid deletion. |

The final signal, not child liveness polling, ends ownership. A naturally exited
unreaped leader still pins the group identity while descendants survive. Keep
strong references through retirement and status collection. Never use Popen
poll, send_signal, kill, terminate, wait, communicate or its context manager;
native Python 3.9 send_signal/kill/terminate may poll. Do not drop the object into
__del__/_active cleanup or install another reaper. Raw os.kill/os.killpg are used
only through the state-checked one-shot transitions above.

After retirement, use only `os.waitpid(owned_pid, os.WNOHANG)` for the child.
Zero means pending. Require the matching PID and WIFEXITED/WIFSIGNALED before
using waitstatus_to_exitcode and assigning that authentic value to returncode.
ECHILD, unexpected/nonterminal status and other errors remain unknown and fail;
never insert zero or expected -9. EINTR may retry within the original deadline,
without another signal. Keep an unresolved object referenced until role exit.
Require both this authentic reap and observed group absence: only ESRCH from a
read-only group probe counts. Success, EPERM, other errors and zombies do not.
Do not claim to reap grandchildren or use saved descendant IDs for signaling.

Ordinary exceptions at setup, owned execution, capture and publication enter or
continue the same cleanup state without resetting deadlines or signal authority.
An exception after retirement cannot signal again. Collect remaining evidence
where possible, keeping unknowns explicit. Uncatchable coordinator SIGKILL,
host loss, arbitrary escaping programs and uninterruptible kernel work remain
outside the guarantee; deadlines bound waits, not host scheduling or filesystem
syscall completion.

## 3. Bound admission, phases and capture

Use a fresh private 0700 invocation directory and token. Bash start/cancel files
and the final completion record carry that token and case. The coordinator owns
an admission pipe and a wrapper phase pipe; pass only the required descriptors,
close unused ends, and make wrapper control descriptors non-inheritable before
any descendant exec. Accept exactly one admission byte. EOF or invalid admission
cannot execute product code.

Immediately before the one nonblocking admission write, check handler flags,
pending INT/TERM and shell cancellation. Briefly mask INT/TERM around that check
and attempted write, restoring the prior mask in finally without waiting while
masked. Observed cancellation prevents the write. Mark possible admission before
the syscall; any attempted-write failure enters conservative group cleanup,
without retrying admission. A signal or file change after the check can race that
single attempt; handle it after restoring the mask and never claim atomic order
between those independent events. A successfully written byte admits at most once.

The wrapper reports entry, materializer entry/return and actual publication
readiness. Instrument the existing capture call without changing arguments,
returned bytes or invocation count. Preserve the before hook ahead of writing a
stored result and the after hook following the original verifying/stored write.
For each real case, acknowledge a pre-publication hold, measure at least 12 seconds
there, then reach the actual hook within setup. The same launch supplies the
crash proof. Hold readiness until the coordinator's group kill; a fixed wrapper
hold deadline prevents indefinite waiting. Phase records identify observations,
not progress inside unobserved product subprocesses.

| Budget | Absolute monotonic deadline |
| --- | --- |
| Admission 5 s; setup 60 s | Both start at coordinator prelaunch setup, including the Bash start gate; setup includes admission. |
| Ready hold 20 s | Actual readiness time + 20. |
| Cleanup 10 s | First cleanup entry + 10; shared by signal, wait, absence and remaining capture. |
| Diagnostic publication 5 s | First diagnostic entry + 5. |

Do not renew budgets, shorten the watchdog proof or add timeout overrides.
The setup margin exceeds recorded successful composite intervals up to 19.376 s;
record new real phase durations on both platforms without assigning the old hang
to a guessed inner stage. Failed readiness is a failure, never a retry or skip.

Use selectors and bounded nonblocking reads/writes, checking cancellation and the
nearest deadline between bounded chunks. Parse fixed token/case/sequence phase
records; reject malformed, duplicate, wrong-case and out-of-order input. Bound
each control record to 4 KiB and total control data to 64 KiB before extending
buffers. Channel EOF can trigger cleanup but never substitutes for wait status.

Drain stdout and stderr concurrently through termination. Count observed bytes,
retain at most 64 KiB in each existing case output file, and fail on overflow.
Capture succeeds only after both real EOFs and successful accounting of every
preceding byte. Preserve buffered tails and account for nested stream writers.
Forced close, read/write error and cleanup/drain expiry mark capture incomplete;
reap or an empty partial file cannot establish zero outward stdout. Keep draining
boundedly after a primary error where possible, without starving cancellation.

## 4. Complete Bash handoff and evidence before deletion

Replace unconditional disposable-root deletion with a managed-case guard.
Before async launch, Bash saves invocation context and marks handoff active.
Traps record the first INT/TERM or shell failure and defer action through the
launch-to-$! assignment. Only after saving that job handle may Bash publish start
permission; pending cancellation publishes cancel instead. The coordinator cannot
launch the replay before permission. Direct coordinator signal controls begin
after handlers-ready; Bash cancellation covers the earlier handoff.

INT/TERM/EXIT paths write cancellation through private invocation state and wait
for the same Bash job, never kill a saved PID/group. Use Bash 3.2 scalars/arrays
and explicit status branches under set -e, not wait -n/-p or newer shell features.
A trap-interrupted wait is retried only for that job; distinguish it from an
actual completed wait. Ambiguous/127 status, failed cancellation write or invalid
completion fails and retains scratch. Preserve the first shell outcome, disable
recursive EXIT cleanup, and make any removal error visible.

Require both actual completed shell wait and a valid completion record for the
same token/case. The record contains cleanup/capture/diagnostic results and the
coordinator outcome; its existence alone is not proof of exit. Publish it only
after bounded diagnostic emission and restoration of temporary output flags.
A completion race cannot erase cancellation, repeat a launch/signal or permit
premature deletion. If any managed case has unresolved ownership, capture,
diagnostics or handoff, retain the suite root. Ordinary deletion is permitted
only after every managed case is confirmed; report retention when output permits.

Emit a structured record with case, phase, elapsed times/deadline, observed IDs,
signal attempt, raw/decoded wait or unknown, reap/absence/EOF facts, stream counts,
primary failure and separate cleanup/diagnostic failures. Limit excerpts to 4 KiB
per stream and the emitted record to 16 KiB. Bound sink writes with nonblocking
I/O and the diagnostic deadline. Save and restore any changed descriptor flags
in finally, including error paths; Bash traps must not write through that shared
description meanwhile. Blocked/broken output, record write/rename failure and
flag-restoration failure cannot seal success or justify deletion.

## 5. Prove the requirements with shared real-process controls

Expand the following groups into an ordered named inventory before coding.
Use the actual coordinator and Bash handoff; every fixture obeys the same
admission gate. Shared fixture modes may exercise
several assertions per launch; separate records must still identify every outcome,
reached boundary, launch/signal count, authentic status, EOF and scratch disposition.
Use acknowledged boundaries, not sleeps, to choose signal/fault injection points.

| Group | Required controls and evidence |
| --- | --- |
| Real before/after | Two delayed real launches: measured pre-publication hold, real readiness, authentic -9, both EOFs, zero stdout and unchanged original recovery/preservation oracles. |
| Natural exit and nested child | Leader exits 37 with exact small stdout/stderr tails while a real nested descendant remains alive. Record PID/PPID/PGID/SID, keep the leader unreaped through group kill, recover tails through EOF, observe descendant termination and ESRCH absence. No signal after retirement. Nonzero stdout must fail the zero-output oracle. |
| Real watchdog | Child and nested descendant remain without readiness through the actual 60-second setup deadline; one launch, timeout failure, bounded cleanup and complete diagnostics. |
| Admission and identity | Pre-release pending INT, pending TERM and shell cancellation prevent product execution. Missing/wrong identity and own-group identity refuse group signaling. Retired authority refuses all signals. Inject a failed/uncertain single-byte write at the real boundary and require conservative cleanup. Real children prove containment separately from inert identity refusal. |
| Cancellation boundaries | INT/TERM × Bash/coordinator × launch handoff, setup, ready hold, cleanup-before-signal, retirement/wait and diagnostic handoff: 24 explicit records. Add repeated signals, actual wait/completion race, shell error, cancellation-write failure and ordinary coordinator exceptions before admission, while owned and after retirement. |
| Cleanup errors | Scoped signal error, wait EINTR, exhausted wait, missing status/ECHILD, and alive/EPERM/other group probes. No invented status, renewed deadline, repeated signal or deletion while unconfirmed. Distinguish injected EINTR handling from proof of interrupting a kernel wait. |
| Capture and control | Exact limit and overflow for each stream, record and total control bound; malformed, duplicate, wrong-case and out-of-order records. Buffered tails and nested writers cannot become empty complete capture. Forced closure, read/write failure and drain expiry fail even when cleanup later succeeds. |
| Diagnostic and handoff | Real blocked and broken sinks, failed record/completion publication, flag restoration and ambiguous shell handoff. Primary evidence remains distinct; every unresolved case fails and retains scratch. |
| Inherited state | Start the coordinator with SIGCHLD ignored and observe a real nonzero child status after reset. Inherit blocked INT/TERM and deliver both at acknowledged boundaries after explicit unblocking. |

Use real /bin/bash control shells under set -e, including native Bash 3.2.
Combine the natural-exit, buffered-tail and surviving-descendant assertions;
reuse its fixture for bounded fault controls instead of building more roles.
For deliberate cleanup failures, give every possible survivor a separately owned
rescue gate or finite lifetime. First assert supervision failure and retention,
then record and verify rescue separately. Rescue failure fails the suite; it
never supplies supervisor cleanup credit or a fallback for the real crash pair.

## 6. Validate once at the final implementation head

Run one complete native focused suite with full logs on the final committed head:
`/bin/bash scripts/test/replay-materialization-result.test.sh`. Require the full
original inventory plus every new control; no partial run supplies a pass.
Record exact source/tool identities, actual exit, UTC bounds and phase timings.
Run pinned ShellCheck 0.11.0 as the unchanged workflow specifies, applicable
structure/rename checks, and git diff --check/name-only/numstat against the
recorded base. Require only the allowed implementation path and unchanged accepted
artifact blobs. No duplicate full native run of unrelated suites is required.

The current Roadmap CI decision supplies the quick gate for this plan-only PR.
For the implementation, preserve the spec's exact-head/base Linux proof: dispatch
the existing full workflow and require all configured full-suite shards, checks
and aggregate ci to pass. Do not change the workflow or mistake automatic quick
ci for full receiver proof. Keep the separate milestone obligations in
`work/ci-minimum-roadmap/decision.md`; reuse a run only when its exact evidence
satisfies that obligation. Repeat affected proof only after relevant changes,
failures or unresolved concerns, without retrying a case until green.

Retain failed/interrupted runs and a hash manifest covering original source and
inventories, final diff/helper bytes, called-source/tool identities, complete
native/CI logs, expanded controls, phase/ownership/capture records, retained
scratch evidence and original-oracle comparison. Independent review reads the
complete raw evidence and diff in Bugs/Security/Compliance passes. The manager
resolves Important findings, verifies exact head/base and required CI, and records
the protected merge receipt. Preserve claims, round limits, separate roles and
one-manager authority. No installation, activation, credentials, new network
scope, real target execution, release or deployment is included.
