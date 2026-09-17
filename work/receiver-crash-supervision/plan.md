---
spec-blob: d92b9a2c4111e0199544c23a74d771bc535fa7ae
drafted: 2026-09-17
---

# Plan: Supervise the receiver's two crash-test processes

Tracks #347. Risk: high. Gate mode: `artifact-high`.
Review size: `accepted-exception`, 700–1,100 added plus removed implementation
lines. G1 intent blob is `ae56dfd965dd4fb2a5b2cf726769954d2a5052cc`.
G2 merged as `e8662e928ac6e1b296dfc93a091248639e5ad836` through PR #349;
that is this plan's source base, not the later implementation plan-base.

The manager must obtain independent exact-head/base plan acceptance and required
CI, then merge this plan separately before a Sol implementation author starts.
The author does not accept this plan. Current-session Roadmap delegation applies;
the artifact and protected-merge gates remain manual.

## Files that change

This plan PR changes only `work/receiver-crash-supervision/plan.md` on
`ystack/plan/receiver-crash-supervision` with plan-only non-merge history.
Implementation changes only `scripts/test/replay-materialization-result.test.sh`.
Its source blob at G2 is `95fc93a2bed283354e67669de10d6ccc4f602b89`.

Generate one private Python helper in the existing suite temporary directory.
It contains coordinator, keeper and control-fixture modes, plus shared bounded
channel/ownership functions. Wire only the early `before`/`after` crash pair and
its controls through it. Keep the other concurrent and later CP4c launch paths,
all original recovery assertions and the full later matrix unchanged. Do not
copy their process-management code or claim a suite-wide lifecycle repair.

No product, fixture builder, source/profile pin, workflow, manifest, policy or
other test file changes. The existing suite is already discovered and restore
listed. Keep artifacts immutable during implementation. A required extra path,
changed design or unexplained size overrun returns through a separate amendment.

## Order of work

### 1. Reconcile the gate and freeze the proof inventory

After plan merge, the manager records freshly fetched main as plan-base, verifies
intent/spec/plan blobs, risk and claim state, and starts
`ystack/impl/receiver-crash-supervision` from that exact base. A moved default
before code needs fresh independent plan/base acceptance under AGENTS.md.
Preserve any existing attempt rather than reset, rebase or replace it.

Before edits, save a scratch source inventory, full test bytes and the ordered
original assertion/case inventory. Retain the early pair's recovery bodies at
source lines 564–582 and every later case/oracle. The accepted original receiver
proof contains 13 outer checks and 654 named matrix cases; verify their actual
names and order from retained complete proof and source, not counts alone.
New supervision controls have their own names and cannot replace those cases.

Retain PR #346 head `2df5d975064814a783cbe3d7763939d23389daa6`, its historical
base `b873a171c550ca68f440b8c454b89ccd49304499`, and the clean candidate plan
attempt at that historical base. Main has moved as external context only.
Do not change those attempts, the merged receiver history, frozen #183 or dirty
#271. Original run 35243355489 attempt 1 stays failed, raw shard SHA-256
`b1eaf0f65828d19cf44b282d312507331dde846b840efadfe64666f160290261`.

Read the full G2 general, critical safety and final CI reports before coding.
Their hashes are respectively
`dfb96461122666c70209072ef7f4393b6f924b6c3af9e1ab567879f12c876bf1`,
`34ea067f254a4869417145198f73ebf5783860f24dec30003815291b074580ee`, and
`be87571141b65d2f18dfd3b302a577fb48cf782d65364f46d0180dc875968c4c`.
They are design evidence, not proof of the repair.

### 2. Preserve the fixed process-containment boundary

Record this complete called-source route and exact blobs in the implementation
proof. Recheck it against plan-base before execution; do not execute a real target.

