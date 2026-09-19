---
spec-blob: d088f283c4ac03a5d6a8c8dd505a02179ea551ef
drafted: 2026-09-14
---

# Plan: resolver-trusted-parent

Tracks #271. The accepted spec is the complete contract, including the retained
R1 and R10 detail. This plan selects the files, construction order and proof; it
does not replace that detail with a smaller acceptance set.

At base `60e6da427c1d536cf68ef763b1920616b52bd65f`, the accepted spec records
`risk: high` and its intent link equals
`bc6e669b755bae6c7f52f10f047c602faa46210a`. Gate mode is `artifact-high`.
This plan-only PR requires independent review, required CI and accepted publication
under AGENTS.md's current operator-led Roadmap program.
Record the fetched merge-containing default as `plan-base`; before first code,
follow AGENTS.md's exact-base refresh/reaffirmation rule if default moved.
The implementation branch is `ystack/impl/resolver-trusted-parent`; code starts
only after that gate and the manager's verified build claim. The plan author
neither implements nor accepts this plan. Implementation uses `Closes #271`.
The existing implementation attempt remains paused. After this amendment is
accepted, the manager must reconcile its exact preserved head and dirty test draft,
merge the accepted main normally and verify the refreshed tuple before authorizing
resumption. This plan amendment does not discard WIP or itself authorize resume.

## Files that change

Exactly eight implementation paths; the plan itself changes only in its plan PR.

| Path | Work | Changed lines |
| --- | --- | ---: |
| `resolver/v1/trusted-launch.c` | New parent, source pins, checks and supervisor | 1988 measured |
| `resolver/v1/resolve-profile.sh` | New public entry, git mode 100755 | 400 measured |
| `scripts/test/resolver-trusted-launch.test.sh` | Complete R10 suite, executable | 2880 measured |
| `scripts/test/portable-core-schema.test.sh` | Add exactly the two new generation consumers | 2 measured |
| `docs/components.md` | Resolver launch, boundary and proof documentation | 66 measured |
| `README.md` | Resolver index row | 1 measured |
| `RESTORE.md` | Resolver restoration and proof | 28 measured |
| `ci/required-files.txt` | Append both shipped files and focused test | 5 measured |

All eight figures are measured at implementation head
`e96804fdaf7417d9a88a10bb6c7555a9eca18fe1` on
`ystack/impl/resolver-trusted-parent`: `git diff --numstat
origin/main...origin/ystack/impl/resolver-trusted-parent` reports 8 files,
5367 insertions and 3 deletions, **5370 changed lines**, of which the three
implementation files are 5268 insertions (1988 / 400 / 2880).

`review_size: accepted-exception`, **4600-6300 changed lines**, for this one
implementation concern. This band supersedes the one carried by the spec's
record (blob `d088f283c4ac03a5d6a8c8dd505a02179ea551ef`) and is the only
range this implementation is measured against. It brackets the measured
5370 with an outward margin of roughly a sixth for the work still open.

The 702-line existing launcher supplies about 605 of the parent's lines; existing
test fixtures are reuse, not permission to omit cases. Choose the specified
platform SHA tools; do not add a C digest implementation. Measure additions,
deletions and net separately at final head. No compressed code, reduced tests or
component/test split to meet the band. An unexplained overrun returns to the
artifact gate before more code; above the top of the band, stop and re-decide
rather than continue.
The spec's separate 8521-11529 artifact range does not apply to this plan or code.

Do not change the resolver runtime, library, jq program, native helper, core files,
profiles, existing test launcher or fixtures, shadow components, workflows or any
accepted intent/spec/plan during implementation. Shipped files never read the test
path. The schema test changes only its two exact consumer-list additions below.
The new test may use existing fixture helpers and create temporary drivers.

## Order of work

### 1. Establish the complete test contract before behavior

