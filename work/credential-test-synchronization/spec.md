---
intent-blob: fe27e456e458f55de9d9ce848350f8473dd60936
risk: high
drafted: 2026-09-14
---

# Spec: Bound fresh setup attempts for credential input mutation tests

Tracks #291. G1 was accepted through PR #295. This repair changes test setup and
its description. The shipped evaluator, dependencies and security assertions stay
unchanged.

## Requirements

### R1. Retry only a proved setup-window miss

The path-swap, same-inode and parent-swap cases get at most three total setup
attempts each, including the initial attempt. Each starts the original evaluator
through the existing isolated process-group launch. Before any input mutation,
the observer must prove the same owned pending marker/path, PID=PGID, own-group
exclusion, stopped T-state and absence of input-snapshot-ready as today.

Only this exact outcome may request a fresh attempt: pending was found and owned,
the evaluator group was stopped and its leader observed in T-state, but readiness
already exists. The observer missed the intended phase; this is not mutation proof.
An exited evaluator, missing marker, unsafe group, wrong owner/path, failed signal,
failed state observation, command error or timeout fails immediately. Do not
classify errors as missed windows merely because setup did not succeed.

After a proved stop with readiness absent, leave the evaluator stopped and return
to the existing mutation case. No retry is possible after this point. Run the
actual mutation, CONT, wait, refusal, restoration, cleanup and descendant checks
exactly once. Any failure in that execution fails the suite immediately.

Three attempts are a small finite setup budget, not a statistical reliability
guarantee. This design keeps the race observable and makes exhaustion fail. Keep
the existing 180-second total alarm and every launch, marker, state and termination
bound. No longer timeout, added sleep, faster polling, platform skip or CI rerun
serves as the repair. A loaded host can still exhaust the budget and must report it.

### R2. Reconcile each missed attempt before starting another

Terminate and reap the exact owned evaluator group using the existing bounded
termination helper. Require successful termination, no live descendants and an
empty case scratch root before any further attempt. Do not remove residual files
to manufacture an empty scratch check. Failure of cleanup or ownership is terminal.
Retire process-signal authority at the helper's wait boundary under R2a, before
fallible filesystem or evidence reconciliation. Retain the former numeric tuple
as historical evidence only. Clear stopped-marker and per-attempt outcome state
only after complete reconciliation. A later attempt creates a fresh evaluator
and runtime scratch; no earlier marker or child can satisfy its checks.

No input has been mutated on a missed attempt. Preserve the original case input
and its identity. Each fresh launch pins the same unmodified input before setup.
The three cases retain their existing replacement, backup and restoration paths.
The successful attempt keeps the original output names used by the assertions.
Before reusing those names, preserve missed-attempt stdout/stderr inside the owned
suite temporary directory under distinct case/attempt names. Their content is not
printed or uploaded. Normal suite cleanup still removes the suite directory.

Print one concise fixed-format setup-miss record for each missed attempt, naming
only the fixed case name and attempt number. Print exhaustion distinctly from a
mutation/refusal failure. A missed attempt never increments the pass count and its
output/status is never accepted as security evidence. Retain the original failed
CI run and later diagnostic rerun as historical observations, not proof of this fix.

### R2a. Manage setup before launch and retire termination authority once

Only the three coordinator invocations enter managed setup. Before their first
launcher call, while both input PID/group globals are empty, publish managed context
in one initialized scalar assignment. Do not enter it after observer classification.
A signal before entry has no current evaluator tuple; after publication the managed
handler below applies through launch, observation, missed-attempt reconciliation and
all further setup attempts. Never become inactive between attempts. The strict
observer callers and separate signal-child path stay outside this context.

