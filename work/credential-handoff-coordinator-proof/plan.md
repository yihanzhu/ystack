---
spec-blob: fa4403204861ab76184e7872a39f3b60537c493b
drafted: 2026-09-26
---
# Plan: credential-handoff coordinator proof

Tracks #412. This high-risk, diagnostic-only plan requires independent review and
protected merge before implementation. It binds accepted intent
`fce779025e17d277f093060b3788788033674b0d` and planning base
`5f2c496fc96316690563a32637fa3262f68b2257`.

## Scope and order

Change only `scripts/test/control-credential-policy.test.sh`. Its base blob is
`6de2eeed77a3ec6722e1d011e4ff91105b91dd4d`. Keep the diagnostic inside its existing
private generated worker/coordinator and failure formatter. Use the existing Bash
and inline Perl conventions; add no dependency, public helper or restore file.

Use `review_size: standard`, with an implementation estimate of 100–180 net lines
for recording, export and focused assertions. Preserve readable code and complete
proof; an unexplained overrun returns for a separate size amendment.

Before code, verify the fresh accepted artifact hashes, plan-base and build claim.
Preserve run 36251606932 and PR #373 unchanged. Its status 70 versus required 64
proves a coordinator-path failure, but neither its cause nor helper completion.
Implement the records and exporter below, then run their focused controls and the
affected proof. No behavioral repair is included. If the new evidence identifies
a cause, pause with the exact clean/dirty attempt tuple and raw evidence for a
separately authored and independently accepted high-risk plan amendment.

## Record operations without changing them

Within `start_coordinator`, append fixed records to one private
`coordinator.records` file. Use Bash builtins on the timing path. Record the ordinal
(0 or 1), phase entry, phase completion and original operation status. Phases are
request-read, request-check, pid-read, group-read, identity-check, child-ready-read,
child-ready-check, child-continue-write, child-continued-read,
child-continued-check, signal-send and ack-write. Non-wait cases omit the child
handshake phases explicitly. Keep every original read timeout, command, predicate,
signal destination, signal placement and exit decision. Observe each original
status before any formatting can overwrite it. Never turn an existing guarded
operation into a broader conditional context that changes Bash errexit behavior.

An EXIT observer in that helper captures its incoming status before recording the
last completed and pending/failing phase, then preserves that exact exit status.
A missing, partial or invalid exit record means helper exit unconfirmed. The exit
record is an observed shell exit status, not proof that the parent reaped it.
Recording errors remain visible as incomplete evidence; they cannot replace the
original failure or convert it to success. Capture coordinator stdout and stderr
in their own private files instead of mixing them into worker output.

Instrument the sole existing `finish_coordinator` wait in place. Record its raw
return status and a dedicated wait-active/interrupted observation flag. The
worker's existing signal wrapper marks that flag without changing dispatch or
handler return behavior. Do not reuse the tested child's wait flag. Classify a
trapped interruption as unconfirmed even if an exit record exists; status 127 or
missing capture also stays unconfirmed. An uninterrupted ordinary wait confirms
helper completion and its status. Preserve the current nonzero-to-worker-failure
branch, including status 70; no added wait, retry, probe, signal or cleanup follows.
Natural status above 128 alone is not an interrupted wait.

Record request writes and acknowledgment reads at the existing `boundary`,
`control_wait_before_wait` and `proof_wait_validate` sites, with ordinal, original
status and a fixed outcome (expected token, empty, unexpected or unobserved).
Keep coordinator acknowledgment writes distinct from worker acknowledgment reads.
Do not add reads to recover missing acknowledgments. Both ordinals appear in the
summary even if the second was never reached. Never copy arbitrary token text.
Keep direct-child wait status, helper completion and descendant confirmation as
three separate facts; absent retirement evidence remains unconfirmed.

## Failure output and complete private inventory

Extend `handoff_worker_diagnostic` with a fixed, at-most-2048-byte summary containing
case/result/expected, last completed and failing phase, both request/ack outcomes,
helper exit observation, helper wait status/interruption/completion, tested-child
wait status and descendant confirmation. Put these fields before optional existing
excerpts so excerpt truncation cannot hide them. Parse only the fixed record grammar;
malformed, missing or contradictory fields become explicitly unconfirmed.

Call a private inventory exporter on the existing expected-status mismatch path,
after that summary and before `fail`/cleanup. It emits exactly the items below in
fixed order. P means the failed case's proof directory; C means its existing
`proof-<case>-none` child directory. These are internal lookup roots, not log paths.

