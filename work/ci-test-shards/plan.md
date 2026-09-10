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

Seven files, nothing else. Counts are net changed lines, honest estimates. The
agent-authored files are listed in the order they are written, which is the order in
Order of work below: the proof script comes before the runner, per Step 0.

**Agent-authored, on `ystack/impl/ci-test-shards`:**

- **`scripts/test/run-all-sharding.check.sh`** (new, ~185, mode `0755`). The focused
  proof of R9. Its name ends `.check.sh`, never `.test.sh`. Written and run first,
  against the unchanged runner (Step 0).
- **`scripts/test/run-all.sh`** (~70 net; the file is 21 lines today, about 90 after).
  Argument and environment parsing, the `--list` mode, the round-robin filter, the
  new selection line, the refusal paths. Discovery (line 15) and the four `GIT_*`
  defaults (lines 5-8) are untouched. Edited only after the proof script's failing run
  is recorded.
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
label (`--list)`). That second pattern begins with `--`, so it is passed as
`grep -Fq -e '--list)'` — the `-e` form works on both BSD and GNU grep. Without the
`-e`, grep reads the pattern as an option instead, and the precondition would keep
refusing even after Step 1 lands. If either is absent it prints

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

### Step 5 — prove the agent-authored half, then push and open the PR

Run everything in Proof below that does not need the new workflow. Steps 0-4 are then
complete and the PR is openable with the operator's two files still missing.

**Push and open the PR here, before the operator's commit. That order is required,
not a preference.** The branch head still carries today's single serial `ci` job, so
the PR's first CI run is the old shape and it runs `bash scripts/test/run-all.sh`
with no argument. That is the only place the no-argument run happens end to end, and
R2's byte-for-byte guarantee rests on it: its log must show 62 `==> ` headers and end
`all 62 test scripts passed`. Record four
things from that run in the PR body — the run's URL, the commit it ran on (call it
`H0`; `AGENTS.md:409-411` requires every pasted proof to name its commit), the `ci`
job's status, and its wall-clock time.

**That run can never happen on the final head, so it is bound to the final head by
content instead.** Step 6 adds the operator's two files and the red-shard pair, so the
final head `HF` is a later commit than `H0` — and at `HF` the workflow is sharded, so
a no-argument CI run is not producible there at all. What the run proves under R2 is
discovery, order and count: the `==> ` headers and the `all 62 test scripts passed`
line. Those depend on nothing but the runner and the set of suite files — that is, on
the tree `scripts/test`. So the binding is a tree identity. At `HF` the coder records,
in the PR body, the real output of both of

    git rev-parse H0:scripts/test
    git rev-parse HF:scripts/test

and the two tree ids must be byte-identical. Git trees are content-addressed, so
identical ids mean the runner and all 62 suites are the same bytes at both heads, and
the recorded discovery, order and count would come out the same at `HF`. The
operator's `ci.yml` and `AGENTS.md` commits touch nothing under `scripts/test`. The
red-shard add-and-delete pair adds a file and then removes it, which returns the tree
to the same id, so it does not break the binding either. Whether every suite still
*passes* at `HF` is not left to the earlier run: that is exactly what the final head's
own green sharded run shows.

R2's other verification — `--list` compared against the raw discovery command — needs
no binding, because it re-runs on every head. It is assertion 1 of
`scripts/test/run-all-sharding.check.sh` (Step 0), and the `Sharding proof` step in the
`checks` job runs that script on every push to the branch, `HF` included.

Step 6 does not begin until that evidence is in the PR body. The manager reads it
there first.

### Step 6 — the operator's commit, then the red-shard proof

**Precondition: Step 5's no-argument run is green and recorded in the PR body.** Once
the operator's commit lands, every run on this branch is sharded, so that evidence can
no longer be produced here, and there is no second PR to fall back on. If the workflow
commit lands first and no such run happened, the only recovery is on this same branch
and it is expensive: the operator reverts his workflow commit — those are his files —
lets one CI run finish under the old shape, records it in the PR body the same way,
then re-applies the workflow commit and waits for the sharded run to go green again.
Three extra runs and two more operator turns for evidence Step 5 gets for free. That
is why the manager checks this ordering before posting Step 6 at all, rather than
treating it as something to repair afterwards.

