---
spec-blob: 217507f00aaec34d5c970244ccd87b64967767aa
drafted: 2026-09-14
---
# Plan: credential-test-synchronization

Tracks #291. Risk: high. Review size: accepted-exception proposed by this plan.

Read from merged main fefa82e10a163c6570b8eb8581e7fbab776ed7f6. The spec binds intent
fe27e456e458f55de9d9ce848350f8473dd60936 and records risk high. This plan repairs only
the three input-mutation setups and their necessary lifecycle dependencies.
It supplies no runtime, credential, activation or resolver-continuation authority.

## Files that change

- `scripts/test/control-credential-policy.test.sh`: bounded coordinator, managed
  launcher/observer/termination/trap bookkeeping and complete private controls.
- `docs/components.md`: one short paragraph in the inactive credential-policy
  evaluator section, describing setup retries and unchanged proof boundaries.

No other implementation path changes. Preserve accepted intent/spec/plan, evaluator
and dependency bytes, fixture identities and the original `copy_runtime` body and
position. The source test is d21bd55592760d76cbaf68d475482cd7b20ad9bc, 1075 lines;
the evaluator is 78e309d9220c189b652f6c1ae0c3e4be38713b3c. Source line references
below bind those original bytes, not later shifted lines.

Propose **650–1050 net added lines** for this one concern. Complete required controls
and safe error/retirement handling exceed the standard small-PR signal. The estimate
is 655–1025 net additions: state/traps 90–140, coordinator 65–95, launcher 40–65,
observer 25–40, termination/shared-wait/probe 85–130, control infrastructure 90–140,
four coordinator controls 45–70, lifecycle cases 210–335 and docs 5–10. About 75–110
existing helper lines may be replaced, giving a rough 730–1135 additions and 75–110
removals; these are paired estimates, not independently combinable measured bounds.
The proposed range rounds the computed endpoints outward by 5 and 25 lines.
The estimate comes from the complete existing source and spec proof inventory.
No implementation or runtime size has been measured. Plan acceptance accepts only
the one-concern review-size exception, never missing tests or unreadable code.
Report actual additions/deletions/net. An unexplained overrun returns to the gate.

## Order of work

1. Obtain independent high-risk plan acceptance before implementation. Verify main's
   current spec/intent hashes and risk, then record this plan's accepted blob and
   plan-base. The manager reconciles any existing implementation attempt and claim
   before coder work. Use `ystack/impl/credential-test-synchronization`; preserve any
   existing attempt rather than create a duplicate. A moved base requires the
   current program's fresh independent review/reaffirmation record. Plan-only work
   tracks #291; the terminal implementation PR uses `Closes #291`.

2. Preserve the original failed CI evidence and the rejected earlier plan as history.
   Add the private coordinator controls before wiring the real mutations. Record a
   deterministic initial failure caused by the not-yet-implemented coordinator or
   its missing required behavior; name the actual failure and commit. Never run an
   intentionally unsafe reaped-group signaling experiment to obtain red evidence.
   A later arbitrary syntax/fixture failure does not prove the intended regression.
   Keep the first failed run/log; do not replace it with a later successful sample.

3. Initialize context, operation, lifecycle, pending signal, interrupted-wait flag
   and local-reap identity before traps read them (source 22–64). Add small private
   scalar publication functions for managed entry, operation, ownership, retirement
   and final context release. Their ordinary bodies perform the actual transition;
   controls may call the saved real body then inject at its return boundary.
   Context begins while both globals are empty BEFORE the first launcher and stays
   active through all attempted setups. Publish owned-live only at actual launcher
   admission, after both globals are assigned and while the original FIFO holds
   the real child. Observer return never republishes ownership.

4. Add one managed dispatcher alongside the existing legacy cleanup route. Dispatch
   context, then operation, then lifecycle. HUP/INT/TERM in launching/observing/
   terminating record the first pending signal; they also set the wait flag during
   admitted wait or active local reap. Busy-operation deferral wins over retired
   lifecycle until the caller publishes operation none. At operation none, a signal
   performs terminal cleanup and exits; it cannot return to setup. EXIT never
   recurses into a running helper or signals retired/unconfirmed/rejected/empty
   identity. Keep legacy behavior outside these three managed coordinator calls,
   including the separate signal-child path and successful mutation continuation.

