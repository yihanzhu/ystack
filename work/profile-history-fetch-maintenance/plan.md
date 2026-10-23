---
spec-blob: 3b00972d677944bdebac512a34ae85bc9c1f63a2
drafted: 2026-09-17
---

# Plan: profile-history-fetch-maintenance

Tracks #351. Risk: routine. Gate mode: `artifact-routine`.
Proposed `review_size: accepted-exception`: 450–600 total added plus removed lines
across this plan and the two named test files. Independent initial plan review
must accept this exact one-concern range before code; this proposal is not acceptance.
Intent blob: `23634448860b28b6bd2f3d6bc0af524b7298c6fd`.
Initial branch-base/current-base: `60e6da427c1d536cf68ef763b1920616b52bd65f`.

## Files that change

This initial implementation-branch history changes only
`work/profile-history-fetch-maintenance/plan.md` on
`ystack/impl/profile-history-fetch-maintenance`. The manager pushes the plan-only
head without opening a PR, directly obtains independent `initial` acceptance
with `routine_phase: plan-only`, and records the complete exact tuple before a
Sol coder starts. The plan author cannot accept its own plan. A moved default
before code follows the routine base-refresh gate; preserve this branch/history.

Code changes only `scripts/test/alternative-profile-assembly.test.sh` and
`scripts/test/default-profile-assembly.test.sh`. Accepted artifacts remain
unchanged during coding. All spec exclusions and original oracles remain binding.

## Order of work

### 1. Bind the evidence and make the minimal helper edit

Before code, verify the manager's current claim, accepted plan head/blob, both
artifact links, branch-base/current-base and clean worktree. Read the complete G2
review whose SHA-256 is
`a11eb593535b5566c7ccd11f9bdb7fc37b0a5272a34e13c6262bea8d1b6fc5b8`.
Save both original test files and ordered assertion names in private proof scratch.

Add `--no-auto-gc` unconditionally to each existing `history_fetch` fetch command,
before its origin and argument expansion. Leave the environment, private HOME,
config isolation, HTTP-extraheader array/count, credential/prompt restrictions,
origin validation, depth/no-tags and pinned call arguments unchanged. The helper
remains a direct command whose actual exit is its return status.

### 2. Add one small control block to each existing suite

Place it immediately after `history_fetch` is defined and before reading/using
the normal origin. The existing jq 1.6 runtime is already ready there. Use a plain
subshell, invoked as a normal command under `set -e`, not the condition of an
`if` or an `||` list that would disable errexit throughout its body. Use Bash 3.2
scalars/indexed arrays and existing Git/jq/shell tools only.

Inside the subshell, use a directory beneath existing `tmp`, a separate fixture
HOME, and separate source/receiver paths. Clear
`fetch_config` and set `fetch_config_count=0` before any measured invocation.
Set `history_home`, `history_repo` and file-URL `origin_url` to fixture values.
Never copy checkout origin/headers. Subshell exit restores the real-path variables.

Build one local source with two commits and a lightweight tag at its tip. Use
isolated `/usr/bin/env -i` Git calls, the fixture HOME, disabled system config,
fixed dummy author/committer data, and no hooks or inherited user settings. Use
an empty tree, two commit-tree commits and explicit refs. Record the actual tip OID.
Initialize a bare positive receiver and, later, a separate bare negative receiver.
Keep setup untraced until the fixture is complete.

Configure only fixture HOME's global config with `trace2.eventTarget` pointing
to one absolute private event file. Set `maintenance.auto=true`,
`maintenance.autoDetach=false` and `gc.autoDetach=false` in that same fixture scope.
Leave config/env-value tracing unset. No xtrace, HTTP/packet tracing or real-HOME
change. Both positive and negative cases use these foreground settings.

### 3. Measure four actual-helper calls per suite

