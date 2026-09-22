---
intent-blob: ae56dfd965dd4fb2a5b2cf726769954d2a5052cc
risk: high
drafted: 2026-09-21
---

# Spec: Own the receiver's crash-test processes and retain their evidence

Tracks #347. Keep the accepted intent and its one-file test-harness scope. A
separately reviewed high-risk plan must land before implementation. Historical
failed runs remain failed; their internal delay location is still unknown.

## Required outcome and scope

Change only `scripts/test/replay-materialization-result.test.sh`, including its
generated private Python helper and loaded-wrapper pause mode. Repair the early
`before`/`after` pair. Preserve all 13 original outer assertions, all 654 original
named matrix cases, their order and their recovery, invocation-count, output and
preservation oracles. New controls supplement that inventory. Other concurrent
and later CP4c launches keep their existing behavior and are outside this
lifecycle repair.

Both crash cases must use real materialization, acknowledge their existing stored
result publication boundary, then prove the replay actually died from SIGKILL.
Require complete capture with zero outward stdout and the original distinct
missing-before/stored-after recovery assertions. A start, elapsed delay, expected
result, requested signal or empty partial output file is not this proof.

Use the existing native Python 3.9/Bash 3.2 facilities and required Linux CI. Keep
product code, fixture builder, source/profile pins, workflows, dependencies and
CI gates unchanged. Add no public option, environment override, process framework,
automatic retry, skip or platform exemption. A wider or product repair returns
to its scope gate.

## One owner and one retained process identity

Use one private Python coordinator that directly launches the loaded replay
wrapper with `start_new_session=True`. The wrapper is the session/group leader
and runs the real replay in that same process. There is no keeper. Before it
loads or calls product code, the wrapper waits on a private one-byte admission
gate; until release it may create no descendants.

Create private channels and install deferred INT/TERM handling before launch.
Handlers record the first signal without raising through ownership transitions.
Explicitly restore normal SIGCHLD child-status retention and unblock INT/TERM in
the coordinator. Keep its child handle strongly referenced and record ownership
immediately after launch, before logging or other fallible work. Ordinary
coordinator exceptions use the same bounded cleanup path, including exceptions
during setup, capture and publication.

Verify positive child PID = PGID = session ID against the direct child handle
and OS queries; exclude the coordinator's own group. Failed verification never
authorizes a group signal. The still-gated exact child can be stopped and reaped
without descendants. Publish verified group ownership before attempting the
single admission byte. Observed cancellation before release forbids product
execution. An uncertain release uses owned-group cleanup, never an assumption
that no descendant could have started. The plan must define the bounded release
and cancellation ordering; independent events need no fictional atomic order.

