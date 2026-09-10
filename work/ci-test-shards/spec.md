---
intent-blob: e56b92429ca56a638827ebf7d0e270ffa2bd1089
risk: high
drafted: 2026-09-09
---
# Spec: ci-test-shards

CI runs all 63 `scripts/test/*.test.sh` suites one after another in a single job and
takes 80 to 90 minutes. This splits that work across six parallel runners without
changing which suites run, what the merge gate is called, or what it means.

**Risk is `high`.** The change edits `.github/workflows/ci.yml` — a constitution path
(`AGENTS.md`: agents never write `.github/**`) and the workflow behind the one
required check the branch ruleset enforces. So a plan-only PR on
`ystack/plan/ci-test-shards` goes first, an independent reviewer reads it, the
operator merges it, and only then does `ystack/impl/ci-test-shards` open. On that
branch the operator commits the workflow file himself; agents prepare everything
else. `review_size: standard`.

## Requirements

1. **Shard selector.** `scripts/test/run-all.sh` accepts `--shard <index>/<count>`.
   `index` is 1-based; `1 <= index <= count <= 16`. The same value may be given as
   the environment variable `YSTACK_TEST_SHARD=<index>/<count>`. If both are given,
   the flag wins and the variable is ignored silently.

2. **No selector means today's behaviour.** With no `--shard` flag and no
   `YSTACK_TEST_SHARD` set, the script runs every suite, prints the same lines in the
   same order, and returns the same exit codes as today. Verified by running it with
   no arguments and diffing against the current output.

3. **Deterministic assignment.** Suites are discovered exactly as today —
   `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh'` piped through
   `LC_ALL=C sort` — and the sharding filters that list afterwards. Suite `k`
   (0-based, in that sorted order) belongs to shard `(k mod count) + 1`: round-robin
   by index. For every `count` from 1 to 16 the shards are disjoint and their union
   is the whole list, so each suite runs exactly once per CI run.

4. **Index, not duration.** Assignment never reads a measured duration. The
   durations we have are one local measurement of 56 suites and they drift with the
   runner. An index rule is reproducible from the file names alone and needs no
   table to maintain.

5. **Refusals.** A malformed selector prints exactly one line to stderr, exits `2`,
   and runs no suite. The line is:

       usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)

   Malformed means at least `0/4`, `5/4`, `a/b`, `1/0`, `1/17`, `1`, `/4`, `4/`, an
   empty value, and any value with no slash. A `--shard` flag with no value after it
   is malformed too. The same rule applies to `YSTACK_TEST_SHARD`.

6. **Listing mode.** `--list` prints the selected suite paths, one repo-relative path
   per line, in sorted order, and runs nothing. It combines with `--shard`; without
   one it lists every suite. It exits `0` when at least one suite is selected. It
   exists so the focused test can prove the partition without paying 80 minutes of
   suite time.

7. **Output when running.** Before the first suite the script prints
   `shard <i>/<n>: <m> of <N> test scripts selected`, where `m` is the number
   selected and `N` the number discovered. Each suite still prints its `==> <path>`
   header. The run ends with `all <m> test scripts passed`. Without a selector,
   neither that line nor any other new line appears (requirement 2).

8. **No vacuous pass.** If the selection is empty — which needs `count > N`, so it
   cannot happen at `count <= 16` with 63 suites, but must still be handled — the
   script prints `error: shard <i>/<n> selected no test scripts` to stderr and exits
   `1`. It never prints a passing line for zero suites. The existing "no
   `scripts/test/*.test.sh` files found" error keeps its current text and exit code.

9. **Focused test.** A new, executable `scripts/test/run-all-sharding.test.sh` proves
   by calling `--list`:
   - for `count` in 1, 2, 6 and 16: the shards are pairwise disjoint, no suite
     appears twice, and their union sorted equals the no-argument listing;
   - the no-argument listing equals `--shard 1/1 --list`;
   - each refusal in requirement 5 exits `2`, writes that exact usage line to stderr,
     prints nothing to stdout, and runs no suite;
   - the flag beats `YSTACK_TEST_SHARD` when both are set, and the variable alone
     selects the same set as the equivalent flag.

   It runs in seconds because it never executes a suite. It is `shellcheck 0.11.0 -x
   -S style` clean and is added to `ci/required-files.txt`.

10. **Workflow shape.** `.github/workflows/ci.yml` keeps its `on:` triggers unchanged
    (`pull_request`, and `push` to `main`) and its `permissions` block, and gains
    three jobs:
    - `checks` — the required-files check, the pinned-shellcheck step and the rename
      gate, exactly as they read today.
    - `test` — `strategy: {fail-fast: false, matrix: {shard: [1,2,3,4,5,6]}}`,
      checkout, then `bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/6`.
      `fail-fast: false` so one red shard still lets the others report.
    - `ci` — `needs: [checks, test]`, `if: always()`, and one step that fails unless
      `needs.checks.result == 'success' && needs.test.result == 'success'`. For a
      matrix job `needs.test.result` is `success` only when every shard succeeded, so
      a failed, cancelled or skipped shard turns `ci` red.

