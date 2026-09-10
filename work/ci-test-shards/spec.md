---
intent-blob: e56b92429ca56a638827ebf7d0e270ffa2bd1089
risk: high
drafted: 2026-09-09
---
# Spec: ci-test-shards

CI runs all 63 `scripts/test/*.test.sh` suites one after another in a single job and
takes 80 to 90 minutes. This splits that work across six parallel runners without
changing which suites run, what the merge gate is called, or what it means.

**Risk is `high`.** The change edits `.github/workflows/ci.yml`. That file is a
constitution path (`AGENTS.md` > "Unattended agents never write the constitution
paths — `.github/**` …") and it is the workflow behind the one required check the
branch ruleset enforces. So: a plan-only PR on `ystack/plan/ci-test-shards` goes
first, an independent reviewer reads it, the operator merges it, and only then does
`ystack/impl/ci-test-shards` open. On that implementation branch the operator
commits the workflow file himself; agents prepare everything else.

`review_size: standard`.

## Requirements

1. **Shard selector.** `scripts/test/run-all.sh` accepts `--shard <index>/<count>`.
   `index` is 1-based; `1 <= index <= count <= 16`. The same value may be given as
   the environment variable `YSTACK_TEST_SHARD=<index>/<count>`. If both are given,
   the flag wins and the variable is ignored silently.

2. **No selector means today's behaviour.** With no `--shard` flag and no
   `YSTACK_TEST_SHARD` in the environment, the script runs every suite, prints the
   same lines in the same order, and returns the same exit codes as it does today.
   Verified by running it with no arguments and diffing against the current output.

3. **Deterministic assignment.** Suites are discovered exactly as today —
   `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh'` piped through
   `LC_ALL=C sort` — and the sharding filters that list afterwards. Suite `k`
   (0-based, in that sorted order) belongs to shard `(k mod count) + 1`. This is
   round-robin by index. For every `count` from 1 to 16 the shards are disjoint and
   their union is the whole list, so each suite runs exactly once per CI run.

4. **Index, not duration.** Assignment never reads a measured duration. Durations
   are not stable evidence: they were measured once, locally, on 56 of the suites,
   and they drift with the runner. An index rule is reproducible from the file names
   alone and needs no table to maintain.

5. **Refusals.** A malformed selector prints exactly one line to stderr, exits `2`,
   and runs no suite. The line is:

       usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)

   Malformed means at least: `0/4`, `5/4`, `a/b`, `1/0`, `1/17`, `1`, `/4`, `4/`,
   an empty value, and any value with no slash. A `--shard` flag with no value
   following it is malformed too. The same rule applies to `YSTACK_TEST_SHARD`.

6. **Listing mode.** `--list` prints the selected suite paths, one repo-relative
   path per line, in sorted order, and runs nothing. It combines with `--shard`;
   with no `--shard` it lists every suite. It exits `0` when at least one suite is
   selected. This exists so the focused test can prove the partition without paying
   for 80 minutes of suite time.

7. **Output when running.** Before the first suite the script prints
   `shard <i>/<n>: <m> of <N> test scripts selected`, where `m` is the number
   selected and `N` the number discovered. Each suite still prints its
   `\n==> <path>` header. The run ends with `all <m> test scripts passed`. Without a
   selector, neither the `shard` line nor any other new line appears (requirement 2).

8. **No vacuous pass.** If the selection is empty — which needs `count > N` and so
   cannot happen at `count <= 16` with 63 suites, but must still be handled — the
   script prints `error: shard <i>/<n> selected no test scripts` to stderr and exits
   `1`. It never prints a passing line for zero suites. The existing "no
   `scripts/test/*.test.sh` files found" error keeps its current text and exit code.

9. **Focused test.** A new `scripts/test/run-all-sharding.test.sh`, executable,
   proves by calling `--list`:
   - for `count` in 1, 2, 6 and 16: the shards are pairwise disjoint, their union
     sorted equals the no-argument listing, and no suite appears twice;
   - the no-argument listing equals `--shard 1/1 --list`;
   - each refusal case in requirement 5 exits `2`, writes the exact usage line to
     stderr, prints nothing to stdout, and runs no suite;
   - the flag beats `YSTACK_TEST_SHARD` when both are set, and the variable alone
     selects the same set as the equivalent flag.
   It runs in seconds because it never executes a suite. It is `shellcheck 0.11.0
   -x -S style` clean, and it is added to `ci/required-files.txt`.

10. **Workflow shape.** `.github/workflows/ci.yml` keeps its current `on:` triggers
    unchanged (`pull_request`, and `push` to `main`) and its `permissions` block,
    and gains three jobs:
    - `checks` — the required-files check, the pinned-shellcheck step and the
      rename gate, exactly as they read today.
    - `test` — `strategy: {fail-fast: false, matrix: {shard: [1,2,3,4,5,6]}}`,
      checkout, then `bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/6`.
      `fail-fast: false` so one red shard still lets the others report.
    - `ci` — `needs: [checks, test]`, `if: always()`, and a single step that fails
      unless `needs.checks.result == 'success' && needs.test.result == 'success'`.
      For a matrix job, `needs.test.result` is `success` only when every shard
      succeeded, so a cancelled, skipped or failed shard turns `ci` red.

11. **The required check keeps its name and meaning.** The ruleset
    (`post_transition_ruleset` in `config/construction-mode.json`: single
    `required_status_check: "ci"`, `required_status_check_app_id: 15368`, strict)
    is not touched. After the change, a green `ci` still means every gate and every
    suite passed. Verified by reading the check name on the PR and by making one
    shard fail on a scratch branch and confirming `ci` goes red.

