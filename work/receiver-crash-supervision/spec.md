---
intent-blob: ae56dfd965dd4fb2a5b2cf726769954d2a5052cc
risk: high
drafted: 2026-09-17
---

# Spec: Supervise the receiver's two crash-test processes

Tracks #347. G1 merged in PR #348. This is one test-harness repair. A separate
high-risk plan must be accepted before code. The original failed CI attempt stays
failed; slow setup remains the leading explanation, not a proved internal cause.

## Requirements

1. Repair the existing `before` and `after` crash pair without removing either
   case or changing its real materialization, publication boundary, outward-output
   check or recovery assertions. Keep the complete later receiver matrix and its
   response, invocation-count and evidence-preservation oracles unchanged.
2. Observe actual readiness at the existing stored-result publication boundary.
   A process starting, a delay ending or an expected result is not readiness.
   Use finite monotonic deadlines; setup expiry fails without another attempt.
3. Give each case one private process owner. Register launch ownership before
   fallible work, retain safe signal authority until cleanup, and retire that
   authority before reaping its group leader. Never signal an unrelated group,
   the supervisor's own group, or a retired numeric identity.
4. Preserve the real replay exit status when observed, including intentional
   SIGKILL. Terminate and verify absence of the case's contained descendants.
   Distinguish directly reaped children from descendants whose absence is observed.
   Missing required status or failed cleanup is not a successful case.
5. Handle ordinary INT and TERM during launch, setup, readiness, termination,
   reaping and diagnostic publication without repeating a launch or reviving old
   signal authority. Preserve the original failure or interruption as the primary
   outcome and report any cleanup failure separately.
6. Emit bounded diagnostics before deleting disposable scratch. Keep scratch when
   cleanup or diagnostic publication is unconfirmed. No pass follows a supervision,
   capture, preservation or cleanup failure. Prove these paths on native Darwin
   and required Linux CI using the actual private supervisor and real children.

## Design

### Scope and compatibility

Only `scripts/test/replay-materialization-result.test.sh` may change during
implementation. Generate private Python helpers inside its existing temporary
directory. Keep one supervisor implementation for this crash pair and its new
controls; add no shipped helper, public option, environment override or framework.
Existing Python 3.9, Bash 3.2 and POSIX facilities are sufficient. The fixture
builder and product entrypoints remain unchanged.

The new lifecycle guarantee applies to the two formerly shell-owned crash cases
and their supervision controls. Existing concurrent and later CP4c cases retain
all their behavior and proof; this work does not claim to repair every process
launch in the suite. Their helper code is not copied into a second implementation.
Any wider migration returns to scope review.

### One supervisor, with a persistent group leader

Use a private Python coordinator with a small keeper mode in the same generated
helper. The coordinator directly owns the keeper. The keeper directly owns the
real loaded replay wrapper. It remains alive after reaping that replay until the
coordinator terminates the keeper's group. This separates the replay's actual
result from the lifetime that reserves the group's identity.

