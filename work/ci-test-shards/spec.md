---
intent-blob: e56b92429ca56a638827ebf7d0e270ffa2bd1089
risk: high
drafted: 2026-09-09
---
# Spec: ci-test-shards

CI runs every discovered `scripts/test/*.test.sh` suite across six runners. The
completed run [35508104260](https://github.com/yihanzhu/ystack/actions/runs/35508104260)
took 40 minutes 37 seconds. Increase the fixed count to ten while preserving every
suite and the meaning of the required `ci` check.

**Risk is `high`.** The workflow and `AGENTS.md` are constitution paths. After G2,
a separate plan-only PR on `ystack/plan/ci-test-shards` must be independently
accepted and merged before implementation. The current operator-led authorization
supplies the applicable authorship and acceptance authority; this spec grants none.
`review_size: standard`.

## Shard count and prerequisite scope

The implementation changes only `.github/workflows/ci.yml` (the matrix list,
invocation denominator and shared jq prerequisite setup), the CI sentence in
`AGENTS.md`, and the matching sentence in `RESTORE.md`. The runner, sharding proof,
all suites, manifest, workflow triggers, permissions, checkout pin, `checks` steps,
aggregate gate and branch rules stay unchanged. No suite is added, removed, renamed or skipped, including on document-only
changes. Requirements 1–9 and 12 preserve the existing runner contract; they do not
ask for its reimplementation.

Validation uses the existing sharding proof, which covers every count from 1 to 16
and checks matrix/denominator equality, plus a fresh complete required CI run at the
implementation head. The existing producer suites verify the jq file, digest and
version. Their failures in run 35660956979 and success in the new complete run
provide the prerequisite regression evidence. Inspect the diff to confirm the
unchanged boundaries above. No new unit tests, temporary failing suite, red-test
commits, duplicate serial run, proposal patch or initial-install sequence is
required. The aggregate gate logic stays unchanged.

## Requirements

1. **Shard selector.** `scripts/test/run-all.sh` accepts `--shard <index>/<count>`.
   `index` is 1-based; `1 <= index <= count <= 16`. The same value may be given as
   the environment variable `YSTACK_TEST_SHARD=<index>/<count>`. If both are given,
   the flag wins and the variable is ignored silently.

2. **The argument-less run keeps its existing behaviour, byte for byte.** The guarantee is
   about the run with no arguments at all: no `--shard` flag, no `YSTACK_TEST_SHARD`
   set, and no `--list`. That run discovers exactly the same suites by the same rule,
   runs them in the same order, prints the same lines, ends with the same final count
   line, and returns the same exit codes as today. There is no carve-out and nothing
   new appears: the sharding proof in requirement 9 is not named `*.test.sh`, so the
   unchanged discovery rule never sees it.

   `--list` (requirement 6) only happens when the flag is given.
   It lists and runs nothing, so it has no output to match against today's run, and
   it changes nothing about the argument-less run — which never lists.

   The existing proof compares `--list` with independently discovered paths in
   sorted order. The runner stays byte-identical to the accepted base, preserving
   its execution order, output and exit codes without another serial run.

3. **Deterministic assignment.** Suites are discovered exactly as today —
   `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh'` piped through
   `LC_ALL=C sort` — and the sharding filters that list afterwards. Suite `k`
   (0-based, in that sorted order) belongs to shard `(k mod count) + 1`: round-robin
   by index. For every `count` from 1 to 16 the shards are disjoint and their union
   is the whole discovered list, so each suite runs exactly once per CI run.

4. **Index, not duration.** Assignment never reads a measured duration. The
   durations drift with the runner and may inform the fixed count, but not runtime
   assignment. An index rule is reproducible from the file names alone and needs no
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
   cannot happen at `count <= 16` when `N >= 16`, but must still be handled — the
   script prints `error: shard <i>/<n> selected no test scripts` to stderr and exits
   `1`. It never prints a passing line for zero suites. The existing "no
   `scripts/test/*.test.sh` files found" error keeps its current text and exit code.

9. **Focused proof, outside the discovered suite set.** The existing executable
   `scripts/test/run-all-sharding.check.sh` proves by calling `--list`:
   - the script works out the full suite list for itself, without asking the runner:
     `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh'` piped through
     `LC_ALL=C sort`, written out as repo-relative paths the same way the runner writes
     them. That raw list is what everything else in this bullet is compared against.
     It has to be, because comparing the shards only to the runner's own no-shard
     `--list` shows the runner agrees with itself, not that it is right: if discovery
     ever narrowed — a changed pattern, a wrong directory — and `--list` and the shard
     filter both read that narrowed list, the shards would still add up to `--list`
     and the proof would pass green while suites quietly went unrun. An independent
     oracle catches that; self-consistency cannot. So the script asserts both:
     (a) the `--list` output with no shard equals the raw list; and (b) for every
     `count` from 1 to 16, and for each of those counts every `index` from 1 to
     `count`: the shards are pairwise disjoint, no suite appears twice, and their
     union sorted equals that same raw list — not merely the `--list` output. Every
     count in that range, not a sample of four, because the runner accepts every one
     of them — that is `--shard <index>/<count> --list` for all 136 index/count pairs,
     written as a loop over the sixteen counts rather than sixteen spelled-out cases.
     This enforces requirement 2's discovery-and-ordering comparison on every PR;
   - the `--list` output with no shard equals `--shard 1/1 --list`;
   - each refusal in requirement 5 exits `2`, writes that exact usage line to stderr,
     prints nothing to stdout, and runs no suite;
   - the flag beats `YSTACK_TEST_SHARD` when both are set, and the variable alone
     selects the same set as the equivalent flag.

   Its name ends in `.check.sh`, not `.test.sh`, so the unchanged discovery rule in
   requirement 3 never picks it up and the no-argument run stays byte-identical
   (requirement 2). It is run explicitly instead, by the workflow's `checks` job, as
   `bash scripts/test/run-all-sharding.check.sh`, in one step right after the
   shellcheck step. It runs without executing suites: the partition sweep is 136 `--list` invocations plus the one `find` that
   builds the raw list, and `--list` lists and runs nothing, so the whole proof never
   executes a suite. It is `shellcheck 0.11.0 -x -S style` clean — the sweep's
   `find . -name '*.sh'` already covers it — and its path remains in
   `ci/required-files.txt`, which also checks that it is executable.

10. **Workflow shape.** `.github/workflows/ci.yml` retains its three jobs:
    - `checks` — the existing checkout, required-files check, pinned-shellcheck,
      sharding proof and rename gate, unchanged.
    - `test` — `strategy: {fail-fast: false, matrix: {shard: [1,2,3,4,5,6,7,8,9,10]}}`,
      the existing checkout, shared prerequisite setup, then
      `bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/10`.
      Before any selected suite runs, each test job prepares executable jq 1.6 at
      `${TMPDIR:-/tmp}/ystack-portable-core-jq16/jq-linux64`. Download the existing
      release asset from
      `https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64` over HTTPS
      into a temporary file. Verify SHA-256
      `af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44`
      before executing or placing it at the cache path, then require `jq-1.6` from
      its version check. A download, digest or version failure fails the job before
      the runner starts. This one workflow step supplies the existing shared
      prerequisite; it runs no suite, changes no system installation or PATH, and
      relies on no earlier suite or cached runner state. The matrix list,
      denominator and this setup step are the only workflow edits.
    - `ci` — unchanged `needs: [checks, test]`, `if: always()`, and the step that
      fails unless both dependency results equal `success`. Failed, cancelled or
      skipped dependencies must still make the aggregate gate fail.

11. **The required check keeps its name and meaning.** The branch ruleset is not
    touched. The sole required check stays `ci` from the same app (`15368`),
    with strict up-to-date protection. A green `ci` still means every gate and every suite
    passed. Read the final PR's check name and results. The aggregate job must be
    byte-identical to the accepted base. Require `checks`, all ten `test` shards
    and `ci` to succeed at the implementation head; no repeat of the initial
    red-shard proof is required because the gate logic is unchanged.

12. **Existing pins.** Three suites assert that run-all.sh still contains the exact
    discovery string in requirement 3:
    `scripts/test/portable-core-result-facts.test.sh:724`,
    `scripts/test/portable-core-stage-request.test.sh:1100`,
    `scripts/test/portable-core-result-truth.test.sh:1023`. Keeping that line
    byte-for-byte satisfies all three; neither the runner nor these suites changes.
    No test pins the blob of `run-all.sh` and none asserts the content of `ci.yml`
    (`scope-qualification.test.sh:721` and `loop-review-fix-planner.test.sh:372` use
    the path only as fixture text). `.github/workflows/ci.yml` is not in
    `ci/required-files.txt`; `scripts/test/run-all.sh` is, at line 89, and its path
    does not change.

13. **Docs.** Change “six parallel” to “ten parallel” in the CI sentence in
    `AGENTS.md` and the matching CI sentence in `RESTORE.md`. All surrounding
    instructions remain unchanged.

14. **Wall time.** Target: under 25 minutes, measured by the implementation PR's
    own complete CI run. Record the duration, head and run link in its description.
    A projection is not a measured result or a substitute for green CI.

## Design and evidence

Use the existing sorted round-robin assignment with a fixed count of ten. No
scheduler, duration table or dependency graph is added. All 66 suite durations from
run 35508104260 were measured between timestamped suite headers and final success
lines. Applying the existing assignment gives these busiest-shard projections:

| Shards | Suite time |
| --- | ---: |
| 6 | 40.41 minutes |
| 8 | 22.02 minutes |
| 10 | 19.51 minutes |
| 13 | 19.07 minutes |
| 16 | 20.26 minutes |

Ten is the smallest supported count projecting below 20 minutes for that run.
Thirteen gains only 26 seconds for three more runners; sixteen is slightly slower
than ten with these suite names. The measured count of 66 is evidence, not a fixed
suite inventory. Discovery remains automatic as files are added by other work.

Runner capacity, setup and machine variance can affect the actual wall time.
Suite additions or renames change modulo assignment and can move the bottleneck.
The longest measured suite, `evals-dashboard`, took 940 seconds; raising the count
cannot beat that individual-suite floor. The existing partition proof verifies
coverage independently of these performance estimates.

The producer suites require a shared digest-pinned jq 1.6 binary but do not download
it. Run [35660956979](https://github.com/yihanzhu/ystack/actions/runs/35660956979)
failed in shards 3 and 4 at that prerequisite: the ten-shard assignment no longer
puts a downloading suite before each producer suite. Preparing the same binary in
each test job removes that order dependency without changing suite membership,
order or identity checks. Running an extra suite as setup, changing assignment, or
copying download helpers across suites is outside this design.

## Out of scope

Individual-suite optimization or test removal, document-only skips, duration-based
scheduling, merge queues, branch-rule changes, runner or proof changes, installation,
activation and changes to the meaning of the required gate are outside this change.
