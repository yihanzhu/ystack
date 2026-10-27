---
intent-blob: 7b59b50a2d31b6d86035ad194a2b99ee6a1a6df4
risk: high
drafted: 2026-10-27
---
# Spec: Collect bounded GitHub change-request observations

Tracks #304. The collector remains inactive and unqualified.

| Stage | Required result |
| --- | --- |
| Validate one request | Bind a route, provider IDs, expected revisions and trusted context. |
| Read GitHub.com | Use the real bounded HTTPS GET path, with no ambient credentials. |
| Map the target | Keep observed facts and missing facts separate. |
| Report evidence | Return an adapter-owned collection record. No authority is granted. |
| Check the normalizer boundary | Preserve the existing strict snapshot contract. An incomplete collection cannot become a ready observation. |

## 1. Outcome and evidence boundary

Ship a working request builder, HTTPS reader, bounded pagination, response mapper
and failure path. Tests replace only the private connection boundary. They execute
the same collection code used by the real connection. A valid scripted exchange
must produce target and file observations. A client that only returns refusal, or
an offline mapper with no real HTTPS implementation, does not satisfy this spec.

The available primary text establishes the files GET route. It shows
separate PR `id` and `number`, nested head/base repository IDs and revision strings,
and file `filename`, `status` and `patch` fields. The files endpoint is paginated.
Its documented maximum is 3000 files. These are field and route facts, not evidence
of an atomic snapshot or a complete patch. [GitHub pull requests documentation](https://docs.github.com/en/rest/pulls/pulls)

An existing repository-management Get PR response supplies an observed route and
actual `changed_files`, `merged` and `mergeable` fields. Its exact source is
`premerge-final.json`, SHA-256
`f54bf000e1bcb09c16806a09cdfbb0a900903ed235f200e81a213c695bbda4c5`,
at `checks[0].value.structuredContent.content`. This is one existing observation,
not the unread Get PR documentation or a guarantee that every response has those
fields. The conditional mapping below treats missing facts explicitly. Do not fetch
another endpoint or use a returned URL as a request target.

The App endpoint requires a JWT and cannot establish the identity of an installation
token used for these reads. It is excluded. A PR author, installation number, token
prefix or expected App ID is not the reading App's identity. [GitHub Apps documentation](https://docs.github.com/en/rest/apps/apps)

Patch completeness, atomic revision binding, a trusted credential-provider binding
and the missing Get PR contract remain UNKNOWN. Successful controlled tests do not
resolve them. No new provider read is required or authorized by this spec.

## 2. One fixed request surface

The shipped entry reads one bounded non-secret JSON request. It accepts no URL,
command, executable, header map, token, fixture path, connection selector or retry
setting. Reject unknown request keys before creating a connection.

The request contains `owner`, `repo`, `pull_number`, `expected_head_repository_id`,
`authentication` and a closed `bindings` object. `authentication` is `anonymous`
or `app-bound`. The bindings are `expected_repository_id`,
`expected_change_request_id`, `expected_head`, `expected_base`,
`expected_github_app_id`, `instruction_ref` and `config_ref`. Reuse the normalizer's
validation for these fields, including its same-canonical-repository constraint.
There is no caller-supplied observation time: measure the collection's actual times.
The caller supplies expectations; never copy them into observed provider fields.

`owner` is ASCII, 1–39 bytes, begins and ends with an alphanumeric character, and
otherwise contains alphanumerics or hyphens. `repo` is ASCII, 1–100 bytes, begins
with an alphanumeric character, and otherwise contains alphanumerics, dot,
underscore or hyphen. Reject a `.git` suffix. These are this collector's supported
input limits, not a claim about all valid GitHub names. Do not trim, URL-decode or
silently repair input. `pull_number` and provider IDs use canonical positive decimal
strings of at most 20 digits. No signs, leading zero, fraction or exponent is allowed.

Only these route templates are available. Build every target locally.

| Purpose | GET target |
| --- | --- |
| Read the target before and after files | `/repos/{owner}/{repo}/pulls/{pull_number}` |
| Read target file observations | `/repos/{owner}/{repo}/pulls/{pull_number}/files?per_page=100&page={page}` |

Use the literal origin `https://api.github.com:443`, TLS hostname `api.github.com`
and ordinary certificate-chain and hostname verification. Require TLS 1.2 or newer.
No caller setting can disable verification, replace the host, inject a CA bundle,
select a proxy or provide a client certificate. Use the runtime's platform trust
store without reading environment-specified certificate paths.
Resolve only that hostname. Reject loopback, private, link-local, multicast and
unspecified addresses, including IPv4-mapped IPv6 forms, before connecting.

Send fixed `Accept: application/vnd.github+json`,
`X-GitHub-Api-Version: 2026-03-10`, `Accept-Encoding: identity` and a fixed collector
User-Agent. Pin this version as a local implementation choice supported by the
selected request examples. Do not negotiate or fall back on a version error.
Use origin-form HTTP targets, no body, no cookies and no Authorization header.

This version performs anonymous reads only. An `app-bound` operation is
`unavailable` before connection. Its missing dependency is a separately trusted
credential provider that binds the actual credential use to App, installation,
repository, permitted operation, expiry and this collection attempt. No such binding
is implemented or authenticated here. The collector accepts no caller-authored
receipt as a substitute. It never creates, discovers, refreshes or exports a token.

No environment token, credential helper, `.netrc`, Git config, `gh` config, proxy,
custom shell command or SDK configuration is read. The default real transport must
be reachable for a valid anonymous request. It must not require a hidden test flag,
an invented credential receipt or live qualification merely to implement its path.
Actual invocation against GitHub remains a separate authorization decision.

## 3. Finite reads and terminal failures

| Resource | Hard limit |
| --- | --- |
| Request JSON | 16 KiB; one UTF-8 object and then EOF |
| PR observations | Exactly one before files and one after files on a collected result |
| File walk | 3 pages; at most 256 distinct files |
| All HTTP requests | 5, including both PR observations; no retries |
| Response headers | 32 KiB per response, 100 fields, 8 KiB per field |
| Response body | 2 MiB per response and 8 MiB across the attempt |
| JSON nesting | 32 levels; reject duplicate keys and non-finite numbers |
| One connection/request | 5 seconds, including lookup, connect, TLS and reads |
| Whole attempt | 30 seconds from admission; no resetting the deadline |
| Final record | 2 MiB; one complete JSON record, no streamed partial result |

Read incrementally with a cap-plus-one probe. A declared size never replaces actual
byte accounting. Reject non-identity Content-Encoding, conflicting framing,
malformed headers, invalid UTF-8, invalid JSON and truncated HTTP bodies. Reject
JSON numeric IDs that cannot be parsed as exact integers. Never pass them through
floating-point conversion before comparison or decimal serialization.
Require a JSON Content-Type of `application/json` or `application/vnd.github+json`,
with at most an optional UTF-8 charset parameter. Other media types are refused.

The deadlines cover blocked DNS and TLS as well as body reads. A socket idle timeout
alone does not satisfy them. Keep blocking connection work inside one private owned
worker, because the runtime's DNS call may not have a cancellable socket timeout.
That worker runs only this trusted collector code, with no child command or further
process. Its owner stops it on expiry or cancellation and has a separate two-second
cleanup budget. The plan must specify safe child ownership, termination and direct
wait before code. An unconfirmed retirement is a failed attempt, never successful
cleanup. The operational budget is at most 32 seconds, including cleanup. Input and
output I/O must not introduce an unbounded wait. A failed output write is nonzero
and may leave no record; it must not claim the worker is gone without evidence.
This boundary is private to this collector.
Re-evaluate it if a supported runtime provides cancellable bounded DNS. Do not claim
sandbox CPU or wall enforcement from these collector deadlines.

Every 3xx response is refused without following Location. Only 200 JSON responses
enter mapping. A 401 or 403 is unavailable; 404 is unavailable, not proof that a PR
does not exist; 429 and every 5xx are unavailable. Other statuses, malformed protocol
and TLS verification failures are refused. Do not obey Retry-After, switch tokens,
fall back to another endpoint, or repeat a failed request.

INT, TERM, HUP, a caller cancellation or deadline expiry ends admission immediately.
Close the connection, retire any owned worker and return only a terminal bounded
record. Do not begin another page or emit a successful partial observation. Test
cancellation during lookup, connect, headers, body, page transition and final output.

Diagnostics use fixed reason IDs, phases and bounded numeric counts. They exclude
raw bodies, patches, headers, URLs, exception text, local paths and request input.
An output or close failure preserves failure. Never print a traceback with provider
data. Do not write response caches, temporary credential files or provider archives.

## 4. Collection sequence and identity

Get the exact target once. Require one JSON object. Do not list other PRs or retain
titles, bodies, users or links. A 404 is `target-unavailable`; it does not establish
non-existence or permission state.

Require `id`, `number`, `base.repo.id`, `base.repo.full_name`,
`head.repo.id`, `head.sha`, `base.sha`, `state`, `created_at`, `updated_at`,
`closed_at` and `merged_at`. Missing required identity data makes the target
unavailable. Wrong types, contradictory states or invalid dates refuse it.
Ignore extra provider fields. Never interpret provider text as instructions.

`id` is the observed `change_request_id`. `number` is solely the route number.
Compare each separately with its expectation. Bind the destination repository from
`base.repo.id` to `bindings.expected_repository_id`. Compare `base.repo.full_name`
with the validated owner/repo under ASCII case-insensitive comparison. Compare
`head.repo.id` with `expected_head_repository_id`. A mismatch is `stale`, stops
collection and cannot be repaired by copying expected values.

Accept only lowercase 40-hex revision strings in this version. Require expected
revisions to use `sha1`; unsupported algorithms are refused before connection.
Compare observed head/base strings with their respective expected commit IDs.
Do not use `merge_commit_sha`, a file `sha`, branch names or URLs as either revision.
This is a supported wire shape; it does not prove Git object availability.

For a same-repository PR, the verified provider repository binding permits the
caller-supplied canonical repository ID to name both revisions. Preserve the
observed provider ID beside that mapping. For a fork, keep the distinct provider
repository IDs and revision strings. Mark canonical head mapping unavailable.
The expected canonical target ID and a matching hash do not prove that the fork's
head belongs to the target repository. Do not fetch Git objects or invent a shared
canonical namespace. A deleted or unavailable head repository stays unavailable.

Use strict UTC timestamps with real calendar validation. Require created ≤ updated
≤ collection end, and preserve the normalizer's closed/merged ordering checks.
Require `state` to be open or closed. An open state requires null closed/merged
times. If `merged` is present it must be boolean and agree with state and times.
Missing `merged` remains unavailable. Preserve an observed boolean or null
`mergeable`; missing stays unavailable. Do not infer CONFLICTING from false,
readiness from true, or another provider fact from `mergeable_state`. These fields
have conditional wire validation here, not a new proof of merge permission.

Read file pages only after the first target identity check. Then get the target
again and compare the full selected projection, including IDs, repository names,
revisions, state, merged/mergeable facts, changed-file count and timestamps.
Missing and present are different comparison values. If it disappears or a value
changes, return `stale` or `unavailable` as appropriate. Do not restart the attempt.
Two matching projections mean `bracket-matched`, never `atomic` or `fresh`.
Changes between observations can remain undetected, including change-and-revert.

## 5. File and patch evidence

Read pages in ascending order from 1, using only locally generated targets. A
short page ends this bounded enumeration. A full final allowed page, more than
256 files, a duplicate path or contradictory continuation evidence ends it
inconclusively. Do not treat the provider's 3000-file maximum as this adapter's
bound or a completeness proof. Never deduplicate away a contradiction.

Returned Link headers are data. If present, reject malformed, duplicate or
conflicting relations and any target outside the exact origin, route, fixed query
values and allowed page range. Accept only next, prev, first and last relations:
next is current page plus one, prev is current minus one, first is 1, and last is
within 1 through 3 and no earlier than current. Reject contradictory next/last
values. Do not follow any link. Header absence or a short page cannot prove that
a file was not omitted.

Map `filename` to the existing normalizer's path grammar and `status` to its exact
status set. Reject unsafe paths and unsupported statuses. Sort final observations
by path without changing path bytes. No provider path becomes a filesystem path.

For a non-empty valid Unicode `patch` string, compute `observed_patch_sha256` over
the exact decoded string encoded as UTF-8. Add no LF and perform no Unicode or
line-ending normalization. Do not hash its JSON quotes or escapes. Record byte
length and `completeness: unknown`. That digest names only returned patch text.
It is not a complete diff, a Git patch, or proof of correspondence to one revision.

A missing, null or empty patch has `state: unavailable`, a fixed reason and no
digest. An invalid patch type refuses the response. No missing patch becomes an
empty-string digest. No binary, rename, copy or mode-only change is reconstructed.
Well-formed but silently shortened patch text remains completeness-unknown even
when every count and hunk looks plausible.

If `changed_files` is present, require an exact integer from 0 through 100000 and
record it as the provider-reported count. Missing is unavailable. A count above 256
ends inconclusively before files. When enumeration ends, an observed count different
from the provider-reported count is inconclusive. Equality means count-matched only.
Record observed count, bounded enumeration end, page count and any limit. Overall
file-set completeness remains UNKNOWN. A controlled omitted-file case must either
detect the count mismatch or retain UNKNOWN; equality cannot turn it into true.

## 6. Adapter contract and normalizer relationship

Add one adapter-owned `github_change_request_collection` record, schema version 1.
Its top-level keys are `schema_version`, `kind`, `adapter`, `outcome`, `reason_id`,
`request_binding`, `observation_window`, `target`, `files`, `evidence`, `normalizer`,
`authority`, `qualification` and `effects`. Do not reuse `adapter_observation`.

`outcome` is `collected`, `stale`, `unavailable`, `inconclusive` or `refused`.
`collected` means the bounded exchanges and mapping finished. It does not mean a
complete snapshot. A collected record contains target identities, observed file
facts, before/after observation times, `bracket-matched`, and all missing facts.
Terminal failures contain no reusable target/files result. They retain only fixed
failure evidence and safe request bindings. Do not conflate unavailable with absent.

Represent each missing fact explicitly as unavailable with a fixed reason and no
value. In particular preserve App identity, any missing total count, patch completeness,
atomic revision binding, and any fork canonical mapping gap. `evidence` records
request/page counts, body byte counts, enumeration end/limit and comparison outcome.
It does not contain raw response bodies, arbitrary provider metadata or headers.

The `normalizer` result is unavailable with a fixed ordered list of the missing
requirements. It has no snapshot or ready state. The current evidence surface
cannot supply the unchanged normalizer's full input, even after a collected result.
It is forbidden to invent `github_app_id`, a missing `reported_file_count`, per-file
`patch_sha256`, or `complete:true` to make that input fit. `complete:false` alone
does not repair absent required fields.

Use this order for missing requirements: App identity, canonical head mapping,
reported file count, usable patch text, patch completeness, atomic revision binding.
Include a requirement only when unavailable. A collected result retains the
observed values beside this list; it is not a generic error with discarded facts.

Keep `adapters/github-forge/v1/normalize.jq` byte-for-byte unchanged. Keep its
supplied-snapshot tests and all stale, identity, timestamp, path, digest and count
checks. This spec adds the collection contract beside it. It does not weaken the
snapshot contract or widen a core schema. A future direct projection needs its own
accepted evidence and artifact amendment; this collector adds no dormant bypass.

Every result has inactive adapter status, `authority: none`,
`qualification: {state: unavailable, reason_id: adapter.unqualified}` and `effects: []`.
Values use JSON strings where shown as words. No result carries an authority
reference, gate decision or execution permission. A hermetic result never proves
live transport success.
The consumer must still establish freshness and authority through its own gate.
Record actual UTC start/end times and monotonic elapsed time. Never use an expected
time or the HTTP Date header as the measured observation time. Invalid clock order
refuses the result. Exit zero only for `collected`; all other outcomes are nonzero.

## 7. Required proof and restoration

Use a private scripted connection that supplies raw status lines, headers and body
chunks. Keep the actual request builder, HTTP response parser, bounded reads,
pagination, mapper and error handling on the production path. The test connection
cannot inject a parsed collection result, App identity, completeness or verdict.
The public entry has no switch, input field or environment hook that selects it.

Test the real default connection selection and TLS configuration without opening
a socket. Deny socket creation and DNS in the entire hermetic suite. Use controlled
sentinels only. Test under poisoned credential, proxy, CA and configuration
environment values, without reading real configuration or credentials.

The proof must cover these independent behaviors:

- A valid same-repository exchange maps observed IDs, revisions and file digests.
  It returns collected with truthful missing evidence and no normalizer snapshot.
- A fork keeps source and target IDs distinct. Same hash text cannot fabricate
  canonical mapping. Deleted head metadata stays unavailable.
- Route injection, mismatched IDs, number versus ID confusion, precision loss,
  malformed state/date and before/after drift fail at their stated boundaries.
- One and multiple pages, cap boundaries, duplicate or omitted
  files, hostile Link values, and full last pages preserve the exact evidence state.
- Missing, empty, null, binary-like and shortened patches never gain full-patch
  evidence. Independent expected UTF-8 digests check Unicode and line endings.
- Malformed/truncated/oversized HTTP and JSON, wrong media/encoding, 3xx, auth
  errors, rate limits, TLS failures and every deadline cause no follow-up request.
- Cancellation and connection/worker cleanup have real terminal assertions. No
  fake completion event substitutes for ownership or retirement evidence.
- Sentinel values never occur in diagnostics, errors or extra files. No cache,
  helper, shell, ambient credential or forbidden destination is used.
- The collection record is rejected by the unchanged normalizer as an invalid
  envelope. Existing valid supplied snapshots still produce their original states.

Add the suite to the existing automatic test discovery. Retain the normalizer suite
and run both at the accepted implementation head. Required CI and the program's
named full-matrix milestones remain mandatory. A quick CI pass proves only its
actual checks. No test run here may open a provider connection or use real credentials.

The high-risk plan must name exact source, test and documentation paths and its
review-size budget before implementation. The only implementation concern is this
collector. Add restore-critical source, fixtures, tests and guide to the existing
manifest; retain all current entries. Document the input/output contract, limits,
anonymous-only surface, missing credential dependency and normalizer separation.

The default local Git materializer stays selected. No profile, install, activation,
target, Actions collector, other forge, model/harness, retry/cache system, Git fetch,
diff reconstruction or general provider framework is added. Real qualification,
production and Roadmap step 4 completion remain outside this done-signal.