| Source | Blob at G2 | Containment fact to retain |
| --- | --- | --- |
| `delivery/v1/replay.py` | `f1144a15a361ab1c989f7bc0b70579a46c288b93` | Ordinary subprocess calls inherit the group. Fresh keyed delivery captures the materializer and validates through fixed core/jq/Git calls before the pause. |
| `adapters/local-git-materializer/v1/materialize.sh` | `ebb8e8b97be8c2f2a380849b7fefdef67bbed02a` | Clean env/Bash exec preserves group; non-job-control commands, substitutions and pipelines inherit it. Source config is allowlisted, hooks disabled and commands are offline. |
| `adapters/local-git-materializer/v1/object-closure.c` | `00cb3c6004bf277ad5bdc46b570c5ce7e1ecbd0d` | fork/exec of fixed Git cat-file changes limits and descriptors, not session/group. |
| `scripts/core-contract.sh` | `18748127ead49a22717723e9860210940010d84e` | Sources the selected immutable ingress; shell calls preserve group. |
| Selected generation's `core-ingress.sh` | `973f5c3808ffbbda23471b2dbdd7b221cb4d0599` | Uses fixed jq and resolved system utilities, not a provider, daemon or session launcher. |

The selected generation is
`core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/`.
Include its `contracts.jq` and five imported modules, materializer `protocol.jq`,
generation registry, fixed jq/object-closure executable identities and actual
Git/Bash/Python identities in the source inventory. These jq files validate data;
they do not execute candidate commands. Ingress resolves head, wc, cmp, cat, rm,
od, awk, stat, mkdir and sha256sum/shasum in the fixed environment. Include shell
pipelines and command substitutions, not just direct subprocess sites.

The source audit found no setsid/setpgid, job-control enablement, disown, daemon
launch or new-session subprocess option on this route. System binaries are trusted
fixed tools, not source-audited arbitrary programs. Candidate files remain data.
Keep that limited claim and prove real nested fixture containment below. A changed
route or escaping descendant is a stop, not permission to scan and kill by name.

### 3. Build one explicit ownership implementation

Use a single-threaded Python event loop in each role. Install INT/TERM handlers
that set only the first pending signal before launch work. Explicitly set SIGCHLD
to SIG_DFL before creating any child in both coordinator and keeper; do not rely
on inherited state or Popen restore_signals. Check the resulting disposition.
The fixed CPython signal setup uses sigaction without SA_NOCLDWAIT. Do not add
ctypes layouts, waitid, subreapers, platform-only APIs or a dependency upgrade.
After installing handlers, explicitly unblock INT/TERM in each private role with
pthread_sigmask; inherited blocked signals must not silently disable cancellation.

Popen creates children, but a private `reap_exact` function is the only consumer
of their statuses: `os.waitpid(owned_pid, os.WNOHANG)`. Return zero means not yet
reaped. Only a returned matching PID with WIFEXITED/WIFSIGNALED yields a status;
decode it with waitstatus_to_exitcode and then set the retained object's returncode
to that observed value. EINTR resumes within the same deadline. ECHILD, another
PID, a nonterminal status or another error means unknown status and failure.
Never accept CPython's ECHILD-to-zero fallback or fill in an expected exit code.

Keep each Popen strongly referenced through its complete ownership interval.
Do not use its poll, send_signal, kill, terminate, wait, communicate or context
manager. send_signal implicitly polls in native Python 3.9.6; kill/terminate call
it. Do not drop an unreaped object into __del__/_active cleanup. No other thread,
SIGCHLD handler or generic subprocess cleanup may reap an owned child. Use raw
os.kill/os.killpg only through the state-checked signal functions below. If a
reap is unknown, keep the object alive until role exit; any interpreter cleanup
then occurs after signal authority retirement and cannot provide proof.

Maintain separate immutable observed IDs, mutable authority state, raw wait
status, primary outcome and cleanup/diagnostic failures. A single first-outcome
setter prevents later cleanup errors from replacing the trigger. Event records
carry fixed role/case/token/sequence fields; record transitions before actions.
Keeper INT/TERM records an interruption event, prevents a not-yet-started replay
and waits for the coordinator's same stop/cleanup protocol; it does not perform
an independent group kill or signal a retired replay.