After possible admission, retain the replay unreaped until the final group
signal is finished and signal authority is retired. Do not poll, implicitly reap,
drop the child handle, or install an automatic reaper. EOF and phase observations
may trigger cleanup but are never wait results. A naturally exited unreaped
leader still reserves its identity, so the same owned group can be cleaned even
when descendants outlive the replay. This follows the POSIX process/group lifetime
rules; it does not depend on native `waitid` support.
[POSIX identities](https://pubs.opengroup.org/onlinepubs/009696699/basedefs/xbd_chap04.html),
[process lifetime](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap03.html),
[Python session creation](https://docs.python.org/3.9/library/subprocess.html).

On actual readiness, failure, timeout or cancellation, enter cleanup once. For an
admitted case, record and attempt at most one raw group SIGKILL while the leader
is still owned and unreaped. This kills the actual replay as well as its contained
descendants. Retire all signal authority even on a signal error, then obtain the
exact direct child's authentic terminal wait status. Missing status, including
ECHILD, stays unknown and fails; never synthesize zero or -9. An interrupted wait
may continue under the same deadline without another signal or launch.

Cleanup requires an authentic direct reap and observed group absence. After
retirement use only read-only group probes; only ESRCH establishes absence.
Success, EPERM, another error or a lingering zombie is not absence. Never signal
again after retirement, signal by name, or claim direct reaping of grandchildren.
Review the actual replay/materializer/core/jq/Git route and prove nested fixture
containment on both platforms. These fixed children inherit the group and may
not escape it. Unexpected escape or unconfirmed cleanup fails and retains scratch.

This contract covers ordinary coordinator errors and INT/TERM, not coordinator
SIGKILL, host/power loss, arbitrary escaping programs or uninterruptible kernel
work. Deadlines bound permitted waits rather than guaranteeing host scheduling
or filesystem syscall completion.

## Readiness, capture and handoff

Bind phase/readiness records to fresh private invocation state. Keep control
descriptors out of descendant execs. Reject malformed, duplicate, wrong-case or
out-of-order records. Observe wrapper entry, materializer entry/return and the
actual publication hook without changing calls or returned bytes. Earlier phase
records locate the last observation; they do not prove internal subprocess progress.

Use fixed monotonic budgets: admission 5 seconds and total setup 60 seconds, both
starting before launch; ready hold 20 seconds from actual readiness; cleanup
10 seconds from its first entry; diagnostic publication 5 seconds from its first
entry. Include admission in setup; never renew a deadline or retry a case. The
60-second setup margin exceeds nearby successful composite work intervals of up
to 19.376 seconds; those measurements do not identify the failed internal stage.
Record actual new phase times on Darwin and Linux. An inadequate bound remains a
failure and returns to the design gate.

The coordinator drains replay stdout/stderr separately and concurrently through
termination. Retain at most 64 KiB per stream and count bytes actually observed.
Control records are at most 4 KiB each and 64 KiB total. Overflow is a named
failure; bounded draining must not starve cancellation or deadlines. Capture is
complete only after both actual EOFs and successful accounting of preceding
bytes. Reaping is not EOF. Forced closure, read/write error or a missed drain
deadline fails, even if files are empty and cleanup later succeeds.

Bash records managed context before its asynchronous coordinator launch. It
publishes permission to proceed only after saving that invocation's job handle.
INT/TERM/EXIT handling sends cancellation through private state and waits for
that same job; it never signals a saved PID/group or removes unresolved scratch.
Defer interruption through launch handoff, retain the first outcome, and handle
Bash 3.2 interrupted waits and `set -e` explicitly. Direct coordinator signal
proof starts after handler installation; Bash cancellation covers the earlier
handoff. A completed shell wait and this invocation's valid completion record
are both required. Neither alone proves
cleanup. A failed cancellation write or ambiguous handoff fails and retains scratch.

Emit a bounded structured record before deletion: case, last phase, elapsed
times, deadline outcome, owned identity, signal attempt, actual wait status,
reap/absence/capture facts, stream counts/excerpts and separate primary, cleanup
and diagnostic failures. Unknown facts remain unknown. Keep excerpts to 4 KiB per
stream and the emitted record to 16 KiB. A blocked/broken sink or failed record
publication cannot hang the supported path or seal success. Restore any temporary
output-descriptor changes before completion. Retain scratch if cleanup, capture,
diagnostics or shell handoff is unconfirmed; report retention when output permits.
Only confirmed completion permits ordinary disposable-root removal. A removal
failure remains visible. No cleanup action may hide the original failure.

## Requirement-to-proof map

Use the actual coordinator and shell handoff. Keep an expanded named inventory;
shared fixtures may serve several assertions, but each required outcome remains
explicit. Boundary acknowledgments establish where a signal or fault was applied.
Do not claim a syscall interruption from a sleep or a later observation.

| Proof | Required evidence |
| --- | --- |
| Original receiver behavior | Preserve the complete named 654-case/13-assertion inventory and original oracle bodies, not counts alone. |
| Both real crash windows and delayed readiness | At each real case, acknowledge a pre-publication hold of at least 12 measured seconds, then actual readiness within the unchanged setup bound, authentic -9, both EOFs, zero stdout and the original recovery assertions. One launch may prove both the delay and that crash window. |
| Early exit and surviving descendants | Known nonzero replay status and exact small output tails; a real nested descendant remains alive when the leader exits. Retain the leader through group cleanup, drain buffered bytes through EOF, prove real absence and no post-retirement signal. |
| Genuine watchdog | One real child with nested descendant remains without readiness through the actual 60-second setup limit. Require failure, bounded cleanup and diagnostics; no shortened substitute supplies this proof. |
| Admission and identity safety | Cancellation before admission prevents product execution. Missing/wrong/own-group identity and retired authority refuse unsafe signals. Failed release cannot lose ownership. Real contained children prove cleanup separately from inert identity/error injection. |
| Ordinary cancellation and coordinator errors | INT and TERM to Bash and coordinator at launch handoff, setup, ready hold, cleanup-before-signal, retirement/wait and diagnostic handoff. Also cover pre-admission cancellation, repeated signals, the wait/completion race, shell error and coordinator exceptions before admission, while owned and after retirement. Preserve the first outcome with no duplicate launch/signal or premature deletion. |
| Cleanup failures | Signal error, interrupted/exhausted wait, missing wait status and non-ESRCH probes fail or remain pending within the original bound as appropriate; unknown facts never become success. Retain scratch on unconfirmed cleanup. |
| Capture and evidence failures | Both stream limits, control limits and invalid records; buffered tails, nested stream writers, incomplete capture, blocked/broken diagnostic output, failed record/completion publication, descriptor restoration, cancellation write and shell handoff. Every failure keeps its primary evidence and prevents a pass or unresolved deletion. |
| Inherited process state | Ignored SIGCHLD is reset so a real nonzero status is observed; inherited blocked INT/TERM are unblocked and delivered at acknowledged coordinator boundaries. |

Deliberately broken cleanup controls need separately owned rescue gates or finite
fixture lifetimes for every possible survivor. First assert the coordinator's
failure and scratch retention, then record rescue separately. Rescue failure
fails the suite; rescue never supplies cleanup credit or a real-crash fallback.

On the final committed head, run one complete native focused receiver suite,
pinned ShellCheck 0.11.0 and applicable structure/diff checks. Required Linux CI
must run all configured full-suite shards, checks and aggregate `ci` on the
exact head/base. No original test is removed; a duplicate full native run of
unrelated suites is not required without a new finding. Retain all failed runs,
full logs, exact source/tool identities, original and new inventories, phase and
ownership records, capture/retention evidence and proof hashes. Independent review
reads the complete raw evidence and diff; summaries do not replace it.

Review size: `accepted-exception`, forecast 600–900 added plus removed implementation
lines in the one file. The plan must support that forecast with a readable work
breakdown before code. It is not a compression target or permission to omit proof.
An unexplained overrun, changed guarantee or extra path returns to amendment.

Preserve recorded prior attempts, frozen #183 and unresolved dirty attempts.
Keep exact artifact hashes, separate authors/reviewers, protected PR/CI gates,
claims, round limits and the one-manager rule. No installation, activation,
credential/network expansion, real target, release or deployment is included.
