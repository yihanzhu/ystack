---
intent-blob: e56b92429ca56a638827ebf7d0e270ffa2bd1089
risk: high
drafted: 2026-09-09
---
# Spec: ci-test-shards

CI runs all 62 `scripts/test/*.test.sh` suites one after another in a single job and
takes 80 to 90 minutes. This splits that work across six parallel runners without
changing any of the existing suites, what the merge gate is called, or what it
means. No suite is added; the sharding proof runs as a separate check.

**Risk is `high`.** The change touches two constitution paths —
`.github/workflows/ci.yml` and `AGENTS.md` — which unattended agents never write
(`AGENTS.md`, "Stage rules (autonomous lane)": the constitution paths are
`.github/**`, `.claude/**`, `AGENTS.md`, `CLAUDE.md`, `REVIEW.md`, `ROADMAP.md`).
`ci.yml` is also the workflow behind the one required check the branch ruleset
enforces. So a plan-only PR on
`ystack/plan/ci-test-shards` goes first, an independent reviewer reads it, the
operator merges it, and only then does `ystack/impl/ci-test-shards` open. On that
branch the operator commits both of those files himself — the workflow and the
`AGENTS.md` bullet of requirement 13. Agents prepare everything else: the runner,
the proof script, the manifest line, and, for the two operator-owned files, the
proposed patch text only — saved as a unified diff under `proposals/`
(`proposals/<slug>-<short-title>.patch`, with the rationale in the PR body) exactly
as `proposals/README.md` describes, never the commit itself.
`review_size: standard`.

## Requirements

1. **Shard selector.** `scripts/test/run-all.sh` accepts `--shard <index>/<count>`.
   `index` is 1-based; `1 <= index <= count <= 16`. The same value may be given as
   the environment variable `YSTACK_TEST_SHARD=<index>/<count>`. If both are given,
   the flag wins and the variable is ignored silently.

2. **The argument-less run keeps today's behaviour, byte for byte.** The guarantee is
   about the run with no arguments at all: no `--shard` flag, no `YSTACK_TEST_SHARD`
   set, and no `--list`. That run discovers exactly the same suites by the same rule,
   runs them in the same order, prints the same lines, ends with the same final count
   line, and returns the same exit codes as today. There is no carve-out and nothing
   new appears: the sharding proof in requirement 9 is not named `*.test.sh`, so the
   unchanged discovery rule never sees it.

   `--list` (requirement 6) is a new mode that only happens when the flag is given.
   It lists and runs nothing, so it has no output to match against today's run, and
   it changes nothing about the argument-less run — which never lists.

   Verified two ways, without diffing two 80-minute runs:
   - run `--list` with no selector and compare it to the discovery command in
     requirement 3, `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh'`
     piped through `LC_ALL=C sort`, written out as repo-relative paths the same way.
     The two lists must be identical, so discovery and ordering are provably
     untouched;
   - from a single no-argument run, compare its `==> <path>` headers, in order, and
     its closing `all <N> test scripts passed` line against today's — today that is
     62 suites and `all 62 test scripts passed`. That plus the `--list` check pins
     discovery, order and count, so a full diff of two long runs is not required.

3. **Deterministic assignment.** Suites are discovered exactly as today —
   `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh'` piped through
   `LC_ALL=C sort` — and the sharding filters that list afterwards. Suite `k`
   (0-based, in that sorted order) belongs to shard `(k mod count) + 1`: round-robin
   by index. For every `count` from 1 to 16 the shards are disjoint and their union
   is the whole list — 62 suites today — so each suite runs exactly once per CI run.

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
   exists so the focused proof can check the partition without paying 80 minutes of
   suite time. This mode exists only when the flag is given, so requirement 2's
   byte-for-byte guarantee does not cover it: `--list` with no shard lists every
   suite and runs none, which is not the argument-less run.

7. **Output when running.** This requirement is about the running mode — `--list` not
   given. Before the first suite the script prints
   `shard <i>/<n>: <m> of <N> test scripts selected`, where `m` is the number
   selected and `N` the number discovered. Each suite still prints its `==> <path>`
   header. The run ends with `all <m> test scripts passed`. Running with no selector
   and no `--list`, the runner prints nothing it does not print today: no `shard`
   line, no extra header, no change to the closing count line — see requirement 2.