| Coordinator state | Permitted next action |
| --- | --- |
| empty/launching | Create keeper; defer signal dispatch through return/handle assignment. No group authority. |
| child-owned | Retain exact unreaped keeper; validate handshake. Failure permits one raw positive-PID kill, then retire direct authority and reap. No descendants are admitted. |
| group-owned | Verified keeper PID=PGID=SID and own-group exclusion; may release exactly one admission. No keeper reap or implicit poll. |
| cleanup | At most one keeper replay-stop command; drain statuses within the first five seconds of shared cleanup. |
| signal-attempted | Record attempt before one raw group SIGKILL; do not retry on error or interruption. |
| retired | Clear all keeper PID/group signal authority before any keeper wait. Only exact reap and read-only observations remain. |
| observed/diagnostic/sealed | Record actual wait and absence; publish bounded diagnostics and completion. No process signaling. |

The keeper has replay states empty, launching, child-owned, signal-attempted,
retired and reaped-or-unknown. Its event loop first consumes an available natural
wait status, then handles a stop command. A reaped child returns its saved status
without a signal. A zero wait result leaves the direct child unreaped; raw kill
of that owned PID is safe until this sole reaper consumes status. Mark the signal
attempt first, signal at most once and retire replay signal authority before
continued wait/drain. No other thread can race that sequence. The coordinator
never inherits replay-PID signal authority, including after keeper EOF.

### 4. Implement channels, admission and deadlines

Create a private 0700 case directory with fresh unpredictable case token, shell
cancellation/start state and bounded records. Use a Unix socketpair for coordinator
commands/keeper events and a separate pipe for wrapper phase events. Pass only
the necessary descriptors. Close unused ends immediately; make wrapper control
descriptors non-inheritable before the product launches subprocesses. Standard
input to the replay is DEVNULL; stdout/stderr are distinct pipes owned by keeper.

Use nonblocking os.read/os.write or socket recv/send and selectors. Queue partial
writes, limit each frame to 4 KiB and total control bytes per case to 64 KiB in
both directions combined. Bound the incomplete frame before appending another
chunk. Reject unexpected fields/types, duplicate keys, wrong token/case/sequence,
duplicate terminal events and illegal order. EOF is an observation, never a reap.
Close overflowed protocol channels and enter cleanup; do not block trying to send
an error to a peer that stopped reading.

The coordinator first installs handlers and records the admission/setup start,
then waits for the shell-owned start record or cancellation before launching
keeper. This prelaunch gate consumes the same admission/setup budgets, so it
cannot wait indefinitely. Keeper uses start_new_session=True, sends its identity
and cannot launch replay until one valid admit command. Coordinator verifies the
actual direct child and OS getpgid/getsid results, positive equality and exclusion
of its own PGID, then publishes group-owned before sending admission.

Cancellation has priority over admission whenever observed. Immediately before
the first admission write, briefly block INT/TERM with pthread_sigmask, check
handler flags, sigpending and shell cancellation state, and record the admission
decision. If cancellation is present, do not write. Otherwise attempt only the
nonblocking write and restore the prior mask in finally, without a selector wait
inside the masked region. The first written command byte is the release boundary;
an EAGAIN with zero bytes repeats this cancellation check before a later attempt.
Cancellation after release may find one replay starting and must clean it; it
never starts a second. A partial/failed write is possibly released under group-owned
cleanup, never pre-admission. A signal becoming pending after the decision check
belongs to that in-flight admission and is handled as soon as the mask is restored;
do not claim atomic ordering between independent kernel/file cancellation events.

Use the accepted deadlines without an environment override:

| Limit | Deadline computation |
| --- | --- |
| Admission 5 s | coordinator prelaunch start + 5 |
| Setup 60 s | the same prelaunch start + 60; includes admission |
| Ready hold 20 s | actual readiness time + 20 |
| Cleanup 10 s | first cleanup entry + 10; never renewed |
| Stop acknowledgment | min(cleanup start + 5, cleanup deadline) |
| Diagnostic publication 5 s | first publication entry + 5 |

