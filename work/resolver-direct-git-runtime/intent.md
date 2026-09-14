# Intent: Remove the Darwin Git shim from resolver runtime reads
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #316.

## Problem

The profile resolver uses /usr/bin/git for repository reads and four startup blob
checks. On Darwin that path is an xcrun dispatcher. Retained native tests observed
xcrun_db residue through both the existing test launcher and the pending trusted
parent. Those runs did not meet the parent's current empty private-TMPDIR check.

The trusted-parent initiative leaves its runtime unchanged and explicitly names a
separate follow-up to move Darwin runtime reads off the shim. This dependency blocks
progress toward a supported resolver launch and the later self-host workflow.
The proposed cache exception remains unaccepted; a later passing toy Git command
would not resolve the runtime's failure.

## Proposed outcome

The resolver uses a closed, trusted Git selection on each supported platform without
routing Darwin reads through the shim. The same request produces the same resolved
profile bytes, validation results and refusals, with existing resource limits and
private scratch cleanup preserved. Missing or unsupported dependencies fail clearly.

Demonstrate the repaired runtime through its supported launch boundary on native
Darwin and Linux, with the full existing suite and focused new proof. Preserve the
original failures. Unexpected cache or write behavior remains a failure, not a new
exception. Ship the repair inactive and include what is needed to restore it.

## Affected users and systems

Maintainers need a usable profile resolver for Roadmap step 1 and the later self-host
path. This concerns the resolver runtime, its dependency checks and tests. The
trusted parent, input assembler and shadow workflow depend on that result but are
not completed or activated by this repair.

## Constraints

Keep this separate from the preserved trusted-parent attempt on #271. Do not edit
or resume its WIP, accept its pending cache proposal or reuse stale evidence. Any
later parent dependency, pin or plan revision follows its own artifact gates and
exact-attempt reconciliation, retaining all required pin and R1–R10 checks.

Preserve runtime outputs, validation, private repository handling, source protection,
resource and watchdog behavior, and the current cleanup standard. Selection must
cover all startup checks, repository reads and dependency validation. Keep every
existing resolver test. Separate fixture/toolchain effects from runtime evidence;
never delete or prewarm shared caches to obtain a pass.

No caller-selected executable, PATH fallback, xcrun/xcode-select discovery,
DEVELOPER_DIR override, download or installation. No new network, credential or
write authority, profile activation or real target execution. Do not replace Git
parsing, change core schemas or repin profiles without separately established need
and accepted scope. Negative tests must not modify host tools.

Use the full artifact chain and a separately accepted high-risk plan before code.
The spec fixes exact paths and proof; required CI and independent review remain.
This repair does not qualify a workflow or complete Roadmap step 7.

## Open questions

Can the already installed direct Command Line Tools Git on Darwin, while retaining
/usr/bin/git on Linux, meet the complete runtime contract? How will the runtime
establish trusted platform identity and reject missing or unsupported tools without
adding a caller-controlled selector?

Which private test boundaries prove dependency refusal and all actual startup/read
paths without modifying host tools? How will fresh and reused fixtures demonstrate
unchanged outputs, cleanup and resource behavior on both platforms?

Does the resulting evidence remove the need for the pending cache exception? That
answer requires actual resolver proof and a separately reviewed parent update;
the other component's finite direct-Git experiment cannot supply it.
