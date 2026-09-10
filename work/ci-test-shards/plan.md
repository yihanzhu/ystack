---
spec-blob: 3338912efa042c62bf89c4a4500acc08fe2263df
drafted: 2026-09-10
---
# Plan: ci-test-shards

The spec (`work/ci-test-shards/spec.md`, blob above) is the contract and states all
fourteen requirements in full. This plan says which files change, in what order,
where in today's files, what can break, and how each requirement is proved. Where a
step names a requirement id, that requirement's own wording is the detail to follow.
Two of the seven files are constitution paths and are the operator's to commit;
agents write only the proposed patch text for those.

## Files that change

Seven files, nothing else. Counts are net changed lines, honest estimates.

**Agent-authored, on `ystack/impl/ci-test-shards`:**

- **`scripts/test/run-all.sh`** (~70 net; the file is 21 lines today, about 90 after).
  Argument and environment parsing, the `--list` mode, the round-robin filter, the
  new selection line, the refusal paths. Discovery (line 15) and the four `GIT_*`
  defaults (lines 5-8) are untouched.
- **`scripts/test/run-all-sharding.check.sh`** (new, ~185, mode `0755`). The focused
  proof of R9. Its name ends `.check.sh`, never `.test.sh`.
- **`ci/required-files.txt`** (+1). One line appended at the very end, after today's
  last line 401 (`docs/transition-kit.md`), becoming line 402.
- **`RESTORE.md`** (~3). The **CI** bullet at lines 416-418 only.
- **`proposals/ci-test-shards-shard-ci.patch`** (new, ~60). One unified diff holding
  both operator-owned edits, per `proposals/README.md`. This is proposed text, not an
  applied change.

**Operator-authored, as the last commit on the same branch:**

- **`.github/workflows/ci.yml`** (~49 net). The three-job shape of R10.
- **`AGENTS.md`** (+1). One sentence added to the CI bullet at line 86.

Both come from `git apply proposals/ci-test-shards-shard-ci.patch`. Agents write the
patch file; the operator applies and commits it. That is the whole reason this
initiative is `risk: high`.

### What does not change

- **No `*.test.sh` file is added, removed, renamed or reordered.** The 62 suites stay
  exactly as they are (R2, R3).
- **The discovery line stays byte-for-byte.** `run-all.sh:15` keeps
  `find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print | LC_ALL=C sort`
  unreflowed. Three suites grep that exact string (R12), so nothing has to move.
- **The branch ruleset.** `post_transition_ruleset` in `config/construction-mode.json`
  is not opened. The required check stays the single name `ci` (R11).
- **`on:` and `permissions:`** in `ci.yml` (lines 3-9) are copied through unchanged.
- **The four existing gate steps** in `ci.yml` — required-files, pinned shellcheck,
  test, rename — keep their text; they are moved between jobs, not rewritten.
- **`ci/required-files.txt:89`** (`scripts/test/run-all.sh`) — the runner's path does
  not change, so that line stays. `.github/workflows/ci.yml` is not in the manifest
  and no entry is added for it.
- **`RESTORE.md:419-424`**, the nested structure-check sub-bullet, stays as written:
  that check still runs, now inside `checks`.
- **`docs/transition.md:108`**, **`REVIEW.md:294`**, **`docs/transition-kit.md`**,
  **`README.md`**, **`QUICKSTART.md`** — all still accurate (R13). Leave them alone.

### Review size

`review_size: standard`, no exception claimed. Distinct content to read is about 309
net lines: 70 in the runner, 185 in the proof script, 49 in the workflow, one manifest
line, four lines of docs. The `proposals/` patch adds ~60 more lines on disk, but they
are the workflow and `AGENTS.md` text a second time, so they are read once. That fits
the ~300-400 budget in `AGENTS.md` > PR rules. If the real diff lands over 400, stop
and re-decide with the operator rather than splitting: the runner, its proof, and the
workflow that calls them are one concern.

## Order of work

### Step 0 — the proof script first (R9)

Write `scripts/test/run-all-sharding.check.sh` before touching the runner. Run it
once against today's unchanged runner and write down what it reports — it must refuse
at once, because no `--shard`/`--list` support exists yet. That refusing run is what
proves the script tests something. Then Step 1 turns it green.