5. Extend the existing termination helper (34–54), not a second terminator. Its
   managed route validates numeric leader=group and own-group exclusion before any
   signal. Rejection publishes rejected-before-signal and fails. Valid ownership
   uses the same TERM/CONT, 100 polls with 0.01s sleeps, optional KILL and another
   100 polls with 0.01s sleeps. A fixed small private Perl probe distinguishes
   kill(0,-PGID) success, ESRCH absence and every other errno/execution/parse error.
   Bound its tiny output and validate exact status/value. Poll errors stay sticky
   and prevent success but do not skip remaining already-owned termination work.
   Capture every ordinary command failure explicitly; no unchecked errexit escape
   may abandon that cleanup or cause a second helper budget.

6. Use one shared actual-builtin-wait boundary and logical-reap loop. Before each
   call clear wait-interrupted; capture the actual wait status explicitly. Repeat
   only same-child wait after a recorded interruption, never signals, polls or gate
   actions. For admitted cleanup publish wait-in-progress before the loop and
   retired-unconfirmed on an uninterrupted return before further commands. Status
   127 stays unconfirmed and terminal; other natural statuses, including 143, do not
   imply interruption by number. The final three-way group probe runs while operation
   remains terminating; only absent plus confirmed reap and error-free probe history
   publishes retired success. Alive/error remains terminal without another signal.
   The caller publishes operation none only after helper result/return, then services
   any pending signal before interpreting the result or doing filesystem work.

7. Extend the launcher only for selected managed setup (364–415). Capture every
   post-fork failure explicitly. Before admission, the existing exact local child
   PID is not a PGID. Attempt original abort token/close/remove while recording all
   failures, then one exact-child KILL and one shared logical reap. Publish an
   active local-reap child identity before waiting; launching dispatch recognizes
   it and sets wait-interrupted. On uninterrupted return retire local authority
   before further commands; 127 is unconfirmed and terminal. Keep operation launching
   through result publication. Original launch error survives cleanup uncertainty;
   no observer or subsequent launch follows, and EXIT cannot signal a guessed group.
   After actual admission, release-write/close/remove failures instead invoke the
   one managed group helper and exit. Do not resume, release twice or bypass cleanup
   when rm fails. Keep successful FIFO, evaluator arguments/default/fourth argument,
   launch bounds and strict callers unchanged.

8. Extend the existing observer (417–476) with a validated private selector and
   initialized explicit outcome. Only exact owned pending marker/path, PID=PGID,
   own-group exclusion, STOP and observed T-state followed by readiness-present
   produces missed-window. Separate find/ps command errors from valid absence.
   All other failures remain terminal; the managed early-exit/direct-wait path and
   other error paths use the managed termination/reap boundary. Default final-output
   observers remain strict. Call coordinator, launcher and observer as ordinary
   commands, never conditional function calls that suppress Bash errexit.

9. Replace only the three start/stop pairs (791–792, 817–818, 841–842) with one
   coordinator. At most three total attempts per case; selector outcomes cannot
   reinterpret arbitrary nonzero status as retry. A miss gets one cleanup, proven
   no descendants, empty case scratch and preserved output under distinct case/
   attempt names. Print a fixed case/attempt miss diagnostic, without payload or
   pass credit. File inspection/preservation failure is terminal and never restores
   retired signal authority. Only complete reconciliation clears old numeric and
   stopped/outcome history before publishing empty. Between attempts context stays
   managed; next launching publication is the initiation boundary. Signal before it
   exits; signal after it belongs to that in-flight launch, which finishes ownership/
   cleanup and exits without observation. No pending signal is reset for a retry.
   A successful ready-absent setup returns a still-live stopped tuple, services pending
   signals and releases context once into the untouched actual mutation continuation.
   No retry is possible after that release. Exhaustion is a distinct failure.

10. Finish all controls listed in Proof, preserving all 45 original assertions and
    the unmodified provenance-unqualified baseline. Add only this short meaning to
    docs/components.md after its credential evaluator description: the three input
    mutation tests allow up to three fully reconciled original-evaluator setups;
    only a proved missed setup window may retry; exhaustion fails; all original
    mutation, refusal and cleanup assertions remain mandatory. This test change
    grants no credentials, enforcement qualification or activation.

## Risks

