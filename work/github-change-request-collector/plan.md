---
spec-blob: 2fe4010ab84858d65daa6df212313c651e1f8021
risk: high
drafted: 2026-10-27
---
# Plan: Implement the bounded GitHub collector

Tracks #304. This plan implements the accepted spec without changing its outcome.
The upstream intent blob is `7b59b50a2d31b6d86035ad194a2b99ee6a1a6df4`.
The collector stays inactive. A separately accepted plan and fresh implementation
brief are required before code. This plan grants no provider or credential use.

| Boundary | Responsibility | Proof |
| --- | --- | --- |
| Entry and owner | Validate one input, own one worker, enforce deadlines, publish one result | Real pipe, signal and direct-wait controls |
| Private HTTP module | Fixed requests, actual DNS/TLS, bounded HTTP framing and reads | Same wire reader with a scripted connection; native constructor controls |
| Private model module | Exact JSON validation, PR/file mapping, drift and missing facts | Independent expected IDs, digests and state assertions |
| Existing normalizer | Keep its strict supplied-snapshot contract | Unchanged original suite plus collector-envelope rejection |

## 1. Files and work order

The implementation may change only these exact paths:

| Path | Work |
| --- | --- |
| `adapters/github-forge/v1/collect.py` | Public entry, one-worker ownership, bounded stdin/stdout and final result |
| `adapters/github-forge/v1/_collector_http.py` | Private native connection and bounded GET exchange |
| `adapters/github-forge/v1/_collector_model.py` | Private input, JSON, mapping and result checks |
| `scripts/test/github-change-request-collector.test.sh` | Discoverable hermetic suite wrapper |
| `scripts/test/fixtures/github-change-request-collector/v1/test_collector.py` | Scripted wire fixtures, constructor and lifecycle controls |
| `docs/github-change-request-collector.md` | Invocation, schema, limits, failure and restoration guide |
| `docs/components.md` | Add the inactive collector and explain the separate result contract |
| `README.md` | Add the collector to the component index |
| `ci/required-files.txt` | Append the six new restore-critical paths above |

Do not change the normalizer, its test, any profile, workflow, core schema, accepted
artifact or existing manifest entry. No generated fixture tree or shared provider,
executor, transport registry or credential framework is needed.

review_size: accepted-exception — implementation: 1500–2400 net added lines for this one collector concern.
The estimate covers three small product modules, the scripted-wire and real-worker
regressions, one test wrapper and the contract guide. Bounds, failure controls and
readable ownership code justify the exception. Do not compress code or trim tests
to meet it. A material overrun returns through the existing plan gate.

One implementation author owns the three product modules and their integration.
Build pure mapping first, then the fixed HTTP exchange, then the worker owner.
Add tests with each part. Finish the public-entry controls and documentation before
review. A separate reviewer reads actual source and complete proof. The author
cannot accept the plan, implementation or its own test result as qualification.

## 2. Runtime and entry

Use the Python 3 standard library on POSIX Linux and macOS, with CPython 3.11 or
newer. Record the actual interpreter version in proof. Unsupported runtimes fail
before collection. No package download, SDK, shell command, CLI or helper is used
by the product. The invocation is `python3 -I -B <collector-path>/collect.py`.
Require isolated mode and disabled bytecode writes. Import only the two adjacent
private modules from the collector's own directory, never a caller search path.

Read the spec's exact request object from stdin. There are no command-line mode
switches, extra endpoints, token inputs or public test hooks. Reject extra keys,
unsafe owner/repo strings, noncanonical decimal IDs and unsupported algorithms
before any worker is created. `app-bound` returns unavailable before a connection.
Anonymous input proceeds through the real backend without a qualification flag.

Start a monotonic 30-second attempt deadline before reading input. Install handlers
for INT, TERM and HUP that record cancellation only. Bound stdin and stdout using
nonblocking descriptors and a poll-based selector that supports pipes and regular
files. Save and restore descriptor flags. Never
block indefinitely on missing EOF, a full output pipe or a failed close.