Before every selector wait, compute the nearest remaining deadline. Poll
cancellation and exact-child status at intervals no greater than 0.02 seconds,
but use monotonic elapsed time for expiry rather than iteration counts. Drain a
bounded chunk per ready descriptor so a noisy child cannot starve deadlines or
cancellation. No blocking readline, sendall, buffered flush or wait-before-drain.

The coordinator opens separate private regular output files before keeper launch
and passes their descriptors to keeper. Preserve the old .out/.err paths. Keeper
drains replay stdout/stderr concurrently into these files, retains at most 64 KiB
per stream and counts bytes actually observed. Overflow or file-write failure
fails and requests cleanup; continue bounded draining/discard while termination
completes. Control frames carry counts/status only, never stream payloads. After
cleanup the coordinator reads capped files for diagnostics. Do not claim an exact
total for bytes never read after a forced close.

### 5. Wire the actual crash boundary and final cleanup

Extend only the loaded wrapper's pause route. Observe wrapper entry, capture
entry and capture return by calling the original capture function once and
returning its unchanged bytes. Send readiness only at the original before/after
stored-journal hook. Before means materialized candidate exists and stored result
is not published; after means stored publication returned in verifying phase.
An earlier phase event cannot satisfy readiness. The wrapper waits at that hook
for the deliberate real crash; readiness carries the current case identity.

The coordinator commands keeper to SIGKILL the actual replay after readiness.
Keeper reports its authentic -9 wait result and zero outward stdout. Then perform
group cleanup and hand control back to the unchanged shell recovery assertions.
The two cases still use fresh real roots, the real replay and original read/reopen
commands. Never synthesize missing/stored output or infer status from a kill call.

For any failure, begin cleanup once with its fixed shared deadline. If responsive,
keeper terminates/reaps its replay or returns the already-observed status. Whether
that succeeds or not, attempt the final admitted-group KILL once while keeper is
still unreaped. Raw os.killpg avoids Popen's implicit poll. Retire group authority
in a finally boundary before calling reap_exact on keeper, even if signaling
fails. A group signal error is recorded and is never a license for another signal.

After exact keeper reap, call `os.killpg(recorded_pgid, 0)` read-only until it raises
ProcessLookupError with errno ESRCH or cleanup expires. A return, EPERM or any
other error is inconclusive/failure. Do not replace this with ps counts, positive
PID probes or zombie filtering. Record actual native results. No signal is ever
sent after retirement, even if reuse makes an absence observation conservative.
Confirmed keeper reap plus ESRCH establishes group cleanup; replay reap remains
a distinct fact. No claim of directly reaping grandchildren is made.

### 6. Complete the Bash and diagnostic handoff

Initialize managed context, operation, first signal, interrupted-wait flag, job
handle and retention flag before installing traps. Keep traps narrow to supervised
context; outside it the existing suite behavior remains. Use Bash 3.2 indexed
arrays/scalars and builtin wait only: no wait -n/-p, associative arrays or newer
descriptor-allocation syntax.

Set launching before `python3 helper ... &`; assign the original `$!` immediately
before another fallible operation. During this window traps only set the pending
signal. After assignment, write cancellation if pending; otherwise publish the
shell-owned start record. The coordinator may not launch keeper before that record.
This prevents an interrupted shell launch handoff from granting unseen effects.
INT/TERM traps preserve the first signal, mark wait interruption, publish only
fixed cancellation data in the private path when ownership is assigned, and return.
No shell signal uses a stored PID/PGID. Cancellation-file failure sets retention
and failure; it cannot authorize deletion or a second coordinator.

