# Inactive GitHub change-request collector

| Property | Current behavior |
| --- | --- |
| Entry | `adapters/github-forge/v1/collect.py` |
| Status | Inactive and unqualified |
| Transport | Anonymous HTTPS GET to `api.github.com:443` |
| Result | `github_change_request_collection`, schema version 1 |
| Authority | `none`; effects are always empty |
| Normalizer | Separate strict supplied-snapshot contract; no projection |

The collector reads one target, enumerates bounded file observations, and reads the
target again. Matching selected fields establish `bracket-matched`. They do not
establish atomicity or freshness. Returned patch text has a digest and unknown
completeness. The default local Git materializer remains selected.

## Invocation

Use standalone CPython 3.11 or newer on Linux or macOS:

```sh
python3 -I -S -B adapters/github-forge/v1/collect.py < request.json > collection.json
```

These interpreter flags are required. The entry checks that site and native crypto
were not already initialized. It clears the environment before other imports.
An embedded interpreter or a preloaded crypto backend is unsupported. This prevents
ambient proxy, CA, key-log and crypto configuration from changing the admitted path.
The product invokes no command, helper, SDK, package manager or credential provider.

This invocation describes a capability. It grants no permission to contact GitHub,
use credentials, select a profile, install a command or execute a target.
Hermetic tests supply a private byte connection. There is no public fixture mode.

## Input

Read one UTF-8 JSON object followed by EOF. Unknown fields are refused. Maximum
input size is 16 KiB. The request has exactly these fields:

```json
{
  "owner": "example",
  "repo": "project",
  "pull_number": "7",
  "expected_head_repository_id": "11",
  "authentication": "anonymous",
  "bindings": {
    "expected_repository_id": "11",
    "expected_change_request_id": "1234",
    "expected_head": {
      "repository_id": "repo.target",
      "hash_algorithm": "sha1",
      "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "expected_base": {
      "repository_id": "repo.target",
      "hash_algorithm": "sha1",
      "commit_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "expected_github_app_id": "42",
    "instruction_ref": {
      "content_id": "instruction",
      "media_type": "application/json",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    },
    "config_ref": {
      "content_id": "config",
      "media_type": "application/json",
      "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    }
  }
}
```

Owner names use 1–39 ASCII letters, digits or interior hyphens. Repository names
start with a letter or digit and use at most 100 ASCII letters, digits, dots,
underscores or hyphens. A `.git` suffix is refused. Decimal IDs are positive strings
with at most 20 digits, with no leading zero. Only lowercase 40-hex SHA-1 revisions
are supported. Both expected revisions use the same canonical repository ID.

Expectations never supply an observed provider fact. Provider PR `id` is the change
request identity. Provider `number` is checked separately against the route.
Provider repository IDs remain beside canonical mappings. A fork's canonical head
mapping is unavailable, even if its hash text equals an expected hash.

`app-bound` returns `github.collect.credential-binding-unavailable` before a
connection. Its missing dependency is a separately trusted credential provider
binding actual credential use to the App, installation, repository, operation,
expiry and this attempt. Caller receipts, expected App IDs and token prefixes do
not establish it. Anonymous reads cannot observe the reading App's identity.

## Output

Accept a result only with exit zero and exactly one complete JSON record. A handled
non-collected outcome exits 65. Output failure may leave incomplete bytes and always
exits nonzero. Consumers must not reuse partial output.

The exact top-level fields are `schema_version`, `kind`, `adapter`, `outcome`,
`reason_id`, `request_binding`, `observation_window`, `target`, `files`, `evidence`,
`normalizer`, `authority`, `qualification` and `effects`.

Facts use `{"state":"observed","value":...}` or
`{"state":"unavailable","reason_id":"github.collect.…"}`. Unavailable facts have
no value. A failed attempt has no reusable target or files. Diagnostics never
contain raw response bodies, patches, headers, URLs, exception messages or paths.

| Outcome | Meaning |
| --- | --- |
| collected | Bounded exchanges, identity checks, mapping and direct worker wait finished |
| stale | Expected binding or selected before/after projection changed |
| unavailable | Provider, identity, credential, transport or time dependency is unavailable |
| inconclusive | Enumeration, duplicate, continuation or count limit prevents completion |
| refused | Input, runtime, HTTP, JSON, destination, lifecycle or output is invalid |