8. **No vacuous pass.** If the selection is empty — which needs `count > N`, so it
   cannot happen at `count <= 16` with 62 suites, but must still be handled — the
   script prints `error: shard <i>/<n> selected no test scripts` to stderr and exits
   `1`. It never prints a passing line for zero suites. The existing "no
   `scripts/test/*.test.sh` files found" error keeps its current text and exit code.

9. **Focused proof, outside the discovered suite set.** A new, executable
   `scripts/test/run-all-sharding.check.sh` proves by calling `--list`:
   - for `count` in 1, 2, 6 and 16: the shards are pairwise disjoint, no suite
     appears twice, and their union sorted equals the `--list` output with no shard;
   - the `--list` output with no shard equals `--shard 1/1 --list`;
   - each refusal in requirement 5 exits `2`, writes that exact usage line to stderr,
     prints nothing to stdout, and runs no suite;
   - the flag beats `YSTACK_TEST_SHARD` when both are set, and the variable alone
     selects the same set as the equivalent flag.

   Its name ends in `.check.sh`, not `.test.sh`, so the unchanged discovery rule in
   requirement 3 never picks it up and the no-argument run stays byte-identical
   (requirement 2). It is run explicitly instead, by the workflow's `checks` job, as
   `bash scripts/test/run-all-sharding.check.sh`, in one step right after the
   shellcheck step; the workflow edit is the operator's commit anyway. It runs in
   seconds because it only calls `--list` and never executes a suite. It is
   `shellcheck 0.11.0 -x -S style` clean — the sweep's `find . -name '*.sh'` already
   covers it — and its path is appended at the end of `ci/required-files.txt`, which
   also checks that it is executable.

10. **Workflow shape.** `.github/workflows/ci.yml` keeps its `on:` triggers unchanged
    (`pull_request`, and `push` to `main`) and its `permissions` block, and gains
    three jobs. Every job that touches a repository file begins with the very
    checkout step the workflow uses today, copied unchanged:

        - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

    Each GitHub Actions job starts with an empty workspace, and a checkout in one job
    does not populate another, so this step is repeated per job rather than shared:
    - `checks` — that checkout step first, then the required-files check, the
      pinned-shellcheck step, then one new `run:` step invoking the sharding proof of
      requirement 9 (`bash scripts/test/run-all-sharding.check.sh`), then the rename
      gate. All four of those read the repository, so without the checkout the very
      first one cannot find `ci/required-files.txt` and the required check goes red.
      The checkout and the three existing gate steps read exactly as they do today;
      the proof step is the only addition.
    - `test` — `strategy: {fail-fast: false, matrix: {shard: [1,2,3,4,5,6]}}`, that
      same checkout step, then
      `bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/6`.
      `fail-fast: false` so one red shard still lets the others report.
    - `ci` — `needs: [checks, test]`, `if: always()`, and one step that fails unless
      `needs.checks.result == 'success' && needs.test.result == 'success'`. This job
      needs no checkout: it reads only `needs.*.result` and opens no repository file.
      For a matrix job `needs.test.result` is `success` only when every shard
      succeeded, so a failed, cancelled or skipped shard turns `ci` red.

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
    the three jobs and the shard flag. `AGENTS.md` is a constitution path, so agents
    only write the proposed sentence into the `proposals/` patch and the PR body; the
    operator commits that edit himself, together with the workflow.

14. **Wall time.** Target: under 25 minutes, measured by the PR's own CI run
    duration, which the operator records in the implementation PR body.

## Design

Order of work on `ystack/impl/ci-test-shards`:

1. `scripts/test/run-all.sh` — argument parsing, `--list`, the round-robin filter,
   the new output line, the refusal paths. Discovery and the `GIT_*` defaults stay as
   they are; the filter sits between discovery and the run loop.
2. `scripts/test/run-all-sharding.check.sh`, plus its line appended at the end of
   `ci/required-files.txt`.
3. `proposals/ci-test-shards-shard-ci.patch` — the agents' proposed text for the two
   operator-owned files in step 4, as one unified diff. Nothing else in `scripts/` or
   `docs/` changes.