Explicitly install coordinator INT/TERM handlers even when asynchronous Bash
launch inherited SIGINT ignored. A bootstrap event after handler installation
marks the earliest valid direct-coordinator signal-test boundary. Shell-directed
launch tests cover the earlier window through cancellation; do not claim receipt
of an ignored pre-bootstrap SIGINT. Set the keeper handlers explicitly too.

Wrap each builtin wait in explicit status capture safe under set -e. Set the
wait-interrupted flag false just before waiting. A trap sets it true. When true,
repeat only wait for this same job; do not infer completion from status >128 or
re-send cleanup actions. An uninterrupted return plus this invocation's sealed
completion record is required. Status 127, missing/wrong seal or unknown status
fails and retains scratch, including a completion/interruption race that cannot
be confirmed. Never infer completion from kill -0 or a stale job number.

EXIT cleanup disables recursive EXIT handling, records the original status, and
uses the same cancellation/wait handoff if managed context remains active. It may
remove scratch only after confirmed completion, cleanup and diagnostics. A signal
after coordinator completion but before shell handoff still makes the shell's
outcome nonzero and cannot delete unconfirmed evidence. Keep first INT/TERM as
130/143 respectively; ordinary supervision failure is 1, success is 0.

Coordinator writes a bounded structured outcome, with primary and secondary
failures separated, to a private regular file and emits its bounded diagnostic
record before atomically renaming a completion seal. The seal binds case/token,
coordinator identity, final exit, cleanup facts, diagnostic completion and the
record's digest. A seal is not process-exit proof; shell still waits. Conversely,
exit alone is not proof of cleanup. Keep unknown statuses explicitly unknown.

Keep emitted excerpts to 4 KiB per stream and the entire emitted record to 16 KiB;
full retained streams remain in their capped private files. Binary excerpts use
an explicit byte encoding within those bounds, not lossy assertions about bytes.
Diagnostic output uses nonblocking descriptor writes within its five-second
deadline. Save file-status flags, enable O_NONBLOCK, handle partial/EAGAIN writes
with selectors, and restore flags on every ordinary exit before sealing. Use no
buffered print/flush on this boundary. While flags are changed, the shell traps
and other children must not write to that shared output description. Restoration
failure prevents a seal and retains scratch. Filesystem syscalls and scheduling
are not claimed to have hard elapsed bounds; no new disk durability contract.

A blocked/broken output sink, failed record write/rename, malformed seal or unknown
cleanup yields no successful handoff. Retain private scratch and emit a short fixed
retention notice only when output remains usable. Do not print raw fixture content
or local paths into public PR comments. Implementation proof may retain private
files with exact hashes. Terminal success cannot precede final cancellation checks.

### 7. Add controls and measure before final verification

Put controls after the early pair and before the later matrix. Reuse the same
helper functions and Bash handoff by extracting their actual definitions into
private control shells; do not make a second lifecycle implementation. Controls
use fixed private case descriptors, not a public switch or inherited environment.
Boundary hooks acknowledge an actual reached operation before an outer controller
releases it or sends a signal. The outer controller proves the real owned target
identity before signaling it, and retires its own signal authority before reaping.

Run targeted control proof as soon as the helper is coherent, with all failure
output retained. Obtain independent checkpoint review of ownership, cancellation
and real nested-child evidence before starting the costly final native run. This
checkpoint does not waive the later complete source/evidence review. If code or
proof meaning changes, rerun affected proof on the new exact head.

Measure scope after helper/integration and after complete controls. Keep the
accepted 700–1,100 changed-line forecast: helper 260–360, integration/diagnostics
90–150, controls 300–470, replaced/deleted lines 50–120. These are allocations,
not quotas. Prefer a shared event loop and table-driven independent cases; do not
collapse failure assertions, combine distinct signal cases into one pass or pack
unreadable statements to fit. Pause before an unexplained overrun; keep the exact
head/dirty state and use separate artifact amendment rather than editing this plan.

## Risks