12. **Existing pins.** Three suites assert that run-all.sh still contains the exact
    discovery string in requirement 3:
    `scripts/test/portable-core-result-facts.test.sh:724`,
    `scripts/test/portable-core-stage-request.test.sh:1100`,
    `scripts/test/portable-core-result-truth.test.sh:1023`. Keeping that line
    byte-for-byte satisfies all three and nothing has to move. If the implementer
    reflows it, those three tests are updated in the same PR. No test pins the blob
    of `run-all.sh` and no test asserts the content of `ci.yml`
    (`scripts/test/scope-qualification.test.sh:721` and
    `scripts/test/loop-review-fix-planner.test.sh:372` only use the path as fixture
    text). `.github/workflows/ci.yml` is not in `ci/required-files.txt`;
    `scripts/test/run-all.sh` is, at line 89, and its path does not change.

13. **Docs.** A grep for `run-all` finds no prose anywhere that describes CI as one
    serial run. `docs/transition-kit.md` mentions `scripts/test/run-all.sh` only
    inside two quoted JSON records (`forbidden_paths`, `required_manifest_entries`),
    which stay accurate and are not edited. README does not describe the test step.
    The one stale passage is the `AGENTS.md` > "Stack & commands" CI bullet, which
    describes the workflow as a structure check plus shellcheck; it gains a sentence
    naming the three jobs and the shard flag. `AGENTS.md` is a constitution path, so
    the operator commits that edit with the workflow.

14. **Wall time.** Target: under 25 minutes. Measured by the PR's own CI run
    duration, which the operator records in the implementation PR body.

## Design

Order of work on `ystack/impl/ci-test-shards`:

1. `scripts/test/run-all.sh` — argument parsing, the `--list` mode, the round-robin
   filter, the new output line, the refusal paths. The discovery pipeline and the
   `GIT_*` environment defaults stay as they are; the filter sits between discovery
   and the run loop.
2. `scripts/test/run-all-sharding.test.sh` — the focused test, plus its line in
   `ci/required-files.txt`.
3. Nothing else in `scripts/` or `docs/` changes.
4. **Last commit, by the operator:** `.github/workflows/ci.yml` and the `AGENTS.md`
   bullet.

Estimated size: about 70 net lines in the runner, about 170 in the new test, about
45 in the workflow, one manifest line and a sentence of docs — roughly 290 net
lines, inside the ~300–400 budget, hence `review_size: standard`.

Expected wall time with six shards, using the ten measured durations and the 34 s
average for the rest: the heaviest shard is the one holding `evals-dashboard`, at
about 21.7 minutes; the others land between 8 and 20 minutes. Add a minute or two
for checkout and the shellcheck bootstrap and the run finishes around 23 minutes.
That clears the 25-minute target but not by much, which is why the shard count is
written as a tunable rather than a constant of nature.

## Out of scope

- Making any individual suite faster. `evals-dashboard` alone is about 14 minutes
  and is the real ceiling; it gets its own follow-up issue.
- A merge queue.
- Any change to the branch ruleset.
- Any change to which suites exist or which ones CI runs.
- Duration-balanced or bin-packed scheduling.

## Areas of concern

- **The workflow edit is operator-authored.** `.github/workflows/ci.yml` and
  `AGENTS.md` are constitution paths. Agents write the runner, the test and the
  manifest; the operator commits the workflow and the docs bullet as the last commit
  on the implementation branch. That is also why this spec is `risk: high`.
- **The aggregate `ci` job must not be skippable.** If `ci` were an ordinary
  `needs:` job it would be *skipped* when a shard fails, and a skipped required check
  can leave the gate ambiguous. `if: always()` plus explicit `needs.*.result`
  comparisons make it run and go red instead. This is the single riskiest detail of
  the change and the plan should say how it is proved (deliberately failing one
  shard on a scratch branch).
- **Six is a tunable.** Changing it means editing both the matrix list and the `/6`
  in the run line; they must stay equal. Any count from 1 to 16 keeps the partition
  property, so a wrong count is slow or wasteful, never incorrect.
- **Shard membership moves when suites are added or renamed.** Round-robin over a
  sorted list means one new file reshuffles everything after it, so the heaviest
  shard's load drifts. Correctness is unaffected; only the estimate is.
- **The setup runs seven times.** Each of the six shards plus `checks` re-runs
  checkout and, in `checks`, the shellcheck download. That is a minute or two of
  duplicated work per run, paid to buy an hour back. Acceptable.
- **The margin is thin.** 23 minutes against a 25-minute target, on an estimate
  built from one local measurement of 56 suites. If the real run lands over, the
  answer is a higher shard count, not a change to the rule.

## Answers to the intent's open questions

- **How many parallel shards?** Six. Four leaves a 32-minute shard, which misses the
  target; eight only reaches about 19 minutes because `evals-dashboard` dominates,
  and costs a third more runner minutes for two more minutes of wall time.
- **Balanced by measured duration or by index?** By index. Durations are one local
  measurement of 56 suites and would need re-measuring and re-committing as suites
  change; an index rule is reproducible from the sorted file names and is trivially
  provable as a partition.
- **Does the slowest suite get a follow-up?** Yes, separately. `evals-dashboard` at
  about 14 minutes is the floor no shard count can go below. It is out of scope here
  and belongs in its own issue.