**Second precondition, checked at the end rather than the start: the binding still
holds.** At the final head the two `scripts/test` tree ids from Step 5 must still
match. If anything under `scripts/test` changed after `H0` — a review fix to the
runner, a new suite, a tweak to the proof script — then the no-argument evidence is
old proof on a new commit, which this repo treats as stale (`AGENTS.md:409-411`), and
a fresh run is required before review. Two ways to get one, both on this branch and
both the operator's: the revert-and-re-apply above, which buys one more old-shape CI
run; or he runs `bash scripts/test/run-all.sh` with no arguments locally at the final
head and pastes the 62 `==> ` headers and the `all 62 test scripts passed` line,
naming that commit. Either way the tree-id pair is re-recorded against the new run's
head. That local serial run is the one place in this plan where anybody runs the
80-90 minute suite by hand, it is the operator's to run because it is 80-90 minutes of
someone's machine, and it happens only if the binding broke. No agent runs it.

The operator runs `git apply proposals/ci-test-shards-shard-ci.patch`, reviews the two
files, commits and pushes them as the last commit on `ystack/impl/ci-test-shards`.
Only after that does CI exercise the new shape. He records the run's wall-clock
duration in the PR body; the target is under 25 minutes (R14).

**Then, once that run is green, the red-shard proof of the first risk below.** The
spec asks for this one on a scratch branch — requirement 11 at
`work/ci-test-shards/spec.md:168-173`, repeated in the risk note at `:311-313`. That
is infeasible as written and this plan corrects it openly; Deviations from the spec
below states the correction and how it is re-accepted. The reason: it needs a pull
request run. `ci.yml`'s `on:` is `pull_request` and `push` to `main` only (lines 3-6,
checked against the file), so pushing a scratch branch starts no run at all — there is
nothing to watch go red. So it runs on **this** PR, the one open PR for this slug, as
two ordinary commits on the implementation branch:

1. From the implementation head — the operator's workflow commit, with its own CI
   green — the coder pushes one commit adding a single file,
   `scripts/test/zz-red.test.sh`, holding two lines, `#!/usr/bin/env bash` and
   `exit 1`. It is a real `*.test.sh` file, so the runner discovers it like any
   other, and `zz-` sorts last under `LC_ALL=C` — no other name in `scripts/test`
   begins with `z`. That makes it element 63 of 63: 0-based index 62, and
   `(62 % 6) + 1 = 3`. So it lands in **shard 3**, predictably, and exactly one shard
   fails. The shebang is not decoration: without it the pinned shellcheck sweep in
   `checks` reports SC2148 and `checks` goes red too, which would blur the one thing
   this proves. Adding a 63rd suite also shifts the split to 11, 11, 11, 10, 10, 10;
   that is expected and changes nothing but the counts in the logs.