**The first check is static, and it runs before the runner is invoked at all.**
Today's `run-all.sh` takes no arguments and never inspects `"$@"` — checked against
the file — so an unknown argument is not rejected, it is discarded. A
`run-all.sh --list` today would therefore not fail; it would start the full serial
suite and sit there for 80-90 minutes. So the script opens by grepping
`scripts/test/run-all.sh` for two fixed strings only Step 1 can put there: the exact
usage line

    usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)

matched with `grep -Fq` so its `<`, `>` and parens stay literal, and a `--list` case
label (`--list)`). If either is absent it prints

    error: run-all.sh does not implement --shard/--list yet

to stderr, runs nothing, and exits `2`. Step 0's recorded failure is exactly that
refusal — one line, under a second, no suite. **No invocation of `run-all.sh --list`
is made anywhere before Step 1 lands**: not by this script, not by hand, not in Proof
below.

Shape: `#!/usr/bin/env bash`, `set -euo pipefail`, resolve `root` the same way
`run-all.sh:4` does, one `mktemp -d` with a `trap` cleanup, and a small
`check`/`fail` pair printing one line per assertion. It builds its own raw suite
list, without asking the runner:

    find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print \
      | LC_ALL=C sort | sed "s|^$root/||"

That raw list is the oracle for everything below. R9 explains why: comparing shards
only against the runner's own `--list` proves the runner agrees with itself, not that
it is right. Assertions, in order:

1. `--list` with no selector equals the raw list, line for line.
2. `--shard 1/1 --list` equals `--list` with no selector.
3. The partition sweep. A loop `for n in $(seq 1 16)`, and inside it
   `for i in $(seq 1 "$n")`: collect `--shard $i/$n --list` into a per-shard file.
   Then assert every selected path appears in the raw list; that the concatenation of
   the `n` shards has no duplicate line (`sort` and `sort -u` of it are equal, which
   is exactly pairwise disjointness plus no repeat inside a shard); and that the
   sorted concatenation equals the raw list. 136 index/count pairs, written as the
   two loops, not sixteen spelled-out cases.
4. Every refusal of R5. For each bad value — `0/4`, `5/4`, `a/b`, `1/0`, `1/17`, `1`,
   `/4`, `4/`, the empty string, a value with no slash — and for `--shard` with no
   value after it: exit status is `2`, stderr is exactly the one usage line, stdout is
   empty, and no suite ran. Run each twice, once as the flag and once as
   `YSTACK_TEST_SHARD`.
5. `YSTACK_TEST_SHARD=2/6 ... --shard 1/6 --list` equals `--shard 1/6 --list`: the
   flag wins and the variable is ignored silently.
6. `YSTACK_TEST_SHARD=3/6 ... --list` equals `--shard 3/6 --list`: the variable alone
   selects the same set.

**Every runner call is bounded.** Once Step 1 lands, the precondition passes and the
assertions above do invoke the runner. Each of those calls goes through a wall-clock
bound, using the form this repo already uses for exactly this — macOS has no
`timeout` or `gtimeout`, and `scripts/lib/` holds no shared helper, so it is the perl
`alarm` idiom of `scripts/test/control-sandbox-policy.test.sh:114` and
`scripts/test/deploy-rollback-gates.test.sh:187`:

    /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$root/scripts/test/run-all.sh" --list

A `--list` run executes no suite and returns in well under a second, so 60 seconds is
pure headroom. SIGALRM makes the exit status `142`, and the script treats any timeout
as a failed assertion reading `run-all.sh --list did not return within 60s (the
runner started a suite)`. If some later change ever makes `--list` execute suites
again, this proof goes red in a minute instead of hanging the job for an hour.

It ends by printing a count of assertions passed and a final line
`sharding proof: all checks passed`, and exits `0`. It runs in seconds: about 170
`--list` invocations of a 90-line script plus one `find`, and `--list` executes no
suite. Keep it `shellcheck -x -S style` clean at 0.11.0 — the workflow's
`find . -name '*.sh'` sweep already covers it.