The highest risk is reusing retired numeric identity after wait or losing live
cleanup through errexit. The old plan delayed clearing globals until after fallible
filesystem work and could re-signal from EXIT. Lifecycle, operation precedence and
one logical reap fix that cause without claiming every inherited signal path is
repaired. Success handoff deliberately returns to unchanged mutation behavior.

A local pre-admission child never becomes a guessed process group. Interrupted wait
may require another physical wait; it cannot repeat KILL, polls, gate writes or a
setup. Returning 127 or final alive/error is failed cleanup, not permission to
resume or to signal a reused number. SIGKILL, the suite alarm, unkillable children
and unexpected shell-abort paths gain no new cleanup guarantee.

A private self-STOP evaluator would change the identity chain and proof meaning;
it is excluded. A parallel process-manager helper would duplicate termination and
make ownership harder to audit; retain one boundary. Shared private control utilities
can reduce repetition, but actual functions, wait, file failures and child identities
must still be exercised. Synthetic helper responses are only coordinator selection
proof, never original-evaluator security evidence.

The 180-second suite alarm remains unchanged. Sleep limits are not elapsed bounds:
launcher/marker/stopped-state request up to 1/5/1 seconds of sleep, managed termination
up to 2 seconds, plus subprocess and evaluator costs. At most six extra original
setups are possible across the three mutation cases. No new control has a measured
time yet; Perl probe startup and zombie/group observations may dominate. Use real
owned disposable children for lifecycle controls rather than unnecessary full
policy evaluations. If complete proof cannot fit the original alarm, retain failure
and return to design; no timeout increase, platform skip or retry-until-green.

## Proof

### Original behavior and private harness

Preserve the complete 45-check inventory and expectation bodies at the source blob:
source-order/reverse-byte checks, identity construction, ordinary baseline, security
and refusal cases, three actual mutation/restoration/replacement/empty-scratch/
no-descendant paths, four strict final-output cases and separate child-signal path.
Compare the full source diff, not only the printed pass count. Preserve copy_runtime
body/position and all evaluator/dependency blobs. No fixture-chain rebinding.

Run failure controls in a fresh real /bin/bash process with set -e enabled; the
outer suite captures status explicitly and increments passes only after checking
all evidence. Bash $$ in a parentheses subshell may still name the main suite:
never use it blindly for self-signaling. Establish the fresh shell's own PID/PGID
and verify it against the outer-owned child handle before any control signal.
Private generated scratch scripts may contain saved trusted function definitions
and fixed fixture code; no new shipped file, public switch or evaluator injection.

Place control execution after the existing *.out claim-result scan (727–732), and
keep synthetic output under distinct private names. Each override calls its saved
actual boundary, captures the real status and records the reached point before
injecting once. Parent checks include named failure, boundary, signal/launch/helper/
KILL/logical-reap/physical-wait counts, actual child/group cleanup when claimed,
no next launch and no mutation. Synthetic numeric identities remain fully inert.
No guessed sleep substitutes for an actual boundary acknowledgment.

### Required control matrix

H/I/T means separate HUP, INT and TERM instances. Parent aggregation must preserve
per-instance evidence; 49 is not a final blanket check count.