| Fixed item IDs / source | Maximum raw bytes per item |
| --- | ---: |
| coordinator-records, coordinator-stdout, coordinator-stderr / P/coordinator.records, P/coordinator.stdout, P/coordinator.stderr | 4096 each |
| worker-events / P/events; child-events / C/events | 16384 each |
| worker-stdout, worker-stderr, child-stdout, child-stderr / P/worker.stdout, P/worker.stderr, P/child.stdout, P/child.stderr | 8192 each |
| worker-identity / P/worker-identity; child-identity / C/identity | 128 each |
| child-diagnostic / P/diagnostic | 2048 |
| fixture-stdout / C/fixture.out; fixture-stderr / C/fixture.err | 8192 each |

The inventory contains only these 14 private diagnostic files. Generated scripts,
FIFOs, scratch contents, credentials, inputs, environment and arbitrary discovered
paths are excluded. The fixture uses `unused` inputs and emits no credentials.
Do not recurse, follow links, drain FIFOs or inspect production output. Use the
existing Perl nonblocking/no-follow open and regular-file descriptor checks. Read
at most bound+1 bytes per item with checked reads and close; no unbounded slurp.

Transport bytes as lowercase hex, 128 raw bytes per numbered line, between fixed
item begin/end records naming ID, byte count, bound and state. State distinguishes
complete, missing, nonregular, read-error and truncated. Empty regular files have
an explicit zero-byte complete record. Detect file changes during capture and
mark them incomplete. When a writer's completion is unconfirmed, label its bytes
as a snapshot, never complete evidence of its eventual output. Emit a final
inventory-complete/incomplete marker; absence of that marker means incomplete.
Raw payload limits total 96512 bytes; hex plus bounded framing must stay below
256 KiB. Export errors never hide the original mismatch or clear scratch retention.

For present regular files within bounds and with confirmed writer completion,
decoding the log must reproduce every byte, including NUL and final newlines.
Oversize files expose a bounded prefix and a truncation marker, never a full-evidence
claim. Do not claim the Linux failure diagnosed when required records are missing,
truncated or still live. Preserve the existing scratch ownership and unresolved
states regardless of export success; an exporter cannot authorize cleanup.

## Focused proof and acceptance

Add assertions inside existing diagnostic/timing controls without adding, deleting
or renaming a ledger case. Use small synthetic records to check helper exit 1 versus
wait 143 with an interruption flag, natural 143 without that flag, status 127 and
missing exit data. Check distinct ordinals including an unobserved second ack.
These parser controls are not evidence that a real helper completed.

Exercise the actual exporter with fixed synthetic private files: binary/newline and
empty round trips, exact-bound and bound+1 data, missing/nonregular inputs, and
unconfirmed-writer snapshots. Verify all 14 IDs, order, states, framing, summary
and total byte limits. Decode after deleting only this completed synthetic fixture
and compare against retained expected bytes. Keep the existing 4096-byte stderr
control and summary assertion; distinguish its summary from the new inventory.
Do not delete failed-case or unresolved scratch to demonstrate recovery.

On the implementation commit, run syntax checks for the test and generated Bash,
pinned ShellCheck 0.11.0, and the complete affected test under native Darwin Bash
3.2 and supported Linux Bash, with recorded interpreter identities, exit status,
whole-process elapsed time and raw stdout/stderr. Do not bypass the 180-second
alarm. Keep all 99 original plus 68 handoff results, including status 64, two real
TERM interruptions, ordinary child zero completion and actual descendant checks.
Inspect those real records separately from synthetic formatter controls.

Require green automatic CI and independent exact-head/base review. The required
Linux matrix must run and be recorded; its affected failure log must contain the
summary and decodable inventory without relying on a surviving runner path.
Keep the first failure and source identity. A passing diagnostic run is not a
root-cause diagnosis or permission to retry unchanged work until green. Any failure
remains a blocker; use its evidence for the next accepted change. PR #373's full
milestone matrix remains separately required before dependent work is accepted.

Compare the final diff and ledger against the base. Keep production, workflows,
timeouts, assertions, signal placement, wait consumers, authority and paused
self-host evidence unchanged. Instrumentation may perturb timing; report that
limit and stop if the unchanged proof cannot fit, rather than extending its alarm.