Use two distinct facts: process lifecycle and current operation. Lifecycle is empty,
owned-live, wait-in-progress, retired, retired-unconfirmed or rejected-before-signal.
Operation is none, launching, observing or terminating. Initialize all fields,
pending-signal, wait-interrupted and the initially inactive local-reap child identity
before managed entry. A numeric PID/PGID retained for diagnosis is never enough to establish owned-live. Publish owned-live only at
successful launcher ownership admission, with its original FIFO still holding the
child; the launcher publishes both numeric globals before that lifecycle assignment.
There is no second owned-live publication on observer return or ready classification.
Keep each publication in a small private boundary function whose normal body is
that scalar assignment; isolated controls can invoke the real assignment and inject
a signal before return, including ownership admission before FIFO release.

Set operation to launching before calling the existing launcher and to observing
before calling the selected observer. Signals during those operations are recorded,
not serviced by the legacy returning cleanup trap. The normal launcher still owns
its pre-admission failure cleanup. Keep its evaluator arguments, isolated group,
FIFO hold/release and bounds unchanged. Its managed additions are ownership
publication, lifecycle bookkeeping and the explicit failure capture below; no new
launch route or successful-launch behavior is added.

After fork and before admission, the launcher owns its exact local child PID, not
an admitted group. In managed context, capture failure of every fallible operation
in that interval and in its existing abort cleanup explicitly. Gate writes, fd close
and gate removal failures must not escape through errexit before child cleanup.
On any such failure, retain the original failure, attempt the existing abort token,
close the gate and remove its path while capturing their failures, then perform the
existing KILL of that exact local child once and one logical reap before terminal
failure. Use the shared private wait boundary below with an active local-reap fact
bound to that child PID; this is never owned-live or group authority. Publish that
fact before waiting. Launching dispatch also sets wait-interrupted while it is
active. Clear the flag before each call, capture the actual builtin wait status,
and repeat only wait on that same child when interruption was recorded. Do not
repeat KILL, gate actions, polls or setup. An uninterrupted return retires local
signal authority before any further command; status 127 leaves reap unconfirmed
and terminal, while other child statuses follow the shared completion rule. Keep
the local identity as historical evidence, with no EXIT fallback signal or second
termination. Preserve the original launch error and disclose any cleanup uncertainty;
no observer or further attempt follows even after confirmed reap. Keep launching
active through result publication, then use the ordinary operation-none dispatch.
Keep the original signal order and bounds. A gate-removal failure cannot skip this
cleanup, and a cleanup failure cannot turn the original error into success.
Do not publish owned-live or guess PID=PGID to make global cleanup own this child.
Audit the complete post-fork/pre-admission interval for unchecked failure exits;
strict legacy callers retain their original path. No duplicate child-termination
implementation or new cleanup budget is permitted.

After admission, a launch-release error instead belongs to the published owned-live
tuple. Capture gate-write/close/remove failures, retain the original error and invoke
one managed termination helper before terminal exit. In particular, failure of the
existing gate removal before group termination cannot bypass that helper. Its
operation/lifecycle dispatch prevents EXIT from invoking it again after retirement.
The launcher cannot resume, release again or start an observer after this error.
All observer error paths remain terminal, never missed outcomes. Where its early-exit
path currently waits directly and clears globals, the managed branch must instead
use the one termination/reap boundary below before failing; strict callers keep
their existing path. Existing observer termination calls use that boundary too.

The coordinator invokes these functions as ordinary commands, captures explicit
outcomes and keeps their ordinary failures fatal. At each function return it sets
operation to none, then services any recorded signal before interpreting outcome.
A new signal with operation none takes terminal cleanup immediately and exits;
it cannot return into setup. Thus neither a signal before observer return nor one
between readiness classification and outcome handling can leave a reaped tuple to
be republished live. A success outcome has one final managed checkpoint and then
one scalar publication relinquishing context to the unchanged stopped-child mutation
continuation. Until that publication signals are terminal managed setup events;
after it the original mutation/signal behavior applies. No new guarantee about
legacy signals after that handoff is claimed. The tuple remains genuinely live and
stopped at handoff; no cleanup or reap may have occurred on the success path.

