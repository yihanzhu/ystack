---
spec-blob: b19c54bdae05f3c849b945a6002627c2d09d0549
drafted: 2026-09-21
---

# Plan: Pass the private index through the materializer's cleared environment

Tracks #386. Risk: high. Implementation `review_size: standard`.
Use Sol/medium for implementation after independent plan acceptance and protected
merge. The manager records plan-base, current artifact hashes and the build claim;
recheck a moved base before first code under AGENTS.md. Preserve existing attempts.

## Paths and implementation

This plan changes only `work/materializer-scratch-index/plan.md` on its deterministic
plan branch. Implementation changes only `adapters/local-git-materializer/v1/materialize.sh`
and `scripts/test/local-git-materializer-adapter.test.sh`. Keep the accepted spec's
modest size forecast; a small helper, four replacements and shared assertions suffice.

Add one private `git_index` helper beside git_dir. Like git_dir, it receives the
repository directory and Git arguments. Its command uses the existing git_env
array followed by the explicit assignment `GIT_INDEX_FILE="$run_root/index"`, then
fixed `/usr/bin/git` with the existing no-replace-objects and git-dir arguments.
The helper takes no caller-selected index path or generic environment parameters.

Replace only read-tree, cached apply check, cached apply and write-tree calls with
that helper; remove their ineffective calling-shell assignments and unused index_file
variable. Preserve conditions, argument order, redirections and error mapping,
including skipping both apply calls for an empty patch. Leave git_dir and every
other Git invocation unchanged. Keep the index/lock in the existing run directory
and let existing cleanup handle it; add no candidate index deletion or filtering.

Keep source, candidate content/tree/commit, same-input response/receipt bytes,
interface, validation, resource limits and security controls unchanged. No parser,
framework, public option, configuration, identity, profile/source pin or workflow
change. Do not touch the dirty candidate attempt or relax its closed layout.

## Tests and regression sequence

First extend the existing adapter suite, preserving all original assertions.
Use a small shared assertion for absence of repository.git/index and index.lock:
require both `! -e` and `! -L` for each path so dangling links also fail. Call it
from the existing success, no-change and SHA-256 cases. Keep success's current
scratch check and add empty-scratch assertions to the other two cases.

Add one real public-entry case through the existing run_case helper with inherited
GIT_INDEX_FILE pointing to a pre-existing sentinel outside candidate/scratch.
Retain its original bytes for comparison. Require successful materialization,
empty stderr/scratch, both published paths absent and unchanged sentinel bytes;
compare its complete response to the ordinary same-input success response.
Keep deterministic repeat, source fingerprint, direct-worker sanitization and all
negative cleanup cases. No mocked Git or source-text test replaces this proof.

Retain the recorded real producer/layout-refusal failure and fixture hash without
modifying that fixture. Before editing materialize.sh, run the changed adapter
suite against its unchanged source: the first new success-case absence assertion
should fail on the real published index. Record source/test hashes, actual exit
and that exact failure. This stops early and is regression evidence, not a full
suite result. If setup prevents reaching it, report that limitation; do not count
an unrelated failure as the expected red result or rerun whole suites needlessly.
Then apply the four-call repair and inspect all call sites for explicit private
assignment and unchanged ordinary Git behavior, with no pruning workaround.

## Final validation and handoff

On the final committed implementation head, run the complete native
`/bin/bash scripts/test/local-git-materializer-adapter.test.sh` once. Require every
original and added case, with full logs, actual exit and exact source/tool identities.
Run applicable pinned ShellCheck 0.11.0, structure/rename and diff checks; verify
only the two allowed paths differ and accepted artifacts are unchanged. Recheck
only affected proof after relevant changes, failures or unresolved concerns.

Require quick CI and independent exact-head/base review under
`work/ci-minimum-roadmap/decision.md`. Relevant downstream integration and the full
dispatched matrix remain due at its existing runnable milestone before dependent
acceptance; quick green does not claim those suites passed. Receiver failures stay
failed. The manager reads complete raw review/evidence and records protected merge.
Keep separate roles, claims, round limits and preserved-attempt gates. No credentials,
real target, installation, activation, release, deployment or destructive disposition.