Validate the complete 16 KiB maximum input before forking. The worker receives that
validated object through inherited memory, not another public input parser. The
parent keeps caller bindings and measured time; the worker cannot replace them.
The public record uses actual UTC start/end times and monotonic elapsed time.
Header Date and expected values never supply those measurements.

## 3. Own exactly one worker

Use one direct `os.fork` child for the attempt. No worker pool, shell, subprocess
command, descendant or thread is needed. The public process is single-threaded.
Restore a waitable SIGCHLD disposition before fork. Block the three cancellation
signals across fork and saving the returned child PID; then restore the mask.
The child installs its own cancellation handler before restoring its signal mask.
Handlers must never reap a child, run cleanup or send a signal.

The parent alone owns `waitpid` and signalling for that child. Use two private pipes:
worker events/results to the parent, and request admission from parent to worker.
The worker closes stdin, stdout, stderr and all other inherited descriptors.
Enumerate descriptor numbers through the platform's fixed `/proc/self/fd` on Linux
or `/dev/fd` on macOS; do not read descriptor contents. Keep the enumeration
descriptor open and exclude it during that pass, then close it explicitly.
Unexpected close failures fail startup. Both sides close unused pipe endpoints.
Clear the worker environment without inspecting values. Only then import the SSL
backend and load the runtime's platform trust store. This prevents environment CA,
key-log, proxy and OpenSSL configuration from affecting the native connection.

The worker-to-parent protocol has only B (begin request), E (end request), and R
(final result). B/E each carry one ordinal byte from 1 through 5. R carries an
8-byte big-endian length followed by one UTF-8 JSON payload, capped at 2 MiB. Allow
at most five ordered B/E pairs and one final R. Reject unknown tags, wrong ordinals,
overlap, partial frames, extra/trailing frames or invalid final JSON. The final
payload has a closed schema with mapped facts, counters and fixed outcome fields.
It contains no raw response or credential. No pipe read or write is unbounded.

Before each request, the worker sends B and waits. The parent checks cancellation,
the attempt deadline and request count. It records a new absolute deadline at most
five seconds away, capped by the attempt deadline, before releasing the worker.
The admission reply is that ordinal byte plus an 8-byte unsigned monotonic deadline
in nanoseconds. The worker requires the complete matching reply and a future
deadline before lookup or connection. An expired or partial reply never authorizes
work. The worker uses this same deadline for all connection operations.

The parent enforces the active request deadline while the worker may be blocked in
DNS/TLS. The worker sends E only after the response reader and checked connection
close finish. A valid E clears that request deadline; mapping still uses the whole
attempt deadline. Another B is invalid until E. A failure may end with R while a
request remains active, but a collected R cannot. This protocol is private to the
five prescribed GETs. It has no arbitrary task or operation field.

The worker has no public output. After R it closes both endpoints and exits. A full
frame does not prove exit. EOF does not prove a valid result. The parent retains
both deadlines and the cleanup budget across every partial read, write and signal.

The parent records these phases: not-started, owned, stopping, reaped or unconfirmed.
While owned, use nonblocking `waitpid` for that exact child and drain the result pipe
under the active deadlines. A normal collected result requires a complete valid
frame sequence, pipe EOF, exit status zero, checked closure of every connection,
and actual direct-child wait completion. Only the parent then adds retirement evidence.

On a returned wait status, retire signal authority immediately, before another
operation. No handler or second thread can reap the PID. While the direct child is
unreaped, its identity cannot be recycled under this ownership rule. Never use
kill-zero, ps, a remembered PID after reaping, or a process-group signal as proof.
ECHILD or an unexpected wait result loses signal authority and yields unconfirmed
retirement; do not try a numeric-PID fallback.

On cancellation, request timeout, whole-attempt timeout or owner failure, stop
admitting work. Begin a separate cleanup budget of at most two seconds. Send TERM
once to an owned unreaped child. Wait and drain for at most the first second. If it
is still owned, send KILL once and use the remaining cleanup budget for direct wait.
Preserve signal, wait, read and close errors separately from the first failure.
ESRCH does not prove retirement; only the matching wait does. After wait completion,
never signal again. A failed fork has no child to signal or reap.

