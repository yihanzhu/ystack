# Intent: Keep the materializer Git index in private scratch

Tracks #386. [Accepted intake](https://github.com/yihanzhu/ystack/issues/386#issuecomment-5769482828).

## Problem

A local producer-to-candidate integration check for #327 rejected an unexpected
`repository.git/index`. The materializer already promises a scratch-only index,
but its four index operations set `GIT_INDEX_FILE` before a wrapper that clears
the environment. Git therefore uses an index inside the staging repository,
which is then published. Existing tree and content checks miss this wrong location.
Candidate preparation correctly refuses the unlisted file under its closed layout.

## Intended outcome

Restore the existing scratch-only index contract. Only the materializer chooses
its private index path; callers cannot redirect it. Preserve the cleared Git
environment, unchanged source, exact candidate tree and receipt, and cleanup.
Published changed, no-change and SHA-256 candidates contain neither a root
`index` nor `index.lock`. Candidate preparation keeps its closed-layout refusal.

## Scope

Implementation changes only `adapters/local-git-materializer/v1/materialize.sh`
and `scripts/test/local-git-materializer-adapter.test.sh`. Use
`work/materializer-scratch-index/` for the separately accepted artifact chain.
The original runtime landed through #229 during construction without a normal
artifact chain; this bounded repair does not reopen its old branches or authority.

Do not add a parser, expand the candidate layout, prune published files, forward
generic ambient environment values, change profile pins or add a test framework.
Preserve the separate dirty #327 attempt until the manager reconciles the repaired
dependency through its existing gates; this intent authorizes no cleanup of it.

## Proof and boundaries

Keep every existing assertion and run the complete affected materializer integration
suite. Extend its real changed, no-change and SHA-256 success cases to prove both
published index paths absent alongside their existing tree, receipt, source and
scratch checks. A real public-entry test with a hostile inherited `GIT_INDEX_FILE`
must leave its sentinel unchanged while producing the expected candidate.

G1, G2 and a separately accepted high-risk plan precede code. Required quick CI
and independent review remain. Relevant downstream integration and the dispatched
full matrix remain required at the existing Roadmap milestone. Known receiver
supervision failures remain failures. No credentials, real target execution,
installation, activation, release, deployment, policy change or destructive
disposition is included.