Between attempts, confirmed retirement is followed by complete R2 filesystem and
evidence reconciliation. Clear the old numeric globals and historical per-attempt
state before publishing lifecycle empty. Context remains managed and operation none,
whose signal handler exits terminally. Require no pending signal, then publish
launching in one scalar assignment: this is initiation of the next launch operation,
not a claim that the OS child already exists. A signal before this publication exits;
a signal after it belongs to that one in-flight launch. Never reset or ignore pending
signal state to authorize an additional launch.
A signal in the check-to-launch interval therefore either exits before launch or is
recorded while launching; in the latter case finish ownership admission/cleanup and
exit at return without observation or mutation. The evaluator may already have been
spawned when a signal is delivered during launch; do not claim atomic signal/spawn
exclusion. No caught signal may be ignored to start a subsequent setup attempt.

**Dispatch precedence is context, then operation, then lifecycle.** Outside managed
context preserve existing traps. Within it, HUP/INT/TERM during launching, observing
or terminating only records the first pending signal; while lifecycle is
wait-in-progress, or a launching local reap is active, it also sets wait-interrupted.
This operation rule wins even if
the terminating helper has already published retired or retired-unconfirmed.
It stays in force after helper return until its caller publishes operation none.
With operation none, a caught signal requests terminal cleanup and exits, never
returns to the coordinator. Pending signals are serviced at that same boundary.
The signal name is passed explicitly to dispatch; EXIT is a separate cause.

On terminal cleanup of owned-live, invoke the existing termination helper exactly
once with operation terminating. It checks the original numeric identity and
own-group exclusion before signaling. Invalid ownership publishes
rejected-before-signal and fails; it never authorizes a guessed group signal.
Valid ownership gets the complete existing TERM/CONT, bounded polls, optional KILL
and bounded polls. No caller or trap duplicates these operations. A miss uses the
same helper through this managed route, not a copied termination implementation.

For admitted group cleanup, immediately before the logical reap publish
wait-in-progress. This retains
the existing helper as sole cleanup owner; it does not assert group absence.
Each private reap-boundary call invokes builtin wait and captures status explicitly.
Clear wait-interrupted immediately before the call. A recorded interruption repeats
only that builtin wait on the same child, not any signals or polls. An uninterrupted
return publishes retired-unconfirmed before any final probe or return. Status 127
is terminal unconfirmed reap, never success. Other child statuses, including signal
termination statuses, are not mistaken for an interrupt merely by their number.
The unchanged 180-second suite alarm remains the outer bound; there is no extra
setup attempt, termination budget, timeout or sleep.

The managed final group probe must return distinct alive, absent and error outcomes.
Use one fixed test-private syscall probe, for example /usr/bin/perl with Errno,
calling kill(0, negative validated PGID): positive result means alive; zero with
ESRCH means absent; every other errno or execution/parsing failure means error.
No signal is delivered by that probe. Do not infer absence from arbitrary nonzero
shell status or stderr text. Bound and validate its tiny output/status. Use the
same three-way interpretation for managed termination polls; errors mark cleanup
unconfirmed, but do not suppress the remaining already-owned bounded termination
work. Preserve original poll counts/delays and KILL escalation; no second budget.
A final absent result with confirmed wait and no probe error publishes retired and
success. Alive or error remains terminal retired-unconfirmed. No later probe can
restore numeric signal authority after wait.

Every ordinary command failure inside managed termination is captured explicitly;
no fail/exit or unchecked errexit escape may skip its remaining owned-live cleanup.
Signal traps there record intent and never exit. After the helper publishes its
result and returns, the caller clears operation before servicing pending signal.
A signal before that clear is deferred even in retired state; one after the clear
is terminal without signaling retired identity. This resolves the return window
without relying on a flag first set by the caller after wait has completed.

