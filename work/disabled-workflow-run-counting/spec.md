---
intent-blob: d9bd79f672384b5b97d43ab96e9165038fb5d3c3
risk: high
drafted: 2026-09-22
---

# Spec: Count runs from disabled selected workflows

Tracks #132. Implementation `review_size: standard`.

## Requirements

Runs inside the existing counting window must contribute to the combined total
even when their selected workflow is disabled. A total below the configured
backstop exits 0; a total at or above it exits 1 with the existing diagnostic.
The reported `runs=<count>` must include those runs.

Keep the selected workflow list, default exclusions, counting window, fetch-limit
scaling and configuration precedence unchanged. Preserve numeric-count validation,
fatal global listing failures and unexpected per-workflow errors, and the existing
missing-workflow-as-zero behavior. An error must not become zero usage.
The implemented run ID and run-attempt identity behavior must remain intact.

## Design

Implementation changes only `scripts/v2/quota-preflight.sh` and its existing
`scripts/test/v2-quota-preflight.test.sh`.

Add `--all` to each selected workflow's `gh run list --workflow` query. This is
the CLI's existing option for including disabled workflows; it does not replace
the workflow filter or expand selection. Keep the global listing sanity check,
other query arguments, count accumulation and error handling unchanged.

Extend the existing PATH-based `gh` stub with a disabled-workflow fixture. Without
`--all`, that selected workflow is hidden using the existing missing-workflow
response. With `--all`, it returns its configured count. Keep enabled workflows
and all existing fixture modes unchanged; no new test framework is needed.

## Required proof

Invoke the real preflight helper through the existing hermetic test suite, with
one enabled and one disabled selected workflow. At the default backstop of 20,
use counts of 3 and 16 to require `runs=19` and exit 0, then 3 and 17 to require
`runs=20`, exit 1 and the existing threshold diagnostic. These cases answer the
intent's fixture and boundary questions: hiding the disabled workflow would
instead report only 3 and incorrectly pass the threshold case.

Preserve every existing test and run the complete affected suite on the final
implementation head. The new regression must fail with the original query that
omits `--all`; matching a command string alone is insufficient. Retain existing
proof for missing workflows, fatal errors, exclusions, fetch limits and environment
aliases and precedence. Apply pinned ShellCheck 0.11.0 to the changed shell files
and required CI; no live provider run is part of this proof.

## Out of scope

No workflow-file edits, probe publication, permission or executable-selection
changes, account quota policy, run-attempt redesign, provider operations or
credentials. No workflow enable/disable action, installation, activation, target
execution, release or deployment. This repairs one helper behavior within the
default GitHub adapter; it does not complete Roadmap step 4 or activate the lane.

## Areas of concern

Risk is high because this helper is the existing runaway safety brake, despite
the small patch. G2 acceptance must be followed by a separately reviewed and
accepted high-risk plan before implementation. Required CI and independent
implementation review remain gates; this spec does not accept itself.

There is no conflict with the accepted intent or portable north star. The change
uses the existing GitHub-specific helper boundary and adds no core dependency or
exceptional implementation path. All output remains inactive and repository-only.
