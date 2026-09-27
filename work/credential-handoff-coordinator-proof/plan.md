---
spec-blob: fa4403204861ab76184e7872a39f3b60537c493b
drafted: 2026-09-26
---
# Plan: credential-handoff coordinator proof

Tracks #412. This high-risk, diagnostic-only plan requires independent review and
protected merge before implementation. It binds accepted intent
`fce779025e17d277f093060b3788788033674b0d` and planning base
`52cb18bacc52e094c876a3da558d3987988f7ff0`.

## Scope and order

Change only `scripts/test/control-credential-policy.test.sh`. Its base blob is
`6de2eeed77a3ec6722e1d011e4ff91105b91dd4d`. Keep the diagnostic inside its existing
private generated worker/coordinator and failure formatter. Use the existing Bash
and inline Perl conventions; add no dependency, public helper or restore file.

Use `review_size: accepted-exception`, with an implementation estimate of 1130–1240 net lines
for recording, coherent record and writer validation, bounded export and complete
recovery/disclosure controls. Measure cumulative additions minus deletions in the
sole allowed implementation file against accepted implementation base
`6bd47f0a5e3b7fff2472663692d6a5ccc473985f`, including all implementation commits and
pending edits, never only the incremental diff from current HEAD. Preserve readable
code and complete proof; an unexplained overrun returns for a separate size amendment.

Before new or resumed code, verify the fresh accepted artifact hashes, plan-base
and build claim. Preserve the existing implementation and first failed evidence.
After this plan lands, merge updated main into that same implementation branch
without reset, rebase or replacement, then recheck its tuple before revision.
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

Observe the suite's existing sole `builtin wait "$worker"` in place as well. Set
separate outer-worker wait-active/interrupted flags; the existing signal dispatcher
only marks interruption while that wait is active, then keeps its original behavior
and return status. Capture the original wait return before formatting. Supply these
facts from the caller to the exporter; do not infer them from worker-written files.
An interrupted wait, status 127 or missing capture leaves worker completion
unconfirmed. A natural status above 128 alone does not. Do not add another wait,
retry, signal, probe, clock or timeout, or change the expected-status branch. All
worker-dependent evidence stays ineligible when that completion is unconfirmed.

Record request writes and acknowledgment reads at the existing `boundary`,
`control_wait_before_wait` and `proof_wait_validate` sites, with ordinal, original
status and a fixed outcome (expected token, empty, unexpected or unobserved).
Keep coordinator acknowledgment writes distinct from worker acknowledgment reads.
Map raw request/acknowledgment input to those enums before writing new records.
Do not add reads to recover missing acknowledgments. Both ordinals appear in the
summary even if the second was never reached. Never copy arbitrary token text.
Existing raw events remain private until their complete content passes validation;
unexpected text must not be made exportable by deleting or normalizing it.
Keep direct-child wait status, helper completion and descendant confirmation as
three separate facts; absent retirement evidence remains unconfirmed.

## Failure output and complete private inventory

Extend `handoff_worker_diagnostic` with a fixed, at-most-2048-byte summary containing
case/result/expected, last completed and failing phase, both request/ack outcomes,
helper exit observation, helper wait status/interruption/completion, tested-child
wait status and descendant confirmation. Build it only from validated enum/numeric
fields; case/operation/signal names come only from the existing fixed case ledger.
Malformed, missing or contradictory fields become explicitly unconfirmed.
Preserve the existing escaped-excerpt assertion: a completed observation-error
control must supply a bounded excerpt from an eligible, completely validated event
source containing LF, rendered as `\x0a`. Use the existing 256-source-byte escape
limit and 2048-byte total summary cap. Otherwise emit a fixed withheld marker.
Required fields precede the optional excerpt. Never remove the escaping assertion,
print raw tokens/paths/parser errors, or format before writer/dependency validation.

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
paths are excluded. Intended synthetic dataflow alone does not prove captured
output safe: inherited environment, shell errors and raw acknowledgments can reach
these files. Encoding is transport, never content validation.

Implement one private inline Perl exporter/validator with an explicit ID-to-path,
bound and grammar table. Do not recurse, follow links, drain FIFOs or inspect
production output. Use the existing nonblocking/no-follow open and regular-file
descriptor checks. Buffer at most bound+1 bytes with checked reads and close. Require
EOF within the bound, stable descriptor metadata and confirmed writer completion.
Parse into private local facts first; no parsed value is yet eligible for output.
Validate shapes, sequences, identities and dependencies before formatting anything.
Use this finite dependency order, without extra reads, waits, probes or process control:

1. The caller's captured outer-worker wait establishes worker completion. Its
   validated launch identity binds worker-written records. No worker event can
   establish the completion of its own writer.
2. Eligible worker events establish the helper's sole wait outcome and the control
   child's actual direct-wait outcome. Only uninterrupted, non-127 ordinary waits
   confirm their respective writers; check their complete recorded wait sequences.
   An early helper failure can leave later retirement records absent. An ordinary
   direct-child wait does not by itself prove descendant retirement.