Provision pinned jq using `scripts/test/shadow-slice.test.sh:24-51`, as R10 requires.
Reuse temporary cleanup and result-helper patterns from
`scripts/test/portable-profile-resolution.test.sh:23-34,521-531`, its launcher source and
loader-trap source; fixture helpers serve auxiliary cases.
The positive request names real committed `profiles/default/v1` profile/manifest
objects with this repository mapped, as R10 requires, not a synthetic profile.
Provision dependencies outside the shipped entry; neither shipped file downloads.
For historical profile objects, first use already available exact objects. If the
checkout lacks them, the test may anonymously fetch the exact required committed
object history from the public ystack repository into a fresh disposable repository.
Use a clean environment and disposable HOME; disable system/global configuration,
credential helpers, prompts and hooks, and do not copy checkout-local configuration
or read its authentication headers. Use only the fixed public HTTPS repository URL,
with no embedded credentials or inherited extra headers. Do not inspect origin
configuration, SSH agents or token variables. Never place fetched objects, refs or
configuration into the source checkout. Both launch paths resolve the same complete
physical disposable graph of this repository's real committed objects. Verify the requested OIDs
and their required object closure before constructing the authentic repository map.
A failed acquisition fails the test; it never skips the real-profile assertion or
substitutes synthetic refs. This is test provisioning, not shipped network behavior.
Keep every fixture and hostile-input probe in disposable scratch, never a real target.

Write the full case inventory from R10, preserving its three refusal/observation
groups, signal cases, mechanism checks and platform-specific proof. Assert the public
entry is executable and the runtime remains 0644. Record an initial failing run
against absent behavior, then develop cases and behavior without disabling failures.
Use R10's actual sample/lifetime bounds; no arbitrary sleeps or success-on-missed-window
substitute for its required observations. The test will be discovered by
`scripts/test/run-all.sh` because its name ends in `.test.sh`.

### 2. Copy the parent baseline and make each accepted deviation explicit

Use `scripts/test/portable-profile-resolution-launcher.c` at the accepted base,
blob `f4de7e48c688b6adb3669f69a221d2aa7bf43b15`. Copy the includes/shims/constants
(lines 1-43), helpers (45-174), process-group readers (176-386), limits (388-398),
supervisor (400-532), and the non-test launch/environment portions of main
(534-702). Remove test modes 547-631, both test variables 686-689, the sandbox
`getenv` selection, and the missing-helper test action. Keep copied blocks under
short copied-from headers naming source path and commit. Preserve the host readers
and limits byte-for-byte. Record exact extracted spans and diffs in final proof.

These ten deviation groups are exhaustive. Mark each changed boundary with a
short provenance/invariant comment referencing the accepted spec requirement;
do not paste review history or explanatory essays into code.

1. Runtime admission adds regular absolute non-symlink and exact mode-0644 checks
   (R5), preserving `E_USAGE` for malformed invocation and `E_RUNTIME` for bindings.
2. Close inherited descriptors above 2 at startup and again in the resolver child
   (R3/R5). Startup enumerates `/dev/fd`, skipping only 0/1/2 and its own `dirfd`;
   enumeration failure refuses. Then sweep to finite hard `RLIMIT_NOFILE`, otherwise
   `_SC_OPEN_MAX`, capped at 65536. Never use the caller's soft limit as ceiling.
3. Add output/run/helper/binary/jq/awk checks and exact directory inventories (R5).
4. Pin the eight loaded files and copy the library's generation/major constants (R5).
5. Add absolute regular non-symlink request and map checks (R5).
6. Add the complete R2 signal ownership, masking, handlers and termination logic.
7. Move all four sandbox creations and all supervisor reads to checked descriptors
   (R5): `supervise` takes the output descriptor; stdout/stderr use `O_RDWR`;
   emptiness uses `fstat`; stream/sanitizer take descriptors and rewind with `lseek`.
   Do not reopen captured output by name or close its descriptor before consuming it.
8. Compute Git blob ids from `fstat` size plus bytes through platform SHA-1 children;
   add SHA-256 and jq-version children, all with explicit fixed `execve` environments
   (R1/R7). No git, `environ`, `execv`, `execvp` or `execlp` in the shipped parent.
9. Add the R2 informational `runtime-pgid:` diagnostic after fork publication.
10. Set `umask(077)` in main before checks and creation (R5).

Use the internal parent argument positions derived from the copied launch: `resolve`,
runtime, helper, bound jq, request, map, followed by output and run directory.
This is a test-driven internal call shape, not a newly supported public interface.
The resolver child still receives exactly `/bin/bash`, runtime, `resolve`, request,
map; never introduce runtime arguments, test variables or an identity marker.

### 3. Finish parent checks before allowing resolver execution

