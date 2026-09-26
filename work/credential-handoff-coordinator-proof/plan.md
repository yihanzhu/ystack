---
spec-blob: fa4403204861ab76184e7872a39f3b60537c493b
drafted: 2026-09-26
---
# Plan: credential-handoff coordinator proof

Tracks #412. This high-risk, diagnostic-only plan requires independent review and
protected merge before implementation. It binds accepted intent
`fce779025e17d277f093060b3788788033674b0d` and planning base
`43394fe8944c388065f8de9fa13e9352095b4aac`.

## Scope and order

Change only `scripts/test/control-credential-policy.test.sh`. Its base blob is
`6de2eeed77a3ec6722e1d011e4ff91105b91dd4d`. Keep the diagnostic inside its existing
private generated worker/coordinator and failure formatter. Use the existing Bash
and inline Perl conventions; add no dependency, public helper or restore file.

Use `review_size: standard`, with an implementation estimate of 240–360 net lines
for recording, complete-content validation, export and focused assertions. Preserve
readable code and complete proof; an unexplained overrun returns for a separate size amendment.

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
Existing excerpts may appear only after their entire source passes the same content
validation as export. Otherwise use a fixed withheld marker. Never print raw tokens,
paths or parser errors. Formatting cannot bypass validation or hide required fields.

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
EOF within the bound, stable descriptor metadata and independently confirmed writer
completion. A changing or potentially live file is not eligible for payload export.

Validate the whole buffered content before emitting any payload from that file,
including summaries or excerpts. Export from that validated buffer, never reopen it.
Each grammar is anchored at both ends, consumes every byte, and accepts only fixed
record shapes. Reject extra fields/lines, NUL, control bytes other than specified LF,
unknown tokens, overlong numbers and malformed records. Do not salvage safe-looking
lines from a rejected file. No permissive wildcard, printable-text fallback,
general shell-error regex or sanitizer can qualify content.

- Coordinator records allow only the phase list above, fixed entry/completion/exit
  record names, ordinals 0 or 1, canonical decimal statuses 0–255, flags 0 or 1
  and the four fixed
  request/ack outcomes. Missing ordinals remain unobserved, not fabricated records.
- Worker and child events use separate finite alternatives derived from their
  existing literal event sites. Hardcode the alternatives; do not infer a grammar
  from captured output. Enumerate their phase, operation, failure, lifecycle,
  signal and outcome names; variable fields are only bounded statuses/counts/flags,
  validated PID/PGID values or fixed tokens such as `delivered`. No arbitrary trailing
  field is accepted. In particular, the existing raw acknowledgment event is accepted
  only with its exact expected/empty token; unknown text withholds the whole file.
- Identity files accept only their exact two-positive-decimal/space/LF grammar and
  validated PID/PGID values. PID fields must match the case's separately validated
  worker/child identities or an owned identity in the fully validated child event
  ledger. Use canonical positive decimals of at most 10 digits, at most 2147483647;
  case counters are bounded by existing launch/wait limits, not arbitrary integers.
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
line numbers, counts and end markers; no partial frame counts as complete.

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

Add assertions inside existing diagnostic/timing controls without adding, deleting
or renaming a ledger case. Use small synthetic records to check helper exit 1 versus
wait 143 with an interruption flag, natural 143 without that flag, status 127 and
missing exit data. Check distinct ordinals including an unobserved second ack.
These parser controls are not evidence that a real helper completed.

Exercise the actual exporter with fixed synthetic private files: validated record
and empty round trips, the exact allowed nonempty synthetic payloads, valid and
invalid boundary values, unknown tokens, trailing bytes, missing/nonregular files,
bound+1 data and unconfirmed-writer states. Verify all 14 IDs, order, states, framing,
summary and total byte limits. Decode eligible output after deleting only the
completed synthetic fixture and compare with retained expected bytes. Keep the
existing 4096-byte stderr control and escaping/bound assertions, using only validated
synthetic sources. Do not delete failed-case or unresolved scratch for this proof.

Inject synthetic secret-like markers into each generic stream and every variable
record/text surface, including raw acknowledgments, diagnostic excerpts and content
after a valid prefix or final LF. Also place markers beyond a byte bound. Assert
that neither export nor summary/error output contains their raw bytes, hex encoding,
prefix or content hash. A file with a valid initial record and a forbidden suffix
must emit zero payload, proving whole-file validation precedes disclosure. Unknown
fields yield only fixed withheld/incomplete markers and prevent inventory completion.
Keep these focused assertions inside existing controls; no new ledger cases, signal
injection, retries or test framework are needed.

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