The coordinator launches the keeper with `start_new_session=True`, without shell
command construction or `preexec_fn`. Python documents that this performs
`setsid()` before execution. The keeper reports its PID, PGID and session ID over
a private channel and waits for admission before launching any replay or other
fixture descendant. The coordinator checks positive PID=PGID=session ID against
its direct child handle and OS group/session queries, and excludes its own group.
[Python subprocess contract](https://docs.python.org/3/library/subprocess.html).

Create control endpoints and install deferred INT/TERM handling before launch.
Keep the returned child handle strongly referenced and publish ownership before
logging, parsing a handshake, opening more files or releasing admission. A signal
handler only records a pending signal; it never raises through launch or performs
cleanup itself. A pending signal before admission forbids the replay launch.

Before admission, only the exact owned keeper child may be killed and reaped.
Its protocol forbids descendants in that state. A missing or invalid identity
handshake fails closed and does not authorize a group signal. Admission publishes
the verified group ownership before the command that permits the replay launch.

After admission, the coordinator must not call `poll`, `wait`, `communicate`, a
Popen context-manager exit, or another reaping operation on the keeper until it
has finished its final group signal and retired signal authority. It neither
ignores SIGCHLD nor installs an automatic reaper. Retain the direct child even
when its channel reports failure or EOF. A still-owned unreaped keeper prevents
its PID from being reused; a live keeper also keeps its group present. POSIX
defines process/group identity reuse separately from a saved integer.
[POSIX identity lifetime](https://pubs.opengroup.org/onlinepubs/009696699/basedefs/xbd_chap04.html).

The keeper may poll and reap its replay child. It alone signals that child by
its owned handle, before retirement, and reports the actual wait result. It never
uses a saved replay PID again after that wait. Thus an early replay exit can be
reported exactly while the keeper still reserves the group for descendant cleanup.
Do not depend on `os.waitid`/`WNOWAIT`: Python only added macOS `waitid` support in
3.13, while the native fixed interpreter is 3.9.6.
[Python waitid availability](https://docs.python.org/3.13/library/os.html#os.waitid).

### Readiness and bounded execution

Pass the existing real replay arguments to the existing loaded wrapper. Its pause
mode acknowledges the exact `before` or `after` stored-journal boundary, including
case identity, and holds there. Bind the acknowledgment to this invocation through
fresh private control state. Control descriptors must not leak into materializer,
Git or helper execs. Reject malformed, duplicate, wrong-case or out-of-order control
records. An old file cannot satisfy readiness for a new case.

Add observations at wrapper entry, materializer entry, materializer return and
publication readiness without changing the returned bytes or skipping any call.
Call these observations, not proof of progress inside an uninstrumented subprocess.
Readiness remains the publication hook, not one of the earlier phase observations.
Keep both original before/after recovery assertion bodies and their output paths.

Use these fixed private limits, measured with `time.monotonic()`:

| Phase | Limit | Start and outcome |
| --- | ---: | --- |
| Keeper admission | 5 seconds | Starts before keeper launch; missing acknowledgment fails before replay admission. |
| Real setup | 60 seconds total | Starts before keeper launch, including admission; expires if actual publication readiness is absent. |
| Ready hold | 20 seconds | Starts at actual readiness; missing deliberate crash command fails. |
| Cleanup | 10 seconds total | Starts at cleanup entry; includes replay-stop acknowledgment, keeper wait and group-absence observation. |
| Diagnostic publication | 5 seconds | Bounded control/output drain; missing completion prevents scratch deletion. |

No phase resets the setup deadline. Readiness does not restart setup. A keeper
stop request receives at most the first five seconds of the shared cleanup budget;
the final group signal and remaining observations use the remainder. Deadlines
bound permitted waits, not OS scheduling or uninterruptible syscalls. Do not claim
a hard wall-clock guarantee on an unresponsive host.

The 60-second allowance is an engineering margin around observed real work, not a
new product latency contract. The failed run spent 12.169 seconds from suite start
through first delivery and 13.320 seconds between legacy and concurrent passes.
The prior Linux run spent 19.376 seconds on both crash setups and reopens together.
Those are composite intervals, not per-stage timings; 60 seconds gives more than
four times the larger single-work interval while preserving a decisive hang bound.
The old roughly ten-second loop had less margin than nearby successful work.
Record actual new phase timings on both platforms. If these limits cannot support
the complete proof, retain the failure and amend the design; do not tune during
execution or rerun until green.

### Termination, retirement and absence

On genuine readiness, command the keeper to SIGKILL its exact live replay child,
wait for it and report its actual status. Require `-SIGKILL`, zero outward stdout
and the original recovery assertions. A different exit fails. This is a real
replay crash; terminating only a helper does not count.

On timeout, early exit, interruption or control failure, enter cleanup once. If
the keeper is responsive, request termination and reaping of its replay child;
an already-reaped replay reports its saved status without another signal. Record
missing replay status as unknown, never manufacture `-SIGKILL` from a kill request.

The coordinator then sends at most one SIGKILL to the admitted keeper group while
it still owns the unreaped keeper. Publish signal-attempt state before the syscall,
so interruption cannot duplicate the signal. Retire PID/group signal authority
before entering keeper wait, even if signaling failed. Wait only for that exact
child with the remaining deadline. An interrupted wait may continue under the
same deadline; it cannot restore signal authority or launch another fixture.
Record the keeper's actual exit separately from the replay's exit.

After keeper reap, use read-only group probes until absence is proved by ESRCH
or the shared deadline expires. Success, EPERM, malformed observation or another
error is not absence. No signal is permitted after keeper retirement, including
when the group remains present. A reused group could cause conservative failure;
it must never receive a signal. Cleanup is successful only with confirmed keeper
reap and group absence; report replay reap independently.

This boundary contains the fixed replay/materializer descendants because they
inherit its group and do not create another session/group. Review the actual
called sources and prove containment with a real nested fixture. It is not a
sandbox for arbitrary children that escape with setsid/setpgid. Escaping children,
uninterruptible processes and uncatchable supervisor SIGKILL cannot gain a cleanup
guarantee. Unexpected containment or cleanup failure stops and retains scratch.
Do not kill by command name, scan-and-signal arbitrary PIDs, or claim the coordinator
can directly reap grandchildren on both platforms.

### Shell ownership and ordinary interruption

During each supervised case, the Bash caller owns one coordinator invocation.
Create a private cancellation path and mark the managed context before launching
it. Shell INT/TERM/EXIT handling records cancellation there and waits for that
same invocation to report cleanup; it does not signal a saved PID or group.
An interruption between launch and assigning its job handle must be deferred
until ownership is recorded. No trap may remove the temporary tree while that
invocation is unresolved. Repeated signals preserve the first interruption.

The coordinator observes cancellation and handles its own INT/TERM through the
same cleanup path, including before admission. Its internal deadlines remain
active while Bash waits. Define the exact Bash wait-interruption handling in the
plan and test it on Bash 3.2; a returned shell status alone is not proof the child
completed. On ordinary completion, clear active ownership only after consuming
the coordinator's status and sealed cleanup/diagnostic record. A missing record
fails and keeps scratch. Other suite phases retain their existing cleanup behavior.

### Diagnostics and scratch preservation

Keep actual replay stdout and stderr separate from control records. Drain them
without pipe deadlock; retain at most 64 KiB per stream and count observed bytes.
An overflow becomes a named supervision failure and triggers cleanup. Never turn
truncated output into valid recovery data. Limit control records to 4 KiB each
and 64 KiB total per case; excess or malformed data fails. The two normal crash
cases still require exactly zero outward stdout before deliberate SIGKILL.

Emit a structured case record with fixed case/point, last acknowledged phase,
elapsed times, deadline outcome, owned identity, requested signal, actual observed
replay/keeper statuses, which children were reaped, group-absence result, stream
counts and excerpts, and primary/cleanup/diagnostic failures. Unknown fields stay
unknown. Keep control records separate from product stdout and pass accounting.

Emit the bounded failure record before scratch removal. If emission, cleanup or
the shell handoff fails, retain the private temporary tree and print a short
retention notice when possible. Do not delete it to obtain a clean assertion.
After confirmed cleanup and diagnostics, ordinary disposable-root removal is
allowed. Preserve original failure logs in manager proof records regardless.
Public comments use fixed case labels and proof hashes, not raw local paths or
fixture payloads. This is test evidence, not product execution provenance.

### Proof and review size

The plan must map every original assertion and named receiver case to unchanged
proof. Add controls below using the actual supervisor. Private injected faults
exercise selection/error handling; real owned children establish lifecycle facts.

| Control | Required proof |
| --- | --- |
| Both real crash windows | Actual readiness, real replay exit -9, zero outward stdout, original missing-before/stored-after recovery and preservation. |
| Delayed real readiness | Hold at an acknowledged pre-publication test gate for at least 12 measured seconds, then allow the actual readiness hook within 60 seconds; keep both real crash outcomes. No guessed crash timing. |
| Early replay exit | Nonzero actual status and stderr preserved; keeper remains owned; no ready/pass; complete cleanup. |
| Genuine watchdog | Real child and nested descendant stay alive without readiness through the actual 60-second limit; one launch, failure, contained cleanup and retained diagnostic. No shortened substitute as the sole proof. |
| Admission failures | Missing/wrong identity and interrupted admission cause no replay launch and no group signal; exact owned keeper cleanup only. |
| Parent INT/TERM | Separate signals to Bash and coordinator at launch handoff, setup, ready hold, cleanup before signal, retirement/wait and diagnostic handoff; first outcome retained, no duplicate launch/signal or early scratch removal. |
| Replay retirement | Replay naturally exits before a stop request; actual status retained and no signal to its retired PID. |
| Keeper failure | Unexpected channel EOF/exit after admission; final group cleanup uses retained ownership; unknown replay status remains unknown. |
| Ownership rejection | Inert synthetic wrong/own/retired identities select refusal with zero actual signals; real group controls separately prove containment. |
| Cleanup errors | Inject signal error, interrupted/exhausted wait and non-ESRCH probe outcomes; fail, retain scratch, never re-signal after retirement. |
| Diagnostic errors | Stream/control overflow, malformed record and failed diagnostic/scratch handoff remain failures with no hidden pass or deletion of unresolved evidence. |

Boundary acknowledgments control signal placement; do not use short sleeps to
claim a particular syscall was interrupted. Tests after a real wait-return boundary
and supplementary interrupted-wait controls must label exactly what they prove.
Proof observes known fixture descendants without signaling them after retirement.
Native Darwin and Linux must each demonstrate direct-child reaps and contained
group absence, including a replay that has already exited before cleanup.
Failure controls need separately owned outer rescue gates or finite fixture
lifetimes so deliberate cleanup faults do not abandon unbounded processes. Record
that rescue separately; it cannot count as the supervisor's cleanup success or
become a fallback in either real crash case.

On the final committed head require the complete receiver suite on native Darwin,
the full native `scripts/test/run-all.sh` run, pinned ShellCheck 0.11.0, applicable
structure/diff checks and every required original CI job. Retain full logs, exact
head/base, tool identities, case inventory, phase timings and cleanup records.
No skipped original case, rerun replacing a failure, or historical pass satisfies
the final proof. Independent review reads complete evidence and the source diff.

Review size: `accepted-exception`, proposed 700–1,100 added plus removed lines,
all in the one test file. The estimate allocates 260–360 lines to the private
coordinator/keeper, 90–150 to wrapper/shell integration and diagnostics, 300–470
to controls, and 50–120 removed/replaced lines. Shared setup may reduce duplication,
but cannot remove original oracles. The range is a forecast, not a target.
Unexplained overrun, another implementation path or changed meaning pauses work
for a separate amendment; readable proof takes precedence over compression.

## Out of scope

No product replay, materializer, fixture-builder, profile/source pin, workflow,
CI-gate, policy or timeout change outside this private supervisor. No generic
process manager, new dependency, automatic retry, test skip or public test switch.
No install, activation, credentials, network expansion, real target, release or
deployment. A product defect discovered by better diagnostics returns to scope
review before product code changes.

Preserve PR #346, the candidate plan attempt and merged receiver history. Their
base may move as external context; do not rewrite or silently recreate them.
Frozen #183 and unresolved dirty #271 remain excluded. Required review, exact
artifact hashes, protected CI and the one-manager rule remain in force.

## Areas of concern

Risk is high because the repair controls process/group identity and signal safety.
G2 accepts this design and risk; a separate high-risk plan still precedes code.
The named Roadmap manager's delegated acceptance applies without expanding it.

The keeper is a private test ownership mechanism for fixed contained processes,
not an exceptional product workaround or reusable API. It avoids a native Python
version upgrade and keeps the real replay exit distinct from group lifetime.
Its admission, signal-retirement and shell-cancellation boundaries require focused
review. A design that reaps the keeper early or depends on a guessed group is not
an equivalent implementation.

The design answers the intent's supervision, supported-signal, budget, diagnostics
and regression questions with explicit limits. It does not establish the missing
historical stall location or guarantee cleanup after parent SIGKILL. If native
ownership/absence proof or the shell handoff cannot meet this contract, preserve
the attempt and return to design rather than introducing a platform skip or a
second cleanup path. No conflict with the accepted north star is identified.
