# Intent: Count runs from disabled selected workflows
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #132.

## Problem

The quota preflight can omit runs from a selected workflow after that workflow is
disabled. Its combined count can therefore miss the threshold intended to stop
abnormal run volume. Maintainers need that check to include runs still inside the
counting window, regardless of whether the selected workflow remains enabled.

The current gap is in `scripts/v2/quota-preflight.sh`. Its existing tests do not
model disabled-workflow visibility. This is a source-level gap, not a claim that a
live account exceeded its quota. The related run-attempt identity requirement is
already implemented and must remain intact.

## Proposed outcome

Runs from a disabled selected workflow contribute to the combined count for the
existing window. Reaching the existing threshold still stops the preflight; a
lower count still passes. The change does not expand which workflows are selected.

A hermetic behavioral regression demonstrates that the disabled workflow's runs
change the combined result when they reach the threshold. The existing suite keeps
proving missing-workflow handling, errors, exclusions and configuration precedence.
No live workflow or provider call is needed to establish this outcome.

## Affected users and systems

Maintainers using the quota preflight and the GitHub Actions adapter tooling in
Roadmap step 4. The affected helper and its existing test are
`scripts/v2/quota-preflight.sh` and `scripts/test/v2-quota-preflight.test.sh`.
This completes one remaining counting behavior, not the entire default-adapter step.

## Constraints

Preserve workflow selection, the default exclusions for lanes that can produce
skipped runs, the counting window, threshold comparison and fetch-limit scaling.
Keep global listing failures and unexpected per-workflow errors fatal. Retain
numeric-count validation, the current missing-workflow behavior and existing
configuration precedence. An error must not silently become zero usage.

Retain the implemented run ID and run-attempt identity behavior. Do not modify
workflow files, probe publication, permissions, executable selection or account
quota policy. Exclude real provider access, credentials, workflow enable/disable
actions, installation, activation and target execution.

Keep the change small and test the resulting count and threshold behavior rather
than only matching a command string. Preserve all existing tests. Design, the
applicable independent plan gate, required CI and independent implementation review
still precede completion.

## Open questions

What minimal hermetic fixture best reproduces disabled-workflow visibility while
proving that the original count would omit those runs?

Which boundary cases around the existing threshold demonstrate the repair without
changing missing-workflow or unexpected-error handling?
