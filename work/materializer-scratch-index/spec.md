---
intent-blob: 20be36f69ff9f3b1f3f7a9e3338a5dc91b7fdf2a
risk: high
drafted: 2026-09-21
---

# Spec: Restore the materializer's scratch-only Git index

Tracks #386. This repairs the private Git environment boundary. A separately
accepted high-risk plan must precede implementation.

## Scope and required behavior

Implementation changes only `adapters/local-git-materializer/v1/materialize.sh`
and `scripts/test/local-git-materializer-adapter.test.sh`.
Implementation `review_size: standard`; expect fewer than about 100 added plus
removed lines, with no minimum size or permission to compress readable proof.

The materializer must use its internally created `run_root/index` for the four
existing index-operation call sites: read-tree, cached apply check, cached apply,
and write-tree. Keep their existing conditions, arguments, ordering and error
mapping. Empty patches still bypass both apply calls.

Pass this internally selected path explicitly within the sanitized invocation's
assignment list, after `env -i` and before fixed `/usr/bin/git`. An assignment to
the calling shell function alone is insufficient. Keep any helper private and
specific to these index operations. Ordinary git_dir calls, source reads, pack
import and all other Git invocations retain their current environment and behavior.
Do not remove environment clearing, forward arbitrary variables or use an inherited
`GIT_INDEX_FILE`, public argument, configuration value or environment override.

The index and its transient lock belong only to the existing private run directory
and follow its existing success/failure cleanup. Changed, no-change and SHA-256
published candidates must have no root `repository.git/index` or `index.lock`
entry, including a symlink. Achieve this by correct creation and use in scratch,
not by deleting or filtering either path before or after publication.

Preserve source storage, candidate content/tree/commit, deterministic response and
receipt bytes for the same input, command interface, validation, security controls,
resource limits and cleanup behavior. No parser, candidate-layout expansion,
framework, fixture-builder change, profile/source pin change or workflow change.
The candidate's closed-layout rejection remains unchanged. The separate dirty
#327 attempt stays preserved until its manager reconciles the repaired dependency.

## Required proof

Use existing real-entry integration cases and keep every existing assertion,
including deterministic repeat, direct-worker sanitization and failure cleanup.
Do not replace real materialization with a mocked Git call or source-text check.

| Existing proof | Added acceptance evidence |
| --- | --- |
| Changed `success` case | Both published index paths are absent; retain bare repository, parent, patch content, receipt digest, stage validation, unchanged source and empty scratch assertions. |
| Empty-patch `no-change` case | Both paths are absent alongside the existing original commit/tree, zero changed paths and canonical no-change response checks; scratch is empty. |
| `sha256` case | Both paths are absent alongside the existing successful SHA-256 materialization check; scratch is empty. |
| Hostile caller environment | Invoke the real public `materialize` entry with GIT_INDEX_FILE pointing to a pre-existing sentinel outside candidate/scratch. Materialization succeeds, the sentinel's bytes are unchanged, both published paths are absent and scratch is empty. Its response matches the ordinary same-input success response. |

The existing suite's source fingerprint and complete negative cases remain proof
of preserved source and failure behavior. Review must also trace all four calls
to the explicit internal assignment and verify that absence is not due to pruning.
Reuse existing cases and helpers; add no separate test framework or index parser.

Run the complete affected adapter suite on the final committed implementation
head, with applicable pinned ShellCheck 0.11.0 and structure/diff checks. Retain
actual exits, full logs and exact source/tool identities. No partial run, retry
until green or removed assertion supplies a pass.

Apply `work/ci-minimum-roadmap/decision.md`: required quick CI and independent
exact-head/base review remain. Relevant candidate/materialization/delivery
integration and the dispatched full matrix remain required at the existing
runnable milestone before dependent acceptance. A quick green result does not
claim those suites ran; known receiver supervision failures remain failures.

Keep the artifact hash chain, separate author/reviewer roles, protected merge,
claims and preserved-attempt gates. No credentials, real target execution,
installation, activation, release, deployment, policy change or destructive
cleanup is included.
