# Intent: Preserve bounded evidence for adapter late-target failures
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #301.

## Problem

The adapter-contract test can report `late target mutation error` without showing
the runner's actual exit status or which output condition failed. Cleanup then
removes the captured files, leaving too little evidence to explain the failure.

PR #296 hit this path in CI run 34797104710, job 103832224183, with unchanged test
and runner bytes. The cause remains unknown. This initiative improves the failure
report; it does not claim to identify the cause or fix a flaky test.

## Proposed outcome

When the existing late-target test fails, its report preserves typed, safe fields
only: the actual wait status, the stdout byte count, the stderr byte count, and a
classification of stderr rather than its bytes. The classification comes from a
small fixed set the specification enumerates, for example `empty`,
`expected-error-line-present` and `unexpected-content`, decided by matching the
captured stderr against the exact expected error line the test already asserts
(`E_TARGET_STALE`). The report carries no raw stderr bytes and no stderr prefix,
so there is no escaping or truncation story to design.

Escaping is not redaction: it makes bytes printable without removing anything
sensitive. An unexpected shell or tool diagnostic on this path can carry temporary
fixture paths, invocation details or other content the constraints below forbid
reporting, and the test cannot tell in advance what such a diagnostic contains.
Classifying against a known constant avoids that whole class of exposure.

If a bounded excerpt is genuinely needed for debugging, it may only be the expected
error line itself when that line is present. That line is a known constant, so
there is nothing in it to redact. The report still helps a reviewer distinguish
failure conditions without exposing stdout or stderr contents.

A reporting error still leaves the original outcome failed. Normal successful
output and every existing acceptance check remain unchanged.

## Affected users and systems

Maintainers and reviewers diagnosing adapter-contract CI failures benefit from
the additional evidence. Only failure reporting around the late-target invocation
in `scripts/test/portable-adapter-contracts.test.sh` is affected. This is separate
from the assembler work in #296 and credential-policy synchronization in #291.

## Constraints

Read only the synthetic output files the test already captures. Do not dump the
environment, arguments, credentials, arbitrary paths or stdout contents. Do not
upload data or retain scratch files after cleanup.

Preserve all assertions, exact error matching, success output, target mutation,
marker polling, launch/wait/kill behavior and synchronization. Do not change the
runner, fake adapters, resource limits, workflows or cleanup. Report only after
execution on an existing failure path. Do not add retries or skipped checks, or
allow diagnostics to turn a failure into success.

Synthetic empty, nonempty, oversized and control-byte cases must prove bounded
reporting and failure preservation. The full adapter-contract suite and required
lint/CI remain gates. No product behavior changes. Any later repair of the underlying
cause needs evidence and its own accepted scope.

## Open questions

Design must fix the exact set of stderr classifications and the matching rule that
assigns one, including how the byte counts are read under a bound so a large or
binary capture cannot slow or break the report. It must also decide whether the
expected error line is echoed back at all, and define how to preserve the actual
wait status when reporting fails, without changing the existing launch,
synchronization or failure checks.