2. Wait for that run and record four things: `test (3)` red; the other five `test`
   jobs green, which is `fail-fast: false` doing its job; `checks` green; and the
   aggregate `ci` **red, not skipped**. The run's URL and the job list — `gh pr
   checks` output, or a screenshot of it — go in the PR body, beside the duration
   measurement.
3. Push a second commit that deletes the file. A plain new commit: never an amend,
   never a force-push. Wait for the run to go green again.

The PR is squash-merged, so both commits collapse into the one squashed commit and
neither the failing suite nor its deletion reaches `main`. A red intermediate head is
expected here and is not a failure of the PR: review and the `merge-ready` decision
are made at the final green head, with the recorded red run sitting in the body as the
evidence.

**The red run is bound to the final head the same way, by blob identity.** Call the
add commit `HR` — the head the red run actually ran on, named in the PR body beside
the run's URL and the `gh pr checks` job list. `HR` is superseded before merge, so the
evidence has to be tied to what ships. What the run proves is the aggregate gate's
behaviour, and that behaviour depends on exactly one file:
`.github/workflows/ci.yml`. Nothing else in the tree decides whether `ci` runs when a
shard fails or what it compares. So at the final head the coder records, in the PR
body, the real output of both of

    git rev-parse HR:.github/workflows/ci.yml
    git rev-parse HF:.github/workflows/ci.yml

and the two blob ids must be identical. Blobs are content-addressed, so identical ids
mean the gate that went red at `HR` is byte-for-byte the gate shipping at `HF`. If the
workflow changes after `HR` — a review fix to the `if: always()` block, say — the red
proof is stale and is redone: another add-then-delete pair on top of the new workflow,
with a new `HR` and a new pair of blob ids.

So the final review reads both identity pairs out of the PR body — the `scripts/test`
tree ids for R2, these `ci.yml` blob ids for R11 — not just the two run URLs. A pasted
run with no matching identity pair is stale proof, and the round is not clean.

There is a cheaper complement, worth doing first, that is **not** a substitute: read
the `ci` job in the workflow file on the branch and confirm by eye that it carries
`if: always()` and compares `needs.checks.result` and `needs.test.result` against
`success` explicitly. That is review of the text, not proof of the behaviour. Only a
real run shows GitHub actually reporting `ci` red.

## Deviations from the spec

One, stated openly rather than done quietly. Requirement 11
(`work/ci-test-shards/spec.md:168-173`) says the aggregate gate is verified "by
failing one shard on a scratch branch", and the risk note at `:311-313` repeats it.
That mechanism cannot work: `ci.yml`'s triggers are `pull_request` and `push` to
`main` only (`.github/workflows/ci.yml:3-6`), so a scratch branch starts no workflow
run whatsoever and there is nothing to watch go red. The spec's *intent* — deliberately
fail one shard, see the one required check go red rather than skipped, and keep that
failure off `main` — is met exactly. Only the mechanism changes: two ordinary commits
on the single implementation PR, add then delete, squash-merged, with the red run
bound to the final head by the `ci.yml` blob id (Step 6, Proof item 14).

The correction is submitted through this gate. Accepting this plan accepts the
corrected proof strategy; yshifu records the correction on the intake issue when this
plan merges, so the spec's wording is not silently overridden. The spec file itself is
not edited — it is the accepted contract, and this plan does not rewrite its text.

## Risks

- **The aggregate `ci` job must not be skippable.** This is the riskiest detail here.
  An ordinary `needs:` job is *skipped* when a dependency fails, and a skipped
  required check leaves the gate ambiguous rather than red. `if: always()` makes the
  job run regardless, and the explicit `needs.*.result != 'success'` comparisons turn
  failed, cancelled *and* skipped dependencies into a red `ci`. For a matrix job
  `needs.test.result` is `success` only when all six shards succeeded. Proved by
  making one shard fail on the implementation PR itself, on a commit that is deleted
  again before merge (Step 6, Proof last item). It has to be a PR run: the workflow's
  `on:` triggers are `pull_request` and `push` to `main` only, so pushing any other
  branch runs nothing and proves nothing — which is why the spec's "scratch branch"
  wording is corrected here (Deviations from the spec). The red run therefore sits on
  a head that is superseded before merge, so it is not left as old proof on a new
  commit: it is bound to the final head by the `ci.yml` blob id. Same blob, same gate,
  so the recorded red run is proof of the gate that ships (Step 6, Proof item 14).
- **One open PR for this slug, the whole way through.** Both awkward proofs — the
  no-argument run and the red shard — run inside the single implementation PR rather
  than a second one, because re-runs update the existing open PR and two PRs must
  never be open for the same slug and stage (`AGENTS.md:389-392`). Nothing in this
  plan opens another PR for `ci-test-shards`.
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
- **The two operator files arrive last, and that order is a requirement.**
  Before Step 6, a `pull_request` run uses the workflow file on the branch head —
  which is still today's single serial `ci` job. So the PR's first CI run is the old
  shape: it runs the required-files check (now including the new manifest line),
  shellchecks both shell files, runs `bash scripts/test/run-all.sh` with no arguments,
  and runs the rename gate. All of that passes, because the argument-less run is
  byte-identical, so the branch is green — just still 80-90 minutes, and without the
  sharding proof, which the old workflow has no step for. Run that proof locally
  (Step 5). After Step 6 the new shape takes over.
  That first old-shape run is the **only** full no-argument run this work gets from
  CI: afterwards every run on the branch is sharded, and no agent runs the serial
  suite locally. So pushing the five agent-authored files and opening the PR
  before the operator's commit is a hard precondition (Step 5, Proof item 12), and the
  manager reads the recorded run in the PR body before posting the operator's step. A
  PR whose first CI run was already sharded has no running-mode evidence, and the only
  recovery is the expensive one in Step 6 — the operator reverts his workflow commit on
  this same branch, one run finishes under the old shape and is recorded, then he
  re-applies it. That cost is why the ordering is checked before Step 6 is posted
  rather than repaired after.
  That run is also, necessarily, on an earlier head than the one that merges, so it is
  bound to the final head by the `scripts/test` tree id rather than left as old proof
  on a new commit (Step 5, Proof item 12). If that pair ever differs, the evidence is
  stale and a fresh no-argument run is taken before review — the same
  revert-and-re-apply, or the operator running the serial suite locally at the final
  head.
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

Run from the repository root on `ystack/impl/ci-test-shards`. Agents do **not** run
`bash scripts/test/run-all.sh` with no arguments locally — that is the 80-90 minute
serial suite, and CI runs it for free on the PR's first run, under the unchanged
workflow, before the operator's commit exists. That run is required, not incidental
(Step 5), and item 12 below is where it is recorded, named by commit, and bound to the
final head by tree identity. It is R2's second verification. The single exception is
the operator's fallback in Step 6, taken only if that binding breaks.

**The order of this list is binding and follows Order of work.** Item 1's first run
happens in Step 0, against the unchanged `scripts/test/run-all.sh`, before Step 1
edits it; every item after that needs the finished runner. Once Step 1 lands, the
pre-fix run can no longer be produced here, so it is never left for later.

1. **The focused proof (R1, R3, R5, R6, R9).** Two runs of the same command, in this
   order.
   **First, before the runner is edited (Step 0).**
   `bash scripts/test/run-all-sharding.check.sh` against today's unchanged runner
   prints `error: run-all.sh does not implement --shard/--list yet` to stderr, exits
   `2` in under a second, and its output contains no `==> ` header — that last part is
   what shows no suite ran. That failing run is what proves the script tests
   something, so record the line, the status and the timing before touching
   `scripts/test/run-all.sh`.
   **Then, after Step 1.** The same command → one line per assertion, final line
   `sharding proof: all checks passed`, exit `0`, a few seconds.
   Both go in the PR body, the recorded refusal beside the green run.
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
12. **The full no-argument run, bound to the final head (R2).** Required, and it
    happens once: on the implementation PR's first CI run, under the unchanged
    workflow, with the operator's commit not yet pushed (Step 5). Expect the old
    single `ci` job green, its log showing 62 `==> ` headers and ending
    `all 62 test scripts passed`. Record the run's URL, the commit it ran on (`H0`),
    the `ci` job's status and its wall-clock time in the PR body. It cannot be re-run
    at the final head, because the final head is sharded, so also record there the
    real output of `git rev-parse H0:scripts/test` and
    `git rev-parse HF:scripts/test`. The two tree ids must be identical — that is what
    makes the earlier run current proof of the shipping tree instead of old proof on a
    new commit. If they differ, the run is redone at the new head before review: the
    revert-and-re-apply of Step 6, or the operator runs
    `bash scripts/test/run-all.sh` with no arguments locally at the final head and
    pastes the 62 headers and the count line, naming that commit. Step 6 does not
    start until the run and `H0` are in the PR body; if the recording was missed
    entirely, the only recovery is that same expensive path, described in Step 6.
13. **The gate keeps its name and meaning (R11, R14).** On the PR after Step 6, the
    check list reads `ci`, `checks`, and `test (1)` through `test (6)`; `ci` is green
    and is still the one required check. The operator records that run's wall-clock
    duration in the PR body; target under 25 minutes.
14. **A failing shard turns `ci` red — on this PR, then removed again (R11).** This
    needs the new workflow, so it cannot be done before Step 6. It needs a PR run:
    `ci.yml` runs on `pull_request` and on `push` to `main` only, so a push to any
    other branch starts nothing — which is why the spec's "scratch branch" wording is
    corrected here (Deviations from the spec). So the coder pushes one commit to the
    implementation branch adding `scripts/test/zz-red.test.sh`
    (`#!/usr/bin/env bash`, then `exit 1`) — it sorts last, so it lands in shard 3.
    Expect `test (3)` red, the other five shards green (`fail-fast: false`), `checks`
    green, and `ci` **red, not skipped**. Record that run's URL, the commit it ran on
    (`HR`) and its job list (`gh pr checks` output) in the PR body, then push a second
    commit deleting the file and wait for green — a plain commit, never an amend or a
    force-push. `HR` is superseded before merge, so bind it: at the final head also
    record the real output of `git rev-parse HR:.github/workflows/ci.yml` and
    `git rev-parse HF:.github/workflows/ci.yml`. Identical blob ids mean the gate that
    went red is byte-for-byte the gate that ships; if the workflow changed after `HR`,
    redo the add-then-delete pair on top of it. The squash merge keeps both commits
    off `main`, and the `merge-ready` decision is made at the final green head, where
    review checks both identity pairs — item 12's tree ids and these blob ids. Step 6
    has the full procedure. This is the direct proof of the first risk above.
