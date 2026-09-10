# Intent: ci test shards
Author: Yihan Zhu (operator). Status: draft.

## Problem

Every CI run takes about 80 to 90 minutes. All 62 test suites run one after
another on a single runner. A local serial run measured 4769 seconds for 56
suites, and three suites alone account for 30 minutes of that. The branch rule
requires a branch to be up to date before it merges, so every merge makes every
other open pull request re-run everything from the start. With several pull
requests in flight, this is the single biggest drag on the loop. The operator
feels it as hours of waiting per merge.

## Proposed outcome

A CI run finishes in well under half an hour. It covers the same suites and
reports through the same single required check name, so the merge gate means
exactly what it means today and is only faster. A partial run must never be
mistaken for a full one.

## Affected users and systems

The operator, who waits on every merge. Everyone with an open pull request in
this repository. The CI workflow, the branch ruleset that gates merges, the
shared test runner, and the documentation that describes CI as one serial run.

## Constraints

- The required check stays exactly one check named `ci` from the same app, so
  the branch ruleset does not change.
- The workflow file is a constitution path, so the operator commits that edit
  himself, and the change counts as high risk by this repository's rule.
- Every suite still runs exactly once per CI run. No suite is skipped, and none
  changes meaning through reordering.
- No merge queue.
- No change to which suites exist.
- The test runner stays usable locally, unchanged, with no arguments.

## Open questions

- How many parallel shards?
- Should shards be balanced by measured duration, or simply by index?
- Should the slowest suite, about 14 minutes on its own, get a follow-up?