Apply R5's order: output path-length guard; opened output owner/mode/listing and
`.run` identity; remaining run/helper/binary/tool checks and exact inventory; pins
and jq identity checks; only then sandbox creation and resolver launch. All checks
that the spec requires before any fork remain before the first digest child too.

Open output and run directories with the prescribed directory/no-follow flags.
Reject `.run` via `fstatat(..., AT_SYMLINK_NOFOLLOW)` unless it is a directory, then
compare `st_dev` and `st_ino` on separately opened descriptors. List using
`fdopendir(dup(fd))`, keeping the original descriptors alive. Helper and compiled
parent are regular caller-owned 0500 files; run directory is caller-owned 0500.
Require exactly `trusted-launch`, the distinct helper basename, `jq`, `awk`.
Reject missing names, extra files/directories, collisions and listing errors.

For jq, retain both file identity and containing-directory identity against checked
`run_fd`, and require basename `jq`; inode equality alone admits an external hardlink
and the wrong runtime tool-root string. Check the platform digest and `jq-1.6` too.
For Linux awk, compare complete bytes against trusted `/usr/bin/awk`, following its
platform symlinks and requiring the opened object regular. Caller `.run/awk` keeps
no-follow checks. Darwin compares the exact 35-byte two-line shim constant.

The eight pins are `resolver/v1/profile-resolve-runtime.sh`,
`scripts/lib/profile-resolution.sh`, `resolver/v1/profile-resolution.jq`, and
`schema.jq`, `profile_graph.jq`, `stage_request.jq`, `result_facts.jq`,
`result_truth.jq` under `core/v2/generations/` plus the pinned generation's `modules/`.
Take the exact `PORTABLE_CORE_GENERATION` selected by the accepted, pinned
`scripts/core-contract.sh`, equal to the accepted library's
`PROFILE_RESOLUTION_CORE_GENERATION`, and schema major `2` from its
`PROFILE_RESOLUTION_SCHEMA_MAJOR`. Copy ordinary generation constants into both
parent and entry, and the schema-major constant into the parent. Do not encode or
assemble the generation to evade the source inventory, or add an unused entry
schema-major constant. Do not read untrusted library text at runtime to discover
a module path. The library's existing four wrapper/registry/ingress/contracts pins remain its own, justified
by its outer pin.

Create `home`, `tmp`, `child.stdout`, `child.stderr` relative to checked output fd;
use exclusive creation and retain descriptors through classification and streaming.
Build only R3's eight environment entries, plus `MallocNanoZone=0` on Darwin.
No caller variable reaches any child. Pre-resolver children get only
`PATH=/usr/bin:/bin` and `LC_ALL=C`; the resolver additionally gets its sandbox HOME,
TMPDIR, bound tool path, trusted/helper/jq names and `GIT_TERMINAL_PROMPT=0`.
Keep CPU/wall 300 seconds, process count 32, file 67108864 bytes, nofile 64,
non-Darwin address space 536870912 and Darwin private-memory poll unchanged.

### 4. Implement signal ownership as its own reviewable block

Install INT/TERM/HUP handlers among main's first statements, each masking all three,
without `SA_RESTART` or `SA_SIGINFO`; ignore SIGPIPE. Shared state is only
`volatile sig_atomic_t pgid` and `pre_child`, initialized zero.

Every one of eleven forks (eight blob tools, SHA-256, version probe, resolver) uses
block → fork → publish owned pid → restore. Resolver adds parent-side `setpgid`
before publishing. Child resets INT/TERM/HUP and SIGPIPE to default while blocked,
then restores the saved mask before execution. This prevents an inherited handler
running inside the child and prevents a blocked signal surviving into the runtime.

Every tracked reap is masked through clearing its id. Resolver normal/limit cleanup
keeps the block across survivor check and required kills; clear pgid last and restore
only then. The ordinary limit/memory/time polling stays outside that block.
Preserve EINTR retries where the copied code requires them. An already-reaped
pre-child is never killed again. Retain the copied supervisor's stated pid-reuse
residual; do not invent a replacement supervisor inside this concern.

Handlers choose group, pre-child or neither, never `kill(0, ...)` or `kill(-0, ...)`.
Use the specified twenty `waitpid(WNOHANG)` / 50 ms `select` iterations after TERM.
Group KILL is unconditional even when its leader was reaped; single-pid KILL/reap
occurs only if the bounded wait did not reap it. Stopped members therefore die too.
Kill/reap before diagnostics and `_exit(128 + signal)`.

