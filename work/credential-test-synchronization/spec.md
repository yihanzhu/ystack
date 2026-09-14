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
Clear PID/group/stopped-marker and per-attempt outcome state only after that
reconciliation. A later attempt creates a fresh evaluator and runtime scratch;
no earlier marker or child can satisfy its checks.

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

### R3. Contain retry selection to these three cases

Add one private input-setup coordinator for the three call sites. It calls the
existing launcher and stop observer with an explicit, narrowly named selection
that allows the single R1 missed-window outcome. All other observer callers retain
their current fail-on-miss behavior. The launcher, its evaluator default/fourth
argument, FIFO protocol, signal/wait helpers and termination bounds stay unchanged.
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
workflow/shard changes, relaxed time limits, other process/signal/cleanup races,
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