For every case, finish all setup/configuration first, truncate the event file,
then call the existing `history_fetch` exactly once. Capture status with
`if history_fetch ...; then status=0; else status=$?; fi`. Do not use `!` and lose
the original status, or add fallback behavior to the helper. Redirect fixture
stderr to its private file; report only a fixed failure label if unexpected.
Immediately copy the completed event file to a case snapshot using a non-Git
file operation, before running Git verification commands. Parse that snapshot.
Later verification may append to the live trace; the next case truncates it after
its setup. No verification record can become part of a measured fetch snapshot.

| Case suffix | Call and acceptance |
| --- | --- |
| `first` | Empty positive receiver; fetch `+TIP:refs/ystack/control-first`. Require exit 0, exact TIP, one reachable commit and no tags. |
| `successive` | Same receiver; fetch `+TIP:refs/ystack/control-next`. Require the same results for the new ref, using a new snapshot. |
| `enabled` | Fresh negative receiver; call the same helper with `--auto-gc` and `+TIP:refs/ystack/control-enabled`. Require exit 0, exact/depth/no-tags assertions, completed automatic maintenance and rejection by the positive absence predicate. |
| `error` | Positive receiver with the normal disabling option; fetch fixed absent `+refs/heads/control-missing:refs/ystack/control-error`. Require nonzero status, exactly one failed measured fetch and no destination ref. |

TIP is the synthetic source's observed OID. The negative override uses the existing
argument list; there is no function edit or normal-path test switch. Foreground
maintenance must complete before return; no threshold, sleep, retry or race probe.

### 4. Parse complete sessions and emit bounded proof

Keep one small jq observer per suite, reused by all four cases. Slurp each private
snapshot as JSON; reject invalid/truncated input, a non-object event or an empty
array. Require exactly one `cmd_name` event naming `fetch` in the entire snapshot,
with a nonempty string session ID. Within that session require exactly one start
and one terminal `exit`; the start precedes command identity and exit. Require
well-typed argv, exact fixture receiver/file origin/refspec context, and an integer
exit code equal to the captured shell status. Another top-level fetch, missing
terminal, duplicate identity/exit or contradictory evidence fails.

Child events from transport and maintenance have distinct sessions; they do not
satisfy top-level fetch requirements. For dispatch detection, inspect the measured
fetch session's `child_start` arrays as command tokens. Recognize the fixed Git
executable prefix followed by `maintenance run` with `--auto`, or `gc` with
`--auto`. Do not grep arbitrary text. Validate necessary event fields and refuse
an unsupported command prefix/shape that would make this decision ambiguous.
Other valid event types and unrelated child commands may be ignored.

For `first` and `successive`, require zero such dispatches. For `enabled`, require
exactly one, plus exactly one subsequent `child_exit` with the same parent session
and child ID, code 0, before the fetch terminal exit. Reject duplicate terminal
events or a matching `child_ready` used in place of completion. The same Boolean
absence predicate must return false for this trace; a separate count-only success
check is insufficient. In `error`, require the captured nonzero exit and record
the maintenance counts without using absence to excuse the failed fetch.

Emit exactly one record per case, before normal scratch cleanup, using prefix
`history-fetch-proof` and IDs `alternative.first`, `alternative.successive`,
`alternative.enabled`, `alternative.error`, and the four corresponding `default`
IDs. Each record is at most 1 KiB and contains only the fixed ID, positive integer
event count, fetch count 1, actual exit, maintenance start/completion counts,
absence Boolean, and exact-commit/depth/no-tags or absent-ref assertion Booleans
(inapplicable fields are explicitly null). Emit observed results, not constants
that assume the check passed. The eight records plus complete run output are
retained evidence. Never emit argv, config, origin URLs, private paths or stderr
contents. Raw snapshots stay private and are not claimed retained after cleanup.

Failure in setup, parsing, cardinality, status or an oracle fails the suite with
a fixed case label. Keep the normal parent suite's success numbering and original
assertion labels unchanged; these records supplement them. Verify that fixture
HOME/config/arrays have no effect on the following real-origin fetches.

### 5. Check scope and obtain implementation proof

Review the two helper diffs and ordered original assertion inventory before final
runs. The built-in enabled case proves detector sensitivity on the same helper;
removing `--no-auto-gc` makes the first positive fetch dispatch maintenance under
the identical enabled fixture config and fail its absence check. Do not require
an extra remote-fetching mutation run or alter accepted source to manufacture one.