Use the R2 static signal-name table and decimal conversion for handler messages;
no `snprintf`, allocation, stdio, `strerror`, `nanosleep` or `usleep` in handlers.
Check every transitive helper call against POSIX.1-2017's async-signal-safe list.
Diagnostics use one nonblocking write, ignore short/EAGAIN/EPIPE, restore the saved
stderr flags unconditionally. The ordinary runtime-pgid toggle gets its own short
three-signal block after fork-publication restore; no blocking diagnostic belongs
inside a masked region. Neither shipped file reads diagnostics back as control input.

### 5. Build the entry around the complete R1 lifecycle

Public arguments are `<jq> <output> <request> <map>`, with no subcommand.
Supported forms are executable `#!/bin/bash -p` entry and
`env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p <entry> ...`.
Clean non-privileged invocation exits 78 before work. Polluted non-privileged
invocation is outside the safety claim; do not promise its refusal defeats pollution.

Preserve these eight adaptation groups from the spec's Copy versus adapt section:
0500 files; fixed platform compiler; computed blob pins without git; fixed `.run`
lifecycle; explicit empty environments; output prechecks; stat's two permitted jobs;
materializer scrub/re-exec with the named entry-specific changes below.

The first operations are privileged-mode check, `umask 077`, builtin nofile ladder
1024 → 256 → 64 (refuse if all fail), and no-exception `/dev/fd/*` close loop.
Refuse unmatched literal glob before basename stripping; close bash's own script fd
as well. Close only numeric descriptors, skip exactly 0/1/2, and suppress eval
errors with `2>/dev/null`; do not quote exec into an ordinary command. Do not fork for headroom or skip a descriptor merely because it names the
entry. Capture absolute script_path using shell-validated PWD before the scrub,
then `builtin export -n script_path`. Preserve it across the copied export scrub.
Copy materializer lines 4-13 verbatim; no external command precedes `/usr/bin/env`.

Dispatch four arguments to re-exec with `__resolve_profile_clean` and five arguments
whose first word is that marker to the clean path; otherwise E_USAGE. Keep `-p` on
re-exec, repeat scrub and alias reset in marker branch, and never make the marker a
supported public entry. Validate repository/platform and output before any creation:
absolute physical caller-owned empty 0700 directory, no symlink component, and the
R1 PATH_MAX reserve for `.run/tmp/` plus NAME_MAX. Use platform stat formats and
builtin glob emptiness, not find or mktemp.

Initialize all names read by traps/checkpoints before arming traps; assign run from
validated output. Signal traps are exactly `: "${entry_signal:=NAME}"; wait_interrupted=1`.
EXIT captures status first, ignores INT/TERM/HUP second, restores/removes owned .run,
prints entry-signal only for `[ -f /dev/fd/2 ]`, then selects the prescribed status.
Create .run by plain mkdir, derive run_created from captured status including the
specified signalled-mkdir case. Every pre-parent external command/substitution is
status capture → checkpoint → refusal, never immediate `cmd || refuse`.

Create compiler home/tmp under .run; perform ten source blob pins, jq digest/version
checks and both compiles under the exact R1 cleared environment. Pin the finished
C parent's source after its implementation stabilizes; update entry's constant after
any later parent edit. Entry pins parent/helper C plus the eight parent-pinned files.
Use fixed Linux `/usr/bin/cc`, Darwin CLT clang and explicit SDK; no CC override or
xcrun fallback. Flags are `-std=c11 -O2 -Wall -Wextra -Werror -pedantic` plus specified
pipe/SDK options. SHA tools are platform fixed paths; parse digest in shell/C, not awk.
Copy jq and Linux awk or write Darwin shim; remove compiler home/tmp, chmod four
files then directory to 0500, launch parent as child under only PATH and LC_ALL.

The wait loop follows R1 exactly: clear interruption flag, forward the first recorded
signal at most once only if jobs lists parent Running, wait, accept uninterrupted
status, otherwise consult jobs and either loop or use the extra-wait status fallback.
Set last_forwarded even when forwarding is skipped, so it cannot be retried later.
Pass child stdout/stderr through unchanged. Do not poll pid liveness with kill -0.
Preserve real status 7/42 in simultaneous-exit
cases; no fixed two-wait replacement. Never remove .run before the parent is reaped.
Use the R1 final status fallback only in the specified both-127 unreachable case.

