---
intent-blob: 23634448860b28b6bd2f3d6bc0af524b7298c6fd
risk: routine
drafted: 2026-09-17
---

# Spec: Suppress maintenance in private profile-history fetches

Tracks #351. Review size: standard.

## Requirements

1. Every normal `history_fetch` call in the alternative and default profile
   assembly suites disables post-fetch automatic maintenance, starting with the
   first fetch into each disposable history repository.
2. Preserve each helper's isolated environment, private HOME, system-config
   suppression, disabled credential helpers/prompts, HTTP-extraheader forwarding
   and origin validation. Preserve exact commits/refspecs, depth 1, no tags, all
   object/history/config assertions and ordinary fetch failure propagation.
3. Each suite contains a small regression check that calls its actual helper,
   observes completed real fetches and rejects automatic-maintenance dispatch.
   A bounded negative control proves the observer detects enabled maintenance;
   missing, empty or malformed evidence fails. Removing suppression must fail
   the positive control without requiring the historical race to occur.
4. Regression instrumentation handles only synthetic local repositories and
   credential-free configuration. It never traces the real origin fetches,
   copies their headers into a fixture or prints credentials.
5. Both affected suites pass on native Darwin and required Linux CI. Preserve all
   original assertions and required checks, including pinned ShellCheck 0.11.0.
   Retain complete raw results tied to the exact implementation head/base.

The observed failure was `fatal: shallow file has changed since we read it`, exit
128, before the alternative suite's first success marker in run 35274748416
attempt 1. Source inspection identifies an unnecessary maintenance writer that
can overlap a later fetch. It does not identify the historical writer or fetch
ordinal, reproduce the race, or prove a failure in the default suite. The repair
removes that concrete writer path; its proof must not make those stronger claims.

## Design

### Paths and fetch behavior

Implementation changes only `scripts/test/alternative-profile-assembly.test.sh`
and `scripts/test/default-profile-assembly.test.sh`. Keep their existing private
helpers and add the regression checks within the same files. This artifact chain
uses `work/profile-history-fetch-maintenance/`; no shared helper is introduced.

Add the unconditional fetch option `--no-auto-gc` to each existing `history_fetch`
command. Do not set repository-wide or workflow-wide maintenance policy. The
normal real-origin call sites remain exact pinned refspecs with no option override.
The option prevents dispatch; lowering a maintenance threshold or merely waiting
for housekeeping would not satisfy this design.