EXIT within managed context uses the same lifecycle. Owned-live invokes the one
helper unless termination already owns it. Retired, retired-unconfirmed,
rejected-before-signal or empty never authorizes a numeric input-group signal.
EXIT while termination already runs cannot recurse; an unexpected shell-abort path
is terminal unconfirmed cleanup, not a pass or another attempt. Normal commands
must use explicit failure disposition so this is not an escape from live cleanup.
Existing pre-admission launcher failures still execute their own bounded child
cleanup before EXIT. After terminal managed cleanup, disable recursive EXIT entry,
perform the normal remaining suite cleanup and exit nonzero. Do not erase a cleanup
failure or let a returning legacy signal handler resume this managed context.

A final alive/error result after the single bounded termination path is disclosed
as failed cleanup. It is not a promise that unkillable survivors vanished, and not
permission to signal a reaped group's reused number again. No retry follows.
SIGKILL, the total alarm and unexpected shell-abort paths gain no new cleanup
guarantee. The separate inherited successful-mutation wait/group logic is unchanged.

Only confirmed retired success with no pending signal reaches empty-scratch
inspection and missed-output preservation. Any file-operation failure is terminal,
with historical identity preserved until ordinary suite cleanup but never revived
as signal authority. Full reconciliation alone permits another of three total
attempts; exhaustion remains a distinct failure. No early state clear abandons
owned-live cleanup, and no late state clear bridges a reaped identity into a new run.

### R3. Contain retry selection to these three cases

Add one private input-setup coordinator for the three call sites. It calls the
existing launcher and stop observer with an explicit, narrowly named selection
that allows the single R1 missed-window outcome. All other observer callers retain
their current fail-on-miss behavior. The launcher's evaluator default/fourth
argument, FIFO protocol and termination bounds stay unchanged. R2a explicitly
permits managed ownership publication and explicit post-fork failure capture in
that launcher, managed observer terminal cleanup, lifecycle publication in the existing helper and the matching global-trap
dispatch. These are the coordinator's required lifecycle dependencies, not a general
helper rewrite. Keep other callers' strict selection and existing helper behavior;
do not apply this policy to the separate signal-child path or successful mutation
continuation after the single handoff publication.
The existing strict input-pending wrapper can remain or become this bounded
coordinator; keep one definition and avoid a parallel copy of the observer logic.

Use an explicit setup outcome rather than treating arbitrary nonzero exit status
as permission to retry. Bash functions invoked in conditional contexts can lose
set -e behavior: do not wrap the existing observer in if/! or an AND/OR test and
thereby suppress its ordinary failures. The observer's optional missed-window path
must report its outcome deliberately; every other failure still calls fail.
Validate the selector and initialize outcome state on every call so stale state
cannot request a retry or pass a later attempt. Keep the default path strict.

Do not instrument a private evaluator, change its bytes, update a copied decision,
rebind a policy-set/duty/claim chain, hide a line from hashing, stub a validator or
add a shipped hook. Keep copy_runtime in its existing place with unchanged body.
All dependencies and the original positive baseline remain byte-identical.

### R4. Preserve and demonstrate the evidence

Retain all 45 existing checks and every existing security and cleanup assertion.
For the three mutation cases retain actual changed input, nonzero wait status,
exactly E_RUNTIME, empty stdout, restored original content, retained synthetic
replacement evidence where applicable, empty scratch and no descendants. A changed
same-inode digest may require reading bytes; do not claim a stronger universal
no-changed-byte-read property from the existing refusal result.

Add focused controls for the setup coordinator: one missed setup followed by a
valid setup reaches the caller only once; three misses exhaust exactly three
launches without reaching mutation; an ordinary setup failure is not retried;
and failed cleanup after a miss prevents another launch. These controls may use
private synthetic helper responses in an isolated test subshell to select the
otherwise scheduling-dependent branches. They must exercise the actual coordinator,
assert launch/reconciliation counts and the no-mutation outcome, and clearly label
the evidence as setup-control tests. Never replace the three complete real evaluator
mutation cases with these controls or treat simulated readiness as security proof.