### Step 1 — `scripts/test/run-all.sh` (R1, R2, R3, R5, R6, R7, R8)

Insert parsing above today's line 10 (`count=0`), keep discovery where it is, and put
the filter between discovery and the run loop.

**Parsing.** Accept only `--shard <value>` and `--list`, each at most once. A second
occurrence of either, the `--shard=1/6` equals-form, a `--shard` with nothing after
it, and any unrecognised argument are all malformed. (The spec lists malformed
*values*; treating unknown arguments the same way is this plan's decision, and it is
what keeps R2 safe — nothing new can be silently accepted.)

Read the environment as *set*, not as non-empty: `[ "${YSTACK_TEST_SHARD+x}" = x ]`.
`YSTACK_TEST_SHARD=""` is therefore a given-but-empty value and refuses per R5, while
an unset variable is the argument-less run of R2. If the flag is given, the variable
is not read at all.

**Validation.** The value must match `^[1-9][0-9]*/[1-9][0-9]*$` — this alone rejects
`0/4`, `1/0`, `a/b`, `1`, `/4`, `4/`, the empty string and anything without a slash,
and it also rejects leading zeros and whitespace. Then check `index <= count` and
`count <= 16`, which rejects `5/4` and `1/17`. On any failure print exactly

    usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)

to stderr, nothing to stdout, and `exit 2` before any suite runs.

