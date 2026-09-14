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

When the existing late-target test fails, its report preserves the actual wait
status, stdout byte count and a small, safely escaped stderr prefix with a clear
truncation indication. Reads are bounded before escaping. The report helps a
reviewer distinguish failure conditions without exposing stdout contents.

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

Design must choose a small byte cap, an escaping format and a truncation indication
that keep arbitrary captured stderr safe and readable. It must also define how to
preserve the actual wait status when reporting fails, without changing the existing
launch, synchronization or failure checks.