11. **The required check keeps its name and meaning.** The ruleset
    (`post_transition_ruleset` in `config/construction-mode.json`: single
    `required_status_check: "ci"`, `required_status_check_app_id: 15368`, strict) is
    not touched. A green `ci` still means every gate and every suite passed. Verified
    by reading the check name on the PR and by failing one shard on a scratch branch
    and confirming `ci` goes red.

12. **Existing pins.** Three suites assert that run-all.sh still contains the exact
    discovery string in requirement 3:
    `scripts/test/portable-core-result-facts.test.sh:724`,
    `scripts/test/portable-core-stage-request.test.sh:1100`,
    `scripts/test/portable-core-result-truth.test.sh:1023`. Keeping that line
    byte-for-byte satisfies all three and nothing has to move; if the implementer
    reflows it, those three are updated in the same PR. No test pins the blob of
    `run-all.sh` and none asserts the content of `ci.yml`
    (`scope-qualification.test.sh:721` and `loop-review-fix-planner.test.sh:372` use
    the path only as fixture text). `.github/workflows/ci.yml` is not in
    `ci/required-files.txt`; `scripts/test/run-all.sh` is, at line 89, and its path
    does not change.

13. **Docs.** A grep for `run-all` finds no prose anywhere describing CI as one
    serial run. `docs/transition-kit.md` mentions `scripts/test/run-all.sh` only
    inside two quoted JSON records (`forbidden_paths`, `required_manifest_entries`),
    which stay accurate and are not edited; README does not describe the test step.
    The one stale passage is the `AGENTS.md` "Stack & commands" CI bullet, which
    calls the workflow a structure check plus shellcheck; it gains a sentence naming
    the three jobs and the shard flag. `AGENTS.md` is a constitution path, so the
    operator commits that edit with the workflow.

14. **Wall time.** Target: under 25 minutes, measured by the PR's own CI run
    duration, which the operator records in the implementation PR body.

## Design

Order of work on `ystack/impl/ci-test-shards`:

1. `scripts/test/run-all.sh` — argument parsing, `--list`, the round-robin filter,
   the new output line, the refusal paths. Discovery and the `GIT_*` defaults stay as
   they are; the filter sits between discovery and the run loop.
2. `scripts/test/run-all-sharding.test.sh`, plus its line in `ci/required-files.txt`.
3. Nothing else in `scripts/` or `docs/` changes.
4. **Last commit, by the operator:** `.github/workflows/ci.yml` and the `AGENTS.md`
   bullet.

Size estimate: about 70 net lines in the runner, 170 in the new test, 45 in the
workflow, one manifest line and a sentence of docs — roughly 290 net lines, inside
the 300–400 budget, hence `review_size: standard`.

Expected wall time with six shards, using the ten measured durations and a 34 s
average for the rest: the heaviest shard is the one holding `evals-dashboard`, at
about 21.7 minutes; the others land between 8 and 20. Add a minute or two for
checkout and the shellcheck bootstrap and a run finishes around 23 minutes. That
clears the target, but not by much — which is why the shard count is a tunable.

## Out of scope

- Making any individual suite faster. `evals-dashboard` alone is about 14 minutes and
  is the real ceiling; it gets its own follow-up issue.
- A merge queue. Any change to the branch ruleset. Any change to which suites exist
  or which ones CI runs. Duration-balanced or bin-packed scheduling.

## Areas of concern

- **The workflow edit is operator-authored.** `.github/workflows/ci.yml` and
  `AGENTS.md` are constitution paths. Agents write the runner, the test and the
  manifest; the operator commits those two as the last commit on the implementation
  branch. That is also why this spec is `risk: high`.
- **The aggregate `ci` job must not be skippable.** An ordinary `needs:` job is
  *skipped* when a dependency fails, and a skipped required check leaves the gate
  ambiguous. `if: always()` plus explicit `needs.*.result` comparisons make it run
  and go red instead. This is the riskiest detail here, and the plan should say how
  it is proved — deliberately failing one shard on a scratch branch.
- **Six is a tunable.** Changing it means editing both the matrix list and the `/6`
  in the run line, and they must stay equal. Any count from 1 to 16 keeps the
  partition property, so a wrong count is slow or wasteful, never incorrect.
- **Shard membership moves when suites are added or renamed.** Round-robin over a
  sorted list means one new file reshuffles everything after it, so the heaviest
  shard's load drifts. Correctness is unaffected; only the estimate is.
- **Setup runs seven times** — checkout on each of the six shards plus `checks`, and
  the shellcheck download in `checks`. A minute or two of duplicated work per run,
  paid to buy back an hour. Acceptable.
- **The margin is thin.** 23 minutes against a 25-minute target, on an estimate built
  from one local measurement of 56 suites. If the real run lands over, the answer is
  a higher shard count, not a change to the rule.

## Answers to the intent's open questions

- **How many parallel shards?** Six. Four leaves a 32-minute shard and misses the
  target; eight only reaches about 19 minutes, because `evals-dashboard` dominates,
  and costs a third more runner minutes for two minutes of wall time.
- **Balanced by measured duration or by index?** By index — see requirement 4.
- **Does the slowest suite get a follow-up?** Yes, separately. `evals-dashboard` at
  about 14 minutes is the floor no shard count can beat. Out of scope here.