Collected targets preserve provider IDs, number, head/base SHA strings, state,
timestamps, conditional `merged`, `mergeable` and `changed_files` facts. Missing and
present optional fields compare differently. Actual local UTC and monotonic time
supply the observation window. Header Date is never an observation clock.

Files are sorted by path. Each has `path`, `status` and `patch`. A non-empty patch
has `observed_patch_sha256`, UTF-8 `byte_length` and `completeness: unknown` inside
its observed value. The digest covers exact decoded UTF-8 text without added LF,
Unicode normalization or line-ending changes. Missing, null and empty patches use
`patch-missing`, `patch-null` and `patch-empty` reasons. They have no digest.

Evidence records local requests started, fully read responses, body bytes, pages,
bounded enumeration, count comparison, bracket comparison and worker retirement.
`count-matched` proves equality only. File-set completeness remains unknown.
A started request does not prove that GitHub received it.
If a worker fails before its result arrives, the parent retains admitted starts and
completed-response events. Other counters contain only bytes/pages reported to the
parent; zero does not establish that no unreported worker activity occurred.

The normalizer remains unavailable with no snapshot. Its ordered missing
requirements are App identity, canonical head mapping, reported file count, usable
patch text, patch completeness and atomic revision binding. Conditional requirements
appear only when unavailable. Patch completeness and atomicity always remain unknown.
The unchanged `normalize.jq` rejects the collector envelope as invalid input.

## Bounds and private worker

| Resource | Limit |
| --- | --- |
| File pages | 3, at most 100 entries each |
| Distinct files | 256 |
| Requests | 5, including both target observations |
| Headers and control bytes | 32 KiB, 100 fields, 8 KiB per field |
| Response body | 2 MiB each; 8 MiB per attempt |
| JSON nesting | 32 levels; unique keys and finite numbers |
| Final record | 2 MiB |
| One request | 5 seconds including DNS, TLS and body |
| Attempt | 30 seconds from input admission |
| Cleanup | Separate 2 seconds maximum |

One direct fork worker contains potentially blocking DNS/TLS. The parent alone
owns its PID, signal authority and wait. The private B/E/R protocol admits each
request under its own absolute deadline. A successful result requires valid frames,
EOF, exit zero, checked connection closure and a real direct-child wait. Child data
cannot assert retirement. The parent retires signal authority as soon as wait
returns. Lost ownership remains unconfirmed and fails.

On cancellation or timeout the parent sends TERM once, then KILL after at most one
second if the child remains owned. It waits within the remaining cleanup budget.
A wait proves process exit and kernel descriptor retirement. It does not prove TLS
close-notify. The exception and its removal condition are recorded in
[the accepted plan](../work/github-change-request-collector/plan.md).

The transport validates every resolved address before choosing one permitted
address. It rejects scoped IPv6, private, loopback, link-local, multicast,
unspecified and IPv4-mapped forbidden addresses. It does not retry another address.
TLS validates certificates and hostname with platform roots and TLS 1.2 or newer.
GET routes and headers are fixed. Redirects, returned Link targets, proxies,
Authorization and cookies never select another destination. Link values are checked
as evidence and never followed.

## Restoration and proof

Restore the three adjacent Python modules, suite wrapper, fixture module and this
guide from the manifest. No installed package or generated command is needed.
The wrapper is discovered by the existing test runner. It requires the existing
verified jq 1.6 test fixture for unchanged-normalizer integration.

Tests deny native sockets and DNS. They exercise the same wire reader, mapper,
owner and entry path with scripted raw bytes. In-memory native constructor controls
check address and TLS settings. Real owned-process controls cover signals, waits,
TERM resistance, request timeout, attempt timeout and output backpressure.

These controls prove implementation behavior under controlled inputs. They do not
qualify native transport, GitHub, a credential provider or a real target. CPU/wall
enforcement is NONE. Native qualification is BLOCKED. Production remains EMPTY.
No profile, workflow, accepted artifact, installed command or live setup changes.
This collector does not complete Roadmap step 4.
