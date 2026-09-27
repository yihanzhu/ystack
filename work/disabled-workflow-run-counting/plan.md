---
spec-blob: c70ccd50c18858f8165da66d5dce64707d1cbbe1
drafted: 2026-09-22
---

# Plan: Count runs from disabled selected workflows

Tracks #132. Risk is high; implementation `review_size: standard`.
This plan must pass independent review and merge before implementation starts.

## Files that change

- `scripts/v2/quota-preflight.sh`: include disabled workflows in each existing
  selected-workflow query.
- `scripts/test/v2-quota-preflight.test.sh`: extend the existing hermetic fixture
  and prove the resulting count and threshold behavior.

These are the only implementation paths. Keep accepted artifacts unchanged.

## Order of work

1. After plan acceptance, verify the current base and intent/spec/plan hash chain
   through the existing high-risk gate before the first code commit.
2. Extend the existing PATH-based `gh` stub to recognize `--all` and a configured
   disabled workflow. Hide that workflow with the existing missing-workflow
   response when `--all` is absent; otherwise return its configured count.
   Preserve enabled workflows and every existing fixture mode and assertion.
3. Add two real-helper invocations with an enabled selected workflow contributing
   3 runs and a disabled selected workflow contributing 16, then 17. At backstop
   20, assert `runs=19` with exit 0, then `runs=20` with exit 1 and the existing
   threshold diagnostic. Keep the fixture local to this suite.
4. Run the augmented suite against the unchanged helper and retain the expected
   regression failure: disabled runs are omitted and the total is only 3.
5. Add `--all` only to the per-workflow `gh run list --workflow` query. Leave the
   global sanity query, other arguments, selection, accumulation and error paths
   unchanged. Run the complete affected suite and required checks below.

## Risks

An omitted disabled workflow can make the runaway brake pass at its threshold.
The riskiest boundary is distinguishing hidden workflows from genuine failures;
the repair must preserve numeric validation, fatal listing/unexpected errors and
the existing missing-workflow-as-zero policy. Keep defaults, exclusions, window,
fetch-limit scaling, environment precedence and run-attempt identity unchanged.

Use the CLI's existing visibility option. Broadening workflow selection or
changing error handling would alter the brake's policy and is outside this plan.
No new framework, dependency, exceptional code path, workflow edit, provider
operation, credential access, installation, activation or target execution.

## Proof

Run from the repository root, recording the command, exit status and output:

```sh
bash scripts/test/v2-quota-preflight.test.sh
shellcheck --version
shellcheck -x -S style scripts/v2/quota-preflight.sh scripts/test/v2-quota-preflight.test.sh
git diff --check
```

ShellCheck must be version 0.11.0. Preserve the pre-fix regression failure, then
run the complete affected suite and lint on the final committed implementation
head. The fixture must exercise the helper's actual output and exit status;
command-string matching alone does not prove the count. Existing assertions keep
covering errors, missing workflows, exclusions, fetch limits and legacy aliases.

Require green automatic quick CI and independent exact-head/base implementation
review under `work/ci-minimum-roadmap/decision.md`. This isolated repair does not
add a full-matrix milestone or claim a full-suite pass. All proof uses the local
stub; runtime output remains inactive and repository-only.