The worker's TERM handler requests cancellation so ordinary code can close its
connection. If blocked DNS/TLS cannot return, KILL ends the worker. A confirmed
wait establishes process exit and kernel descriptor retirement; it does not prove
TLS close-notify or a peer response. An unconfirmed wait remains a nonzero failed
attempt with `worker_retirement: unconfirmed`. No later page, new attempt or success
is admitted. Do not claim cleanup success from a child-written event.

Use the same 30-second operational deadline and at most two seconds of cleanup,
without resetting either. Publishing failure must not add an unbounded wait after
that budget. Scheduler or uncatchable process termination is not a promised success.
These are application controls. CPU/wall enforcement remains NONE and native
qualification remains BLOCKED.

This private worker is the already specified exception for blocking DNS/TLS. The
normal path would call a cancellable bounded connection in the entry process. The
external constraint is an uninterruptible runtime resolver call. The one boundary
is the owner in `collect.py`; its provenance is this plan and spec section 3.
Keep one short source link to this plan at the worker owner. The real wait/signal
regressions run in CI. Re-evaluate the boundary when a supported runtime supplies
cancellable bounded DNS. Do not copy it into a general executor.

## 4. Native connection and HTTP exchange

The only native factory resolves `api.github.com` for TCP port 443. Validate resolved
numeric addresses before connect. Reject the spec's forbidden classes, including
their IPv4-mapped IPv6 forms, and reject scoped IPv6. Choose one permitted address and attempt it
once; a failed connect does not try another address. The TLS server name remains
`api.github.com`. No response or input can change it.

Use a fresh socket and TLS connection for each request. Use `SSLContext` with client
mode, CERT_REQUIRED, hostname checking and minimum TLS 1.2. Load platform roots only
after the worker environment is cleared. Missing roots or setup failure is a named
unavailable outcome; never downgrade verification. Do not offer HTTP/2. All resolver,
connect, handshake, send, read and close work shares the request's five-second
absolute deadline, capped by the remaining attempt deadline.

Build the request bytes in the HTTP module. Use HTTP/1.1, origin-form target,
`Host: api.github.com`, `Connection: close`, `User-Agent: ystack-github-collector/1`,
`Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2026-03-10` and
`Accept-Encoding: identity`. No body, Authorization,
cookies or caller headers are sent. The two permitted target forms are:

- `/repos/{owner}/{repo}/pulls/{pull_number}`
- `/repos/{owner}/{repo}/pulls/{pull_number}/files?per_page=100&page={page}`

The response reader is private to these GETs. Use a bounded byte reader and explicit
HTTP/1.x status/header/framing checks. Do not delegate redirect, proxy, decompression,
retry or credential decisions to a high-level HTTP client. The scripted connection
must supply the same raw byte interface used by this reader.

| Bound | Implementation rule |
| --- | --- |
| Headers | 32 KiB total, at most 100 fields and 8 KiB per field; reject folded lines, invalid names, controls and conflicting singleton fields |
| Body | 2 MiB per response; 8 MiB across all requests; cap-plus-one actual reads |
| JSON | UTF-8, at most 32 nesting levels, unique object keys, finite numbers and valid Unicode strings |
| Pages/files | At most 3 file pages, 100 entries per page and 256 distinct files |
| Requests | At most 5 started requests, including both PR reads; no retry |
| Output | At most 2 MiB, assembled before publication |

Support exactly one canonical Content-Length, one final chunked transfer encoding,
or a close-delimited body. Refuse Content-Length with Transfer-Encoding, duplicate
lengths, unsupported transfer codings and malformed chunk framing. Bound chunk-size
lines and trailer/control bytes with the header byte/line limits. Chunk sizes cannot
reserve or allocate memory beyond remaining body allowance. Require the zero chunk
and final terminator for chunked bodies; trailers cannot alter the response fields.
Read every declared body byte; early EOF is failure. Do not reuse the connection.

Require the spec's JSON media types and absent/identity Content-Encoding. Every 3xx
stops without following Location. Read no error body merely to report a provider
message. Map status classes exactly as the spec states. Ignore Retry-After.
Unknown error text is replaced with a fixed reason ID.