### 6. Complete R10 and documentation before collecting final proof

Implement every R10 runtime case and every R10 explicitly required source/mechanism
check; the focused test inventory is the coverage ledger, with clear names and one
pass/fail result per case. Record review-only items separately; they do not count as
runtime coverage. Preserve the accepted observational boundaries and retry budgets.
No test-only override enters shipped files to make a difficult timing case easier.
The ledger must explicitly cover:

- Entry-owned digest/source/module pins and all five validate-before-write output
  refusals; parent-source tampering also checks named refusal, no observed compiler
  output, untouched helper source and final empty output. Preserve sampling limits.
- Direct-parent owned refusals for every loaded pin, runtime mode, jq version/digest
  and directory identity, awk type/mode/content, request/map paths, overlong output,
  helper/binary mode/location, exact run names and output ownership/mode/listing.
  Include the separate library generation-constant edit, both rogue-awk positive
  controls for copied and hardlinked jq, all four request/map path cases, and every
  exact-name/decoy run case. Aim the reachable output-length fixture strictly between
  PATH_MAX-16 and PATH_MAX with a short independent run path. Use R10's test-only
  fstat interposition for matching output dev/ino ownership, with a reached assertion
  and real-uid control; no shipped hook. Require no runtime-pgid and no side effects.
- Runtime-owned malformed request; explicit-env/no-copy comparisons and polluted
  helper inputs with negative control; the privileged clean-marker invocation with
  exported pwd/cd/find and BASH_ENV pollution must succeed without markers, while
  a clean nonprivileged marker invocation exits 78 without writes; relative entry; both
  supported invocation forms; compiler pollution and direct binary comparisons.
  Keep both controlled compiler outputs digest-identical; no nondeterminism relaxation
  is selected. Preserve Linux loader-marker allowance only for the initial process
  and Darwin's allowed zero; helper/runtime markers fail. Check exact Linux runtime
  environment and R10's Darwin alternative.
- All four cleanup outcomes, entry umasks 000 and 777, direct-parent umask 000
  proving its own reset, and observed temporary/final modes under R10's bounded
  observation attempts. Observe .run, .run/tmp and .run/home at 0700, all four run
  files and .run at 0500, and final sandbox directories/capture files at 0700/0600.
  Cover all eight descriptor scenarios:
  six entry cases and two parent cases, including exhausted headroom and high
  descriptors above a lowered soft limit. Preserve R10's distinction between
  observed behavior and source-order proof.
- All six signal cases and the specified stalled-stderr variant. Freeze the resolver
  from the observed diagnostic, assert group death and parent-before-cleanup order,
  first-signal status/one diagnostic, pre-parent cleanup and foreground-group safety.
  The direct-parent pre-resolver case has twenty attempts total shared by late-stop
  and early-signal outcomes, logs both counts, and requires one proving attempt;
  neither timing miss is a pass. Preserve 100 ms gaps in the three-signal sequence,
  the shared-group sentinel with asserted PGID equality, and the duplicate stderr
  open-description check that O_NONBLOCK was restored. The full-pipe case uses R10's blocking filler,
  survival observation and descriptor-mode assertion, not an O_NONBLOCK substitute.
- Eighteen three-way blob checks (computed digest, Git answer, constant), three
  non-blob constant checks: parent generation, parent schema major and entry
  generation. Include all named source/mechanism checks and native Darwin write
  attribution. Root-owned output's root-run skip is only the explicit R10
  ownership exception, printed as such; missing timing/platform proof is not a pass.

Before fixing signal-case timeouts, measure one complete compile on each proof
platform and set a finite timeout above that observed duration with a stated margin;
record the measurement and chosen bound. A timeout fails. Re-run R1's interrupted
wait measurement for sixty attempts on the CI image's bash, recording which status
rung each attempt used, including preserved exits 7 and 42. R10's live signal cases do not reach
the second-wait coincidence window; do not claim that they do. Re-run R1's
signalled-mkdir guard design measurement on the CI image's bash too, recording both
successful creation with interrupted status and ordinary failed creation outcomes.