| Cases | Actual boundary or controlled input | Required evidence |
| --- | --- | --- |
| Four coordinator controls |Actual coordinator with private synthetic miss→success, three misses, ordinary error, miss→cleanup error |Respectively two launches/one continuation; three launches/no mutation; one launch/no retry; one launch/no retry. Named outcomes and reconciliation counts required. |
| Entry H/I/T |After managed-entry scalar publication, before launcher |Empty tuple, terminal signal, zero launches. |
| Admission H/I/T |After actual owned-live publication while original FIFO holds real child |Launching defers; one cleanup, terminal return, no observer/mutation. |
| Classification H/I/T |After actual observer missed-window publication, before return; real owned stopped fixture with pending/ready markers |Deferral and one real cleanup; no re-admission or retry. |
| Observer-return H/I/T |After actual observer returns and operation none is published, before outcome handling |Immediate terminal dispatch; no stale ownership or mutation. |
| Next-launch H/I/T, both sides |After real retirement/reconciliation, immediately before and after actual launching publication |Before: no launch. After: at most that initiated launch, fully cleaned before terminal return; no later attempt. |
| Pre-admission file failure |Real FIFO-held child, actual gate rm fails because fixture pathname became an owned nonempty directory |One exact-child KILL/logical reap, no group signal/observer, original failure terminal. |
| Local reap H/I/T |Same real file-failure case; inject after actual local wait returns before shared boundary return |Launching flags interruption; physical wait may repeat, KILL/gate/polls do not; retire locally, original failure survives. |
| Admitted release/file failure |Real admitted group; actual release write fails, then actual rm fails |One real managed helper/reap; no resume, repeated release or EXIT termination. |
| Retired inspection failure |Real helper retires, then actual find fails because private fixture moved its scratch root |Named terminal file error; no old-tuple signal/helper or launch. |
| Retired preservation failure |Real helper retires, then actual rename fails because its owned destination parent moved |Distinct named terminal error; same no-revival proof. |
| Group reap H/I/T |After actual builtin wait before shared boundary return |Flag-driven wait-only repeat; real final probe before caller dispatch. |
| Helper-return H/I/T |After helper return and operation none, before reconciliation |Immediate terminal exit without old-tuple signal. |
| Pre-wait H/I/T |Inside actual managed termination before logical wait |Deferral, original remaining cleanup completes once. |
| Retired-pre-probe H/I/T |After actual retirement publication, before real final probe |Busy-operation rule wins; probe runs before pending-signal exit. |
| Ownership rejection |Invalid identity or own-group exclusion, inert synthetic identities only |Rejected-before-signal, zero delivered signals and no retry. |
| Actual absence |Real child, real reap and real ESRCH probe |Retired success only after confirmed reap/error-free probe history. |
| Probe refusal cases |Private inert final-alive, errno error, malformed output and failed executable/status controls |Each distinct failure remains unconfirmed; remaining owned budget completes; no retry or second signal budget. |
| Wait status cases |Supplementary uninterrupted127 in local and admitted modes, recorded interruption/completed status, natural signal status |127 terminal/no observer; only recorded flag repeats wait; natural143 alone does not. |

For admitted release failure, closing only the owned fixture gate FD before actual
release creates a real write error; replacing its pathname before actual rm creates
the second real error. Keep child identity genuine. Parent checks fixture cleanup
after verifying the negative result. Never remove actual mutation scratch to fake
successful reconciliation. Probe/status overrides supplement real reap/absence
controls; they do not prove absence themselves or signal invented IDs.

The old Bash3.2 experiment exited 1. Its sleep-timed during-wait case is inconclusive,
not passing evidence. Required controls observe real post-reap/pre-return and
post-return boundaries; they do not claim a signal inside Bash's blocked syscall.
Supplementary status controls cover flag logic without pretending that observation.

### Commands, evidence and final gates

Record the actual implementation base, head, full logs, platform, Bash version,
per-control/phase elapsed time, observed poll counts, setup misses and exhaustion.
Run the full focused suite once per required platform for each meaningful candidate:

```sh
bash scripts/test/control-credential-policy.test.sh
```

Require all original 45 assertions, four coordinator controls and the entire matrix
on native Darwin/Bash3.2 and required Linux CI under the same 180-second alarm.
No failed run is discarded or converted into proof by a later rerun. A changed
implementation may receive fresh proof, with earlier failure retained and explained.

On the final committed implementation head, run:

```sh
git diff --check BASE HEAD
git diff --name-only BASE HEAD
git diff --numstat BASE HEAD
bash scripts/check-rename.sh
```

Replace BASE with the recorded full implementation-base OID. Require exactly the two
allowed paths, readable complete proof and size explained against the accepted range.
Verify current accepted spec/intent/plan blobs by `git rev-parse HEAD:<artifact-path>`;
none may differ from the manager's accepted tuple. Compare complete original assertion
sections and strict-call behavior in independent review.

Run pinned ShellCheck 0.11.0 with `shellcheck -x -S style` over the repository shell
files as CI does. Require all existing final-head/base CI jobs: checks, all six test
shards and ci aggregate. The shard command is
`bash scripts/test/run-all.sh --shard N/6` for each actual N from 1 through 6.
No workflow, timeout, sharding, schema or manifest change is permitted.

A non-author read-only reviewer applies Bugs/Security/Compliance passes to the full
implementation, all original/new proofs and exact head/base. The manager reads the
complete raw review, resolves every Important finding and requires all CI green
before protected merge. Plan or G2 review/CI is never implementation evidence.