**Discovery, unchanged.** Keep today's `while IFS= read -r ... done < <(find ... |
LC_ALL=C sort)` construct and its `find` line verbatim. Change only the loop body:
instead of printing and running, append each path to an array. Its length is `N`.

**Filter.** If a selector was given, keep element `k` (0-based, in that sorted order)
when `(k % count) + 1 == index` (R3). With no selector, keep everything. Call the
kept count `m`.

**The two zero cases, in this order.** If `N` is `0`, print the existing
`error: no scripts/test/*.test.sh files found` to stderr and `exit 1` — same text,
same code, same meaning as today (R8). Otherwise, if a selector was given and `m` is
`0`, print `error: shard <i>/<n> selected no test scripts` to stderr and `exit 1`.
Never print a passing line for zero suites. With `count <= 16` and 62 suites this
second case cannot fire today, but it is handled.

**Output.** In `--list` mode, print the `m` kept paths, one repo-relative path per
line, in sorted order, and nothing else on stdout — no blank line, no selection line,
no headers — then exit `0`. That is what makes the diff in Proof possible. Otherwise
(running mode) print, with no leading blank line and only when a selector was given:

    shard <i>/<n>: <m> of <N> test scripts selected

then loop the kept paths printing today's `printf '\n==> %s\n'` header and running
`bash "$test_file"`, and finish with today's `printf '\nall %s test scripts passed\n'`
over `m`. With no selector `m == N`, no selection line prints, and the whole run is
byte-identical to today, ending `all 62 test scripts passed` (R2, R7).

### Step 2 — the manifest line (R9)

Append `scripts/test/run-all-sharding.check.sh` as the last line of
`ci/required-files.txt`, after line 401. The `scripts/*.sh` case in the workflow's
structure check (today's `ci.yml:34-40`) then also enforces that the file is
executable, which is why Step 0 sets mode `0755`.

### Step 3 — `RESTORE.md` (R13)

Rewrite the **CI** bullet at lines 416-418, in two or three sentences. Today it reads
"comes from `.github/workflows/ci.yml` (structure check + shellcheck)". It must name
the three jobs — `checks`, six parallel `test` shards, and the aggregate `ci` that
stays the hard merge gate — and the `--shard <index>/<count>` flag each shard passes
to `scripts/test/run-all.sh`. Keep the existing "hard merge gate" wording, keep
"Don't copy its steps here — link to it", and do not touch the nested sub-bullet at
419-424. `RESTORE.md` is not a constitution path, so this is an agent commit and it
stays out of the `proposals/` patch.

### Step 4 — `proposals/ci-test-shards-shard-ci.patch` (R10, R13)

One unified diff, applyable with `git apply`, covering both operator-owned files. Its
`AGENTS.md` half adds one sentence to the CI bullet at line 86, naming the three jobs
and the shard flag, and leaves the pinned-shellcheck sub-bullet at 88-95 alone —
`SHELLCHECK_VERSION` in `ci.yml` is still the single source of truth, now read by the
`checks` job.

Its `ci.yml` half replaces the single `ci` job (today's lines 11-106) with three,
keeping `name:`, `on:` and `permissions:` (lines 1-9) exactly as they are:

    jobs:
      checks:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
          - name: Check required files exist        # today's lines 17-45, verbatim
          - name: Shellcheck (if any shell scripts) # today's lines 47-94, verbatim
          - name: Sharding proof                    # new, the only added step
            run: |
              bash scripts/test/run-all-sharding.check.sh
          - name: Rename gate                       # today's lines 102-106, verbatim

      test:
        runs-on: ubuntu-latest
        strategy:
          fail-fast: false
          matrix:
            shard: [1, 2, 3, 4, 5, 6]
        steps:
          - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
          - name: Test suite
            run: |
              bash scripts/test/run-all.sh --shard ${{ matrix.shard }}/6

      ci:
        runs-on: ubuntu-latest
        needs: [checks, test]
        if: always()
        steps:
          - name: Gate
            run: |
              set -eu
              echo "checks: ${{ needs.checks.result }}"
              echo "test:   ${{ needs.test.result }}"
              if [ "${{ needs.checks.result }}" != "success" ] \
                 || [ "${{ needs.test.result }}" != "success" ]; then
                echo "ci gate FAILED"; exit 1
              fi
              echo "ci gate ok"

Four points the diff must get right. The checkout step is repeated in `checks` and in
`test` because each job starts with an empty workspace; without it the very first
step cannot find `ci/required-files.txt`. The aggregate job gets no checkout — it
opens no repository file. The aggregate job keeps the bare id `ci` and is given no
`name:` key, so the check it reports is still literally `ci`. And the `6` in the
matrix list and the `/6` in the run line are the same number.

The rationale paragraph for these two files goes in the implementation PR body, per
`proposals/README.md`.

### Step 5 — prove the agent-authored half

Run everything in Proof below that does not need the new workflow. Steps 0-4 are then
complete and the PR is openable with the operator's two files still missing.

### Step 6 — the operator's commit

The operator runs `git apply proposals/ci-test-shards-shard-ci.patch`, reviews the two
files, commits and pushes them as the last commit on `ystack/impl/ci-test-shards`.
Only after that does CI exercise the new shape. He records the run's wall-clock
duration in the PR body; the target is under 25 minutes (R14).

## Risks

- **The aggregate `ci` job must not be skippable.** This is the riskiest detail here.
  An ordinary `needs:` job is *skipped* when a dependency fails, and a skipped
  required check leaves the gate ambiguous rather than red. `if: always()` makes the
  job run regardless, and the explicit `needs.*.result != 'success'` comparisons turn
  failed, cancelled *and* skipped dependencies into a red `ci`. For a matrix job
  `needs.test.result` is `success` only when all six shards succeeded. Proved by
  deliberately failing one shard on a scratch branch (Proof, last item).
- **Job naming versus the required check name.** The ruleset requires one check named
  exactly `ci`. A job's check name is its `name:` if present, else its id, so the
  aggregate job must keep the id `ci` and no `name:` key. `checks` and
  `test (1)`..`test (6)` are new check names; they are not required and the ruleset
  is untouched. Getting this wrong blocks merges rather than passing them falsely —
  strict mode would wait forever for a check that never reports — but it would waste
  a review round, so read the check names on the PR (Proof).
- **Six appears twice and must stay equal.** The matrix list and the `/6` in the run
  line are independent text. If they ever disagree — matrix `[1..6]` against
  `--shard .../8` — two shards' worth of suites silently never run and `ci` still
  goes green. That is the one false-green in this design. Review is the only guard
  today: the proof script sweeps every count from 1 to 16 but cannot see the workflow.
  Rejected: having the proof script grep `ci.yml` for the matrix and the `/N` and
  assert they match. It is a second concern and it points an agent-owned script at a
  constitution path; better as its own follow-up issue than smuggled in here.
- **`--list` against today's runner would silently run the whole suite.** Today's
  `run-all.sh` parses nothing — no `case`, no `"$@"` — so `--list` is not refused, it
  is ignored, and the script falls through to the serial 80-90 minute run. This is
  the failure mode that makes Step 0's ordering delicate: a proof script that simply
  began asserting would look hung rather than failing, and on a CI runner it would
  spend the whole job budget before anyone learned anything. Two guards, both in
  Step 0: the static precondition, which refuses on the file's own text before any
  invocation, so the pre-Step-1 run is instant; and the perl `alarm` bound on every
  runner call afterwards, which turns "the runner started a suite" into a red
  assertion in 60 seconds rather than a hang. Rejected: writing the proof script
  against the finished runner and only then recording a failure, which is the
  ordering R9 exists to forbid — the script has to fail before the fix exists.
- **The shellcheck bootstrap runs once, not seven times.** It stays in `checks` only.
  Checked before writing this: no suite invokes the `shellcheck` binary — all ~60
  mentions across `scripts/test/*.test.sh` are `# shellcheck` directives — so the
  shards need no install. Rejected: copying the pinned-shellcheck step into the
  `test` job, which would download and verify the same tarball six more times per run
  for nothing. Seven checkouts plus one shellcheck download is the duplicated setup
  the spec accepts.
- **Three suites pin the discovery string.**
  `scripts/test/portable-core-result-facts.test.sh:724`,
  `portable-core-stage-request.test.sh:1100` and
  `portable-core-result-truth.test.sh:1023` each `grep -Fq` the exact `find` text out
  of `run-all.sh`. Keeping line 15 unreflowed satisfies all three and nothing moves.
  If a reflow ever becomes unavoidable, all three change in the same PR. Verified
  those three line numbers against today's files.
- **`.check.sh` sits outside the discovered set on purpose, and that has a cost.**
  The name keeps it out of the `*.test.sh` glob, which is what preserves R2, but it
  also means nothing runs it except the one workflow step. The manifest entry proves
  the file exists and is executable, not that the workflow still calls it: delete the
  `Sharding proof` step later and the proof goes quiet while every check stays green.
  While the step exists, `checks` is a `needs:` of `ci`, so a red proof is a red gate.
  Rejected: naming it `*.test.sh`, which would add a 63rd suite, change the
  no-argument output and count, and breach both R2 and the accepted intent.
- **The two operator files arrive last, and the branch is not broken meanwhile.**
  Before Step 6, a `pull_request` run uses the workflow file on the branch head —
  which is still today's single serial `ci` job. So the PR's first CI run is the old
  shape: it runs the required-files check (now including the new manifest line),
  shellchecks both shell files, runs `bash scripts/test/run-all.sh` with no arguments,
  and runs the rename gate. All of that passes, because the argument-less run is
  byte-identical, so the branch is green — just still 80-90 minutes, and without the
  sharding proof, which the old workflow has no step for. Run that proof locally
  (Step 5). After Step 6 the new shape takes over.
- **Shard membership drifts.** Round-robin over a sorted list means adding or renaming
  one suite reshuffles everything after it, so the heaviest shard moves. Correctness
  is unaffected — the partition property holds for any count from 1 to 16 — only the
  time estimate is. Rejected: duration-balanced or bin-packed assignment, per R4; the
  only durations on record are one local run and they drift with the runner.
- **The margin is thin.** About 24 minutes against a 25-minute target, on an estimate
  built from one local measurement of 56 suites; the heaviest shard is whichever holds
  `evals-dashboard` (shard 5 of 6 today, confirmed). If a real run lands over, raise
  the shard count; do not change the assignment rule.
- **Rejected: parallelism inside the single job.** Running the suites under
  `xargs -P` in one runner would interleave their output, make a failure hard to
  attribute, and change the local no-argument run — breaching R2 to avoid a workflow
  edit. A merge queue and any ruleset change are out of scope.

## Proof

Run from the repository root on `ystack/impl/ci-test-shards`. Do **not** run
`bash scripts/test/run-all.sh` with no arguments locally — that is the 80-90 minute
serial suite, and CI runs it for free on the branch's first push (see the
operator-files risk above), where its log must show 62 `==> ` headers and end
`all 62 test scripts passed`. That is R2's second verification.

1. **The focused proof (R1, R3, R5, R6, R9).**
   `bash scripts/test/run-all-sharding.check.sh` → one line per assertion, final line
   `sharding proof: all checks passed`, exit `0`, a few seconds.
   The fast-fail half is evidence too, and it is recorded once in Step 0 before the
   runner is touched: that same command against today's runner prints
   `error: run-all.sh does not implement --shard/--list yet` to stderr, exits `2` in
   under a second, and its output contains no `==> ` header — that last part is what
   shows no suite ran. Paste that line, the status and the timing in the PR body
   beside the green run.
2. **Discovery and ordering are untouched (R2, R3).**

       root=$(pwd -P)
       diff <(bash scripts/test/run-all.sh --list) \
            <(find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print \
                | LC_ALL=C sort | sed "s|^$root/||")

   → no output, exit `0`. And `bash scripts/test/run-all.sh --list | wc -l` → `62`.
3. **Refusals (R5).** `bash scripts/test/run-all.sh --shard 0/4; echo $?` → the single
   usage line on stderr, nothing on stdout, `2`. Repeat for `5/4`, `a/b`, `1/0`,
   `1/17`, `1`, `/4`, `4/`, `''`, a value with no slash, and a bare `--shard` with
   nothing after it; then repeat all of them as `YSTACK_TEST_SHARD=<value>
   bash scripts/test/run-all.sh`. Item 1 asserts every one of these automatically.
4. **Selection and partition, by hand (R3, R7).**
   `bash scripts/test/run-all.sh --shard 1/6 --list | wc -l` → `11`;
   `--shard 3/6` → `10`. Today's split over 62 suites is 11, 11, 10, 10, 10, 10.
   `bash scripts/test/run-all.sh --shard 1/1 --list | wc -l` → `62`.
5. **The three pins still pass (R12).** Run each and expect exit `0`:
   `bash scripts/test/portable-core-result-facts.test.sh`,
   `bash scripts/test/portable-core-stage-request.test.sh`,
   `bash scripts/test/portable-core-result-truth.test.sh`.
6. **Lint at the pinned version.** `shellcheck --version` reports `0.11.0`, then
   `shellcheck -x -S style scripts/test/run-all.sh scripts/test/run-all-sharding.check.sh`
   → no output, exit `0`.
7. **Schema guard.** `bash scripts/test/portable-core-schema.test.sh` → final line
   `failures: 0`, exit `0`.
8. **Rename gate.** `bash scripts/check-rename.sh` → no hits, exit `0`.
9. **The manifest entry (R9).** `tail -1 ci/required-files.txt` →
   `scripts/test/run-all-sharding.check.sh`, and
   `[ -x scripts/test/run-all-sharding.check.sh ] && echo ok` → `ok`. The workflow's
   structure check enforces both on every run; there is no standalone script for it.
10. **The patch applies (R10, R13).**
    `git apply --check proposals/ci-test-shards-shard-ci.patch` → no output, exit `0`.
    Agents run `--check` only; they never apply it.
11. **Scope.** `git diff --stat main` lists exactly five paths before Step 6 —
    `scripts/test/run-all.sh`, `scripts/test/run-all-sharding.check.sh`,
    `ci/required-files.txt`, `RESTORE.md`,
    `proposals/ci-test-shards-shard-ci.patch` — and exactly seven after it, adding
    `.github/workflows/ci.yml` and `AGENTS.md`.
12. **The gate keeps its name and meaning (R11, R14).** On the PR after Step 6, the
    check list reads `ci`, `checks`, and `test (1)` through `test (6)`; `ci` is green
    and is still the one required check. The operator records that run's wall-clock
    duration in the PR body; target under 25 minutes.
13. **A failing shard turns `ci` red — operator-run.** This needs the new workflow, so
    it cannot be done before Step 6, and it must not land on the implementation
    branch. On a scratch branch off the implementation head, add a line that exits
    non-zero to one suite in shard 3, push, and confirm `test (3)` is red, the other
    five shards still report (`fail-fast: false`), and `ci` is **red, not skipped**.
    Then delete the scratch branch. This is the direct proof of the first risk above.