The three command sweeps use R10's fifteen absolute command words and exact data
tokens, including only `/dev/fd`, `/dev/fd/*`, `/dev/fd/2` for that family. Preserve
awk's data-position checks and external-printf ordering below the env re-exec.
Derive builtin/reserved names from `/bin/bash`; shell local functions are exactly
`checkpoint` and `refuse`, each defined once before calls and scanned themselves.
Fix the command-variable names as `compiler`, `sha1_tool`, `sha256_tool`, `jq_bin`,
`parent_bin`, assigned by platform/arguments/owned run path; no default expansion
or other command variable is permitted. Review their values separately.

Treat `/dev/null` only as the exact temporary `2>/dev/null` target on R1's three
`ulimit -S -n` ladder rungs, descriptor-close eval, both prescribed unset forms
in every required scrub including the marker branch, and the unique signal
forwarding kill in the job-table Running arm above wait. Check those source roles
and positions, not only an occurrence count. Reject every other command/descriptor,
input or append redirection, variable sink, prefix path, C pathname or execve
argument using that target. It is neither an executable nor a general data member.
Keep the redirect outside eval's quoted exec; persistent stderr suppression remains
forbidden. Existing refusals and diagnostics must not be newly suppressed.

Implement small inspectable lexical/role extraction for all three passes:

- Classify only the required self-path `/*)` case pattern as a non-path pattern;
  still inspect its arm's commands. Keep both actual `/dev/fd/*` roles inventoried.
- Distinguish C slash characters, division and comments from pathname strings;
  a C root string used as a path remains forbidden, and /proc strings remain checked.
- Inspect absolute values inside quoted arguments and shell/C assignments, including
  the exact PATH value. Never exempt a whole assignment to hide an absolute value.
- Do not manufacture host paths from dynamic joins, parameter patterns or `%s/home`,
  `%s/child.stdout` and `%s:/usr/bin:/bin` suffixes. Preserve dynamic value review.
- Classify the fixed Darwin shim as written/verified data under the existing awk
  position checks. Inspect executable trap/eval strings and commands within command
  and process substitutions, including jobs, kill and compgen. Quoting is no exemption.
- Extract command positions rather than case patterns, for-list data, function
  declarations or redirection operands. Keep commands behind exec/env and assignment
  substitutions visible, plus the existing function and variable restrictions.

No full parser or linter AST supplies this invariant. Review extraction coverage
against the actual shipped source shapes; a broad quoted-token skip is forbidden.

In the same implementation PR, add exactly `resolver/v1/resolve-profile.sh` and
`resolver/v1/trusted-launch.c` to the closed expected generation-hit list in
`scripts/test/portable-core-schema.test.sh`. Preserve every existing entry, the
sorted exact comparison and the indexed tracked-byte scan. No wildcard, generation
change or other schema-test change is permitted. Stage the complete implementation
before running this test so its indexed-byte proof includes both new consumers.

Update docs at the existing resolver sections, not new conflicting instructions.
State both supported forms, 100755 entry, direct-parent test-only boundary, CLT
prerequisite, build-every-time distribution, caller-provisioned jq, informational
stderr and exit-status meaning. Preserve the loader, same-uid, compiler, signal and
Darwin residuals below. Say the accepted old resolver spec's production-parent
absence is superseded here; do not edit that historical artifact. This change does
not regenerate `/yshifu`, activate a profile or execute the self-host run.
Append exactly the three new restore-critical paths to the manifest.

## Risks

The highest-risk new code is signal ownership: a late cleanup can leave a resolver
alive; an early cleanup removes its dependencies; a stale pid can kill a stranger.
Review fork publication, reap/clear ordering, blocked sibling signals, stopped-group
KILL, EINTR handling and shell wait-status preservation together, not as isolated helpers.
A diagnostic must be incapable of blocking, and where the language cannot make it
so, it is not written. Compile-time signals are acted on at the next checkpoint;
cleanup can be one foreground compile late. Pre-resolver waits lack the resolver's
limits, so a hung trusted tool can delay a masked signal; do not claim a broader bound.