3. Helper records require helper-writer eligibility. Reconcile their observed exit
   status with the eligible helper wait before any helper field can be reported.
   Child records require control-child eligibility. Fixture streams additionally
   require the existing complete owned-descendant termination/reap/absence evidence.
4. A child-diagnostic or summary excerpt requires every embedded source to be
   eligible after those checks. Withholding propagates to all dependent content,
   even when its immediate writer completed. Never cache a derived field across
   later source invalidation. A helper exit observation remains distinct from
   confirmed reaping, but an ineligible observation is printed only as unconfirmed.

A changing or potentially live file is never eligible for payload or derived output.
Use private functions and fixed records within this exporter, not a generic graph,
supervisor, coordination framework or second implementation of process lifecycle.

Validate the whole buffered content before emitting any payload from that file,
including summaries or excerpts. Export from that validated buffer, never reopen it.
Each grammar is anchored at both ends, consumes every byte, and accepts only fixed
record shapes. Reject extra fields/lines, NUL, control bytes other than specified LF,
unknown tokens, overlong numbers and malformed records. Do not salvage safe-looking
lines from a rejected file. No permissive wildcard, printable-text fallback,
general shell-error regex or sanitizer can qualify content.

- Coordinator records allow only the phase list above, fixed entry/completion/exit
  record names, ordinals 0 or 1, canonical decimal statuses 0–255, flags 0 or 1
  and the four fixed request/ack outcomes. Check the fixed phase order for each
  selected operation and ordinal: entry precedes its one matching completion; the
  second request follows the first. Permit only a valid terminated prefix on failure.
  Require exactly one final exit record, no records after it, and last/pending values
  equal to the sequence's last successful and outstanding/failed phases. A successful
  exit requires all expected phases and no recorded write error. A nonzero exit
  may end with one pending phase entry; unmatched completions, extra entries,
  duplicates, reordered or contradictory records are invalid. Missing ordinals
  remain unobserved, never fabricated; a recorded write error makes proof incomplete.
- Worker and child events use separate finite alternatives derived from their
  existing literal event sites. Hardcode the alternatives; do not infer a grammar
  from captured output. Enumerate their phase, operation, failure, lifecycle,
  signal and outcome names; variable fields are only bounded statuses/counts/flags,
  validated PID/PGID values or fixed tokens such as `delivered`. No arbitrary trailing
  field is accepted. In particular, the existing raw acknowledgment event is accepted
  only with its exact expected/empty token; unknown text withholds the whole file.
  Accept actual producer spelling, including `kill -TERM -- -PID` and the matching
  CONT/KILL forms. Never rewrite producer events to fit the validator. Enforce each
  case's finite event multiplicities and ordering: one launch/identity per role,
  one helper-wait result, one request and final acknowledgment per ordinal, and
  the permitted direct-child interrupted waits followed by its ordinary result.
  Reconcile raw and normalized acknowledgments, statuses, interruption flags and
  completion claims. Conflicting duplicates cannot be resolved by first/last match.
  Check cross-record implications only where both observations exist; a delivered
  write does not manufacture a successful read or fill absent evidence.
- Identity files accept only the exact two-positive-decimal/space/LF grammar.
  Bind roles separately: the outer captured job and checked group bind the worker;
  its unique captured coordinator record binds the helper; its unique launched job
  plus published child identity bind the control child. An `owned` event identifies
  a separate evaluator descendant, never the control child. Bind every PID-bearing
  event to its proper role, including launch observers, outer signals, direct waits,
  owned group signals, physical/logical reaps and descendant-absence records. Require
  the producer's PID/PGID relationships, not mere membership in a bag of numbers.
- Copy all regex captures and numeric arguments into lexical values before another
  match or validator call can overwrite them. Every status field in every record,
  summary argument and diagnostic uses the same canonical decimal 0–255 check.
  PIDs are positive canonical decimals of at most 10 digits and at most 2147483647;
  flags and ordinals use their fixed sets; counters use the case's existing limits.
  Bind case, operation, signal, identity mode and expected status as one exact entry
  in the existing 68-case ledger, retaining uppercase signal names. Reject arbitrary
  names and invalid tuple combinations without echoing them. Synthetic controls use
  valid ledger entries and independently known fixture-role bindings.
- Generic stdout/stderr accepts only empty bytes, plus these complete synthetic
  exceptions at their stated IDs: `worker-failure: coordinator\n` at worker-stderr,
  and exactly 4096 `x` bytes at child-stderr for the observation-error control.
  The `\n` here denotes one LF. All other nonempty captures are withheld, including
  utility errors, paths and shell job notices. Adding a payload needs plan acceptance.
- A nonempty child-diagnostic must match the existing fixed formatter exactly using
  validated enum/numeric fields and excerpts derived from fully validated identity,
  child-event and child-stderr buffers. Require byte-for-byte reconstruction of its
  existing escaping and 2048-byte cap. This comparison accepts only known formatter
  output; it does not authorize embedded text or truncated source validation.

