---
intent-blob: fce779025e17d277f093060b3788788033674b0d
risk: high
---

# Spec: credential-handoff coordinator proof

## Scope

Change only `scripts/test/control-credential-policy.test.sh`. The work makes the
existing credential-handoff timing failure diagnosable. It does not repair a timing
or coordinator behavior unless the diagnostic later establishes that cause and a
separate accepted plan permits that repair.

The expected implementation is a focused 100-180 net-line test change. It extends the
existing private coordinator and generated worker records; it does not add a generic
coordination framework.

## Requirements

1. On a credential-handoff proof failure, retain the coordinator helper's actual exit
   status as a distinct fact. Do not treat a nonzero parent `wait` interrupted by a
   signal as the helper's exit status. An unknown or interrupted helper status remains
   explicitly unconfirmed.
2. Use a fixed, bounded diagnostic record that names the last completed phase and the
   failing phase. Record each request and acknowledgment with its ordinal and outcome.
   Record helper completion and tested-child completion as separate facts.
3. The expected-status mismatch path must write the diagnostic to Linux-visible failure
   output before cleanup. The record must diagnose the failure without relying on an
   ephemeral scratch path. It may contain no credential value, credential-like input,
   or unbounded child output.
4. Alongside that summary, keep a finite, explicit inventory of the complete private
   failed-case records and streams recoverable byte-exact after runner exit. Each item
   has a stated byte bound and escaped or encoded transport so its boundaries are
   unambiguous in failure output. Missing or truncated evidence remains visibly
   incomplete. This requirement does not decide scratch ownership.
5. Keep the existing timing proof intact: status 64 remains required; the two signal
   interruptions remain real; ordinary direct-child completion and descendant-retirement
   checks remain required. Keep the 167-case ledger, finite coordination reads, and the
   180-second suite alarm unchanged.
6. Add focused assertions for the diagnostic fields, inventory, and bounds. They must prove
   that the two acknowledgment records remain distinct and that a helper exit status is
   not confused with an interrupted parent wait.

## Non-goals and boundaries

Do not change production code, CI, workflows, credentials, timeouts, retries,
assertion strength, repository settings, authority, or the paused #264 / PR #373
evidence. Do not accept status 70, skip the timing proof, or make a speculative timing
change. Do not add a second coordinator-wait consumer, move a signal placement, change
a deadline, or fabricate helper completion. A repair is allowed only for a cause
demonstrated by this diagnostic and only after a separate high-risk plan amendment.

## Proof

Run the affected credential-policy test and inspect its failure-path checks. The later
implementation review requires an exact-head/base review and the required Linux matrix.
The bounded diagnostic and the complete failed-case inventory must be recoverable from
Linux failure output after the test's temporary directory is gone.