Add controls at the actual managed transitions and retirement boundary, in
addition to the four coordinator controls:

- Exercise managed entry before launcher call, owned-live admission while the
  original FIFO holds a real owned child, observer missed-window classification
  before return, observer return before outcome handling, and reconciled-empty
  state immediately before the next launcher call. Inject each signal through a
  private isolated boundary override. Assert terminal exit, no stale owned-live
  publication, no later evaluator launch and no mutation; a signal injected after
  launch begins may require cleanup of that just-created child, not pretend it
  never existed. Controls must call the actual context/dispatch transitions.
- At the actual pre-admission abort cleanup's gate-removal boundary, force a real
  file-operation failure while a real owned child is still held on the launch FIFO.
  A private isolated override may make that fixture's gate pathname an owned
  nonempty directory immediately before the actual removal command, so removal
  fails deterministically. Require the original terminal launch error, one exact-
  child KILL and one logical reap, no admitted group signal, no observer or next
  launch, and no live fixture child afterwards. Repeat this real pre-admission
  failure control for HUP, INT and TERM injected after the actual local builtin
  wait returns but before the shared boundary returns, preserving captured status.
  Confirm launching dispatch records interruption, only same-child wait repeats
  (physical wait count may exceed one), and local authority retires before terminal
  exit. The named file failure remains terminal. Supplementary status-127 controls
  must report unconfirmed cleanup and prohibit observation/retry; they cannot replace
  the real reap controls or claim blocked-syscall timing proof. Do not substitute
  a synthetic PID or simulate the real reap.
- Separately force an admitted release error and a real gate-removal failure before
  its cleanup, using the original FIFO fixture with confirmed ownership. Require
  the one managed group termination/reap path, terminal failure and no repeated
  termination from EXIT. These isolated controls change no real evaluator bytes or
  ordinary successful launch. Record the actual injected file failure and cleanup
  entry counts so an unrelated setup failure cannot satisfy either control.
- Run the real termination helper on a genuinely owned disposable child, then
  force post-retirement scratch inspection failure and output-preservation failure
  separately. Require terminal failure and no second helper entry or next launch.
- Give the managed reap boundary a normal body that calls builtin wait and returns
  its status. In an isolated control, call that same builtin wait on a real owned
  child, inject HUP, INT or TERM exactly once after it returns but before the boundary
  function returns, and preserve its captured status. Confirm the operation-first
  deferred route and completion of the final group probe. Repeat only wait as the
  protocol requires; a synthetic return cannot substitute for the real reap.
- Separately inject a signal after the helper has returned and operation none is
  published, before any file reconciliation. Require immediate terminal dispatch
  with no old-tuple signal. Also inject within termination before wait and after
  retirement but before its final probe; these must defer and finish that helper.
- Exercise pre-signal ownership rejection and final alive/absent/error results,
  including a failed probe executable/status, with isolated inert probe overrides.
  Never signal synthetic numeric groups. Require distinct results, no retry and
  no second termination; only absent with a confirmed reap and error-free probe
  history can count as cleanup success.

For a signal at an exact function boundary, the isolated override calls the actual
operation first and then signals its own control shell before returning. Save and
invoke the actual implementation rather than substitute a fabricated lifecycle.
Use real owned child/FIFO fixtures where ownership matters; fixture barriers and
bounded acknowledgments replace guessed sleeps. Keep all injection private to
isolated controls, with no public environment switch, evaluator change or shipped
hook. Record transition/helper/signal counts and parent-checked outcomes. The
negative result must be the named injected failure, not an unrelated setup error.

The retained Bash 3.2 wait experiment exited 1. Its after-reap cached statuses are
limited observations; its sleep-timed during-wait case did not establish the timing
or expected status and is not passing proof. Required controls above deliberately
cover actual pre-return and post-return boundaries. They do not claim deterministic
coverage of a signal inside Bash's blocked wait syscall. The implementation must
handle both interrupted-status and already-completed-status returns using its
recorded flag; controlled status cases can supplement, never replace, the actual
reap cases. Do not demand status 143 merely because a signal was caught or retry a
timing experiment until it happens to return that value.