4. **Both operator-owned files, in the operator's own last commit:**
   `.github/workflows/ci.yml` and the `AGENTS.md` bullet of requirement 13. Agents
   write neither file. What agents produce for them is patch text: one unified diff
   saved as `proposals/ci-test-shards-shard-ci.patch`, covering both files, with the
   rationale in the implementation PR body, per `proposals/README.md`. The operator
   applies it (`git apply proposals/ci-test-shards-shard-ci.patch`) or types the
   edits himself, and commits. In the workflow, `checks` and each of the six `test`
   shards open with the workflow's existing checkout step
   (`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`), because a
   job's workspace starts empty; the aggregate `ci` job gets no checkout, since it
   only inspects `needs.*.result`.

Size estimate: about 70 net lines in the runner, 170 in the new proof script, 49 in
the workflow (the three jobs, the checkout step in each job that needs one, and the
one step that calls the proof), one manifest line and a sentence of docs — roughly
291 net lines, inside the 300–400 budget, hence `review_size: standard`. The
`proposals/` patch adds about 60 more lines, but they are the same workflow and
`AGENTS.md` text written twice — once as patch text, once as the operator's commit —
so they are read once, not twice.

Expected wall time with six shards, over the 62 suites in sorted order. The only
durations on record are the three in the accepted intake — `evals-dashboard` 835 s,
`portable-adapter-contracts` 485 s, `evals-approvals` 443 s — so every other suite is
counted at 57 s, which is what the 4769 s local run over 56 suites averages once
those three are removed. On that basis the heaviest shard is the one holding
`evals-dashboard` (shard 5 over today's 62 names), at about 22.5 minutes; the others
land between 9 and 18. Add a minute or two for checkout and the shellcheck bootstrap
and a run finishes around 24 minutes. That clears the target, but only just — which
is why the shard count is a tunable.

## Out of scope

- Making any individual suite faster. `evals-dashboard` alone is about 14 minutes and
  is the real ceiling; it gets its own follow-up issue.
- A merge queue. Any change to the branch ruleset. No change to which suites exist:
  none is removed, renamed, skipped, or reordered in meaning, and none is added — the
  sharding proof of requirement 9 is a `checks`-job script outside the discovered
  suite set, by design. Duration-balanced or bin-packed scheduling.

## Areas of concern

- **Two files are operator-authored, not one.** `.github/workflows/ci.yml` and
  `AGENTS.md` are both constitution paths, and requirement 13 needs an `AGENTS.md`
  edit, so it is easy to read this initiative as "the workflow is the operator's, the
  rest is ours" and land the docs bullet by mistake. Agents write the runner, the
  proof script and the manifest line; for those two files they write only patch text
  under `proposals/` plus the rationale in the PR body, and the operator commits both
  as the last commit on the implementation branch. That is also why this spec is
  `risk: high`.
- **The sharding proof sits outside the suite set on purpose.** The accepted intent
  says "No change to which suites exist" and that the runner stays usable locally,
  unchanged, with no arguments. A new `*.test.sh` file would breach both: the
  discovery rule would pick it up and the no-argument output would gain a header and
  a higher count. Naming it `.check.sh` and calling it from the `checks` job honours
  the intent exactly — and does not hide the proof, because `checks` is a dependency
  of the aggregate `ci` job, so a red proof still turns the one required check red.
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
- **Setup runs seven times.** Seven of the eight jobs check the repository out: each
  of the six `test` shards and `checks`. The aggregate `ci` job is the one that does
  not, because it reads only `needs.*.result`, so the count is seven and not eight.
  Add the shellcheck download in `checks` and that is a minute or two of duplicated
  work per run, paid to buy back an hour. Acceptable.
- **The margin is thin.** 24 minutes against a 25-minute target, on an estimate built
  from one local measurement of 56 suites. If the real run lands over, the answer is
  a higher shard count, not a change to the rule.

## Answers to the intent's open questions

- **How many parallel shards?** Six. On the same 62-suite estimate, four leaves a
  28-minute shard and misses the target; eight only reaches about 21 minutes, because
  the three slow suites dominate at any count, and it costs a third more runner
  minutes for barely a minute of wall time.
- **Balanced by measured duration or by index?** By index — see requirement 4.
- **Does the slowest suite get a follow-up?** Yes, separately. `evals-dashboard` at
  about 14 minutes is the floor no shard count can beat. Out of scope here.