For an eligible file, transport its exact bytes as lowercase hex, 128 raw bytes per
numbered line, between fixed begin/end records naming ID, byte count and bound.
Empty files have an explicit zero-byte complete record. Raw payload limits total
96512 bytes; hex plus fixed framing stays below 256 KiB. Decoder checks IDs, order,
line numbers, counts and end markers; no partial frame counts as complete. Check
every output write and final close/flush so failed transport cannot report success.
A later write failure may leave an incomplete frame; a missing final marker remains
incomplete and never licenses a retry or cleanup.

Missing, nonregular, oversized, changing, live, unreadable or content-unproven files
emit only their fixed ID and withheld/incomplete state, with an optional fixed reason
enum. Emit no content, prefix, encoded fragment, content length or hash for them.
This includes the entire oversized file: the former bounded-prefix transport is
forbidden. Error handling must not echo offending input or native parser/OS errors.
Emit a final inventory-complete/incomplete marker; its absence is incomplete.
Export failures never hide the original mismatch or clear scratch retention.

Preserve all original private bytes and ownership, including rejected content.
Do not rewrite raw evidence to fit the grammar. For eligible files, log decoding
must reproduce every byte after runner exit. Withholding is a disclosure refusal,
not fulfillment of the accepted evidence requirement. Any required withheld, missing
or incomplete record blocks diagnosis and completion; neither a safe summary nor
partial inventory substitutes for complete necessary evidence. Do not claim G2
satisfied by relaxing that requirement. If complete necessary evidence cannot be
safely retained under this design, stop for a separately accepted G2 amendment before
changing scope or acceptance. No waiver is inferred from this plan or exporter.

## Focused proof and acceptance

Keep diagnostic assertions within the existing private test without adding,
deleting or renaming a ledger case. Use bounded synthetic records and explicit
caller wait facts to check interrupted outer-worker waits; helper exit 1 versus
wait 143 with interruption; natural 143 without interruption; status 127; missing
exit data; and both distinct acknowledgment ordinals, including unobserved second
acknowledgment. Test duplicate/conflicting waits and acknowledgments, exit-before-
phase, unmatched/reordered phases and inconsistent last/pending values. These
controls verify refusal and classification, not actual process completion.

Exercise role separation using distinct worker, helper, control-child and owned
identities. Include genuine group-kill spelling, role swaps, unknown IDs, each
numeric maximum/max+1, zero/negative/leading-zero/overlong/malformed values, and
multiple captures passed through validators. Require no numeric warnings. Test
uppercase ledger names, invalid tuple combinations and the synthetic stderr
exception under both its allowed operation and a disallowed one.

Exercise the actual exporter with fixed synthetic private files: validated record
and empty round trips, the exact allowed nonempty synthetic payloads, valid and
invalid boundary values, unknown tokens, trailing bytes, missing/nonregular files,
bound+1 data and unconfirmed-writer states. Verify all 14 IDs, order, states, framing,
summary and total byte limits. Preserve expected bytes for all 14 IDs, remove only
the completed synthetic source fixture, decode the saved log, and compare every
reconstructed file byte-for-byte, including empty files and final LF. The decoder
requires exactly the fixed ordered ID list, one nonnested frame per ID, correct
bounds/counts/contiguous line numbers/even-length lowercase hex, complete end records
and one final complete marker. It must reject missing, reordered, duplicate, unknown,
malformed, nested, truncated and trailing frames/lines; no silent skipping. Recognize
only one complete grammar-validated summary line before inventory framing. Exercise
failed output writes without disclosing source bytes or claiming complete transport.
Keep the 4096-byte stderr and eligible escaped-excerpt/bound assertions. Do not
remove failed-case or unresolved scratch to demonstrate recovery.

Inject synthetic secret-like markers into each generic stream and every variable
record/text surface, including raw acknowledgments, diagnostic excerpts and content
after a valid prefix or final LF. Also place markers beyond a byte bound. Assert
that neither export nor summary/error output contains their raw bytes, hex encoding,
prefix or content hash. A file with a valid initial record and a forbidden suffix
must emit zero payload, proving whole-file validation precedes disclosure. Unknown
fields yield only fixed withheld/incomplete markers and prevent inventory completion.
For each rejected item, assert zero payload lines and no begin-complete frame, plus
its fixed withheld marker and the final incomplete marker; marker absence alone is
insufficient. Use a finite table covering every variable field of each accepted
record shape, all stream IDs, raw acknowledgments, diagnostic fields/excerpts and
ineligible writer/dependency combinations. Include a valid suffix/prefix around an
invalid field and otherwise valid content from unconfirmed writers. Verify that
withheld child sources invalidate their worker-written diagnostic, and withheld
helper sources invalidate every helper-derived summary field. No new signal
injection, retry or test framework is authorized.

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