All controls fit under the unchanged suite alarm. Increment their pass counts only
after the parent checks their evidence. Retain the original 45 plus four coordinator
controls and these additional controls; 49 is not the final claimed total.

The ordinary unmodified-evaluator positive baseline remains unchanged. Its zero
status, canonical output and inconclusive claim.provenance-unqualified result do
not grant credentials, qualification or authority. No new instrumented positive
control or changed baseline output is needed under this design.

### R5. Keep the change bounded and reviewable

Only these implementation paths may change:

- scripts/test/control-credential-policy.test.sh;
- docs/components.md, one short credential-policy paragraph describing the finite
  setup attempts, original-evaluator proof, exhaustion and unchanged assertions.

No new restore-critical file or manifest change is needed. No workflow, sharding,
timeout, evaluator, policy, fixture identity or unrelated test change is included.
R2a is the only added lifecycle dependency within the existing test path.
Use the standard small-PR budget. The separate high-risk plan must estimate the
complete coordinator, observer delta, controls and documentation. Do not reduce
assertions or compress code to fit a line budget.

## Design

The pending marker is an observation, not a handshake. The evaluator may reach
readiness before the observer's group STOP arrives. The existing launch FIFO binds
process-group ownership but cannot hold this later phase. A proved missed window
therefore ends that setup attempt; it cannot establish an input-mutation assertion.

The selected repair uses the bounded fresh-attempt option explicitly allowed by G1.
It preserves execution of the original evaluator and its complete identity chain.
A proposed private self-STOP was rejected during design review: observer STOP can
precede it, and changing the driver bytes invalidates its decision binding. Making
that alternative coherent would also require a test-only decision, policy-set,
duty and claim identity chain and different output references. That complexity is
unnecessary for this bounded repair and is not part of this proposed design.

At source base 80fee9fbbeb720abf89ac510c10dfe8a7e0cbe76, evaluator blob is
78e309d9220c189b652f6c1ae0c3e4be38713b3c and test blob is
d21bd55592760d76cbaf68d475482cd7b20ad9bc. The three call sites currently launch then
stop at pending before mutating. Their continuation code remains unchanged; the
coordinator replaces only setup. The observer change exposes just the already
recognized readiness-present miss after all ownership/stopped-state checks.

Run the full test on native Darwin and required Linux CI under unchanged bounds.
Both must execute all original cases plus the new controls. Record actual commit,
commands, platform and logs; report any observed setup misses and exhaustion.
No retry of a failed suite counts as implementation proof. Run pinned ShellCheck
0.11.0 and the repository's complete required structure, rename and six test shards
with a green ci aggregate on the final exact head/base. Independent review compares
the preserved assertion bodies and strict behavior of other observer callers.

## Out of scope

Deterministic evaluator instrumentation, new runtime hooks, policy or credential
changes, real credentials, provider access, installation, activation, targets,
workflow/shard changes, relaxed time limits, process/signal/cleanup changes beyond
R2a's missed-attempt transaction and required global-dispatch dependency,
and general scheduling infrastructure. Adapter diagnostics #301 is separate.

## Areas of concern

Risk is high because these tests supply evidence for a credential security boundary.
A retry that hides a real refusal or cleanup failure would weaken that evidence.
The exact classification, no-mutation boundary, finite budget, cleanup gate and
control tests prevent that interpretation; full original mutation executions remain
mandatory. A separate independently accepted high-risk plan precedes code.

This repair is probabilistic setup coordination with a hard failure boundary. It
does not claim deterministic scheduling or guarantee every host can prove the case
within three attempts. If unchanged bounds cannot provide the required proof, retain
the failure and return to the design gate; do not raise the budget or silently broaden
retry conditions. No production exception or safety waiver is introduced.