Own either the raw socket or its TLS wrapper at each construction step. Transfer
ownership only after wrapping succeeds. Close the owned object in a checked finally
path on success, parse failure, deadline and cancellation. Close failure prevents a
collected result even if the body was valid. Keep the first error and the close
outcome; do not overwrite them with a successful worker exit.

## 5. Parsing, mapping and output

Pre-scan bounded JSON text for depth before decoding. Use duplicate-key rejection
and exact integer parsing. Reject bool-as-integer IDs/counts, non-finite values and
invalid Unicode. Ignore extra provider fields after safe decoding. No raw provider
object is copied into the output.

Implement the spec's route identity, provider IDs, SHA-1 shape, calendar timestamps,
state contradictions and expected revision comparisons in the model module. Keep
provider `id` separate from route `number`. The first PR read validates identity and
the reported count, when present, before files. A reported count above 256 ends
inconclusively before a file request. Missing optional facts remain unavailable.

Read files in order. Validate paths/statuses before retaining them. Never deduplicate
away a repeated path. Enforce the exact next/prev/first/last relation checks from
spec section 5, without following Link URLs. Reject an array over 100 entries.
Use a short page as bounded enumeration end, not proof of provider completeness.
Count equality proves only count-matched. Missing files either cause a count
mismatch or leave completeness unknown.

Hash only a non-empty decoded patch string's exact UTF-8 bytes. Keep its byte length
and observed digest. Missing, null or empty patch has no digest. Do not parse a hunk
to manufacture full-patch proof, fetch a Git object or reconstruct a diff.

Perform the final PR read only after a valid bounded file walk. Compare the exact
selected before/after projection, including presence versus absence. Keep canonical
same-repository mapping separate from provider IDs. Fork head mapping stays
unavailable without new evidence. Matching reads produce bracket-matched only.

Use the spec's exact top-level collection keys and adapter ID
`adapter.github-forge.collector.v1`, version `v1`, status `inactive`.
Observed facts use `{state: observed, value: ...}`. Unavailable facts use
`{state: unavailable, reason_id: ...}` with no value. These words are JSON strings.
`request_binding` contains only
validated non-secret request fields and bindings. Invalid-input failures have an
unavailable request binding. `target` and `files` are observed or unavailable typed
values; a failure cannot look like an observed empty file set. Each unavailable
fact has a fixed reason and no value. The model exposes no generic arbitrary-data
or provider-metadata slot.

Record local request starts, fully read response bodies, byte and page counts,
enumeration, count comparison and bracket comparison. A request start does not
claim that GitHub received it. Record worker retirement from the parent's real wait.
The worker frame cannot set that fact. Keep ordered missing-normalizer requirements
as the spec defines. The normalizer field stays unavailable with no snapshot.

| Outcome | Fixed reason suffixes |
| --- | --- |
| collected | `observed` |
| stale | `binding-stale`, `bracket-drift` |
| unavailable | `credential-binding-unavailable`, `trust-store-unavailable`, `network-failed`, `provider-unavailable`, `target-unavailable`, `identity-unavailable`, `fact-unavailable`, `request-timeout`, `attempt-timeout`, `cancelled` |
| inconclusive | `file-limit`, `page-limit`, `duplicate-file`, `continuation-conflict`, `count-mismatch` |
| refused | `invalid-input`, `unsupported-runtime`, `forbidden-destination`, `invalid-http`, `invalid-json`, `invalid-provider-data`, `tls-verification-failed`, `clock-invalid`, `ipc-invalid`, `close-failed`, `worker-failed`, `worker-ownership-lost`, `output-invalid`, `output-failed` |

Prefix these suffixes with `github.collect.`. Missing-fact reasons use the same
prefix and the ordered suffixes `app-identity-unavailable`,
`canonical-head-unavailable`, `file-count-unavailable`, `patch-text-unavailable`,
`patch-completeness-unknown` and `atomic-revision-binding-unknown`.
Individual missing/null/empty patches use `patch-missing`, `patch-null` or
`patch-empty`, with no digest. The normalizer object has state unavailable,
reason `github.collect.normalizer-input-unavailable` and its ordered
`missing_requirements` array. The guide and tests use these closed sets.
Exit zero only for collected; use exit 65 for every other handled
outcome. Preserve first failure while recording cleanup independently. A redaction
failure cannot turn into a successful generic result.