This spelling is documented in [Git 2.28 fetch](https://git-scm.com/docs/git-fetch/2.28.0).
[Git 2.29](https://git-scm.com/docs/git-fetch/2.29.0) documents it as a synonym
of `--no-auto-maintenance`. The reviewed native versions are Apple Git 2.54.0
and Linux Git 2.55.0. Record actual versions during proof. These observations and
older documentation support the choice; they neither declare Git 2.28 a project
minimum nor claim execution on every older release.

### Actual-helper regression

Run the control block after the helper is defined and before its first normal
origin fetch. Use a subshell so fixture variables and configuration cannot alter
the following real fetches. Call the already-defined `history_fetch` directly;
do not copy its command into an alternate wrapper or substitute a fake Git.

Inside existing test scratch, create a tiny local origin with two commits and a
tag at its tip, an empty bare receiver and a separate empty fixture HOME. Use
fixed dummy author data and isolated Git configuration for fixture creation.
Override `history_repo`, `history_home` and `origin_url` only in the subshell;
use the local origin's file URL, not the checkout origin. Empty `fetch_config`
and set its count to zero before any traced helper call. This exercises the fetch
helper, not the normal remote-origin validator; leave that validator unchanged.

Enable Trace2 JSON only in this fixture HOME's global config, using an absolute
private trace-file destination. The helper's existing HOME isolation then exposes
that configuration without adding a trace environment option to the real path.
Trace2 reads global configuration, not repository-local or `-c` configuration.
Keep config/environment-value tracing unset; do not enable shell xtrace, HTTP or
packet tracing. [Git Trace2 configuration](https://git-scm.com/docs/git-config#Documentation/git-config.txt-trace2eventTarget)
documents the destination and scope. Create/reset trace files outside each measured
call, and configure the fixture before measuring, so records cannot be confused
with fixture setup or an earlier fetch.

In fixture configuration only, set `maintenance.auto=true`,
`maintenance.autoDetach=false` and `gc.autoDetach=false`. Use the same settings
for positive and negative cases. Enabled maintenance makes option removal visible;
foreground maintenance keeps the negative control self-contained. Do not force
repacking or wait for an object-count threshold: the observed event is dispatch
of automatic maintenance, whether or not it decides any work is due.

Use these bounded cases in each suite:

| Case | Required result |
| --- | --- |
| First fetch | Actual helper fetches the local tip by exact commit into the empty receiver. Exit 0; exact commit, one-commit history and no tags; complete nonempty fetch trace with no maintenance/gc dispatch. |
| Successive fetch | Same helper and receiver fetch the tip into a second fixed ref. Require the same outcome in a fresh trace, proving the check is not limited to initialization. |
| Enabled-maintenance control | Fresh bare receiver and fresh trace, same actual helper, with test-only `--auto-gc` supplied through its existing argument list after the unconditional disabling option. Require successful fetch and an observed automatic-maintenance child with matching successful completion. The same absence predicate used by the positive cases must reject this trace. |
| Fetch error | Normal helper options with a fixed nonexistent local ref. Capture nonzero status explicitly under `set -e`; require one failed fetch in its nonempty trace and no created destination ref. No retry, fallback or success conversion. |

Git's fetch parser handles both maintenance spellings as the same Boolean; the
later enabling option in the negative control overrides the earlier disabling
one. Verify that behavior through the required observed child, not from argv
alone. This override exists only in the synthetic control call. The ordinary
helper body and normal call arguments have no test-mode branch.
[Git 2.55 fetch source](https://raw.githubusercontent.com/git/git/v2.55.0/builtin/fetch.c)
binds the option and dispatch behavior.

Parse complete JSON events with the suite's existing jq. Identify the top-level
fetch session, its start/command identity, expected fixture destination/refspec
and matching terminal exit. Match automatic maintenance by child command tokens
(`maintenance run --auto` or `gc --auto`), not a loose substring anywhere in a log.
The negative case must include the corresponding child completion in the same
parent session and child ID; no background-ready event counts as completion.
Reject empty/truncated JSON, absent fetch evidence, contradictory exit status or
an unknown record shape needed for these assertions. Other valid event types may
be ignored. [Trace2 event contracts](https://git-scm.com/docs/api-trace2) define
the command and child event fields.

Only fixture-generated paths and data enter these traces. Parse them before the
existing scratch cleanup. Emit a bounded proof record per case with its fixed name,
trace event/fetch counts, actual exit, maintenance dispatch/completion counts,
absence-predicate result and exact-history assertion results. Do not dump argv or
configuration. Retain complete run output for review; raw trace files stay private
and need not survive successful cleanup. The plan must name these proof records
and their capture command, so deleted scratch is not cited as retained evidence.
Keep these cases finite and small: one tiny origin, the named calls and fresh
receivers as specified, with no sleeps, repeated attempts or timing acceptance.
This is ordinary test-local use of Git's documented command and tracing features,
not an exceptional product implementation or a reusable maintenance framework.

### Acceptance and stage order

G2 accepts this design and routine risk before planning. The implementation branch
must begin with `plan.md` only and obtain independent exact-head/base plan acceptance
before code. Its author cannot supply that acceptance. Target the normal review
budget of about 300–400 net lines; do not compress checks or expand scope to fit.
An unexpected size or compatibility problem pauses for the appropriate artifact
review instead of silently weakening this design.

Prove both suites on the actual native Git/Bash environment and obtain all required
original Linux CI jobs on the final head/base. Preserve the existing history and
profile assertions and compare the full changed-path list. Independent review
reads source and complete raw positive, negative and failure evidence. The plan
selects exact commands and evidence records; a passing rerun alone is insufficient.

## Out of scope

No product, workflow, source/profile pin, runtime configuration, credential or
network-authority change. No new dependency, shared framework, retry, sleep,
ignored error, lock deletion, full-history fetch or real target execution.
No installation, activation, release or deployment.

Preserve PR #350 at `e958333f37d41638ac4190cc21369e2406c97bba` and its original
red run. Its plan-content acceptance is separate from CI. After repair, the same
branch needs a permitted base update and fresh exact-tuple review/CI without
history rewriting. Preserve PR #346, its original receiver failure, the candidate
plan attempt, frozen #183 and dirty #271; this repair changes none of their gates.

## Areas of concern

Risk is routine because this is a small test-local invocation correction and
bounded regression proof. Authentication, isolation and security controls remain
unchanged; no constitution, workflow or broad architecture path is touched. It
supports the north star's reliable portable proof without changing product policy.
No conflict with the accepted intent or current repository rules was found.

Trace support and event details require native proof; unsupported or ambiguous
evidence fails rather than being skipped. The local controls prove the actual
helper's maintenance behavior and detector sensitivity, not remote authentication
or the historical race. The unchanged real-origin suites retain that existing
integration evidence. Git option spelling and the regression mechanism settle
the intent's open questions; exact plan acceptance and runtime proof remain ahead.