Implicit Popen reaping is the highest identity risk. The raw wait/signal boundary,
strong references and one reaper per child prevent losing the keeper pin before
group cleanup. ECHILD is missing evidence, including when deliberately injected;
it cannot become zero status. Inert dispatch controls supplement actual lifecycle
proof; they do not establish that a real process is absent.

The admission command can race cancellation. Ownership is published before any
possible release; observed pending cancellation prevents it, while a partially
released command is conservatively admitted for cleanup. Signals record intent
without unwinding critical operations. Signal-attempt and retirement transitions
cannot be repeated by a trap, finally block or late error.

Ordinary supported errors may leave cleanup unconfirmed; retaining scratch and
failing is required. A group with lingering zombies is not declared absent. Test
rescue belongs only to deliberately broken controls, never the two real cases.
An escaped descendant, uninterruptible process, supervisor SIGKILL or failed host
is outside the guarantee. Better diagnostics may expose a product hang; that
returns to scope review without a product timeout patch.

A bare longer wait, polling/reaping keeper for convenience, a native-version
upgrade, global ps-and-kill cleanup, or migrating all later launch sites would
evade or widen the accepted design. Keep the private keeper boundary. The current
size estimate is ambitious; complete readable proof and independent review win
over saving lines. No unresolved platform assumption may be converted into a skip.

## Proof

### Named control inventory

Before code, save an explicit expanded inventory using these IDs. Parameterized
rows expand to separate records. Every record includes actual reached boundary,
launch/signal/reap counts, actual statuses or unknown, primary/secondary failures,
timings, identity and scratch disposition. A failed subcase fails the suite.

| IDs | Cases and required evidence |
| --- | --- |
| C01-before, C01-after | Both original real crash/reopen cases; real ready, replay -9, zero outward stdout, unchanged original assertions. |
| C02-before, C02-after | Actual pre-publication acknowledgment, at least 12 measured seconds of controlled hold, then real readiness within 60 s and the same original recovery outcomes. No sleep selects the crash boundary. |
| C03-early-exit | Fixture exits 37 with known stderr before readiness; authentic wait 37, no pass, keeper retained through cleanup. |
| C04-watchdog | Actual 60-second setup expiry with live replay fixture and nested descendant; one launch, named timeout, replay status if observed, keeper reap and ESRCH group absence. |
| C05-missing, C05-wrong | Missing/invalid keeper identity; zero replay launches and group signals; exact-child-only cleanup. |
| C06-target-signal-boundary | Cartesian product of targets Bash/coordinator, signals INT/TERM, boundaries launch handoff/setup/ready hold/cleanup-before-signal/retirement-wait/diagnostic-handoff: 24 distinct records. Direct coordinator launch means handlers-ready; Bash covers pre-assignment. |
| C07-replay-retired | Replay exits naturally before stop request; saved actual status, no signal after its retirement. |
| C08-keeper-eof, C08-keeper-exit | Keeper fails after admission, including a nested child; coordinator does not poll it early, unknown replay result stays unknown, group cleanup uses retained keeper ownership. |
| C09-wrong, C09-own, C09-retired | Inert fabricated identities select refusal with zero real signals. |
| C10-signal-error, C10-wait-eintr, C10-wait-expired, C10-wait-echild | First three exercise actual boundary plus scoped error injection; ECHILD separately for coordinator and keeper. Unknown result never fabricates zero; no repeated signal or new launch. |
| C11-probe-alive, C11-probe-eperm, C11-probe-other | Non-ESRCH responses never count as absence; retained scratch and no post-retirement signal. Real absence remains separately proved. |
| C12-stdout, C12-stderr, C12-frame, C12-total | Each accepted capture/control ceiling and overflow refusal; simultaneous pipe pressure cannot block cancellation or deadlines. |
| C13-malformed, C13-duplicate, C13-wrong-case, C13-out-of-order | Strict control parsing/order failures; no forged readiness or pass. |
| C14-output-blocked, C14-output-broken, C14-record-write, C14-seal-rename, C14-flags-restore, C14-shell-handoff | Diagnostics/hand-off failures retain scratch and fail; no indefinitely blocking output or hidden success. |
| C15-sigchld-coordinator, C15-sigchld-keeper | Start with inherited SIGCHLD ignored; explicit reset permits an authentic nonzero direct wait, not Popen fallback zero. |
| C15-mask-coordinator, C15-mask-keeper | Inherit blocked INT/TERM; verify explicit unblocking after handlers, with actual delivery through an acknowledged supported boundary. |
| C16-wait-return-signal, C16-repeat-signal, C16-cancel-write, C16-errexit | Completion/interruption race, repeated INT/TERM, failed cancellation write and ordinary shell error do not bypass handoff or scratch retention. |