Assemble and validate the entire result before writing stdout. Require consumers
to accept only exit zero plus exactly one complete valid JSON record. An interrupted
output write can leave incomplete bytes; it cannot leave a successful partial
observation or authorize reuse. Return nonzero without a traceback on write failure.
Diagnostics contain only fixed codes, phases and bounded numeric counts. Do not
emit raw input, response text, patches, URLs, headers, exception messages or paths.

All records preserve inactive status, authority none, unavailable qualification and
empty effects. The original normalizer and default local materializer stay unchanged.
App identity, full patch, atomicity and unavailable fork facts are not supplied by
test fixtures, expected values or the existing management response.

## 6. Proof and completion

The fixture module provides one private byte-stream connection and controlled
clocks/checkpoints. Patch only the private native connection boundary for exchange
tests. Keep request construction, wire parsing, collection, mapper, worker owner
and public stdin/stdout handling on their production paths. No fixture can return
a parsed result or inject an App identity, completeness bit or verdict.

The wrapper runs isolated Python with socket creation and DNS denied by default.
It opens no real socket or credential. Native-constructor controls use in-memory
resolver/socket/TLS stand-ins and assert real destination checks, SNI, trust setup,
certificate flags and default backend selection. They do not claim a TLS handshake.
Poison token, proxy, CA, key-log and configuration values with controlled sentinels.
Require no secret discovery, configuration-file access or sentinel leakage.

Require a collected same-repository control and a fork control through the complete
owner/worker path. Assert actual requests, independently known IDs and patch hashes,
precise missing facts, strict output shape, pipe EOF and real successful direct wait.
Keep the existing normalizer suite intact. The new test must pass a collector record
to that actual normalizer and observe invalid-envelope rejection; existing supplied
snapshots must retain their states. Reuse the repository's pinned jq 1.6 proof
discipline for this test-only subprocess, never as a product command mechanism.

Cover every spec section 7 failure, each resource boundary and byte-fragmented
HTTP/JSON. Include CL/TE conflict, bad/truncated chunks, stale head/base/IDs, changed
file count, missing and shortened patches, duplicate and omitted files, unsafe Link
targets, wrong media/encoding, redirects and each error class. Assert no request
after a terminal result. Rejected and incomplete cases must not gain normalizer data.

Use real owned processes and pipes for cancellation and retirement controls. Hold
the scripted connection at lookup, connect, headers, body and page transition;
deliver the real signal or deadline, then inspect the owner's actual wait result.
Test close failure, frame/EOF mismatch, early worker exit, TERM resistance requiring
KILL, wait failure, invalid ownership and output backpressure. Private injected
observer errors must remain failed proof; a fabricated completion event is never
enough. Preserve failed-case evidence. Do not signal an unowned PID to tidy a test.
Use real monotonic deadlines in at least one five-second blocked-request control
and one 30-second attempt-stall control. Shortened or synthetic clocks in other
controls cannot substitute for these actual owner timeout and retirement results.

At the implementation head, run the new suite and the unchanged
`scripts/test/default-github-forge-adapter.test.sh`. Run required structure and lint
checks, with shellcheck 0.11.0. The new wrapper is discovered by the existing
`scripts/test/run-all.sh`; no workflow change is needed. The first runnable collector
is a full-matrix milestone: record a successful manual CI dispatch at that exact
head before G3, plus the required quick checks and relevant integration proof.
Do not report skipped automatic tests as a full-suite pass.

Append the three product modules, wrapper, fixture module and new guide to the
restore manifest. Document the private worker boundary, public contract, unsupported
authentication dependency, all bounds and observed-only evidence. Confirm no profile
selection, installed command or live setup changed. A complete source/test result
proves controlled implementation behavior only. It does not qualify GitHub, authorize
real network/credentials or target execution, or complete Roadmap step 4.