The parent must be started by a trusted process — the supported entry. For the
Roadmap step-7 self-host run the operator's trusted shell starts that entry, which starts the parent.
Direct-parent invocations remain test-only. The entry must itself be started by a
trusted process for the same reason, because its first process has no loader-variable
defence either. A parent, or an entry, invoked from a hostile environment has none
at all. Direct invocation is unsupported, not detected, blocked or refused as such.
Only the entry supplies compiled-helper provenance; every parent check still runs.

No hostile same-uid process is active in the caller's output root while the run is
in progress. Root is outside all of it, and so is the compiler, which is trusted
unverified. Descriptor checks prove check-time facts; helper/jq/HOME/TMPDIR remain
runtime path handoffs. Do not claim the parent binds or guarantees what the runtime
executes. Fixing that requires the separately gated descriptor-handoff follow-up.

DR-2 on #271 accepted a Darwin residual: the unchanged runtime's `/usr/bin/git`
xcrun_db write in the per-user temp directory. PR #328 removed it by selecting the
CommandLineTools git directly, so there is no residual left to accept, measure or
document. The write root is the caller's output root on both platforms, for the
runtime as well as for everything this initiative adds. Neither shipped addition may
run the shim path. Keep the accepted provenance link in the boundary documentation and
regression proof; no second workaround is added.

Copied supervisor process-table reads are host state, not repository content; they
remain byte-identical and review-only. Cleanup is best-effort on exits the entry can
observe; SIGKILL/power loss can leave .run, and the next call must refuse it. Native
Darwin proof is platform-specific; Linux CI does not prove Darwin behavior.

Rejected alternatives stay rejected: cached/committed binaries, a private caller
marker as provenance, changed resolver limits, in-C hashing, digest via git, tool
lookup via PATH/CC, diagnostic files, runtime hooks and shrinking tests to fit.

## Proof

Run against the final implementation head and freshly fetched base; publish commands,
statuses and output with full OIDs. A change after proof invalidates affected proof.

- `bash scripts/test/resolver-trusted-launch.test.sh` — complete R10 suite on Linux
  CI and native Darwin where available, with every required case present and passing.
- `bash scripts/test/portable-profile-resolution.test.sh` — unchanged resolver and
  fixture launcher regression suite; byte-identical resolved-profile stdout through
  test launcher and shipped public entry for the default request.
- `bash scripts/test/portable-core-schema.test.sh` — zero failures against the
  staged final implementation bytes. Verify the two exact consumer additions and
  unchanged existing list, indexed scan and exact comparison in the final diff.
- `shellcheck --version` must report 0.11.0; then
  `find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x -S style`.
  Keep both new shell files shellcheck-clean without weakening the lint gate.
- `bash scripts/test/v2-check-rename.test.sh`; `bash scripts/check-rename.sh`;
  `git diff --check`; required CI checks and all six
  test shards green, followed by green `ci` aggregate. New tests require no workflow edit.
- `git diff --name-only <base> HEAD` — exactly eight implementation paths above;
  `git diff --numstat <base> HEAD` — report additions/deletions/net against 4600-6300.
  `git ls-files --stage resolver/v1/resolve-profile.sh` — 100755; runtime stays 100644.
- R10 pin-liveness checks compare all eighteen source pins and all three non-blob
  constants: parent generation and entry generation equal the accepted library
  generation, and parent schema major equals its accepted library counterpart.
  No historical Git object is needed by CI's pin check.
- Run the required mechanical comparisons of copied spans and command sweeps;
  retain their results. Source review records each comparison and named deviation;
  it reads unsupported-platform and unreachable jq-length guards, host readers,
  handler-safe call inventory, masked fork/reap/diagnostic sequences and entry ordering.
  Do not label these readings as executed negative cases or sandbox qualification.
- The native Darwin R10 operator run must show no write outside the output root.
  Record exact platform/tools and the R10 observation method and its limits.
  Use `/usr/bin/getconf DARWIN_USER_TEMP_DIR` to locate the observed directory;
  record the whole directory's names/sizes/mtimes, and xcrun_db's absence or its
  size/mtime/SHA-1, before and after. Both listings must be identical, and xcrun_db
  must come back in the state it started in, absence included; the isolated
  compile/pin half must do the same. Caller HOME/TMPDIR remain unchanged. Any other
  observed change fails, including a new or modified xcrun_db, which would mean a
  shim got back into the entry's path or the runtime's. Missing platform evidence
  remains an explicit proof gap, not a pass.