Request the size exception before initial plan acceptance and coding. The first
plan revision contains 225 added lines; the two readable fixture/observer blocks
are estimated at 240–320 added plus removed code lines, including the helper edits.
That gives 465–545 lines before this small sizing revision. The proposed 450–600
total-line range includes that revision and a modest margin for readable checks.
Required plan detail and proof exceed the normal 300–400-line signal while keeping
one concern and exactly the same three paths. This changes only the review-size
signal, not design, scope, oracles, controls, required CI or independent review.

Check the complete branch-base-to-head diff after the first control block and
again before final proof. An unexplained overrun beyond the accepted range or a
new concern pauses work for separate amendment/review. Preserve the attempt;
do not reduce proof, relax checks, compress code or edit this accepted plan.

## Risks

Empty/mixed/incomplete traces can falsely imply absence. Reset/snapshot ordering,
unique session/terminal matching and the enabled control address this. Trace2
differences fail visibly; no unsupported-platform skip or command-text-only proof.

Review separate HOME, cleared arrays, env isolation and subshell restoration before
real-origin runs. Native version proof remains required; older option documentation
does not establish a project minimum.

The historical writer/race remain unproven. Preserve PR #350 and its original red
run, PR #346's failure, candidate plan, frozen #183 and dirty #271. Their later
reconciliation is separate.

## Proof

After independent plan acceptance and implementation, record exact head/base and
versions. Run from the implementation worktree, with no source edits during proof:

```sh
/bin/bash --version
/usr/bin/git --version
git rev-parse HEAD
git diff --check 60e6da427c1d536cf68ef763b1920616b52bd65f HEAD
git diff --name-only 60e6da427c1d536cf68ef763b1920616b52bd65f HEAD
git diff --numstat 60e6da427c1d536cf68ef763b1920616b52bd65f HEAD
```

Only this plan and the two named tests may differ from branch-base. Recheck the
accepted intent/spec/plan blobs and capture actual jq 1.6 identity already verified
by the suites. Native proof uses `/bin/bash` 3.2 and `/usr/bin/git` 2.54.0 as observed;
a changed version is reported and evaluated, never silently relabeled.

Capture both complete focused runs and separate status receipts with fresh names:

```sh
profile_proof=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-history-proof.XXXXXX")
for suite in scripts/test/alternative-profile-assembly.test.sh scripts/test/default-profile-assembly.test.sh; do
  started=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
  if /bin/bash "$suite" >"$profile_proof/${suite##*/}.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  finished=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s %s exit=%s\n' "$started" "$finished" "$status" >"$profile_proof/${suite##*/}.receipt"
  [ "$status" -eq 0 ] || exit "$status"
done
```

Require all eight proof IDs exactly once across these logs, their specified actual
outcomes, every original suite assertion and both terminal successes. Hash logs,
receipts, original-oracle comparison and final diff in the manager's retained
proof manifest. Failed attempts keep their own log/receipt; no overwrite or retry
can replace failure evidence. Deleted fixture trace paths are not artifacts.

Run the unchanged checks with their full output retained:

```sh
/bin/bash scripts/check-rename.sh
/bin/bash scripts/test/run-all-sharding.check.sh
shellcheck --version
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x -S style
```

Use ShellCheck 0.11.0, with its existing official asset digest verified; no other
version supplies lint proof. Run the structure-manifest check exactly as committed
in `.github/workflows/ci.yml`. Required Linux CI must pass checks, all six original
`run-all.sh --shard N/6` jobs covering all 65 suites, and aggregate ci on the exact
final head/base. Preserve complete original job logs and the new proof records
in their corresponding shards. Do not change the workflow or narrow the runner.

The independent reviewer reads full source/diff, preserved assertions and complete
raw native/CI proof. The manager reads the complete verdict, resolves Important
findings and verifies exact head/base and every required original CI job before
protected merge. A later green result does not alter any preserved failed run.