For C06 and C16, run real /bin/bash control shells under set -e; capture their
outcome explicitly in the outer driver. Inject only after actual boundary
acknowledgment. Post-wait boundary proof and injected EINTR handling are distinct
from claiming a signal inside the kernel's blocked wait. Verify native Bash 3.2
ignoring/handler behavior directly through these controls.

At acknowledged nested-fixture boundaries save PID/PPID/PGID/session membership
for keeper, replay and descendant, using their actual owned records and read-only
OS observations. Repeat with replay exited while descendant remains, and with
keeper EOF/exit. At finish require authentic direct reaps and ESRCH-only group
absence; separately observe known descendant termination without signaling saved
numbers. Do not call a zombie absent or use process-name matching as ownership.

Deliberate cleanup failures use independently owned rescue pipes or fixed finite
fixture lifetimes. Outer control first records and asserts the supervisor's failed
result and retained scratch, then releases rescue and observes its separate result.
No rescue event supplies supervisor cleanup credit. A rescue failure itself fails
the suite and remains visible. Neither real crash case has a rescue fallback.

### Commands and retained evidence

Only after the plan gate, run from the implementation worktree. Record full OIDs,
UTC start/end, actual exit, platform/interpreter versions and raw output for each
command. Keep failed and interrupted runs; do not overwrite their files.

```sh
/bin/bash --version
/usr/bin/python3 --version
/bin/bash scripts/test/replay-materialization-result.test.sh
/bin/bash scripts/test/run-all.sh
```

The focused run proves all original and new cases on native Darwin/Python 3.9.6
and Bash 3.2. The full unsharded native run must finish all 65 current suites on
the final committed head, with no source writes while running. A later changed
head requires affected fresh evidence; partial output is not a complete pass.
Required Linux CI runs the original six `run-all.sh --shard N/6` invocations,
checks and aggregate ci on that same head/base. No workflow or runner change.

Also run, with BASE replaced by the recorded implementation plan-base:

```sh
git diff --check BASE HEAD
git diff --name-only BASE HEAD
git diff --numstat BASE HEAD
bash scripts/check-rename.sh
```

Require exactly the one allowed implementation path and accepted artifact blobs.
Run the unchanged workflow structure-manifest check and pinned ShellCheck 0.11.0
over every shell file with `shellcheck -x -S style`, verifying its exact version
and existing pinned asset digest. The plan does not authorize a replacement lint
version, reduced file set or skipped test because a run is long.

Keep a hash manifest for original source/case inventory, final diff, generated
helper bytes, exact called-source/tool identities, raw focused/native/CI logs,
expanded C01–C16 case records, actual phase durations, complete ownership events,
diagnostic/retention records and original-oracle comparison. No private progress
summary replaces full raw evidence. Preserve all original 654 matrix cases and
13 outer assertion labels, adding controls separately without deleting coverage.

Independent review performs Bugs/Security/Compliance passes on source and complete
proof, including implicit reapers, cancellation order, native absence, rescue
separation and shell completion. The manager reads the full verdict, resolves all
Important findings and verifies exact head/base and every required original CI
job before protected merge. Preserve the receipt and fresh clean tuple. A base
move or changed meaning invalidates affected review; no direct main push, force
push, protection bypass, activation or new external authority is included.
