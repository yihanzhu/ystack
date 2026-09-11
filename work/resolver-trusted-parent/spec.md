---
intent-blob: eaa322c405502cc0ca7c453814ca0f005f11b48f
risk: high
drafted: 2026-09-09
---

# Spec: resolver-trusted-parent

Ship the parent process the resolver has always demanded, so a real profile can be
resolved outside a test run. The resolver does not change. The parent copies what
`scripts/test/portable-profile-resolution-launcher.c` already proves, adds the checks
that today live in the test script rather than in the launcher, and produces the same
bytes for the same request.

**Implementation `review_size: accepted-exception`** — this figure and the derivation
under it are the *implementation* pull request's exception, not this spec pull request's
(that one is recorded separately at the end of this section). One concern: this is a
single security-boundary component whose only honest proof runs the real resolver twice
and compares the output.

**Evidence-based range: 2066-2796 changed lines** (implementation). The derivation,
measured rather than guessed:

- **C parent ~1075 lines** = ~605 copied verbatim + ~470 new. The test launcher is 702
  lines (`wc -l scripts/test/portable-profile-resolution-launcher.c`), and what the parent
  copies is nearly all of it. Block by block: the includes, platform shims and the four
  limit constants, lines 1-43 (43 lines); the eight small helpers `set_limit` through
  `monotonic_seconds`, lines 45-174 (130), of which the error sanitiser
  `sanitized_error` alone is lines 118-165 (48); `process_group_count` in its three
  platform variants, lines 176-271 (96); the Darwin address-space block
  `darwin_private_virtual_size` and `process_group_address_space_exceeded`, lines 273-386
  (114); `apply_child_limits`, lines 388-398 (11); and the supervisor `supervise`, lines
  400-532 (133). That is the entire file above `main` — 532 lines, none of it test-only,
  all of it needed by R2, R3 and R4. From `main` (lines 534-702, 169 lines) the parent
  deletes the test-only argv modes, lines 547-631 (85), and the two test-variable lines
  686-689 (4), and replaces the five-line `YSTACK_TEST_SANDBOX` lookup (640-644); the
  remaining ~75 lines — the argv shape check, `child_argv`, and the whole environment
  construction R3 lists — are copied. New code on top of that: copied-from headers (~15),
  the output-path and run-directory arguments that replace `YSTACK_TEST_SANDBOX` (~30),
  the runtime mode-0644 and blob checks (~45), the blob checks for the other two files
  of the parent-pinned subset — `scripts/lib/profile-resolution.sh` and
  `resolver/v1/profile-resolution.jq`, sharing the runtime's blob-id helper, so ~30 for
  the repository-root derivation, two constants and two comparisons — the parent's own jq
  digest and `jq-1.6`
  checks (~40), the three `fstat` run-directory checks in R5 (~90), the caller
  output-directory check (~60 — it is no longer a plain emptiness test but an `fdopendir`
  on a `dup` of the checked descriptor and a `readdir` over it that admits the single
  `.run` entry, and then a descriptor-identity comparison against the run directory the
  parent was handed: an `fstatat` with `AT_SYMLINK_NOFOLLOW` and its `S_ISDIR` test, an
  `openat`, a second `open` on the run-directory argument, two `fstat`s and the
  `st_dev`/`st_ino` compare, each with its own refusal, R5), the regular-non-symlink check on
  the request and map
  arguments (~15), the `INT`/`TERM`/`HUP` handlers and process-group termination in R2
  (~73 — the group sequence itself is ~45, the two `volatile sig_atomic_t` variables,
  the `pre_child` branch, the zero-`pgid` guard and the one `parent-signal:` line each
  branch writes are ~25 more, and the three-signal `sa_mask` each of the three `sigaction`
  installations sets is ~3 more), the one `runtime-pgid: <n>` line written after the fork — a `snprintf` and one
  stderr write (~5, R2), closing inherited descriptors above 2 (~15), the fd-relative
  creation of the four
  sandbox entries (~20 — two `mkdirat` and two `openat` calls in place of two `mkdir` and
  two `open` calls is nearly free, and the cost is carrying the output-directory descriptor
  into `supervise` and out of `main`: the signature, the call site, the ownership of the
  close, and the error paths, R5), the same move on the supervisor's reads back
  (~15 — `empty_regular_file` becomes an `fstat` on the kept descriptor, `stream_file` and
  `sanitized_error` take an `int` instead of a path and gain an `lseek`, and their
  `open`/`close` bookkeeping goes away, R5), the git blob id computed rather than asked
  for (~20 — the `blob <size>\0` header built from its own `fstat`, the pipe into the
  platform's SHA-1 tool, and the hex compare, R1), and the usage
  text and `E_*` exit paths those new checks need (~15). The biggest unknown in that ~470
  is how the parent computes digests: delegating to the platform's SHA-256 and SHA-1 tools
  at fixed paths sits at the low end, while a SHA-256 implementation
  carried in the C file would add roughly 150 more lines. The
  plan decides that, and it is the one thing that could push the C file past ~1200. The
  round before this one moved this figure by the ~35 just named — the supervisor's reads
  moving onto the
  descriptors it already holds, and the blob id being computed in C rather than delegated
  to `git hash-object`. The round before it moved nothing here, and the one before that
  added the ~20 for the fd-relative creation. The round before that added the ~5 for the
  `runtime-pgid` line and nothing else, the round before this one added nothing here at all,
  the round before this one added the ~25 named in the handler bullet above: the two
  `sig_atomic_t` variables, the `pre_child` branch and the `parent-signal:` line (R2).
  The round before this one added ~15 more, to ~1090: the signal set built once, and the
  `sigprocmask(SIG_BLOCK, …)`/`sigprocmask(SIG_SETMASK, …)` pair around each fork the
  parent performs — the resolver's and each pre-resolver child's — plus the child's
  `SIG_DFL` resets and the mask restore after them, before `execve` (R2). The round before
  this one added
  ~5 more, to ~1095: the `SIGPIPE` disposition set beside the three handlers, the
  `fcntl` that makes stderr non-blocking for the handler's one line, and that line becoming
  a single unchecked `write(2)` instead of a `write_all` call — the reordering that puts it
  after the kill and the reap costs nothing, being the same statements in a different
  order (R2). The round before this one added ~2 more, to **~1097**: the `runtime-pgid:`
  line gets the same
  treatment, which is one `fcntl` to set `O_NONBLOCK` and a second to put the flags back
  (the parent keeps running, so it cannot leave them), and its `write_all` becomes a single
  unchecked `write(2)`. Moving it out of the blocked-signal region to after the
  `sigprocmask(SIG_SETMASK, …)` costs nothing, being the same statements in a different
  order (R2). The round before this one added nothing here and the figure stayed at ~1097:
  both of its
  findings were outside the C parent — the entry's signal design, and this artifact pull
  request's own size record. The round before this one added ~2 more, to ~1099: the
  `umask(077)` call
  among the first statements of `main`, which the copied launcher does not have, so the
  `home` and `tmp` the parent creates are 0700 and its two capture files 0600 whatever
  umask the caller left behind (R5). The round before this one added ~15 more, to ~1114: the
  output-directory check's `realpath` string comparison becomes the descriptor-identity
  sequence the bullet above itemises — the `fstatat` with `AT_SYMLINK_NOFOLLOW` and its
  `S_ISDIR` test, the `openat` on `.run`, the `open` on the run-directory argument, the two
  `fstat`s and the `st_dev`/`st_ino` compare, the `fdopendir` on a `dup` of the checked
  descriptor for the listing, and a refusal on each — where two `realpath` calls and a
  `strcmp` were three statements (R5). This round adds ~3 more, to **~1117**: the
  three-signal `sa_mask` on each of the three `sigaction` installations, which is one
  `sigemptyset` and three `sigaddset` calls on a set the parent already builds for the
  fork mask, assigned into each `struct sigaction` before it is installed (R2).
- **Entry shell ~380 lines.** `shadow/v1/reproduce.sh:94-142` does the closest existing
  subset — self and repository-root resolution, platform case, jq digest pin, its own
  `mktemp -d` scratch,
  the `EXIT`/`HUP`/`INT`/`TERM` traps, the bounded copy and the `--version` probe — in
  about 50 lines. The entry adds ten computed blob-id pins — two C sources plus the
  eight loaded files R5 lists (~40 more than two pins would be: the constants and the loop
  over them are most of it, plus ~15 for computing each id from a `stat` size and the
  platform's SHA-1 tool rather than calling `git hash-object`, R1) — two compiles, the awk
  copy, the `tmp` subdirectory, the `chmod 0500` pass, the explicit
  environment every command it runs is given, and run-as-child plus wait plus signal
  forwarding plus `128 + signal`, each step with its own `E_RUNTIME` exit. The output
  directory it now takes as an argument, and the `PATH_MAX` guard it runs on that argument
  before making `<output>/.run` (R1), are ~15 of the total. The round before this one took
  the entry from
  ~270 to ~320: ~35 for validating the output root before writing into it — the `cd -P`
  comparison, the `/usr/bin/stat` owner-and-mode read with its per-platform format, the
  `dotglob nullglob` emptiness glob, and an `E_RUNTIME` exit for each (R1) — and ~15 for the
  `env -i` prefixes on the pin checks, both compiles and the parent launch, plus the `home`
  subdirectory the compile line's `HOME` needs and its removal beside `tmp`. The round
  before this one added
  ~15 more, to ~335: ~10 for the builtin scrub, which is the ten copied lines of
  `materialize.sh:4-13` and nothing else, and ~5 for the re-exec — the argument-count and
  marker-word discrimination, the `${BASH_SOURCE[0]}` absolute check, and the `exec` line
  itself (R1). Moving the pin checks after the run directory costs nothing: the same
  statements in a different order. The round after that added ~10 more, to ~345: the marker
  branch's re-run of that scrub, which is the same ten lines again plus the two alias-reset
  builtins (R1). The round after *that* added ~20 more, to ~365: the computed blob-id
  construction and the Darwin compiler arm (R1). The round after that added ~10 more, to
  ~375: the
  trap's second branch — the parent-pid variable it tests, and the chmod, remove and
  `128 + signal` exit for a signal that arrives while `.run` exists and no parent does
  (R1). This round adds ~5 more, to **~380**: the one `printf` line each trap branch writes
  to the entry's own stderr, with the signal name and the branch word it carries (R1). The
  round before this one added nothing here at all: the entry's forwarded branch was
  unchanged and the new handling was all on the parent's side of it (R2). The round before
  this one added
  ~5, to **~385**: the `run_created` guard — the `trap` line moving ahead of the `mkdir`,
  the guard inside both of its removal branches, and the `mkdir` becoming the one
  `run_created=$(/bin/mkdir -- "$run" && printf 1)` command with its
  `[ -n "$run_created" ]` refusal (R1) — that command form is withdrawn this round, though
  the guard itself survives in a different shape. The round before this one added nothing here and the
  figure stayed
  at ~385: each trap branch's `printf` moves to the end of the branch, after the
  forward and after the removal, which is the same statements in a different order (R1).
  The round before this one added nothing here either and the figure stayed at ~385: its
  only
  entry-side change was to a sentence in R2 that summarised the forwarded branch in the wrong
  order, which is prose about the entry rather than a change to it (R1, R2). The round
  after that added ~10 more, to **~395**, and it was the first entry-side figure in several
  rounds that moved because shipped statements moved: the three signal traps shrink to one assignment
  each, which is cheaper than the branch bodies they replace, but the `checkpoint`
  function and its calls after the `mkdir`, after each pin check, after each compile and
  after the copies, the `[ -e ]` pre-check, the three-case status test on the `mkdir`, and
  the forward-then-wait moving out of a trap body and into the main flow around the `wait`
  come to about ten lines more than what came out (R1). The round after that added ~2 more,
  to **~397**: `umask 077` in the marker branch, beside the scrub it already re-runs there
  and copied from the same file (`materialize.sh:31`), plus the comment that says why a
  scrub of variables does not cover a process attribute (R1). The round before this one
  added nothing here and the figure stayed at ~397: both of its findings were in the
  parent and the test. The round before this one added ~8 more, to ~405: every external
  command in the
  entry gains a captured status and a `checkpoint` ahead of its refusal in place of a
  `cmd || refuse` written beside it — one extra statement each across the ten pin checks,
  the two compiles and the two copies, which comes to fewer lines than fourteen because
  the `checkpoint` calls were counted in the figure above already and the refusals only
  move (R1). This round adds ~4 more, to **~409**: the four empty initialisations
  `entry_signal=''`, `run_created=''`, `entry_status=''` and `parent_pid=''`, placed among
  the entry's first builtins after the `umask 077` and before any trap is installed, so
  that `set -u` meets a set name at every checkpoint and in the `EXIT` trap on the paths
  where nothing has written one (R1). Four assignments is the whole cost; the rule they
  satisfy is stated in R1 and read in R10 rather than tested. This round adds ~6 more, to
  **~415**: the wait on the parent becomes a loop rather than two `wait` calls — the
  `while`, the `kill -0` test that tells an interrupted wait from a reaping one, the
  `last_forwarded` guard with its assignment beside the `kill`, and the `continue` and
  `break` — where two waits and one `kill` were three statements (R1). The traps changing
  from `entry_signal=NAME` to `: "${entry_signal:=NAME}"` costs nothing: the same three
  lines in a different form. This round adds ~3 more, to **~418**, and all three are single
  lines: `trap '' INT TERM HUP` as the first statement of the `EXIT` trap body, so the
  `chmod` and the `/bin/rm` inherit the ignore; `case $- in *p*) ;; *) exit 78 ;; esac` as
  the first statement of the marker branch; and the comment that says why a marker arrival
  without `-p` is refused rather than scrubbed (R1). The `-p` added to the re-exec's
  `/bin/bash` costs nothing — two characters on a line that was already there.
- **Focused test ~951 lines.** For scale, the existing resolution test is 746 lines and
  `scripts/test/shadow-slice.test.sh` is 622. R10 is now at the same scale as both:
  jq provisioning the `shadow-slice` way (~30), request and map fixtures (~40), the two
  resolutions plus `cmp` (~30), eleven entry-level refusals in group 1 (~140 — the seven
  that were there plus this round's five output-root cases at ~55, each of them also
  asserting the target was never written to), the entry-driven loader-variable pollution run
  with its marker library (~25 — the library, the two runs, and the at-most-one-line count
  assertion over the marker file), the forged clean-marker invocation with its
  exported-function fixture and its marker-file assertion, in two halves this round
  (~20 — the `-p` half as before at ~15, plus ~5 for the non-`-p` half: one run from a
  clean environment, the exit-78 assertion and the untouched-output-directory
  assertion), the
  polluted-compiler-environment block — poisoned-header
  fixture, two entry runs, two hand-built compiles whose digests are compared, and the
  control compile that proves the fixture poisonous (~55, of which ~20 is the Darwin
  `xcrun_db` before-and-after assertion — the state recorded as absent, or as a size, an
  mtime and a digest, with no skip either way, R1), a shared
  hand-built run-directory helper for the direct-parent cases (~15) and the nineteen
  group-2 cases on top of it (~150, the overlong-value case now building a near-`PATH_MAX`
  directory tree rather than naming a long path, and the two new `.run` containment cases —
  the symlinked `.run` and the regular-file `.run` — each asserting the refusal and an
  untouched target), the group-3 runtime refusal (~10),
  the R3 polluted
  environment run plus the Linux `/proc/<pid>/environ` allowlist assertion (~25), the
  five signal cases — the mid-run one with its live read of the entry's stderr for the
  parent's `runtime-pgid` line, its `SIGSTOP` freeze and its group assertions (~40), the
  repeated-signal one that runs the mid-run case again and sends a second `SIGTERM`, and
  in a variant a `SIGINT`, 100 ms after the first — the second signal, the sampler that
  polls the parent's pid against the existence of `.run` and fails on the first sample
  that finds the directory gone with the parent alive, the cross-check of that pid
  against the `entry-signal:` line, the one-line count-and-name assertion, the `set -m`
  both runs now need, and this round's third signal sent to the whole group 100 ms after
  the second (~18) — the
  pre-parent one that signals as soon as `.run` appears and asserts the trap's own
  `entry-signal:` line, with a bounded wait for the deferred trap (~30), the group-signal
  one that runs the entry in a process group of its own, waits for a compile to be the
  foreground step and signals the group rather than the pid, reusing that case's poll and
  its bounded wait and adding the assertion that no `E_RUNTIME` line was written (~12),
  and the stopped-parent one that drives the parent directly, sends `STOP`/`TERM`/`CONT`, asserts
  the `parent-signal: TERM no-runtime` line and a surviving sentinel in the test's own
  process group, and retries a bounded twenty times — both non-proving outcomes now, the
  late stop as well as the early signal, each printed per attempt and counted in the
  message the exhausted budget fails with (~40) — the cleanup assertions
  (~85 — four cases now rather than three, each asserting the exact entry set of the output
  directory rather than one emptiness test), the two-umask case (~15 — a `umask 000` run
  and a `umask 777` run, the background poll that reads `.run`, `tmp` and `home` while
  `home` exists, its bounded retry, and the `umask 000` direct-parent invocation that reads
  the parent's four sandbox modes), the pin-constant assertions over ten pins
  (~35 — each one now a three-way check that the computed id, `git hash-object`'s answer
  and the pinned constant all agree, R1), the
  command-word allowlist grep in its three sweeps, with the `compgen -b` and `compgen -k`
  exclusion sets derived at run time,
  plus the downloader grep, which no longer needs a `git`-subcommand assertion now that
  `git` is off the allowlist, plus the `/usr/bin/awk` position assertion that comes with
  awk moving to pass 1's data paths — every occurrence matched against the `cp` source
  and the Darwin shim text, none in command position, and none at all in the C file
  (~46),
  exit-status assertions (~15), harness
  boilerplate (~30), and the per-case temporary directory setup and teardown (~45).
- **Docs and manifest ~60 lines.** `docs/components.md:33-39`, the `README.md:252` row,
  `RESTORE.md:43-46`, and three lines appended to `ci/required-files.txt`.

Those sum to about 2431 lines; the range above is that sum with ~15% headroom at both
ends. It grew from 1350-1800 twelve rounds ago, then 1560-2120, then 1580-2130, then
1650-2240, then 1790-2420, then 1836-2484, then 1866-2524, then 1925-2605, then
1972-2668, then 1985-2685, then 2036-2754, then 2053-2777, then 2057-2783, and the
growth is itemised
above rather than absorbed: ~90 more in the parent (the two extra blob pins, the request
and map check, the signal handlers), ~25 more in the entry (eight more pins), and ~155
more in the test (thirteen more direct-parent cases, the R3 environment proof, the signal
test). The round before this one moved ~15 net lines, all of them in the test: the
unsupported-platform case left the runtime list for code review
(−10), the overlong-value case grew a near-`PATH_MAX` directory fixture (+10), and the
downloader grep became a full command-word allowlist grep plus a `git`-subcommand
assertion (+15). The round after that added ~90, all of it from the second of its two findings —
moving the run directory inside the caller's output root, which is a change to what the
shipped files do and so does cost implementation lines: ~20 in the parent (the
output-directory check became a `readdir` plus a `realpath` comparison — the comparison
this round replaces), ~15 in the entry
(the output-directory argument and its `PATH_MAX` guard), and ~55 in the test (two more
group-1 cases, one more group-2 case, and cleanup assertions that name the exact expected
entry set three times). The first finding — the process-table reads in R7 — adds nothing
here, because it only states what the copied supervisor already does. Nothing was made
cheaper to compensate.

The round before this one added ~160, all of it in the entry and the test, from three
findings that share one shape — a check or a scrub that was in the wrong process. ~50 in
the entry: validating the output root before writing into it, and running the pin
checks, both compiles and the parent launch under `/usr/bin/env -i` with a named
variable list. ~110 in the test: five output-root refusals in group 1, the
loader-variable pollution moved from the parent's caller to the entry's, and the
polluted-compiler-environment block with its poisoned header and its control compile.
Nothing in the C parent moved, for the reason its bullet gave, and again nothing was
made cheaper to compensate.

The round before this one added ~55, spread across all three files, from three findings
that all say the
same thing about *when* something happens rather than whether it happens. ~20 in the C
parent: creating the four sandbox entries relative to the checked output-directory
descriptor, whose real cost is carrying that descriptor into `supervise`. ~15 in the entry:
the copied builtin scrub and the empty-environment re-exec ahead of every external command
— the reorder that puts the run directory before the pin checks is free, being the same
statements in a different order. ~20 in the test: the count assertion on the marker file,
and a fourth cleanup case now that a pin-check refusal happens with `.run` on disk. Nothing
was made cheaper to compensate.

The round before this one added ~35, in the entry and the test only. ~10 in the entry:
the marker branch
re-running the scrub with its two alias-reset builtins. ~25 in the test: the forged
clean-marker case, and the Darwin note with the narrowed write assertion beside it. Nothing
moved in the C parent, because the other two findings that round settled cost no
implementation lines — one corrected what this spec says about the Darwin toolchain's own
cache, and the other stated a residual the parent cannot close from where it stands.

The round before this one added ~70, and unlike the round before it, it moved the C parent,
because both of its findings changed what shipped code does. ~35 in the parent: the
supervisor's three
path-based reads of `child.stdout` and `child.stderr` moving onto the descriptors it
already holds (~15), and the parent-pinned subset's blob ids being computed from an
`fstat` size and the platform's SHA-1 tool instead of delegated to `git hash-object`
(~20). ~20 in the entry: the same computed-blob-id construction with its `stat` size and
its `cat` pipe (~15), and the Darwin compiler arm gaining a path, an `-isysroot` and a
refusal when the Command Line Tools are absent (~5). ~15 in the test: the three-way
assertion that each computed id equals both `git hash-object` and the pinned constant, and
the Darwin `xcrun_db` before-and-after check that replaced a note. Nothing was made
cheaper to compensate — dropping `git hash-object` costs lines rather than saving them,
which is the honest trade for the claim it buys back.

The round before this one added ~55, and it moved all three files, though only just in the
parent's case.
~5 in the parent: the one `runtime-pgid: <n>` line written after the fork, which is a
`snprintf` and a `write_all` (R2). ~10 in the entry: the trap's second branch and the
parent-pid variable that selects it (R1). ~40 in the test: a new signal case that signals
the entry as soon as `.run` appears (~20), the mid-run signal case trading its `pgrep -P`
chain and its `ps` fallback for a live read of the entry's stderr (~5 net — the poll is on
a line in a file rather than on a process, and the fallback goes away), the Darwin
`xcrun_db` assertion recording size, mtime and digest and skipping nothing (~5), and the
command-word grep becoming three documented sweeps with a `compgen -b`/`compgen -k`
exclusion set derived at run time (~10). Nothing was made cheaper to compensate.

The round before this one added ~15, in the entry and the test only. ~5 in the entry: the
one `printf` line
each trap branch writes to the entry's own stderr, naming the signal and the branch (R1).
~10 in the test: the pre-parent signal case redirecting the entry's stderr to a file,
asserting exactly one `entry-signal: TERM no-parent` line and no `runtime-pgid:` line, and
waiting for the entry with a bounded timeout instead of expecting an immediate exit (R10).
Nothing moved in the C parent, and nothing was made cheaper to compensate: the round's
other change — correcting why the no-parent branch cannot race a live compiler child, from
foreground-group signalling to bash's deferral of a trapped signal — costs no
implementation lines, because the entry it describes already ran every pre-parent child in
the foreground. What it does add is a stated requirement that it keep doing so.

The round before this one added ~60, in the parent and the test, and all of it came from
the second of its
two findings. ~25 in the parent: the signal handler's two `volatile sig_atomic_t`
variables, the assignment of each at the right moment, the `pre_child` branch with its own
`SIGTERM`-then-`SIGKILL` and reap, the guard that keeps a zero `pgid` away from
`kill(-pgid, …)`, and the one `parent-signal:` line each branch writes with the copied
`write_all` (R2). ~35 in the test: the third signal case, which builds a run directory the
group-2 way, starts the parent and stops it immediately, sends `TERM` then `CONT`, starts a
sentinel process in its own group and asserts it survives, distinguishes the two
non-proving outcomes by their own messages, and retries a bounded twenty times (R10).
Nothing moved in the entry, whose forwarded branch is unchanged. The first finding — the
Darwin write residual narrowing to the runtime's own `git` under DR-2 — costs no
implementation lines at all: it changes what this spec claims and what the Darwin operator
run measures, not what any shipped file does, which is the whole reason it is a residual
rather than a fix. Nothing was made cheaper to compensate.

The round before this one added ~20, in the parent and the entry, and nothing in the test,
because neither
of its two fixes has a proof a test can run. ~15 in the parent: the three-signal set, the
`sigprocmask(SIG_BLOCK, …)` before each fork it performs and the matching
`sigprocmask(SIG_SETMASK, …)` after the pid assignment and the `runtime-pgid:` line, and
the child's `SIG_DFL` resets and the mask restore after them (R2). ~5 in the entry:
the `trap` line moving ahead of the `mkdir`, the `run_created` guard inside both removal
branches, and the `mkdir` written as one command with its assignment and its emptiness
refusal (R1). Nothing in the test, and that is a claim rather than an omission: the
fork-and-publish window and the trap-arming order are both proved by reading, for the
reasons R10 states in each place, and inventing a case that lands in neither window would
pass by missing it. The round's other finding was the DR-2 decision, which was the
operator's to make rather than that round's to settle and added nothing anywhere until it
was answered.
Nothing was made cheaper to compensate.

The round before this one added ~5, all of it in the parent, and both of its fixes were
mostly reorderings
rather than new code. ~5 in the parent: the `SIGPIPE` disposition set beside the three
handlers, the `fcntl` that makes stderr non-blocking for the handler's one line, and that
line becoming a single unchecked `write(2)` in place of a `write_all` call. Nothing in the
entry, whose trap writes the same `printf` in a later position, and nothing in the test,
whose three signal cases keep every assertion they had — the lines are still written, only
later — which is checked case by case in R10 rather than asserted in passing. The child's
`SIG_DFL`-before-unblock order costs nothing either: it is the same two calls in the
opposite order, plus `SIGPIPE` joining the resets it already performs. The round's third
finding was DR-2, then still open with the operator. Nothing was made cheaper to compensate.

The round before this one added ~2, all of it in the parent, and it finished the fix its
own
predecessor left
incomplete on one line. ~2 in the parent: the `runtime-pgid:` line gets the same two
`fcntl` calls and the same single unchecked `write(2)` the handler's line got, and it moves
out of the blocked-signal region to after the `sigprocmask(SIG_SETMASK, …)` — a move that
costs nothing, being the same statements in a different order. Nothing in the entry: the
fix there was to a sentence in R2 that summarised the forwarded branch in the wrong
order, and R1, which owns the branch, already stated the right one, so no shipped statement
moved. Nothing in the test either, and that was checked rather than assumed: the one case
that reads the line reads it from a plain file, where a non-blocking write can neither block
nor fail, so it keeps every assertion it had (R10). That round's third finding was DR-2,
then still open with the operator.

The round before this one added ~10, all of it in the entry, from one of its two findings;
the other cost
no implementation
lines at all. ~10 in the entry: the signal path is redesigned so the three
`INT`/`TERM`/`HUP` traps only record the signal's name and the main flow acts on it at
checkpoints, which nets out at about ten lines — the trap bodies lose the forward, the
chmod, the removal, the write and the exit, and the main flow gains a `checkpoint`
function with its calls after the `mkdir`, each pin check, each compile and the copies, an
`[ -e ]` refusal ahead of the `mkdir`, a three-case test on the `mkdir`'s captured status
in place of a command substitution, and the forward-then-wait around the `wait` on the
parent (R1). The reason it is a change to shipped statements rather than prose is that the
withdrawn design could lose its own guard: a group signal can kill the substitution's child
after `mkdir` has created `.run` and before `printf` writes the `1`, leaving the directory
on disk with the cleanup disarmed. Nothing in the C parent, which the finding does not
touch, and nothing in the test either, and that is checked case by case rather than assumed
— all three signal cases keep every assertion they had, because nothing observable changes
(R10). The second finding was this artifact pull request's own size record, which is a
statement about this document and changes no shipped file. The sum of the four bullets was
~2432 against the ~2420 the range is derived from, which is inside the rounding rather than
a new figure, so the implementation range was unchanged. That round's third finding was DR-2,
then still open with the operator; it did not touch it. Nothing was made cheaper to
compensate.

The round before this one added ~19, and for once it touched all three files from a single
finding. ~2 in
the C parent: `umask(077)` among the first statements of `main`, so the `mkdirat` and
`openat` modes the parent asks for are the modes that appear on its four sandbox entries
(R5). ~2 in the entry: `umask 077` in the marker branch beside the scrub it already re-runs
there, copied from `materialize.sh:31`, because a scrub that resets variables, functions
and aliases does not reset a process attribute and neither does an `env -i` re-exec (R1).
~15 in the test: the two-umask case — the entry run under `umask 000` and the one under
`umask 777`, the background poll that reads `.run`, `tmp` and `home` while `home` still
exists, the bounded retry that poll needs, and the direct-parent invocation under
`umask 000` that reads the parent's own four modes (R10). The round's other finding costs
no implementation lines at all, in the way the Darwin residual never has: DR-2 was decided
by the operator on 2026-09-10 and carried into the chain by intent pull request `#282`, so
what changes is the intent this spec pins and the way R7 and the residual bullet describe
the deviation — not what any shipped file does. The sum of the four bullets was ~2451
against the ~2420 the range is derived from, which is inside the rounding rather than a new
figure, so the implementation range was unchanged. Nothing was made cheaper to compensate.

The round before this one added ~25, in the C parent and the test, from one finding. ~15 in the parent:
the output directory's `.run` containment check stops being two `realpath` calls and a
`strcmp` and becomes a descriptor-identity sequence — `fstatat` with
`AT_SYMLINK_NOFOLLOW` and an `S_ISDIR` test on the `.run` entry, an `openat` on it, an
`open` on the run-directory argument, two `fstat`s, the `st_dev`/`st_ino` compare, the
listing moving to `fdopendir` on a `dup` of the checked descriptor, and a refusal on each
step (R5). ~10 in the test: two more group-2 cases, a `.run` that is a symlink to a real
well-built run directory elsewhere and a `.run` that is a regular file, each asserting the
refusal and that the parent touched nothing (R10). Nothing in the entry, which never
compared paths for this: its own output-root validation is the emptiness glob and the
`cd -P` comparison, and the `.run` it creates is one it makes itself, so the finding does
not reach it. Nothing was made cheaper to compensate — the withdrawn `realpath` comparison
was the cheap wrong answer, and the right one costs more lines than it. The sum of the four
bullets was then ~2476 against the ~2420 the range is derived from, about 2% above it and so
still well inside the ±15% the range expresses, so the implementation range was unchanged.

The round before this one added ~8, in the C parent and the test, from two findings, and
neither was a new mechanism: one is a flag on code that already exists, the other is a test outcome
reclassified. ~3 in the parent: each of the three `sigaction` installations gets `sa_mask`
set to the whole `SIGINT`/`SIGTERM`/`SIGHUP` set, which is one `sigemptyset` and three
`sigaddset` calls — on the same set the fork mask already builds, so the cost is the
assignment into each `struct sigaction` and the comment saying why — so that a sibling
signal cannot re-enter a handler that is part-way through the kill, the reap and the
shared `pgid`/`pre_child` state (R2). ~5 in the test: the stopped-parent signal case stops
treating a `runtime-pgid:` line as an immediate failure and retries on it the way it
already retries on a missing `parent-signal:` line, which is the outcome branch changing
target plus the second counter and the two counts in the failure message (R10). Nothing in
the entry, which neither finding touched, and nothing was made cheaper to compensate. The
sum of the four bullets was then ~2484 against the ~2420 the range is derived from, about
3% above it and so still well inside the ±15% the range expresses, so the implementation
range was unchanged.

The round before this one added ~20, in the entry and the test, from one P2, and it is an
ordering rule
rather than a new mechanism. ~8 in the entry: every external command it runs — the ten pin
checks, the two compiles and the two copies, and the `$(...)` substitutions among them —
is written status first, `checkpoint` second, refusal third, in place of a `cmd || refuse`
beside the command, which costs one statement each where the refusal and the checkpoint
already existed (R1). ~12 in the test: a fourth signal case that runs the entry in a
process group of its own and sends `SIGTERM` to the group while a compile is the
foreground step, reusing the pre-parent case's poll, its bounded wait and its
stderr-from-a-plain-file reading, and adding the assertion the case exists for — no
`E_RUNTIME` line on a signalled run (R10). Nothing in the C parent, which the finding does
not touch: the shape it forbids is a shell shorthand and the parent has no equivalent.
Nothing was made cheaper to compensate. The sum of the four bullets was then ~2504 against
the ~2420 the range is derived from, about 3.5% above it and so still well inside the ±15%
the range expresses, so the implementation range was unchanged.

The round before this one added ~10, in the entry and the test, from two P2s, and neither
was a mechanism:
one was four assignments, and the other moved a path from one side of an existing grep to
the other. ~4 in the entry: `entry_signal`, `run_created`, `entry_status` and `parent_pid`
declared empty among the first builtins, ahead of the `trap` builtins, so the first
checkpoint of a signal-free run and the `EXIT` trap of a refusal that happens before the
run directory exists read set names instead of aborting on an unbound one under `set -u`
(R1). ~6 in the test: the `/usr/bin/awk` position assertion beside the allowlist grep —
each occurrence in the entry matched against the `cp` source or the Darwin shim text, none
of them in command position, and none at all in the C file (R10). Nothing in the C parent,
which neither finding reaches: it names no awk and it has no shell variables to leave
unset. Nothing was made cheaper to compensate, and `/usr/bin/awk` leaving the command-word
list makes nothing dearer either, because the entry never ran it — what changed is which
half of the grep holds it. The sum of the four bullets was then ~2514 against the ~2420 the
range is derived from, about 4% above it and so still well inside the ±15% the range
expresses, so the implementation range was unchanged.

This round adds ~21, in the entry and the test, from one P1, and it is the first
entry-side figure in several rounds to move because a control structure changed rather
than a statement being added. ~6 in the entry: the wait on the parent becomes a loop that
ends only when `kill -0` says the parent's pid has been reaped — the `while`, the
`kill -0` test, the `last_forwarded` guard that keeps a repeat from being forwarded twice,
and the `continue` and `break` — in place of the two `wait` calls and the one `kill` an
earlier round wrote, which a second signal during the second wait would have cut short
with the parent still alive and `.run` about to be removed (R1). The three traps becoming
assign-if-empty costs nothing, being the same three lines in a different form. ~15 in the
test: a fifth signal case, which is the mid-run case run again with a second `SIGTERM` —
and in a variant a `SIGINT` — 100 ms after the first, plus the sampler that polls the
parent's liveness against the existence of `.run` and fails on the first sample that finds
the directory gone with the parent alive, the cross-check that the pid it polled is the pid
the entry says it forwarded to, and the assertion that exactly one `entry-signal:` line
was written naming the first signal (R10). Nothing in the C parent, which the finding does
not reach: its handler already `_exit`s on the first signal it takes and holds its siblings
under `sa_mask` (R2). Nothing was made cheaper to compensate. The sum of the four bullets
is now ~2535 against the ~2420 the range is derived from, about 5% above it and so still
well inside the ±15% the range expresses, so the implementation range is unchanged.

**That is well over ~1200 lines, and the recommendation is still one pull request.** The seam
considered was the obvious one: the C parent in one pull request, the entry and the test
in another. It is not clean. The direct-parent cases in R10 build a run directory by
hand, so the parent is technically exercisable alone — but everything that makes the proof
a proof needs the entry. R6's byte-identical `cmp` runs through the shipped entry, every
cleanup assertion is about the entry's trap, and the mode-0500 checks the parent enforces
only ever pass because the entry set those modes. Splitting would ship a security-boundary
binary with no shipped way to launch it, and would need a throwaway harness in the first
pull request duplicating the entry's pin-compile-tighten sequence, so it raises the total
reviewed lines instead of lowering them. The size is the honest cost of proving one
boundary once.

**Size exception for this spec pull request (the artifact PR, not the implementation).**
The `AGENTS.md:102-106` soft budget of ~300-400 net lines applies to artifact pull
requests too, and this one exceeds it by about ten times: `wc -l
work/resolver-trusted-parent/spec.md` is 5023 lines. Accepted as one concern — the
launch boundary as a security control, the same one the waiver at the end of this section
records: one
high-risk security-boundary spec whose review
rounds each added a verified requirement (offline jq, attestable provenance, cleanup,
compiler temporaries, narrowed read claims, the full pinned load set, process-group
termination on signals, per-check direct-parent coverage, an exact executable allowlist,
the parent's host process-table reads, a single write root, a validated
output root, loader variables tested at the boundary that can defend them, a scrubbed
compiler environment, the scrub moving ahead of every external command, the
scratch directories moving ahead of the pin checks, the parent's sandbox writes moving
onto the descriptor it checked, a narrowed write claim on Darwin where the
toolchain shim writes a cache the entry cannot redirect, the `.run` swap stated as a
residual with the same-uid assumption it needs, the marker branch re-running the
scrub, the parent's reads of the child's output moving onto the same
descriptors it created, the Darwin write claim restored unconditionally by taking
the `xcrun` shim out of the shipped path — no `git`, and the CommandLineTools clang in
place of `/usr/bin/cc` — the trap's branch for a signal that arrives before
any parent exists, the resolver's process group reported by the parent rather than inferred
from the process table, the Darwin cache assertion that no longer skips the case it exists
to catch, a command-word grep with a mechanism a test can actually be written from, that
pre-parent trap branch made observable on the entry's own stderr so its
test asserts the branch instead of an empty directory, with the deferral rule that keeps
its removal off a live child stated correctly for the first time, the
Darwin write claim narrowed to the one residual that belongs to the unchanged runtime's
own `git`, with DR-2 raised on it, beside the parent's signal handler specified for the
window before a runtime process group exists, the three signals blocked
across every fork the parent performs and its publication, so no handler can run in the
instant when a child exists and its pid does not, beside the entry's cleanup trap armed
before the `mkdir` rather than with it, guarded so it never removes a `.run` that is not
its own, the forked child resetting the three dispositions before it
unblocks the mask, so an inherited handler can never run in the wrong process, beside both
signal diagnostics moved after the killing and the cleanup and made best-effort, so a
blocked stderr cannot hold up the termination they exist to describe, and this round the
one diagnostic still left inside a blocked-signal region — the parent's `runtime-pgid:`
line — moved out to after the unmask and made best-effort with it, so nothing that can
block sits anywhere a forwarded signal cannot reach the handler, the entry's
signal traps cut down to recording the signal's name with the main flow acting at
checkpoints, so the cleanup guard can no longer be lost to a group signal that kills the
very command that was supposed to set it, and this round DR-2 answered and written into
the intent this spec pins, so the one deviation from the write-root constraint is carried
by the accepted artifact rather than by a spec waiting on a decision, beside a known umask
set before anything is created, so the modes every other requirement states are the modes
that appear whatever umask the caller left behind, beside the `.run` containment
check decided by descriptor identity with no symlink followed anywhere in it, so an output
directory whose only entry is a link to a run directory somewhere else can no longer
satisfy the containment the check exists to prove, and this round the three signal handlers
installed with a mask that blocks all three of them, so a sibling signal can never re-enter
a handler that is part-way through killing a group and reaping, beside the one signal test
that could fail a correct implementation on a loaded runner now retrying that outcome
instead of failing on it, beside every external command in the entry ordered
status first, checkpoint second, refusal third, so a command the caller's terminal signal
killed can never be reported as an `E_RUNTIME` refusal in place of the signal exit it
actually was, with a fourth signal case that signals the foreground group to prove it,
beside every variable the entry's traps, checkpoints and `EXIT` trap read
initialised before any trap is installed, so the ordinary signal-free run cannot die on an
unbound variable at its very first checkpoint, beside `/usr/bin/awk` reclassified from a
command the entry may run to a path it only names, with the two positions it may stand in
asserted, so an accidental host-awk invocation fails the allowlist grep instead of passing
it, and this round the entry's wait on the parent made a loop that ends only when the
parent's pid has actually been reaped, with the signal forwarded once and the first name
recorded kept, so a second `Ctrl-C` during the termination can no longer take an
interrupted wait's status for the parent's and remove the run directory out from under a
resolver that is still alive, with a fifth signal case that presses twice to prove it,
and this round the entry's `EXIT` trap setting the three signals to ignore before it
touches the disk, so the `chmod` and the `/bin/rm` it runs inherit the ignore and a third
`Ctrl-C` can no longer stop the removal part-way and leave the run directory behind,
beside the marker branch refusing outright unless it was reached in privileged mode, so
the one door into the clean path is shut by a condition the supported invocations create
rather than by a scrub the unsupported one could have shadowed, and the spec's claim for
that scrub cut back to what it is).
**Evidence-based range for this spec pull request: 4270-5776 lines** — the measured
5023 lines plus or minus 15%, rounded. This is the artifact pull request's own range,
recorded again in the waiver at the end of this section; the implementation pull request's
range is the separate figure above and the two are never compared. It was
553 lines and 470-636 fourteen rounds ago, then 783, then 847, then 1012, then 1202, then
1503, then 1764, then 1955, then 2245, then 2512, then 2636, then 2933, then 3168, then
3295, then 3409, then 3642, then 3866, then 4013, then 4128, then 4293, then 4476, then
4773 (the round before this one appended none of its own, and both are restored here);
where each block of
growth went is worth naming so it can be checked rather than taken on trust. The 230 lines
of that first big round were its three findings: about 65 enumerating the runtime's loaded
set with its
evidence and deciding the pins (R5), about 40 restructuring R10's refusals into
owner-labelled groups with one line per case, about 25 on the signal decision in R2 and
its test, and the rest spread over R1, R7, the Design steps, three Areas-of-concern
bullets and the re-derived size figures. The 64 lines of the round after it were its two
findings: about 27 stating pin ownership once and naming the parent-pinned subset with
its residual (R5, echoed in R1, R7 and R10), about 28 replacing the signal test's
fallback with the `SIGSTOP` freeze and its failure case (R10, echoed in R2 and Areas of
concern), and the remaining handful in re-derived size figures.
The 165 lines of the round after that were its three findings: about 55 replacing
R7's seven-tool read list with the exact command enumeration per
shipped file and the path-policy choices behind it, about 30 explaining why the
overlong-value case aims at the output path (R10, echoed in R5), about 25 on the
unsupported-platform refusal becoming code-review coverage (R10, echoed in R8, Design
step 2 and Areas of concern), about 11 turning the read list into R10's command-word
grep, and the rest in the Copy-versus-adapt deviation list and re-derived figures.
The 190 lines of the round after that, in turn, were its two findings, split
unevenly. About 45 go to R7's new
third read item, which names the copied supervisor's `/proc` and `libproc` reads per
platform with their line numbers, says they take no file content, and says the coverage is
code review of the copied block — echoed in R10's grep paragraph and in Areas of concern.
The rest go to the run directory moving inside the caller's output root, which reached
further than any single finding so far: R1's run-directory paragraph and its `PATH_MAX`
guard, R7's write claim rewritten around one root, R5's output-directory refusal and the
check order it now fixes, three more R10 cases, the whole cleanup block, the signal test's
final assertion, Design steps 1 and 2, two Areas-of-concern bullets, the Copy-versus-adapt
list, and the implementation size figures — which moved for the first time in three
rounds, because unlike the recent findings this one changes what the shipped files do.
The round before this one was +301 net, the largest yet, over three findings that all say
the same thing in
different places: a check or a scrub was sitting in the wrong process. About 70 go to the
entry validating the output root before it writes there — R1's validate-first paragraphs
with the `cd -P`, `stat` and glob mechanisms, R5's paragraph on why the same rule now sits
in two places, and five R10 cases. About 80 go to the compiler environment: the verbatim
`env -i` compile line, the reasoning about Darwin's `cc` finding its SDK with an empty
environment and the honest note that Linux-only CI cannot check that reasoning, the `home`
subdirectory, and R10's poisoned-header block with its control compile. About 45 go to the
loader variables moving out of the direct-parent pollution test and into the caller of the
entry, the one place the claim can be made — R10's corrected block with its marker library,
the `env -i` parent launch in R1, and the rewritten boundary note under Areas of concern.
About 40 are the re-derived size figures, here and for the implementation. The remaining ~60
are the ripples the three findings drag behind them: two more command words in R7's list and
R10's grep (`/usr/bin/env`, `/usr/bin/stat`) with the two extra deviation bullets that
explain them, a fourth per-platform table in three places, Design steps 1 and 2 reordered,
two more entries in the Copy-versus-adapt list, and `home` appearing everywhere `tmp`
already did.

The round before this one was +261 net over three findings that were all corrections to
the round before it
rather than new ground — each one says a defence it added is in the right place but at the
wrong moment. About 105 go to the loader scrub: R1's three new paragraphs on why an
`env -i` prefix cannot protect the `env` that carries it, the verbatim builtin scrub and
the adapted re-exec with its two named deviations, the residual that the entry's own first
process is uncovered, and the rewritten boundary note under Areas of concern. About 55 go
to the parent creating its sandbox with `mkdirat` and `openat` on the descriptor it
checked — R5's two new paragraphs with the race they close and the path residual they do
not, plus R7's collision paragraph and Design step 1. About 35 go to the scratch
directories moving ahead of the pin checks: R1's order paragraph and Design step 2's
reordering, with the reason stated once. About 45 are the re-derived size figures, here and
for the implementation. The remaining ~20 are ripples: R10's marker assertion becoming a
count, its cleanup list going from three cases to four with the group-1 pin cases
reclassified, R3's parenthetical on `mkdirat`, and two more entries in the
Copy-versus-adapt list.

The round before this one was +191 net over three findings that were corrections of a
different kind: two
of them narrow a claim this spec was making too strongly, and the third closes a door it
had described as locked. About 65 go to the Darwin toolchain cache — R1's measured
paragraphs on where `xcrun_db` actually lives, why the documented `xcrun_nocache` control
makes the write more frequent rather than stopping it, and that `/usr/bin/git` is the same
shim as `/usr/bin/cc`, plus R7's narrowed write claim and R10's platform note on the
compiler-pollution case, with the settled-fact line under Areas of concern beside them.
About 25 go to the `.run` swap: R5's rewritten residual, the
same-uid assumption stated beside the accepted spec's trusted-parent one, and the reworded
bullets under Areas of concern and Out of scope. About 75 go to the marker branch — R1's
third named deviation with the re-run scrub and its two alias-reset builtins, the
unsupported-form statement, the one sentence on why a nonce would be theatre, and R10's
forged-marker case. The remaining ~25 are ripples: Design step 2, R9's documentation line,
the Copy-versus-adapt list, and the re-derived size figures here and for the
implementation.

The round before this one was +290 net over two findings, both of them corrections to what
the round just described settled. The first says the fd-relative sandbox creation was half a fix:
the copied supervisor reads `child.stdout` and `child.stderr` back by path after the child
exits — `empty_regular_file`, `stream_file` and `sanitized_error`, across five call sites
— so the race the creation move closed was still open at the point where the bytes are
trusted. About 70 go to that: R5's three new paragraphs on the path-based readers, what
replaces them and what is fd-bound afterwards, plus Design step 1, the Copy-versus-adapt
entry absorbing the reads into the existing deviation rather than adding a second one, and
the parent's size line. The second says the Darwin write residual the previous round
accepted contradicts the intent's own constraint
(`work/resolver-trusted-parent/intent.md:36`), and that the fix is to take the `xcrun` shim
out of the shipped path rather than to send the claim back through G1. About 180 go to
that: R1's rewritten Darwin block with the CommandLineTools clang probe, the
computed-blob-id construction beside it, R7's restored one-write-root claim with its two
rewritten command lists and its two new deviation bullets, R9's Darwin prerequisite, R10's
allowlist grep losing `/usr/bin/git` and gaining three words, R10's three-way pin
assertion and its `xcrun_db` before-and-after check, and the platform-matrix concern
turning a question into a prerequisite. The remaining ~40 are ripples: Design step 2,
the `stat` deviation bullet, R10's marker list, R7's executables count, and the re-derived
size figures here and for the implementation.

The round before this one was +267 net over five findings, four of them P2 and one P3, and all five are
corrections to what earlier rounds wrote rather than new ground. About 65 go to the
resolver's process group being reported instead of inferred: R2's two new paragraphs on the
`runtime-pgid` line and on the four stderr conventions it was checked against, R10's
rewritten identification block, R6's stdout clarification, R9's documentation line, the
ninth named parent deviation, and the group-2 stderr assertion. About 70 go to R10's
command-word grep, which becomes three documented sweeps with a builtin and reserved-word
set derived from `/bin/bash` at run time, and which now says why it is not a `shellcheck`
invocation. About 40 go to the trap's two branches — R1's block on the window between `.run`
and the parent, Design step 2's rewritten trap clause, and the signals concern. About 30 go
to R10's new pre-parent signal case with its output-directory assertions, and about 15 to
the Darwin `xcrun_db` assertion, which now records absence as a state and size, mtime and
digest as the other one, and skips nothing. The remaining ~45 are the re-derived size
figures, here and for the implementation. One of the five cost negative lines and was much
the cheapest to fix: R7's opening sentence still promised a named Darwin residual
that the round before it had removed from the rest of the requirement, and the fix was to
delete the promise.

The round before this one was +124 net over one P2, and it was a correction to the round
just described
rather than new ground: the pre-parent signal case that round added does not actually prove
the branch it names. About 35 go to the mechanism — R1's no-parent bullet losing the claim
that a compiler child "was signalled too" because the caller's signal reached the whole
foreground group, which is only true at a terminal, and gaining the rule bash's manual
states instead: a trapped signal is deferred until the foreground command completes, so
every pre-parent child has already exited by the time the branch runs. The honest cost of
that rule is stated beside it — the branch acts up to one compile late — along with the
requirement it depends on, that the entry background no pre-parent child, and the terminal
case as the other path to the same place. About 30 go to making the branch observable:
R1's new block on the one `entry-signal: <NAME> no-parent` / `forwarded <pid>` line each
branch writes to the entry's own stderr, why stderr and why that is not a violation of the
pass-through claim, and Design step 2's trap clause carrying the same line. About 40 go to
R10's rewritten pre-parent case: four assertions in place of three, the stderr line and the
absent `runtime-pgid:` line as the two that make it a test of the branch rather than of a
side effect, the plain statement that an empty output directory cannot tell "no parent"
from "parent just started", and the bounded wait the deferred trap forces on the test. The
remaining ~20 are ripples: the signals concern under Areas of concern, and the re-derived
size figures here and for the implementation.

The round before this one was +297 net over one P1 and one P2, and the two were unrelated
except in
being places where an earlier round claimed more than it had. About 90 go to the Darwin
write residual: R7's claim narrowed to name exactly what it covers — everything this
initiative adds, on both platforms, and the unchanged runtime on Linux — its Darwin
paragraph rewritten around the runtime's own `/usr/bin/git`
(`scripts/lib/profile-resolution.sh:313-323` and `:711-714`) reaching the `xcrun` shim
where the parent cannot redirect it, the deviation from
`work/resolver-trusted-parent/intent.md:36` stated plainly with DR-2 named as open and
its two refused-case alternatives given a sentence each, R1's "what this buys" paragraph
losing the word "unconditionally", and a new Areas-of-concern bullet for the residual
itself. About 45 go to R10's Darwin measurement, which stops asserting an unchanged
`xcrun_db` across a run that launches the runtime and becomes an operator recipe instead —
two before-and-after records, one permitted difference, any other new or modified file a
failure — with the strong unchanged-cache assertion moving to the half that compiles with
no runtime behind it, and with the plain statement that a primed cache may show no write,
which is why the claim is narrowed rather than reported clean. About 85 go to the parent's
handler before a runtime group exists: R2's new block with its two `volatile sig_atomic_t`
variables, its three branches, its refusal to ever call `kill(0, …)` or `kill(-0, …)` and
why, its `parent-signal:` line reconciled against the same four conventions the
`runtime-pgid:` line was, and the entry-side consequence; plus Design step 1's handler
clause carrying the same variables and branches. About 55 go to R10's third signal case —
the stop-immediately sequence, the sentinel in the test's own group, the two outcomes that
are failures rather than passes, and the bounded twenty attempts with the honest reason the
retry exists. The remaining ~25 are ripples: the signals concern under Areas of concern
going from two tests to three, the platform-matrix concern handing the Darwin question to
the new residual bullet, R9's documentation line naming the second stderr form, the
Copy-versus-adapt handler item growing rather than a tenth deviation being added, eight
sentences that said "the shipped path" where they meant "either shipped file", and the
re-derived size figures here and for the implementation.

The round before this one was +235 net over two P1 findings and one P2, and only two of
the three were
settled there. About 70 go to the parent's fork-and-publish window: R2's new block on why
two variables are not enough on their own, the blocked-signal region around every fork
with the exact order of `setpgid`, the pid assignment, the `runtime-pgid:` line and the
unmask inside it, the child's three `SIG_DFL` resets and its mask restore with their two
different reasons stated separately rather than merged, the honest note on why the
`pre_child` clear needs no mask of its own, Design step 1's handler clause carrying the
same sequence, the Copy-versus-adapt handler item growing again rather than a tenth
deviation being added, and the signals bullet under Areas of concern. About 15 go to R10
saying the window is proved by reading rather
than by a fourth signal case, with the reason a poll-and-signal case aimed at a few
instructions would pass by missing them. About 65 go to the entry's cleanup being armed
before the `mkdir` rather than with it: R1's new three-statement block with the
`run_created` guard, the create-and-flag written as one simple command, and the bash
deferral rule behind it measured rather than assumed; both removal branches gaining the
guard; the fixed-order sentence and the run-directory paragraph naming the trap's new
position; Design step 2's rewritten clause; and the cleanup bullet under Areas of concern.
About 20 go to R10's cleanup block: the
fifth case considered and deliberately not written, with the two reasons no deterministic
fixture for it exists, and cleanup case 2's order corrected. The remaining ~65 are
ripples: the accepted-concern list at the top, the pre-parent signal case's opening
sentence, and the re-derived size figures here and for the implementation.
The third finding was DR-2 on intake `#271`, which was the operator's decision rather than
a round's to fix; that round did not touch it either.

The round before this one was +127 net over one P1 and one P2, and both were orderings
inside the signal
path rather than new mechanisms. About 40 go to the child's side of the fork: R2's
child paragraph rewritten so the three dispositions are reset to `SIG_DFL` while the
signals are still blocked and the mask is restored last, with the one-sentence reason —
a pending signal unblocked first would run the parent's handler inside the child and kill
groups and `_exit` from the wrong process — plus `SIGPIPE` joining those resets because
the parent now leaves it ignored, and the same order carried into Design step 1, R10's
read-and-check sequence, the Copy-versus-adapt handler item and the signals bullet under
Areas of concern. About 70 go to the diagnostics never blocking termination: R2's
handler writing its `parent-signal:` line after the kill and the reap with stderr made
non-blocking, one unchecked `write(2)` instead of `write_all`, and `SIGPIPE` set to
`SIG_IGN` with the reason it is the disposition and not the mask; R1's trap writing its
`entry-signal:` line last in both branches, with the bash-`printf`-can-hang reason and the
plain file R10 reads it from; both branch bullets and Design step 2 reordered; and R10's
new paragraph checking the mid-run, pre-parent and stopped-parent cases one at a time
against the new order, none of them losing an assertion. The remaining ~17 are the
accepted-concern list at the top and the re-derived size figures here and for the
implementation. The third finding was DR-2, unchanged and then still open.

The round before this one was +114 net over one P1 and one P2, and both of them were its
own predecessor's two fixes applied to a place they had missed. About 60 go to the `runtime-pgid:` line: R2's
`pgid` bullet no longer claiming the line and the variable become true together, a new
paragraph saying why nothing that can block belongs inside the blocked-signal region and
what a blocked write in there would cost, and the line's own block rewritten around its
position after the unmask, the same non-blocking single `write(2)` the handler's line uses
with the two `fcntl` calls the parent needs because it keeps running, and a paragraph saying
plainly what best-effort costs a reader; plus that order and mechanism carried into Design
step 1, R10's read-and-check sequence, R10's mid-run case and its diagnostics paragraph, the
Copy-versus-adapt handler and `runtime-pgid` items, and R7's documentation line. About 5 go
to the forwarded branch: R2's one-sentence summary of it, which had the `entry-signal:` line
written before the forward and so contradicted both R1 and Design step 2, rewritten to the
order R1 states with the reason it is last. The remaining ~49 are the accepted-concern list
at the top and the re-derived size figures here and for the implementation, whose range does
not move because the ~2 the parent gains is inside the rounding of the sum it is derived
from. That round's third finding was DR-2, unchanged and then still open.

The round before this one was +233 net over two P2s, and neither was new ground: both said
an earlier round
recorded something it could not
back up. About 153 go to the entry's signal handling. The command-substitution guard —
`run_created=$(/bin/mkdir -- "$run" && printf 1)` — is withdrawn, because a signal
delivered to the whole foreground process group can kill that substitution's child between
the `mkdir` and the `printf`, leaving `.run` on disk with the guard empty and the cleanup
deliberately skipped: the exact leak the guard exists to prevent. What replaces it is a
split R1 now states in full — the three signal traps record the signal's name and do
nothing else, the `EXIT` trap does the guarded cleanup and writes the one line last, and
the main flow acts at `checkpoint` calls and at the wait on the parent — with the guard set
from `/bin/mkdir`'s own captured status behind an `[ -e ]` pre-check, including the status
above 128 that means the caller's signal killed `mkdir` after it had created the directory.
The new design was measured on a Darwin `/bin/bash 3.2.57`, output quoted in R1, and the one
thing that cannot be timed is marked as reasoning rather than measurement. Every observable
stays where it was, which is what lets R10's three signal cases keep every assertion; the
ripples are Design step 2's clause, R10's arming-order paragraph, its pre-parent case, its
deferral and diagnostics paragraphs, the Copy-versus-adapt run-directory item, and the
cleanup and signals bullets under Areas of concern. About 15 go to this pull request's own
size record: the waiver at the end of the size section pointed at "the range above" when
the nearest labelled range belongs to the implementation, so a reviewer could not check
this artifact against an approved number. It now records the one concern and an
evidence-based range for this spec pull request in the waiver itself, labelled as the spec
PR's and separate from the implementation PR's, and the self-count paragraph above states
the same two figures. The remaining 65 are the accepted-concern list at the top and the
re-derived size figures here and for the implementation, whose range does not move because
the ~10 the entry gains is inside the rounding of the sum it is derived from. That round's
third finding was DR-2, unchanged and then still open; it did not touch it.

The round before this one was +224 net over one P1 and one P2, and the P1 was the one
finding
this spec had carried
unanswered for five rounds. About 45 go to DR-2, which the operator decided on
2026-09-10, choosing option (a): the residual is accepted, named, and measured exactly. The
decision reaches this artifact the only way an intake decision can reach a spec after G1 —
through the intent, by amendment — so intent pull request `#282` amends the write-root
constraint to name the Darwin residual as the one accepted exception, and this spec re-pins
to that amended intent, `intent-blob:
eaa322c405502cc0ca7c453814ca0f005f11b48f` in place of `0fd28feb…`, which is the only
frontmatter change this round makes. R7's Darwin block stops asking and starts recording:
it quotes the amended constraint in full so a reader can see the intent and the spec agree
sentence by sentence, and the two refused-case alternatives it used to hold open become one
sentence of history. The Areas-of-concern bullet becomes an accepted, intent-recorded
residual rather than an open question, Out of scope gains the follow-up the amended
constraint names in its own last sentence, R1's "what this buys" paragraph and R10's Darwin
recipe say "accepted" where they said "asks", and every round-history sentence that
reported DR-2 as pending is put into the past tense it now belongs in. About
116 go to the umask: R1's new paragraph on why the builtin scrub and the
`env -i` re-exec leave a process attribute untouched and what a caller's `umask 000` or
`umask 777` does to a run tree whose modes are `mkdir` requests, the three-statement
creation block and Design step 2 saying where 0700 actually comes from, R5's new paragraph
on the parent's own `umask(077)` with the launcher's missing call and the test harness's
`umask 077` that hid it, R3's parenthetical, R7's two command lists noting that `umask` is
a builtin and forks nothing, Design step 1's clause, the tenth parent deviation and the
widened entry copy in Copy versus adapt, and R10's two-umask case with the poll it borrows
from the pre-parent signal case. The remaining 63 are the accepted-concern
list at the top and the re-derived size figures here and for the implementation, whose
range did not move because the ~19 the three files gained is inside the rounding of the sum
it is derived from.

The round before this one was +147 net over one P2, and it was a correction to a mechanism an
earlier round chose too quickly rather than new ground: the `.run` containment check was
written as a comparison of two `realpath` answers, and `realpath` resolves through the one
thing the check exists to refuse. About 55 go to R5: the refusal clause losing the words
"both resolved with `realpath`", the new block that says why that was wrong in one sentence
and then gives the five-step descriptor-identity sequence — the `O_NOFOLLOW` open of the
output directory, the `fstatat` with `AT_SYMLINK_NOFOLLOW` and its `S_ISDIR` test, the
`openat` on `.run`, the `open` on the run-directory argument, and the `st_dev`/`st_ino`
compare — with the two mechanism notes beside it (why the `S_ISDIR` test and not the
`O_NOFOLLOW` flag carries the refusal, given the launcher's own shim at `:30-31`, and the
listing moving to `fdopendir` on a `dup` of the checked descriptor), and the ordering
paragraph that puts the identity comparison before anything inside the run directory is
trusted and keeps the descriptors open from check to use. About 5 go to the helper block's
own half of the same comparison, which had the same flaw and now reads the same way. About
10 go to R10's two new group-2 cases — the symlinked `.run` and the regular-file `.run`,
each asserting the refusal and an untouched target — with the sentence saying the symlinked
one is precisely the case the withdrawn comparison passes. About 15 are the two ripples
that carry mechanism: Design step 1's clause, and the parent deviation item growing rather
than an eleventh being added, with the launcher verified to contain no `realpath`, no
`fstatat`, no `openat` and no `O_DIRECTORY`. The remaining ~60 are the accepted-concern
list at the top and the re-derived size figures here and for the implementation, whose
range does not move because the ~25 the parent and the test gain is inside the ±15% band
the range expresses. Nothing else in this spec used `realpath` for anything: the only other mentions
are round-history sentences recording what an earlier round added, which are left as the
history they are.

The round before this one was +115 net over two P2s, and both were the same kind of
finding: a sentence that was true of one signal and not of three. About 40 go to the handler mask.
R2 gains a block saying that POSIX blocks only the delivered signal by default, that this
handler touches the shared `pgid` and `pre_child`, kills a group and reaps, and that each
of the three `sigaction` installations therefore sets `sa_mask` to all three of `SIGINT`,
`SIGTERM` and `SIGHUP` — with the two flags stated beside it, `SA_RESTART` unset and
`SA_SIGINFO` unused, and the note that the held sibling is discarded by the `_exit` every
branch ends in, so the handler runs at most once and nothing in it has to be written to
survive running twice. The ripples carry the same clause: the installation sentence in R2,
Design step 1's handler clause, the Copy-versus-adapt handler item growing again rather
than a new deviation being added, R10's read-and-check sequence gaining the mask as
something the reviewer checks by reading, and the signals bullet under Areas of concern,
where "a second signal during termination" stops being one of the plan's open questions.
About 30 go to R10's stopped-parent case, where a `runtime-pgid:` line stops being an
immediate failure: the two non-proving outcomes are now retried inside the same budget of
twenty, with the reason the late stop is a scheduling artefact of driving a process from a
shell rather than an implementation fault, the per-attempt print of which outcome was seen,
the failure message carrying a count of each, and the retry-cost paragraph rewritten so it
covers both windows instead of one. The case's opening sentence loses the words
"deterministic by construction", which were the claim the finding actually landed on, and
its three assertions are labelled as the assertions of a proving attempt. The remaining
~45 were ripples: the accepted-concern list at the top, and the re-derived size
figures here and for the implementation, whose range did not move because the ~8 the
parent and the test gained is inside the rounding of the sum it is derived from.

The round before this one was +165 net over one P2, and it was an ordering rule rather
than new
ground: the entry's signal design was stated in full and its checkpoints were placed
correctly, but nothing said what shape the commands *between* the checkpoints take, so a
plan following the ordinary `cmd || refuse E_RUNTIME` shorthand would have reported an
interrupted pin check or compile as a runtime refusal and swallowed the signal exit the
same design promises. About 40 go to R1's new block: the shape forbidden by name, the
three numbered steps with the `set -uo pipefail` and `-e`-unset detail they need, the
reason stated as a mechanism — a terminal signal reaches the foreground child, so the
status is non-zero because of the signal and the refusal beside the command runs before
the checkpoint ever looks at `entry_signal` — the same rule extended to `$(...)`
substitutions that run tools, and the note that the `mkdir` block above is already written
this way and is the worked example rather than an exception. About 35 go to R10's new
group-signal case, which is the entry's no-parent branch reached the way a terminal
reaches it rather than the way a bare `kill` does: the entry in a process group of its
own, the signal sent to the group while a compile is the foreground step, and four
assertions of which the third — no `E_RUNTIME` line anywhere on the run's stderr — is the
one the case exists for, with the case after it renumbered and the
diagnostics paragraph checking it beside them. The remaining ~90 are ripples that
carry the rule where it is needed rather than restating it: R1's fixed-order sentence,
R5's pin-check clause, Design step 2's checkpoint clause, the signals bullet under Areas
of concern, the accepted-concern list at the top, and the re-derived size figures here and
for the implementation. A grep of this spec's entry pseudocode for `|| refuse`,
`|| emit`, `|| exit` and the like found one construct and it is correct as it stands: the
`checkpoint` function's own body, `[ -z "$entry_signal" ] || exit`, written out once in R1
and once in Design step 2, which is a test on a shell variable rather than an external
command's status being turned into a refusal. So no existing line had to be rewritten, and
the finding is settled by stating the rule where the plan will read it rather than by
fixing examples that were never there.

The round before this one was +183 net over two P2s, and both were the same kind of
finding as the
round before it: a design stated correctly at the level of what happens, with one level
below
it left to a plan that could get it wrong. About 50 go to the entry's state variables.
`set -u` is required of this entry and the checkpoint it requires reads `entry_signal`,
but nothing had said where that name comes from on the run where no signal ever arrives —
so R1 gains the block that initialises all four of `entry_signal`, `run_created`,
`entry_status` and `parent_pid` empty among the first builtins, before the `trap` builtins,
with `run` named as the fifth thing the `EXIT` trap reads and assigned rather than emptied,
the rule written as one line for the plan to carry, and the `${var:-}` alternative rejected
in the open for the two reasons it loses on — state a reviewer can see in one place, and a
`set -u` still able to catch a misspelled name. About 70 go to `/usr/bin/awk`. It was on
R7's command-word list and it should never have been: the entry copies the file in, or on
Darwin writes a shim naming it, so the *runtime* can execute the copy from `.run`, and no
shipped file runs host awk at all — so R7 loses the word, gains the paragraph saying where
the path does appear and the companion paragraph setting the bound jq beside it as the
opposite case (read, digested **and** run, by both files, through a variable rather than a
path), and R10 moves the path into pass 1's data list and adds the position assertion that
keeps the reclassification from weakening the grep it lives in. Both figures include the
ripples that carry each fix to where it is checked rather than restating it — the
checkpoint paragraph's clause on why its test is a read of a set variable, Design step 2's
two clauses and R10's read-and-check sequence for the first; R7's read-claim list gaining
awk as an input, its no-`awk`-process deviation bullet widening to say no awk process at
all, and the two count sentences moving from sixteen to fifteen with the `git` sentence
that cites them for the second. The remaining ~60 are the accepted-concern list at the top
and the re-derived size figures here and for the implementation, whose range did not move
because the ~10 the entry and the test gained is inside the rounding of the sum it is
derived from.

This round is +297 net over one P1, and it is a correction to a mechanism an earlier
round wrote one `wait` too short rather than new ground: the entry's forward-then-wait
handled the first signal and could be cut short by the second, which would have let the
`EXIT` trap remove `.run` while the parent was still terminating a stopped resolver.
About 105 go to R1's wait on the parent: the loop written out in full, the piece-by-piece
account of why the status alone cannot tell an interrupted wait from a reaping one and why
`kill -0` can — a live or zombie parent answers, a reaped pid gives `ESRCH` — the note
that pid reuse is impossible inside the loop because the zombie holds the pid until this
very `wait` takes it, the forward-once rule with both choices stated and the quieter one
picked, and the bash 3.2 measurement with its two variants and its zombie check. About 35
go to the first-signal-wins rule the loop rests on: the three traps becoming
`: "${entry_signal:=NAME}"`, the block on why the first name stands and what that costs a
reader, the `EXIT` trap's status rule saying in so many words that a second signal cannot
change the number, the checkpoint and no-parent branches checked against the same rule,
and `last_forwarded` named as deliberately outside the initialise-before-arming rule.
About 63 go to R10: a fifth signal case in the mid-run family — the second `SIGTERM` and
the `SIGINT` variant with the `set -m` it needs, the sampler that fails on any observation
of `.run` gone while the parent is alive, the pid cross-check against the `entry-signal:`
line, and the one-line count-and-name assertion — plus the four case ordinals that move
and the diagnostics paragraph checking the new case beside the others. The remaining ~56
are the ripples and the bookkeeping: Design step 2's trap and wait clauses, the signals
bullet under Areas of concern with the entry half of the second-signal question now
settled, the accepted-concern list at the top, and the re-derived size figures here and
for the implementation.

This round is +250 net over one P2 and one P3, and both findings are the same kind of
thing: a protection written one process, or one statement, short of where it had to be.
About 38 go to the P2, the cleanup's own signal disposition. The `EXIT` trap's body now
runs `trap '' INT TERM HUP` after its status capture and ahead of its first external
command, and most of those lines are the reason rather than the
line: that `chmod` and `/bin/rm` are external commands a foreground-group signal reaches
too, that a recording trap protects the shell and never the children it forks, that
`SIG_IGN` is the one disposition inherited across `fork` and preserved across `exec`, the
bash 3.2 measurement of a child surviving a group `TERM` with the line and dying without
it, why nothing is lost by ignoring at a point where the signal has already been recorded,
forwarded and the parent reaped, why `trap ''` and not `trap ':'`, and the measurement
behind the one ordering that is not free — `trap` is a builtin, a builtin that succeeds
sets `$?` to 0, so the status capture keeps first place and the ignore takes second.
About 70 go to the
P3, the marker branch. It stops trusting `builtin` — or anything else — before it knows
how it was entered: the first statement is `case $- in *p*) ;; *) exit 78 ;; esac`, the
re-exec gains the `-p` that makes that true on the supported path (a fourth named
deviation from the copied materializer lines), and the measurement behind it is written
out — `$-` under each of the four invocation forms, `BASH_ENV` read under the plain ones
and not under `-p`, an exported function imported under the plain ones and not under `-p`,
and, on the other side, an exported `exit` and an aliased `case` both shadowing the
refusal in a non-privileged process, which is exactly why that invocation is outside the
boundary. The rest of the P3 is subtraction: the spec stops saying the re-run scrub proves
hostile functions and aliases were removed before validation and says it is a second layer
on the arrivals the refusal admits. About 48 go to R10 — the forged-marker case split into
a `-p` half whose claim is rewritten and a clean-environment non-`-p` half asserting exit
78 and an untouched output directory, the repeated-signal case gaining a third signal to
the whole group with an honest note that nothing makes it land inside the trap, and the
read-and-check sequence gaining the `trap ''` line's position. The remaining ~94 are
the ripples and the bookkeeping: Design step 2 on both fixes, R9's documentation line, the
Copy-versus-adapt scrub item, the cleanup bullet and the entry's-first-process bullet
under Areas of concern, the accepted-concern list at the top, and the re-derived size
figures here and for the implementation.

This waives only the soft line signal for this artifact pull request, and
`work/README.md:71-73` requires the two things it is waived against to be recorded rather
than inferred, so both are recorded here in the waiver itself. **The one concern is the
launch boundary as a security control** — the single concern this whole spec has, named at
the top of this section and carried by every requirement in it. **The evidence-based range
for this spec pull request is 4270-5776 lines**, which is this file's measured
5023 lines plus or minus 15%, the same two figures the self-count paragraph above
states. That is the *spec* pull request's range and nothing else's: the
2066-2796 changed lines derived at the top of this section belong to the *implementation*
pull request, they measure a different artifact, and the two are never compared or summed.
It waives nothing
else: one concern per PR, readability, the review itself, CI, and operator merge all
still apply, and an unexplained overrun beyond
the spec pull request's range above still blocks review.

## Requirements

- **R1 — two shipped files.** `resolver/v1/trusted-launch.c` is the parent.
  `resolver/v1/resolve-profile.sh` is a thin entry that checks the jq it was handed,
  compiles the parent and `resolver/v1/nofollow-snapshot.c` from the committed sources,
  then runs the parent as a child and waits for it. The entry does **not** `exec` the
  parent: it needs to outlive it so it can delete the run directory, which an `exec`
  would make impossible because the entry's `EXIT` trap would never run and the
  compiled parent, the compiled helper, the compiler's own intermediates, and the copied
  jq and awk would be left behind in the caller's output directory on every invocation.
  The entry passes the child's
  stdout and stderr through unchanged (it does not capture, buffer or rewrite them), and
  exits with the child's own exit status, or `128 + signal` when the child died on a
  signal. Its `EXIT` trap removes the run directory. It also traps `INT`, `TERM` and
  `HUP`, and those three traps do one thing only: they record the *first* signal's name in
  an `entry_signal` variable. Everything else happens in the main flow afterwards, at the
  checkpoints set out below. When a parent exists the entry **forwards the same signal to
  the parent, waits for the parent to exit, and only then** lets the `EXIT` trap remove the
  run directory, and it exits `128 + signal`. That order is the whole point: the parent,
  not the entry, terminates the resolver's process group (R2), so the entry must never
  remove the run directory while a resolver could still be running out of it. A bash `wait`
  interrupted by a trapped signal returns at once with `128 + signal` of its own rather
  than the child's status, and a second signal interrupts the next `wait` the same way, so
  the main flow does not wait a fixed number of times: it waits in a loop that forwards the
  signal once, ignores every further interruption, and ends only when the parent has
  actually been reaped, taking the parent's real status from the wait that reaped it; the
  removal happens after that. Because the `EXIT` trap runs against a run
  directory the entry has by then set to mode 0500 (below), it restores mode 0700
  on the directory before removing it — harmlessly a no-op when the signal arrives earlier
  than that, while the directory is still 0700. Nothing shipped reads `scripts/test/`.
  The split follows the test today: the test
  script owns compilation, jq binding and platform choice
  (`scripts/test/portable-profile-resolution.test.sh:90-151`), and the C file owns only
  the launch.

  **The signal traps only record, and the main flow acts.** An earlier round of this spec
  put the whole of the signal path inside the `INT`/`TERM`/`HUP` trap bodies — the forward,
  the chmod, the removal and the exit — and armed the removal with a `run_created` guard
  that a command substitution produced:
  `run_created=$(/bin/mkdir -- "$run" && printf 1)`. That is withdrawn, because the guard
  can be lost in exactly the window it exists to cover. When `INT`, `TERM` or `HUP` is
  delivered to the whole foreground process group — which is what a `Ctrl-C` at a terminal
  does — the substitution's own child can be killed after `/bin/mkdir` has created `.run`
  and before `printf` has written its `1`. The substitution then yields the empty string,
  the guard stays empty, the trap deliberately removes nothing, and the caller is left with
  precisely the `.run` directory the guard was meant to cover. No ordering of statements
  fixes that, because the loss happens inside a child process rather than in the shell.

  So the signal path is split in two. The three traps are one assign-if-empty each —
  `: "${entry_signal:=INT}"`, `: "${entry_signal:=TERM}"`, `: "${entry_signal:=HUP}"` —
  and nothing else: no
  forward, no chmod, no removal, no write, no exit. The `EXIT` trap does the cleanup, and
  the main flow decides when to leave. That costs nothing in latency, and the reason is the
  same bash rule the rest of this requirement rests on: while a foreground command runs, a
  trapped signal is not delivered at all, so a trap body could never have acted sooner than
  the statement that follows that command. Acting in the main flow immediately after each
  command is therefore the same moment in time, reached from the one place where the
  entry's own variables are consistent.

  **The first signal recorded is the one that stands, which is what the assign-if-empty
  form buys.** Signals arrive more than once in practice — a user presses `Ctrl-C` twice
  because the first press did not appear to do anything, or sends `TERM` and then `INT`
  while the parent is still terminating a stopped resolver — and a plain
  `entry_signal=TERM` would let the second arrival overwrite a name the entry had already
  acted on, so the forward would be in flight for one signal while the `entry-signal:`
  line named another and the exit status came from a third. `: "${entry_signal:=NAME}"`
  assigns only while the variable is still empty, so one name is fixed at the first
  arrival and every later reader sees it: the checkpoints, the forward below, the one
  `entry-signal:` line and the `128 + signal` the `EXIT` trap derives from it. The
  alternative — record the latest — was considered and is not taken, because it makes
  every one of those observables depend on when the caller's second press landed relative
  to a compile, which is exactly the kind of scheduling-dependent output a test cannot
  assert. The cost is named rather than hidden: the signals the entry actually forwards
  may differ from the name on the line, since a later `INT` is delivered to the entry and
  recorded nowhere. R10 tolerates that by construction — it asserts exactly one
  `entry-signal:` line naming the **first** signal, and asserts nothing at all about a
  later one.

  **Every variable a trap, a checkpoint or the `EXIT` trap reads is initialised before any
  trap is installed.** The entry runs under `set -u` (the three-step command rule below
  states the full `set -uo pipefail`), so reading a name nothing has assigned is not an
  empty string but a fatal error — and on the ordinary run, the one where no signal ever
  arrives, nothing has assigned any of these names, because the only statements that write
  them are the three trap bodies and the three places in the main flow that set the guard,
  record the parent's pid and record its status — and every one of those sits after a read
  that would already have happened.
  The first `checkpoint` after the `mkdir` would evaluate `[ -z "$entry_signal" ]`
  against an unset name and abort the entry there, before a single pin check, before either
  compile and before the parent is launched. The `EXIT` trap is the same problem on every
  refusal path: it reads `run_created`, then `entry_signal`, then `parent_pid` to choose
  its line's second word, then `entry_status`, and an `E_RUNTIME` that happens before the
  run directory exists reaches it with all four unassigned.

  So the entry declares all four empty — `entry_signal=''`, `run_created=''`,
  `entry_status=''`, `parent_pid=''` — among its first builtins, immediately after the
  `umask 077` below and before it runs any external command, and the `trap … EXIT` line and
  the three recording traps are installed after them. `run` is the fifth name the `EXIT`
  trap reads, and it is not initialised empty but assigned, from the output root the entry
  has by then validated; that assignment precedes the `trap` builtins for the same reason.
  The rule is one line long and the plan should carry it as one: **no trap is installed
  until every variable that trap, the checkpoint or the `EXIT` trap can read has been
  assigned.** The `last_forwarded` variable the wait loop below uses is deliberately not
  in that list and does not belong among these four: no trap, no checkpoint and no part
  of the `EXIT` trap reads it, it is assigned empty on the statement immediately above the
  loop, and nothing under `set -u` can reach a read of it before that.

  The alternative was considered and is not taken: writing each read as
  `${entry_signal:-}` and leaving the variables undeclared would satisfy `set -u` too. An
  explicit initialisation is preferred for two reasons. It puts the entry's whole signal
  state in one place a reviewer can see at a glance, which is what makes R10's read-check
  of the arming order cheap — four assignments, then the `trap` lines, in that order on
  the page. And a `${var:-}` written at every read is indistinguishable from a misspelled
  name, so it switches off exactly the thing `set -u` is on for: with the defaults in
  place, `${entry_signl:-}` is a silent empty string on every path rather than an error on
  the first one.

  **The `EXIT` trap, which is now the only thing that touches the disk.** It runs on every
  exit path, signal or not, and does five things in this order: capture the status it was
  entered with, because the `trap`, the `rm` and the `printf` below would otherwise
  overwrite `$?`; then set `INT`, `TERM` and `HUP` to **ignore** with a bare
  `trap '' INT TERM HUP`, which is the second statement of the trap body and stands ahead
  of every external command in it;
  then, **if `run_created` is set**, `chmod 0700` the run directory and remove it and
  everything in it; then, **if `entry_signal` is set**, write the one `entry-signal:` line
  described below to the entry's own stderr; then exit. The
  `chmod` is a harmless no-op when the signal arrives before the mode pass, while the
  directory is still 0700. With `run_created` unset the trap touches nothing on disk, which
  is the normal case for a refusal that happens before the directory exists. With
  `entry_signal` unset it writes nothing, which is every non-signal exit.

  **The `trap ''` line is there for the `chmod` and the `/bin/rm`, not for the shell, and
  saying why makes clear that recording is not enough here.** Everywhere else in this entry
  a signal trap only records a name, because the shell is the thing at risk and the next
  checkpoint is where it can act. Cleanup is the one place where that shape is wrong. A
  caller's `Ctrl-C` goes to the whole foreground process group, so a signal arriving while
  the trap is running is delivered to `chmod` and `/bin/rm` as well as to the entry — and a
  recording trap does nothing for them, because a trap protects the shell that installed it
  and never the children that shell forks. `/bin/rm` would die part-way through its
  descent, the entry would exit, and the caller would be left with precisely the `.run`
  directory this trap exists to remove. Ignoring is the one disposition that reaches the
  children: `SIG_IGN` is inherited across `fork` and preserved across `exec`, so `chmod`
  and `/bin/rm` start life with these three signals already ignored and run to completion
  however many times the caller presses. Measured, bash 3.2: a `/bin/sh` child forked after
  `trap '' INT TERM HUP` survives a `TERM` sent to its whole process group and prints its
  last line, and the identical child without that line is killed before it gets there.
  Nothing is given up by ignoring at this point in the entry's life — by the time the
  `EXIT` trap runs, the first signal has been recorded, forwarded once and the parent
  reaped (or there was never a parent to forward to), the exit status is already decided,
  and the only thing a further signal can still do is break the removal. `trap ''` and not
  `trap ':'` on purpose: the empty string is the ignore disposition, which children
  inherit; a command, even a `:`, is a handler, and handlers are reset to the default in
  the child.

  **Second statement and not first, and the reason is measurable.** The status capture has
  to come before it. `trap` is a builtin and a builtin that succeeds sets `$?` to 0, so a
  trap body opening with `trap '' INT TERM HUP` has thrown away the status it was entered
  with before it can read it — measured, bash 3.2: an `EXIT` trap that runs `trap ''` and
  then reads `$?` sees `0` where the shell was exiting `7`, and the same trap with the two
  statements the other way round sees `7`. Since the entry's `E_RUNTIME` refusals are
  exactly the paths whose status the trap must pass through, first place belongs to the
  capture, which is a plain assignment that starts no process and can lose nothing to a
  signal. Everything the ignore is for stands after it, which is why the rule R10 reads is
  a position relative to the cleanup rather than an absolute one: **the `trap ''` line
  comes before the first external command of the trap body.**

  The status it exits with is three cases and no more: `entry_status`, when the main flow
  recorded one — which happens on exactly one path, the forwarded one below, where it is
  the parent's own status; otherwise `128 + signal` for the recorded name, when
  `entry_signal` is set; otherwise the status the trap was entered with, which is the
  normal path and every `E_RUNTIME` refusal. Those three collapse to two numbers in
  practice, because a parent that was forwarded a signal exits `128 + signal` itself (R2)
  and a parent killed by that signal gives the shell the same number. `entry_status` is
  the parent's real status and nothing else: it is taken from the one `wait` that actually
  reaped the parent, never from a `wait` a signal interrupted, which the loop below is
  built to guarantee. A second signal arriving during that wait therefore cannot change
  the entry's exit status — it interrupts a wait whose `128 + signal` is discarded, and
  the number the caller sees is still the parent's own.

  **Creating the run directory, and setting the guard without a producer that can be
  killed.** Three statements, in this order and no other. All three run under the
  `umask 077` the entry set among its first builtins (above), which is what makes the modes
  below the modes that actually appear on disk.

  1. **Refuse a pre-existing `.run` before anything is created.** `[ -e "$run" ]` is
     `E_RUNTIME` — `-e` rather than `-d`, so a file or a symlink of that name refuses too.
     This is what keeps the entry from ever adopting, or destroying, a directory that is
     not its own: the refusal happens with `run_created` unset, and unset is the one state
     in which the `EXIT` trap leaves the disk alone.
  2. **Create it with a plain simple command and keep the status.** `/bin/mkdir -- "$run"`,
     with no `-p`, no `-m` and its exit status captured. It lands at exactly 0700 because
     of the umask, not because the command asks for a mode: `mkdir` requests 0777 and
     `umask 077` takes the group and other bits away, which is why no `chmod` follows it.
     Three cases follow, all decided in the
     main flow:
     - *Status 0.* The directory is the entry's own: `run_created=1`.
     - *A status above 128, with `.run` now present.* `/bin/mkdir` was itself killed by the
       caller's signal to the whole foreground group, after it had already created the
       directory. The pre-check an instant earlier found no `.run`, so the directory is the
       entry's own: `run_created=1`. `/bin/mkdir` exits 0 or 1 of its own accord, so a
       status above 128 is the shell reporting a signal death and nothing else.
     - *Any other non-zero status.* An `EEXIST` from a creator that raced the pre-check, a
       permissions failure, anything else: `E_RUNTIME` with `run_created` left unset, so
       the `EXIT` trap leaves that directory exactly where it found it.
  3. **Only then create `tmp` and `home` inside `.run`** at mode 0700, by the same umask
     and with no `chmod` of their own. A failure of either
     is `E_RUNTIME`, and by then the guard is set, so the `EXIT` trap chmods back to 0700
     and removes `.run` and everything in it on the way out.

  One residual is named rather than hidden. A foreign process that creates an empty `.run`
  in the same instant a terminal signal kills the entry's `/bin/mkdir` would have its
  directory removed by the `EXIT` trap, because the second case above cannot tell it from a
  directory `mkdir` created before it died. That needs a same-uid process writing into the
  caller's mode-0700 output root during the microseconds of one `mkdir`, while a signal
  lands, and it sits inside the same-uid assumption R5 already states; this spec treats it
  no further. It is strictly smaller than the failure it replaces, which lost the guard on
  the entry's *own* directory in that window rather than on somebody else's.

  **The checkpoints.** One small function —
  `checkpoint() { [ -z "$entry_signal" ] || exit; }` — is called wherever the entry would
  otherwise start a fresh piece of work: immediately after the `mkdir` and its guard
  assignment, after each of the ten pin checks, after each of the two compiles, after the
  jq and awk copies, and immediately before the parent is launched. A bare `exit` there
  hands control to the `EXIT` trap, which does the cleanup, writes the line and supplies
  the status — `128 + signal` for the recorded name, because a checkpoint never records an
  `entry_status`. That is the same number every path through this requirement produces.
  The function's test is a read of a set variable at every one of those call sites, and on
  the normal run it is a read of the empty string every time: `entry_signal` is declared
  empty among the entry's first builtins, ahead of the traps (above), which is what keeps
  `set -u` from turning the first checkpoint of a signal-free run into a fatal unbound
  variable. Repeated signals need no handling here at all, which is worth saying so the
  plan does not invent some: a checkpoint exits on the first name it sees, and a second
  signal that lands before that exit, or during the `EXIT` trap that follows it, runs a
  trap body that assigns nothing because `entry_signal` is no longer empty. The status and
  the line are the first signal's in every case.

  **Every external command the entry runs is written in three steps: status, then
  checkpoint, then refusal.** The usual shell shorthand — `cmd || refuse E_RUNTIME`, or
  any `||` that turns a non-zero status straight into an error — is **forbidden** for
  every external command in this entry, and the reason is the same bash rule the
  checkpoints rest on. A `Ctrl-C` at a terminal signals the whole foreground process
  group, so the SHA-1 pipeline, the compile or the `cp` the entry happens to be waiting on
  receives the signal too and dies on it. That command's status is then non-zero *because
  of the signal*, and a refusal written beside the command runs first — before the
  checkpoint ever looks at `entry_signal` — so the caller gets an `E_RUNTIME` line and a
  refusal status where this requirement promises `128 + signal` and one `entry-signal:`
  line. The refusal would be true of nothing: the command did not fail, it was
  interrupted, and hiding the interruption behind a refusal is the one report the caller
  cannot act on, because it names the wrong cause and loses the signal the caller sent.

  So each one is three statements, in this order and no other:

  1. **Run the command and capture its status.** `cmd; status=$?` — the entry runs under
     `set -uo pipefail` with `-e` deliberately not set, so a non-zero status reaches the
     next line instead of killing the shell — or `status=0; cmd || status=$?` where that
     reads better. Either way the status lands in a variable and nothing branches on it
     yet.
  2. **`checkpoint`.** If `entry_signal` is set the entry leaves here, through the `EXIT`
     trap, with `128 + signal` and the one `entry-signal:` line, which is exactly what a
     command that died on the caller's signal should produce whatever status it left
     behind.
  3. **Only then the refusal.** `[ "$status" -eq 0 ] || refuse E_RUNTIME`, or the step's
     own error id where it has one. By this point a non-zero status can only mean the
     command itself failed, because an interrupted run has already left through step 2.

  The same three steps apply to a `$(...)` substitution that runs an external tool — the
  SHA-1 and SHA-256 pipelines and the `uname` and `stat` reads are the ones here: assign
  the substitution's output in its own statement, capture that statement's status,
  `checkpoint`, and only then judge the status. A substitution is a foreground child like
  any other and a group signal reaches it the same way; that is the same lesson the
  withdrawn `run_created=$(…)` guard taught, applied to every command rather than to one.
  The `mkdir` block above already reads in this order, and is written out there only
  because its status test has three cases rather than two — it is the worked example of
  this rule, not an exception to it.

  **The wait on the parent is the last checkpoint, and it is the one that forwards. It is
  a loop, and the loop ends only when the parent has been reaped.** The
  entry records the parent's pid in `parent_pid` the instant it starts the parent, and
  then waits for it like this and not with a fixed number of `wait` calls:

  ```
  last_forwarded=''
  while :; do
    wait "$parent_pid"; status=$?
    if kill -0 "$parent_pid" 2>/dev/null; then
      [ "$entry_signal" = "$last_forwarded" ] || {
        kill -"$entry_signal" "$parent_pid" 2>/dev/null || :
        last_forwarded=$entry_signal
      }
      continue
    fi
    entry_status=$status
    break
  done
  ```

  An earlier round of this spec wrote that as two `wait` calls — one interrupted by the
  signal, one for the parent's real status — and the second of those is not safe from the
  thing that interrupted the first. A second `INT`, `TERM` or `HUP` arriving while it runs
  (the user presses `Ctrl-C` again because the first press did not appear to do anything,
  while the parent is still terminating a stopped resolver, which takes as long as the
  parent's `SIGTERM`-then-`SIGKILL` sequence takes) interrupts it in exactly the same way,
  and it returns `128 + signal`
  rather than the parent's status. Recording that number in `entry_status` and exiting
  would hand the `EXIT` trap its removal of `.run` while the parent — and therefore the
  resolver's process group — was still alive, which is the one ordering this whole
  requirement exists to prevent.

  Each piece of the loop earns its place. **`wait "$parent_pid"; status=$?`** returns for
  one of two reasons and the status alone cannot tell them apart: a wait a trap
  interrupted returns `128 + signal` with the parent still alive, and a wait that reaped
  the parent returns the parent's own status — which, on the forwarded path, is itself
  `128 + signal` for the same signal (R2), so the two are frequently the same number.
  **`kill -0 "$parent_pid"`** is what tells them apart, because it asks about the process
  rather than about the number: a running parent answers, and so does a parent that has
  died but has not yet been reaped, because a zombie still holds its pid; only a pid that
  has actually been reaped fails with `ESRCH`. So a successful `kill -0` means the wait
  was interrupted and the parent is still there — loop round and wait again — and a
  failing one means this `wait` is the one that reaped it, so `status` is the parent's own
  and the loop ends. The intermediate case takes care of itself: a parent that died a
  moment ago is a zombie, `kill -0` succeeds, the loop waits again, and *that* wait reaps
  it and returns the real status. **`entry_status=$status; break`** therefore runs at one
  moment only — after the parent has been reaped — and the `EXIT` trap's removal of `.run`
  can never precede the parent's exit, however many signals arrive.
  Pid reuse is not a risk inside this loop, and the reason is the same zombie: the kernel
  cannot hand `parent_pid` to another process while an unreaped child still holds it, and
  the only thing that reaps it is this `wait`, so every `kill -0` and every `kill` in the
  loop is aimed at the entry's own parent and at nothing else.
  Nothing in the loop is an external command — `wait`, `kill` and `[` are bash builtins,
  so `kill -0` starts no `/bin/kill` process — which is why the three-step rule above does
  not apply to it and why R7's command-word list and R10's grep are untouched by it.

  **Forwarding is once per new signal, and a repeat is not re-forwarded.** The
  `[ "$entry_signal" = "$last_forwarded" ]` test is what makes that true: without it every
  interrupted wait would send another `kill`, so a user holding `Ctrl-C` would produce a
  stream of signals at a parent that is already terminating. Both choices are safe, which
  is worth saying before picking one. Re-forwarding would be harmless — the parent's
  handler `_exit`s on the first signal it takes (R2), so a second `kill` reaches either a
  process that is already inside its final sequence or a zombie, and in the second case
  `kill` fails with `ESRCH`, which the `|| :` discards. Not re-forwarding is harmless for
  the same reason, and it is the one taken here, because it sends the minimum: exactly one
  signal per name the entry has recorded, which is the behaviour a reader can state in one
  sentence. Since the traps keep the *first* name (above), `entry_signal` never changes
  after it is set, so in practice the loop forwards exactly once per run — but the
  comparison is not therefore redundant, because what it suppresses is the re-forward on
  every subsequent interrupted wait, not a second name.

  Nothing is removed before that loop ends, which is the
  ordering the whole requirement exists for. On a forwarded signal the parent's own status
  is the `128 + signal` its handler exits with (R2), and a parent killed rather than exiting
  gives the shell the same number for the same signal, so the entry's status is
  `128 + signal` here too — the *parent's* number, arrived at by the wait that reaped it,
  not the number some interrupted wait returned.

  **This was measured rather than argued, on the same `GNU bash, version
  3.2.57(1)-release` the other measurement in this requirement used.** A script built as
  the loop above describes — three assign-if-empty traps, a child standing in for the
  parent whose own `TERM` handler takes a second to finish terminating its group before it
  exits, and the loop with a line printed at each iteration — was started in the
  background of a driving shell and sent two `TERM`s 0.5 s apart, the second landing while
  the stand-in parent was still inside its handler:

  ```
  entry status=143
  wait 1 returned 143; parent alive=yes; entry_signal=[TERM]
  forwarded TERM to 49256
  wait 2 returned 143; parent alive=yes; entry_signal=[TERM]
  wait 3 returned 143; parent alive=no; entry_signal=[TERM]
  parent marker at entry exit: present
  entry-signal: TERM forwarded 49256
  ```

  (The status prints first for the same reason it does in the other measurement in this
  requirement: the script's stderr went to a file the harness reads back after the entry
  had exited.)
  The second `TERM` interrupted the second wait exactly as predicted — `143` with the
  parent still alive — and the loop went round instead of exiting on it; the third wait is
  the one that reaped the parent, and the marker the stand-in writes as it exits was
  already on disk when the entry left, so the cleanup could not have preceded the parent.
  Nothing was forwarded twice. Two variants were run the same way. With the second signal
  an `INT` rather than a `TERM`, wait 2 returns `130` with the parent alive, `entry_signal`
  stays `TERM`, the `INT` is not forwarded, and the entry still exits `143` — a second,
  differing signal changes neither the line nor the status. And with the stand-in parent
  exiting `42` instead of `128 + 15`, the entry exits `42`, which is the assertion that
  matters most here: the status comes from the wait that reaped the parent and not from
  either of the two that a signal interrupted. (The `INT` variant needs the entry in a
  process group of its own — `set -m` in the driving shell — because a shell starts an
  asynchronous child with `SIGINT` ignored when job control is off, and a signal ignored
  at entry cannot be trapped.) The `kill -0` claim the loop turns on was checked on the
  same machine rather than taken from the manual page: a pid whose child had exited and
  had not been reaped answers `kill -0` and shows state `Z` in `ps`, and the same pid
  fails with `ESRCH` immediately after it is reaped. The same script is re-run against the
  Linux CI image's `/bin/bash` while the plan is written, for the same reason the other
  measurement is.

  **The two branches are `parent_pid` empty or not, and the main flow is what distinguishes
  them.** The traps go on ahead of the `mkdir` that creates the run directory, which is
  well before the pin checks, the two compiles and the launch (the order is fixed below),
  so `INT`, `TERM` or `HUP` can arrive at a moment when `.run` is on disk and there is no
  parent process to forward anything to. That is not a narrow window: ten pin checks and
  two compiles run inside it. With no pid recorded, nothing was launched, so no resolver
  and no process group exist and there is nothing to forward to; the entry reaches its next
  checkpoint and exits `128 + signal`, and the `EXIT` trap removes the run directory — or
  nothing at all, if `run_created` is still unset. A second signal in that window changes
  nothing on this branch either: there is no `wait` for it to interrupt, and the name it
  would record is already taken by the first. With a pid recorded, the forwarding wait
  loop above runs instead. The `EXIT` trap reads `parent_pid` as well, but only to choose which
  of the two words its one line carries; it takes no different action either way, and
  `entry_status` is the only other thing the main flow hands it. The entry
  sets `parent_pid` immediately after starting the parent and never clears it, so the
  no-parent form cannot be written while a parent is alive.

  Both paths exit rather than re-raising the signal, which is a deliberate choice over the
  more idiomatic reset-and-re-raise: an explicit `exit` makes the entry's status on a signal
  the same number in every path through this requirement — `128 + signal`, the same rule the
  normal path already uses for a child that died on a signal — and that number is what R10
  asserts.

  No child of the entry's own is alive when the no-parent removal runs, and the reason is
  bash's own deferral rule rather than anything about process groups. An earlier round of
  this spec said a compiler child "was signalled too" because the caller's signal went to
  the whole foreground group, which is only true of a signal a terminal generates; a plain
  `kill <entry pid>` reaches the entry alone and leaves its children untouched, so that
  sentence was proving the wrong thing. What actually holds is the rule the bash manual
  states under SIGNALS: if bash is waiting for a command to complete and receives a signal
  for which a trap has been set, the trap is not executed until the command completes.
  Every pre-parent child the entry runs — each SHA-1 pipeline, the SHA-256 digest, both
  compiles, the jq and awk copies — runs in the foreground, or inside a `$(...)`
  substitution the entry waits on, so at the moment the checkpoint after that command runs
  the entry has no live child and the removal cannot race one.

  The cost of that is worth stating rather than hiding: the entry acts up to one step late
  — at most one compile, the longest pre-parent step there is — so it keeps working on
  something it is about to throw away. That latency is bounded by that one step and is
  accepted; R10's pre-parent case waits for the entry with a timeout wide enough to cover
  it rather than expecting an instant exit. The requirement the whole argument rests on is
  stated explicitly so the plan cannot drift off it: **the entry runs no pre-parent child in
  the background.** A plan that backgrounds one would have to record its pid and terminate
  and reap it at the checkpoint before anything is removed, and that is not this design.

  The terminal case is the other path to the same place: a `Ctrl-C` at a terminal signals
  the whole foreground process group, so a running compile does get the signal too and
  exits sooner, and the deferred trap still records after it and the next checkpoint still
  acts — earlier than in the `kill` case, not differently. Either way, everything a compile
  writes is inside the directory being removed and no resolver exists anywhere in the
  picture.

  **The entry says which branch it took, on its own stderr, so the branch is
  observable rather than inferred from what it left behind.** Both branches end with the run
  directory gone, and "gone" is not enough to tell them apart: an empty output directory is
  equally consistent with no parent ever existing and with a parent that started and had not
  yet created its sandbox. So the `EXIT` trap writes exactly one line, and only when
  `entry_signal` is set — an exit with no signal behind it writes nothing:

  ```
  entry-signal: <NAME> no-parent
  entry-signal: <NAME> forwarded <pid>
  ```

  `<NAME>` is `INT`, `TERM` or `HUP` — the name the trap recorded in `entry_signal`, not
  its number. The no-parent branch writes the first form; the parent branch writes the
  second with the pid it forwarded to. The line goes out with `printf` to the entry's own
  stderr, never buffered anywhere else — the same channel the parent's `runtime-pgid:` line
  uses (R2) — and it is the **last** thing the `EXIT` trap does before its own final
  `exit`, after the forward and the wait loop that the main flow has already completed
  and after the chmod and the removal.
  That ordering is deliberate and it is the same rule the parent's handler follows: bash's
  `printf` writes to whatever descriptor the caller gave the entry as stderr, and a write
  to a full pipe blocks, so a line written first could hang the entry with the parent still
  alive and the run directory still on disk. Written last, a hung write can only delay the
  exit status; it can never delay the cleanup or the forward. Nothing is lost for the test
  that asserts the line, because R10 reads it from a plain file in the test's own scratch,
  where a write cannot block. It does not conflict with this requirement's claim that the entry passes the
  child's stdout and stderr through unchanged: this is the entry's own line on the entry's
  own stderr, not a byte added to or removed from anything a child wrote — exactly the
  distinction the parent's line already relies on. R10's command-word allowlist is
  unaffected, because `printf` is a bash builtin and pass 2 of that grep drops the builtins
  by name from `compgen -b`. R10's pre-parent case asserts this line, and that assertion is
  the case.

  **The entry's first statements scrub its environment with builtins, and then it re-execs
  itself with an empty one. Only after that does it run any external command.** An earlier
  round of this spec put `/usr/bin/env -i` in front of the pin checks, both compiles and
  the parent launch and stopped there, which is not early enough for a reason worth stating
  plainly: `/usr/bin/env` is itself an external process, so the loader honours the caller's
  `LD_PRELOAD` and `LD_LIBRARY_PATH` on the way to running `env` — the very command that
  was supposed to remove them. Nor is `env` the first external command in that order.
  `/usr/bin/uname` runs for the platform case, `/usr/bin/stat` for the output root's owner
  and mode, and in the order an earlier round used `/usr/bin/git` and `/usr/bin/cc` ran too,
  every one of them an absolute path executed while the caller's loader variables were
  still in the entry's own environment and therefore inherited.

  So the entry begins with a scrub that forks nothing, copied verbatim from the
  materializer's clean entry (`adapters/local-git-materializer/v1/materialize.sh:4-13`):
  `builtin unset -f` over every name `builtin compgen -A function` reports, then
  `builtin unset` over every name `builtin compgen -e` reports except `PATH`, then
  `PATH=/usr/bin:/bin`, `LC_ALL=C` and `export PATH LC_ALL`. Builtins only — no `env`, no
  `uname`, no subprocess of any kind — so there is no window in which an external command
  runs under a caller-set variable. The shebang comes over with it, `#!/bin/bash -p`
  (`materialize.sh:1`), because privileged mode is what stops bash from sourcing `BASH_ENV`
  before the scrub's first line.

  A scrub in the current shell does not undo what the current shell's own loader already
  did, so the entry then re-execs itself under an empty environment, adapting the
  materializer's re-exec (`:22-29`):

  ```
  exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
    /bin/bash -p "$script_path" __resolve_profile_clean "$1" "$2" "$3" "$4"
  ```

  Four named deviations from the copied lines, and nothing else. The marker word is
  `__resolve_profile_clean` in place of `__materialize_clean` (`:25,29`). And the arity
  differs: the materializer's caller-facing shape carries a leading subcommand word, so
  both of its invocations are eight arguments and `$1` alone tells them apart (`:22,25,29`),
  while the entry's caller-facing shape is `<jq> <output directory> <request>
  <repository map>` (below) — four arguments with no subcommand word — so the entry tells
  them apart by count and word together: five arguments whose first is the marker word is
  the clean path, exactly four arguments is the dirty path and re-execs, and anything else
  is `E_USAGE`. That keeps one of the materializer's two properties intact — the re-exec
  cannot re-enter the dirty path, because it always supplies the marker word. The other one
  it does not keep: a caller *can* enter the clean path, by supplying the marker word
  themselves, and the third and fourth deviations below are what this spec does about that.
  The third of the four is the `-p` on the re-exec's `/bin/bash`, where the materializer
  writes a plain `/bin/bash` (`:27`): the entry's shebang is `#!/bin/bash -p` already,
  and the flag is added here so that privileged mode survives the re-exec instead of being
  dropped at the one hop that matters — the hop that lands on the marker branch, which is
  where the fourth deviation then tests for it. It costs nothing else. Under `env -i` there
  is no environment left for privileged mode to refuse, so `-p` changes no behaviour on
  this path; what it changes is that `$-` carries a `p` in the second process, which is the
  fact the branch can act on. Everything
  else is the same:
  `$script_path` comes from `${BASH_SOURCE[0]}` and must be absolute (`:23-24`), and the
  re-exec is an `exec`, so no extra process is left behind. The literal
  `PATH=/usr/bin:/bin` above is not a further deviation: the materializer writes
  `PATH="${PATH:-/usr/bin:/bin}"` there (`:26`), and the scrub has just set `PATH` to
  exactly that value, so the two are the same line with the indirection spelled out.
  Every step this spec describes after this point — the platform case, the output-root
  validation, the pin checks, the compiles, the mode pass, the launch — runs in that second
  process, which was started with an empty environment.

  **The fourth deviation: the marker branch refuses unless it is in privileged mode, and
  only then re-runs the scrub.** Nothing stops a caller from invoking the entry as
  `/bin/bash <entry>
  __resolve_profile_clean <jq> <output> <request> <map>` — five arguments whose first is the
  marker word — and landing on the clean path directly. The marker word is a literal in a
  committed file, not a secret. What such a caller reaches is the clean path running in a
  process whose loader consumed *their* environment, because the re-exec, the only step that
  produces an environment built from nothing, is precisely the step the marker branch skips:
  it is the branch the re-exec arrives on. So the marker branch does not assume it was
  reached through the re-exec — it checks, and the check is its very first statement:

  ```
  case $- in *p*) ;; *) exit 78 ;; esac
  ```

  Both supported invocations set that flag. Executing the file starts bash from the
  `#!/bin/bash -p` shebang; the documented direct form passes `-p` on the command line; and
  the re-exec above now passes it too, which is the third deviation and the reason it
  exists. So the branch's own arrival condition — privileged mode — is true on every path
  this spec supports and false on the one it does not. Measured, bash 3.2 on
  `arm64-apple-darwin`: with a `#!/bin/bash -p` shebang `$-` is `hpB`; with
  `env -i … /bin/bash -p <script>` it is `hpB`; with a plain `#!/bin/bash` shebang or a
  plain `/bin/bash <script>` it is `hB`. And privileged mode is worth having for itself,
  not only as a marker: in the same measurement, a `BASH_ENV` pointing at a file that
  echoes a line and defines an alias is executed under the plain forms and **not** read at
  all under either `-p` form, and an exported function (`BASH_FUNC_evilfunc%%` in the
  environment) is imported under the plain forms and **not** imported under either `-p`
  form. That is the whole shape of the pollution this branch was scrubbing by hand.

  The statement is written the way it is because of what has run before it, which is
  nothing: `case`, `in` and `esac` are reserved words, and `$-` is a special parameter the
  shell maintains itself, so the test itself runs no command and reads no variable the
  entry has not been able to set. The one word in it that is neither is `exit`, a builtin
  and therefore shadowable by a function of that name — which is not patched over here,
  it is the subject of the paragraph after next, and the answer to it is that the only
  arrival that can install such a function is the one this line turns away. `78` is a bare
  literal for the same
  no-state reason — no name has been assigned at that point, and under `set -u` a symbolic
  `E_*` would be an unbound variable — and the number is chosen to be distinct from the
  entry's
  `E_USAGE` and `E_RUNTIME` status and from anything `128 + signal` can produce, so a test
  asserting it cannot be satisfied by an ordinary refusal.

  **Then the scrub, re-run in full, as defence in depth.** Immediately after the refusal
  come `builtin unalias -a` and `builtin shopt -u expand_aliases` — two lines the copied
  bytes do not have, needed because the scrub unsets inherited functions and exported names
  and an alias is neither. They go before the rest because bash expands aliases as it reads
  each command, so the reset has to run before the shell parses what follows. Then the
  builtin scrub itself: `builtin unset -f` over `builtin compgen -A function`,
  `builtin unset` over `builtin compgen -e` except `PATH`, `PATH=/usr/bin:/bin`, `LC_ALL=C`,
  `export PATH LC_ALL`. `builtin` prefixes every one of these, so on any invocation that
  got past the refusal above no function of that name can intercept the reset. The sibling
  specs treat this the same way — #268 and #273 both
  add the alias reset to their own marker branch for the same reason — and the plan should
  keep the three files' wording in step.

  **What that scrub does and does not prove, stated plainly, because an earlier round of
  this spec claimed more for it than it can carry.** On the supported invocations the
  scrub is belt-and-braces over a shell that already refused to read `BASH_ENV` and already
  refused to import functions, and it costs a handful of builtins to have the second layer.
  On the unsupported one — `/bin/bash <entry> __resolve_profile_clean …` from a polluted,
  non-privileged environment — the honest statement is that the refusal is the answer and
  the scrub is not, because in that process a hostile environment gets to act *before* any
  statement of the branch runs and can in principle shadow the refusal itself. Measured,
  same shell: an exported function named `exit` is called instead of the builtin, so the
  `exit 78` runs the caller's code and the branch continues; and a `BASH_ENV` that sets
  `expand_aliases` and aliases the reserved word `case` makes the whole refusal expand to
  something else entirely. Both of those need the plain form — under either `-p` form the
  `BASH_ENV` is not read and the function is not imported, so both attacks are gone before
  they start. This is not a hole being conceded for the first time: it is the same boundary
  the paragraph below draws and the same one the Areas-of-concern bullet on the entry's
  first process has drawn for several rounds — the entry's own loader runs under whoever
  started it, and no statement inside the entry can unrun that. What changes this round is
  that the spec stops describing the marker branch's scrub as proof that hostile functions
  and aliases were removed before validation, and describes it as what it is: a second
  layer on the invocations where the first layer already holds.

  **Then `umask 077`, as the last of the entry's first builtins and before anything at all
  is created.** The scrub above resets variables, functions and aliases; it does not reset
  the process umask, which is not a variable and is inherited across `exec` like any other
  process attribute, so the `env -i` re-exec does not clear it either. That matters because
  every mode this requirement states is a mode a `mkdir` *requests*, and the umask is what
  the kernel subtracts from it. Left alone it breaks the run tree in two opposite
  directions. A permissive caller umask — `umask 000` is the ordinary case, and it costs
  nothing to arrange — makes `/bin/mkdir -- "$run"` create `.run` at 0777 and the `tmp` and
  `home` subdirectories at 0777 with it, so a directory this spec requires to be 0700 is
  world-writable for the whole compile, which is exactly the window in which the compiled
  binaries are written and before the 0500 pass tightens anything. A restrictive one —
  `umask 777` is the extreme, but anything with the owner bits set does it — makes the same
  `mkdir` create a directory the entry cannot then enter or write, so the very next step
  fails and, worse, the `EXIT` trap's removal of a directory it cannot traverse fails with
  it. Setting `umask 077` once removes both: `/bin/mkdir -- "$run"` under it yields exactly
  0700 with no separate `chmod`, and the same holds for the `tmp` and `home` subdirectories
  and for every file the entry creates afterwards. The line is copied, not invented — the
  materializer's clean branch sets the same umask in the same position
  (`adapters/local-git-materializer/v1/materialize.sh:31`), immediately after its own scrub
  and before its first creation — and `umask` is a bash builtin, so it forks nothing and
  keeps its place among the statements that run before the first external command. R10
  asserts the result rather than the line: the mode assertions on the run tree already
  check for 0700, and one case runs the entry with the caller's umask set to `000` and then
  to `777` and requires 0700 both times.

  **And the direct marker invocation is unsupported, which is the part that actually settles
  it.** There are two supported ways to run the entry: execute the file, so its
  `#!/bin/bash -p` shebang is what starts bash, or
  `env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p <entry> <jq> <output> <request> <map>`.
  Invoking the marker word directly is neither, this spec makes no safety claim about it,
  and R9's documentation says so: the marker exists so the re-exec has somewhere to arrive,
  not as a public entry point. What the branch does about it is the refusal above, and the
  refusal draws the line in the one place a reader can check: a marker invocation carrying
  `-p` is inside the boundary, because privileged mode is exactly the condition the
  supported forms create and the polluted direct form cannot; a marker invocation without
  it exits 78 having created nothing and read nothing. It is worth being plain about what
  the caller who gets past that gains —
  nothing beyond their own process, which they already control. The environment they can
  pollute is the environment of a process they started themselves, and every claim this spec
  makes further in still holds: the parent is launched under `/usr/bin/env -i` and the
  resolver's environment is built from empty (R3). The re-scrub is defence in depth on the
  invocations the refusal admits; the refusal and the unsupported-form statement are the
  answer to the door existing at all.

  **No nonce, and one sentence on why.** The obvious-looking fix — the dirty path mints a
  random token, passes it through the environment, and the clean path refuses unless the
  token matches its argument — is theatre, because the same caller who can supply the marker
  word supplies both sides of that comparison, so it would add a check that refuses nobody
  while reading like a lock.

  **The residual, stated plainly: the entry's own first process is not covered by any of
  this.** The caller started that process, so its loader read the caller's `LD_PRELOAD` and
  `LD_LIBRARY_PATH` and mapped whatever they named before the entry's first line ran. The
  injected code has already run by then; the builtin scrub keeps it from spreading to
  anything the entry starts, and it is not a way to unrun it. So the entry must itself be
  started by a trusted process — the operator's own shell, or the trusted lane — exactly as
  the parent must, and for exactly the same reason. R10's marker-library test is written to
  claim no more than that: it asserts that nothing below the entry's first process records
  the marker, and it does not assert that the first process is clean. The `/usr/bin/env -i`
  prefixes on the pin checks, the compiles and the parent launch stay where they are even
  though the re-exec has already emptied the environment, because each of them names the
  variables that command is meant to have rather than trusting a scrub upstream to have
  been complete.

  The entry takes the jq 1.6 binary as a positional argument, exactly as
  `shadow/v1/reproduce.sh` takes it (`shadow/v1/reproduce.sh:74` binds `caller_jq` from
  argv, `:82` requires an executable regular non-symlink file, `:113-118` picks the
  per-platform pinned SHA-256 and refuses a mismatch). The entry does the same: absolute
  path, regular, non-symlink, executable, SHA-256 equal to this platform's pin, and it
  answers `jq-1.6`. Missing binary, unreadable binary, or any mismatch → one `E_RUNTIME`
  line on stderr and a non-zero exit. There is no download, no cache lookup, no PATH
  search and no fallback anywhere in the shipped path. Provisioning the pinned jq is the
  caller's job; `scripts/test/shadow-slice.test.sh:24-51` is the way to do it — platform
  case, download verified against these same two digests, copied into a mode-0700
  directory, `--version` confirmed — and the focused test provisions it exactly that way
  before invoking the entry.

  The entry also owns helper provenance, because the parent only ever receives a path
  (`portable-profile-resolution-launcher.c:632-636,679`). Before compiling, the entry
  computes the git blob ids of `resolver/v1/nofollow-snapshot.c` and
  `resolver/v1/trusted-launch.c` and compares them against blob ids pinned as constants in
  the entry, the way the runtime pins its own dependencies
  (`scripts/lib/profile-resolution.sh:7-10,711-717`). It computes them rather than running
  `git hash-object`, for a reason the Darwin toolchain paragraphs below set out: neither
  shipped file runs `git` at all. In the same pass it pins the whole
  set of files the runtime itself loads, which R5 enumerates: the runtime script, the
  library it sources, the resolver jq program, and the five jq modules the core contract
  imports. Pinning the whole set is the entry's job alone; the parent later re-checks only
  the first three of them (the parent-pinned subset, R5). The pinned constants carry a
  `# pinned at <commit>` header naming the commit they were read from, and the focused
  test asserts they equal the working tree's blob ids, so a source edit that forgets the
  pin fails CI rather than shipping. A mismatch on any of them is `E_RUNTIME` before any
  compile.

  **The run directory lives inside the caller's output directory, so the caller's output
  path is the only write root.** The entry's positional arguments are
  `<jq> <output directory> <request> <repository map>`, and the run directory for this
  invocation is `<output>/.run`: created with a plain `/bin/mkdir` — no `-p`, so an
  existing `.run` is refused with `E_RUNTIME` rather than adopted, by an `[ -e ]` check
  ahead of the `mkdir` and by the `mkdir`'s own `EEXIST` behind it — at mode 0700, owned by
  the current uid, with a `tmp` subdirectory at mode 0700
  inside it for the compiler's scratch files, and removed by the `EXIT` trap — which is
  installed ahead of that `mkdir` rather than with it, for the reason given below — before
  the entry exits. It is deliberately **not** `mktemp -d` under the caller's `TMPDIR`, which is what
  an earlier round of this spec said: a run directory there is a second write root, and the
  intent allows exactly one — "no writes outside the caller's own output"
  (`work/resolver-trusted-parent/intent.md:36`). The name is fixed rather than random
  because a fixed name is what lets the parent check containment: the parent requires the
  output directory to hold no entry but `.run`, and requires that entry to be the very run
  directory it was handed (R5).

  Because `<output>` comes from the caller and every path inside the run directory is built
  from it, the entry refuses an output path too long to hold one. Before the `mkdir` it
  checks once that `<output>/.run/tmp/` plus a maximum-length file name still fits inside
  `PATH_MAX` — reserving `NAME_MAX` rather than any one name, because the compiler chooses
  its own intermediate names — and refuses with `E_RUNTIME` if it does not. That guard is
  the entry's own and is stricter than the parent's copied
  `strlen(sandbox) > PATH_MAX - 16` (`:641`), which reserves only enough room for
  `<output>/child.stdout`.

  **The entry validates the output root before it writes anything into it.** An earlier
  round of this spec left emptiness, mode and ownership to the parent alone, which put them
  in the wrong order: the entry created `<output>/.run`, compiled two binaries into it and
  copied jq and awk in, and only then did the parent look at the directory all of that had
  been written to. A caller who named a directory that should have been refused — one that
  is really a symlink somewhere else, one that is group-writable, one that already holds
  files, one owned by somebody else — got the writes first and the refusal second. So the
  entry checks the output root itself, first, and refuses with `E_RUNTIME` before creating
  anything at all. In order: the argument is an absolute path; it passes the `PATH_MAX`
  guard above; it is a directory and not a symlink, with no symlink in any component —
  `[ -d ]`, `[ ! -L ]`, and `(cd -P "$out" && pwd)` equal to the argument itself, which also
  refuses a relative path, a trailing slash and any `.` or `..` component, so the caller
  names the path exactly; it is owned by the current uid; its mode is exactly 0700; and it
  is empty. Ownership is checked before mode, so a directory belonging to somebody else
  refuses on ownership even when its mode is also wrong. Only after all of that does the
  entry create `<output>/.run`.

  **And the scratch directories come before the pin checks, not after.** An earlier round of
  this spec ran the pin checks under the
  `env -i … TMPDIR=<output>/.run/tmp HOME=<output>/.run/home` line quoted below and created
  `.run` only afterwards, so neither of those two directories existed when the first
  pin check was told to use them. A `TMPDIR` or a `HOME` naming a directory that is
  not there is not a refusal; it is a quiet fallback, and what the tool does instead —
  fail obscurely, or write somewhere the spec has just promised it will not — is the
  toolchain's choice rather than the entry's. So the order is fixed here, and every later
  section uses it: validate the output root; install the traps; refuse a pre-existing
  `.run`; create `<output>/.run` and
  then its `tmp` and `home` subdirectories at mode 0700; run the pin checks; run the two
  compiles; empty and remove `tmp` and `home` and tighten the modes; launch the parent —
  with a `checkpoint` call after the `mkdir`, after each pin check, after each compile,
  after the copies and immediately before the launch (above), and with every one of those
  external commands written status first, checkpoint second, refusal third, never
  `cmd || refuse` (above). The
  only refusals that happen before anything is written are the output-root validations
  above. Every refusal after them — the pin checks included — happens with `.run` already on
  disk, which is why the traps are installed ahead of the `mkdir` rather than after the
  pins, and why R10 counts a pin-check refusal as cleanup evidence rather than as a
  nothing-was-created case.

  **The cleanup trap is armed the instant `.run` can exist, which means before the `mkdir`
  and not with it.** An earlier round of this spec said the trap was installed "with the
  `mkdir`", and the sequence that came out of that phrase ran the `mkdir` first, then
  created `tmp` and `home` inside `.run`, and only then executed the `trap` line. Three
  things can happen in that gap and every one of them leaves the caller's output root
  dirty with nothing registered to clean it: the `mkdir` of `tmp` can fail, the `mkdir` of
  `home` can fail, and `INT`, `TERM` or `HUP` can arrive while `.run` is already on disk
  and the three signals still carry their default disposition. The entry would then refuse
  or die with a `.run` directory it created itself and no `EXIT` or signal path to remove
  it — the one outcome the trap exists to prevent, in the one window where the trap was
  missing. So the four statements of this step run in this order and no other: install the
  traps, refuse a pre-existing `.run`, create the directory and set the guard from its
  status, create `tmp` and `home`. The three creation statements and the guard rules are
  specified above with the signal design they belong to; what this step adds is why the
  `trap` line comes first.

  **Install the `EXIT`/`INT`/`TERM`/`HUP` traps before anything creates `.run`.** The
  removal is inside the `EXIT` trap, guarded by `run_created`, which is unset until the
  directory is known to be the entry's own, so a trap armed before or during the `mkdir`
  removes nothing. That guard is not a detail: without it the `EXIT` trap would delete a
  pre-existing `.run` that the entry refused rather than adopted, which turns a refusal into
  a destructive act on a directory whose contents the entry does not own. Nothing before
  the `trap` line has written anything — the output-root validations above are a `stat`, a
  glob and a `cd -P` — so a signal that lands earlier still finds the default disposition
  and still leaves nothing behind. Pins, compiles, tighten and launch follow in the order
  above, unchanged, each with its `checkpoint` after it.

  The design was measured before being written here rather than assumed, on
  `GNU bash, version 3.2.57(1)-release`, the `/bin/bash` a Darwin machine ships. A script
  built exactly as this step describes — recording traps, an `EXIT` trap guarded by
  `run_created`, a `[ -e ]` pre-check, a creating command whose status is captured, then
  `checkpoint` — was run in its own process group and sent `TERM` while the creating
  command was still running, so the command was killed rather than completing:

  ```
  entry status=143
  Terminated: 15
  mkdir-status=143 run-exists=yes
  run_created=[1] entry_signal=[TERM]
  entry-signal: TERM no-parent
  --- output dir contents:
  (count: 0)
  ```

  (The status prints first because the script's stderr was redirected to a file the
  harness reads back after the entry has exited.)

  The directory existed, the producer was dead, the main flow adopted it from the status
  and the `[ -e ]` pre-check, and the `EXIT` trap removed it — the case the withdrawn
  command-substitution guard lost. The same script sent a plain `kill` to the entry alone
  reports `mkdir-status=0` and cleans up identically, which is the deferral rule: the trap
  did not run until the foreground command completed. A pre-existing `.run` holding a
  foreign file refuses with `run_created` unset and the file is still there afterwards, and
  a racing creator — `mkdir` returning status 1 on an existing directory — refuses the same
  way, so the two destructive mistakes are both closed. What is *not* measured is the one
  thing that cannot be timed: a `kill -TERM` landing on a real `/bin/mkdir` between the
  `mkdirat` it makes and its own exit. The stand-in above makes that window reachable; that
  `/bin/mkdir` itself would report `128 + signal` there is reasoning from bash's documented
  status rule and from `mkdir` exiting 0 or 1 of its own accord, not a measurement. The
  plan re-runs the same script against the Linux CI image's own `/bin/bash` while writing
  this step, because that is the other `/bin/bash` the entry ever runs under. R10 does not
  turn any of this into a test case, for the reason its cleanup block gives.

  Two of the output-root checks above need a mechanism worth naming. Emptiness is a glob,
  not a command:
  `shopt -s dotglob nullglob` and then a glob of `<output>/*` into an array that must have
  no elements, which sees dotfiles and needs neither `find` nor `ls`. Owner and mode come
  from a single `/usr/bin/stat` call whose format flags differ per platform — `-c '%u %a'`
  on Linux, `-f '%u %Lp'` on Darwin — chosen in the same `case` that chooses the jq digest
  pin and the SHA-256 tool, and compared against bash's own `$EUID` and the literal `700`.
  So `/usr/bin/stat` becomes a command word the entry runs (R7's list and R10's grep both
  say so), and the per-platform format becomes a fourth per-platform table that the
  platform `case` has to agree with (R10).

  **The parent still checks the same facts, and that is deliberate.** The entry's checks are
  path-based — a `stat` and a glob against a name — so a same-uid process can change the
  directory between the entry's look and anything that follows. The parent's are `fstat`
  calls on a descriptor it opened itself with `O_DIRECTORY|O_NOFOLLOW` (R5), which is the
  authoritative pass and the one group 2 proves. The entry's copy is the cheap early refusal
  that keeps a bad output root from being written to at all; the parent's is defence in
  depth, plus the one fact the entry cannot check because it does not exist yet when the
  entry looks — that `.run` is the only entry in the directory and is the very run directory
  the parent was handed (R5). The same rule in two places is accepted here, where the
  earlier round refused it, because the two places check it at different times against
  different objects, and the earlier order bought that tidiness with writes into a directory
  that should have been refused.

  The entry compiles both C
  files from those pinned sources into the run directory with the fixed flags
  (`portable-profile-resolution.test.sh:146-149`), with `-o` naming a path inside the run
  directory and with the compiler's own `TMPDIR` pointed inside it, so that the compiler's
  intermediates — preprocessor output, assembler input,
  temporary object files — land inside the run directory and are removed by the same
  cleanup that removes everything else, rather than being left in the caller's `TMPDIR`
  where nothing tracks them. Passing `-pipe` as well is preferred wherever the compiler
  accepts it, because it keeps most intermediates off disk altogether; it is not required
  and the entry must work without it.

  **The blob id is computed, not asked for, so neither shipped file runs `git`.** A git
  blob id is a SHA-1 over a short header and the file bytes — `blob <size>\0`, then the
  content — and nothing about it needs git to be installed. So both shipped files compute
  it. The size comes from the platform's `stat` format in the entry (`-c '%s'` on Linux,
  `-f '%z'` on Darwin, the same `case` that already chooses the owner-and-mode format) and
  from `fstat` in the parent, which needs no `stat` process at all. The digest comes from
  the platform's SHA-1 tool at a fixed path — `/usr/bin/sha1sum` on Linux,
  `/usr/bin/shasum -a 1` on Darwin — the same pairing, and the same `case`, as the SHA-256
  tool the jq digest already uses. The entry's construction, verbatim:

  ```
  /usr/bin/printf 'blob %d\0' "$size" | /bin/cat - "$file" | <sha1 tool>
  ```

  and the blob id is the first field of that output, taken with a bash parameter expansion
  the way the SHA-256 digest already is. The parent does the same thing without `cat` or
  `printf`: it has the size from its own `fstat` and writes the header and then the file
  bytes to the tool's stdin itself.

  Reading the file twice — once for its size, once for its bytes — is safe here, and the
  reason is worth stating rather than assuming. If the two reads disagree, the computed id
  cannot match the pinned constant, because the size is inside the hashed header. The only
  outcome of a mid-check swap is therefore a refusal, never a pin that passes on the wrong
  bytes. The construction fails closed.

  Why compute it instead of running the tool built for it: `git hash-object` means a git
  subprocess, and on Darwin `/usr/bin/git` is the Apple toolchain shim, which writes a
  cache outside the caller's output path (below). Dropping git is what lets R7 keep its
  one-write-root claim with no platform exception, and it removes the largest dependency in
  the entry's trust base for a job that is nine bytes of header and a hash. `/usr/bin/git`
  is therefore not a command word either shipped file contains, and R10's allowlist grep
  enforces that. The focused test still runs git — it asserts the computed id equals
  `git hash-object`'s answer for every pinned file, which is what keeps this construction
  honest (R10).

  **The pin checks and both compiles run under an explicit, otherwise empty environment.**
  Ignoring `$CC` is not enough. Every C compiler here reads a dozen variables the caller
  controls,
  and several of them change what actually gets compiled: `CPATH` and `C_INCLUDE_PATH` add
  include directories searched *before* the system ones, so a caller can put their own
  `stdio.h` ahead of the real one; `LIBRARY_PATH` does the same for the link; `SDKROOT`,
  `DEVELOPER_DIR` and `MACOSX_DEPLOYMENT_TARGET` redirect the whole toolchain on Darwin.
  None of that is caught by pinning a source blob, because the source is exactly what the
  pin says and the headers it pulls in are not. So the entry names the whole environment
  instead of clearing parts of it. The compile line, verbatim, for the parent — the helper's
  is the same line with the other source and another `-o` name:

  ```
  # Linux
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
    TMPDIR=<output>/.run/tmp HOME=<output>/.run/home \
    /usr/bin/cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -o <output>/.run/trusted-launch <repo>/resolver/v1/trusted-launch.c

  # Darwin
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
    TMPDIR=<output>/.run/tmp HOME=<output>/.run/home \
    /Library/Developer/CommandLineTools/usr/bin/clang \
    -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -o <output>/.run/trusted-launch <repo>/resolver/v1/trusted-launch.c
  ```

  `-pipe` is appended to that line wherever the compiler accepts it. Four variables and no
  others: `PATH` because the compiler execs its own assembler and linker, `LC_ALL=C` so
  diagnostics are stable, `TMPDIR` so intermediates stay inside the one write root, and
  `HOME` so nothing the toolchain does reaches the caller's real home directory. `TMPDIR`
  is not decorative: run the Darwin line above with it unset and `clang -v` shows the
  `-cc1` stage writing its object file into the per-user temp directory, which is exactly
  the write the entry exists to prevent. `HOME`
  needs a directory to point at, so the entry creates `<output>/.run/home` at mode 0700
  beside `tmp`, and removes both before the mode pass. The pin checks run
  under the same line (with the SHA-1 pipeline in place of the compiler), for the same
  reason:
  a caller-set `HOME` or `TMPDIR` should not reach anything the entry runs.
  `/usr/bin/env` is therefore a command word the entry runs, and R7's list says so.

  **Darwin's compiler is the CommandLineTools clang, and no `xcrun` shim runs at all.**
  `/usr/bin/cc` on Darwin is the `xcrun` shim, and the shim is the problem rather than the
  SDK: before running the real tool it writes a tool-lookup cache in a place the entry
  cannot name or redirect, which is a write outside the caller's output path and would cost
  R7 its single-write-root claim. An earlier round of this spec accepted that as a Darwin
  residual. It does not have to be accepted, because the shim does not have to be run. What
  follows was measured on a Darwin 27 machine rather than argued.

  First, what the cache is, since that earlier round had it wrong twice over. It is a
  single file, `xcrun_db`, in the *per-user temp directory* — the one
  `confstr(_CS_DARWIN_USER_TEMP_DIR)` reports, `/var/folders/<...>/T/`, mode 0600 — and the
  `TMPDIR` in the compile line does not move it: run `/usr/bin/xcrun --find <tool>` under
  `env -i PATH=/usr/bin:/bin TMPDIR=<scratch>` for a tool name the cache did not already
  hold, and the file under `/var/folders` grows while the scratch directory stays empty.
  The documented control does not help either. `xcrun(1)` has `-n, --no-cache` with the
  environment equivalent `xcrun_nocache`, and the environment form is the one to reach for,
  because the manual page says the command-line options cannot be used when the shim stands
  in for another tool — but `--no-cache` is documented as causing "the cache entry to be
  refreshed", and that is what it does: a warm-cache compile through `/usr/bin/cc` wrote
  nothing to `xcrun_db`, while the same compile with `xcrun_nocache=1` grew the file on
  every run. Setting it would turn an occasional write into a guaranteed one.

  Second, and this is the way out: there is a real compiler beside the shim, and it can be
  invoked directly.

  - `/usr/bin/cc`, `/usr/bin/clang` and `/usr/bin/ld` are all one file. `ls -li` reports
    the same inode for all three, with dozens of links, and `file` reports a universal
    binary of three architectures. That single file is the shim, and `/usr/bin/git` is the
    same inode again.
  - `/Library/Developer/CommandLineTools/usr/bin/clang` is a different file and a real
    compiler: a distinct inode, and `file` reports `Mach-O 64-bit executable arm64` — one
    native architecture, not the shim's three.
  - Invoked under `env -i` it compiles and links a trivial C file, and `xcrun_db` is
    untouched across the run: same mtime, same size, same SHA-1 before and after.
    `clang -v` shows why — it execs `/Library/Developer/CommandLineTools/usr/bin/ld`, its
    own linker, by absolute path and at its own distinct inode, never `/usr/bin/ld`. No
    shim appears anywhere in the process tree, so there is nothing to write the cache.
  - One condition, and it is not optional: it needs `-isysroot`. Without it the link fails
    with `ld: library 'System' not found`, because locating the SDK is precisely the job
    the shim was doing. With
    `-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` the compile succeeds
    and the resulting binary runs.

  So on Darwin the compiler is the fixed path
  `/Library/Developer/CommandLineTools/usr/bin/clang`, and the compile line carries the
  fixed `-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`. Both are named by
  the entry and neither is ever taken from the caller: `SDKROOT` and `DEVELOPER_DIR` are
  still absent from the environment, and now nothing in the process tree would read them if
  they were there. On Linux the compiler stays `/usr/bin/cc`, where it is a real compiler,
  and there is no `-isysroot`. The compiler path and the flag join the per-platform `case`
  beside the jq digest and the `stat` formats.

  A note on the SDK path, because it is a symlink:
  `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` points at the versioned directory
  the installer maintains (`MacOSX27.0.sdk` on the probed machine). The entry names the
  stable unversioned path so the line survives a tools update, and checks it for existence
  only. It is under `/Library` and root-owned; a caller who can write there has already
  won, and no mode check the entry could add would change that.

  **If the Command Line Tools are absent the entry refuses, and does not fall back.** When
  `/Library/Developer/CommandLineTools/usr/bin/clang` is missing or not executable, or the
  SDK directory is not there, the entry exits `E_RUNTIME` with a message naming the missing
  path and saying the Command Line Tools are the prerequisite. `xcode-select --install` is
  the documented way to get them, and installing them is the operator's job, not the
  entry's. Falling back to `/usr/bin/cc` is the one thing that must not happen: it would
  put the shim back in the path, and with it the write R7 no longer admits. This is a new
  refusal reason on Darwin and a new documented prerequisite (R9).

  **What this buys: the one-write-root claim holds for everything this initiative adds, on
  both platforms.** Taking the shim out of the compile is only half of it, because
  `/usr/bin/git` is that same single inode — ten `git hash-object` pin checks would have
  reached the same cache the compiles used to. That is why the blob ids are computed
  instead (above), and why neither the entry nor the parent runs `git` at all. What it does
  not buy is the runtime: the runtime runs `/usr/bin/git` for itself, this spec leaves the
  runtime unchanged, and on Darwin that is the one write outside the caller's output path
  that remains. R7 states that residual in full, and DR-2 accepted it: the operator decided
  it on 2026-09-10, and the intent now names it as the one accepted exception to its
  write-root constraint (`work/resolver-trusted-parent/intent.md:36-45`, quoted in R7).
  Linux CI still cannot exercise any of this: the Darwin compile line, the refusal when the
  tools are absent, and the cache measurement are confirmed only when someone runs the
  focused test on a Darwin machine. R10 gives the operator the recipe for that measurement,
  and the platform note and the plan both say the other two are operator-confirmed.

  The entry then copies in the bound jq and the platform's awk, and then — only after both
  compiles have finished — empties and removes the `tmp` and `home` subdirectories and
  tightens modes
  before anything is launched: every file in the run directory (the compiled parent, the
  compiled helper, the jq copy, the awk copy) is
  set to mode 0500, and the run directory itself is set to mode 0500. The order is
  load-bearing: compilation happens while the run directory is still 0700 and writable,
  and the 0500 tightening happens strictly afterwards, so the compiler is never asked to
  write into a directory that admits no new entries. Removing `tmp` and `home` before the
  tightening is what keeps the R5 checks simple — at launch the run directory holds only
  those four files and no subdirectory. A 0500 directory admits no new entries and no
  renames, and
  0500 files admit no writes, so from that
  moment nothing in the run directory can be added, replaced or overwritten without a
  `chmod` first. This is a deliberate deviation from the test, which uses 0555 for the
  copied jq and awk (`portable-profile-resolution.test.sh:130-143`); 0500 is the same
  minus the group and other bits, which nothing in the shipped path needs. Only after
  the mode pass does the entry launch the parent, handing it the helper path inside that
  directory along with the directory itself.

  **The parent is launched under an explicit empty environment as well** —
  `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C` and nothing more. That is stronger than the
  named clearing of `LD_*`, `DYLD_*`, `BASH_ENV` and `ENV` an earlier round asked for, and
  it is the only place the loader-variable claim can be made about the parent at all: those
  variables are read by the dynamic loader and acted on before the parent's `main` is
  entered, so no code the parent contains can defend against them and only the process that
  starts it can (R10, and the boundary note under Areas of concern). By the time this line
  runs, the environment it is emptying is already the scrubbed one the re-exec above
  produced; the `-i` is here because this command's environment should be named where it is
  launched, not because anything is expected to be left in it. The parent needs no `HOME`
  and no `TMPDIR` of its own: it builds the resolver's environment from empty (R3), and its
  own two helper
  commands — the platform's SHA-1 tool, which it feeds the `blob <size>\0` header and then
  the file bytes for a blob-id pin, and the platform's SHA-256 tool, for the jq digest —
  each write a digest to
  stdout.
- **R2 — the launch is copied, not reinvented.** The parent `execve`s the fixed path
  `/bin/bash` with argv `{"/bin/bash", <runtime>, "resolve", <request>, <map>}`
  (`portable-profile-resolution-launcher.c:652-657,701`), supervises the child the same
  way (`:400-532`), and applies the same limits. Every C block taken from the test
  launcher carries the repo's copied-from header naming the file and commit, the way
  `loop/v1/review-fix-planner.jq:1-3` does. Every deviation from the copied source is
  named in a comment and in the plan; R4 and R5 are the known ones, and so is the signal
  handling below.

  **Signals: the parent owns process-group termination, and this is new code, not a copy.**
  The resolver runs in its own process group — the child calls `setpgid(0, 0)`
  (`portable-profile-resolution-launcher.c:440`) and the supervisor sets it from the parent
  side as well (`:450`) — and the test launcher installs no signal handler at all.
  `<signal.h>` is included (`:7`) only for `kill` and the `SIG*` constants; there is no
  `sigaction`, no `signal()` and no `sigprocmask` call anywhere in the file — none of the
  three names appears in it, which is why the mask discipline below is new code too; the only group kill is on the
  limit paths (`kill(-child, SIGKILL)` at `:491`, then `kill(child, SIGKILL)` at `:492`,
  reaped at `:493-494`). So a `TERM` to the launcher kills the launcher on the default
  disposition and leaves the resolver's whole process group running, orphaned. That is
  harmless in a test that runs to completion; in the shipped path it means an entry that
  killed only its direct child would delete the run directory — the compiled helper,
  the jq copy, the awk copy — from under a live resolver.

  So the shipped parent adds handlers for `INT`, `TERM` and `HUP` that send `SIGTERM` to
  the child's process group (`kill(-pgid, SIGTERM)`), wait briefly, send `SIGKILL` to the
  same group, reap the child, and exit `128 + signal`. The `SIGKILL` is not a
  belt-and-braces second try; it is required. A member of that group may be stopped — R10's
  signal test stops the whole group on purpose to make the test deterministic — and a
  stopped process does not act on `SIGTERM` until something continues it, while it dies to
  `SIGKILL` either way. The parent owns all of this because the parent is the only process
  that knows the group id. The entry's part is to forward the
  signal and wait (R1); it never terminates the group itself and never removes the run
  directory before the parent has exited.

  **Each of the three handlers blocks all three signals while it runs, not only the one
  that was delivered.** POSIX adds just the delivered signal to the mask for the duration
  of its handler, so on the default terms a `HUP` can run this handler while a `TERM` is
  part-way through it — and this is not a handler that could survive that. It reads and
  writes the shared `pgid` and `pre_child`, it kills a process group, and it reaps a child
  the outer run is already reaping. So each of the three `sigaction` installations sets
  `sa_mask` to the same set — `SIGINT`, `SIGTERM` and `SIGHUP`, all three, not only the one
  being installed — and a sibling signal that arrives mid-handler is held until the handler
  returns. It never returns: every branch below ends in `_exit(128 + signal)`, so the held
  signal is still pending when the process goes away and is discarded with it. The handler
  therefore runs at most once in the life of the parent, which is the property every other
  paragraph in this block is written against. Two flags go with that and are stated so the
  plan does not have to choose: `SA_RESTART` is **not** set, because nothing in the parent
  needs a slow call resumed after the handler — the handler does not return to it — and
  `SA_SIGINFO` is not needed, because the handler uses the signal number and nothing else a
  `siginfo_t` would carry. Blocking is the whole of the protection here: nothing in the
  handler is written to be correct if it runs twice.

  **The handler has to work before any runtime process group exists, and that window is
  most of the parent's life.** The entry records the parent's pid the instant it starts the
  parent and forwards from that moment on (R1), but the parent does not fork the resolver
  first: it runs its own pre-resolver work ahead of the `fork` — the blob-id pins for the
  three files of the parent-pinned subset, the jq SHA-256 digest and the `jq-1.6`
  `--version` probe (R5, R7) — and every R5 refusal happens in that same stretch. So a
  forwarded `TERM` can reach a parent that has no child process group at all. Written as
  `kill(-pgid, SIGTERM)` with nothing guarding it, that handler would signal whatever
  `-pgid` happened to name, and with `pgid` unset or zero that is not the resolver: it is
  the caller's own process group. The requirement is therefore stated as two variables and
  three branches rather than left to the plan.

  - `pgid` is a `volatile sig_atomic_t` initialised to `0` and assigned in the parent
    immediately after the `fork` (`portable-profile-resolution-launcher.c:432`) and the
    parent-side `setpgid(child, child)` (`:450`) — and those three statements are the whole
    of the blocked-signal region the next block specifies. Nothing else goes in there, and
    the `runtime-pgid:` line below in particular is written after the mask is restored
    rather than inside the region with them. So the line and the variable are not published
    in the same instant, and they do not need to be: what a reader needs from them is the
    order, and the order holds either way. The variable is set before the line goes out, so
    a reader who has seen the line knows the handler will take the group branch, and a
    handler that runs in the gap between the restore and the line still finds `pgid` set and
    kills the group.
  - `pre_child` is a second `volatile sig_atomic_t` holding the pid of the pre-resolver
    child that is running right now: each SHA-1 tool invocation, the SHA-256 tool, and the
    jq `--version` probe. It is set in the parent immediately after that child's `fork`,
    inside the same blocked-signal region, and before the `waitpid` on it, and cleared
    back to `0` once the `waitpid` returns, so at most one pid is ever live in it and it
    is `0` whenever no pre-resolver child exists.

  **Two variables are not enough on their own, because a signal can land between a `fork`
  and the assignment that publishes what it returned. So the parent blocks the three
  signals across every fork and its publication.** `fork` returns in the parent before any
  statement can record its value, and the handler reads only the variables. An `INT`,
  `TERM` or `HUP` delivered in that gap therefore sees `pgid == 0` and `pre_child == 0`,
  takes the nothing-to-kill branch, writes `parent-signal: <NAME> no-runtime` and
  `_exit(128 + signal)` — leaving the child it has just forked running, and, when that
  child is the resolver, leaving it running while the entry's wait returns on a parent that
  is gone and its `EXIT` trap removes `.run` from under it. That is the exact failure this requirement exists to
  prevent, reached through a window a few instructions wide.

  The window is closed by blocking, because no ordering of statements can close it. Before
  **every** `fork` the parent performs — the resolver's
  (`portable-profile-resolution-launcher.c:432`) and each pre-resolver child's: the SHA-1
  tool for each of the three blob-id pins, the SHA-256 tool for the jq digest, and the jq
  `--version` probe — the parent blocks `SIGINT`, `SIGTERM` and `SIGHUP` with
  `sigprocmask(SIG_BLOCK, &three, &saved)`, keeping the previous mask in `saved`. In the
  parent after `fork` returns, in this order: `setpgid(child, child)` (`:450`, the
  resolver's fork only); assign `pgid = child` for the resolver or `pre_child = child` for
  a pre-resolver child; then `sigprocmask(SIG_SETMASK, &saved, NULL)`. A signal that
  arrived while the three were blocked is delivered at that restore, when the handler
  already reads the published id and takes the branch that kills the child that exists.
  The forked-but-unpublished state is never observable by a handler, because no handler
  runs while it holds.

  **Nothing else belongs inside that region, and the `runtime-pgid:` line in particular is
  written after the restore rather than before it.** An earlier round of this spec put the
  line inside the block, between the `pgid` assignment and the unmask, which read tidily —
  the variable and the line becoming true in the same breath — and it was wrong for the same
  reason the handler's own line goes last: a write to stderr can block. If stderr is a pipe
  nobody is draining, or is full at that moment, that write waits with `INT`, `TERM` and
  `HUP` still blocked, so a forwarded `TERM` cannot run the handler at all — and the
  resolver group keeps running while the entry waits on a parent stuck in a diagnostic and
  `.run` stays on disk. That is the same failure the whole requirement exists to prevent,
  reached this time through the one statement in the region that has no business being
  there. So the order is `fork`, `setpgid`, assign, restore, **then** write; the write is
  also best-effort rather than blocking, in the way the line's own block below states; and
  the region is left holding only statements that cannot block.

  **In the child, after `fork` and before `execve`, both the dispositions and the mask are
  put back — and the order between them is fixed: dispositions first, while the three
  signals are still blocked, and the mask last.** Concretely: with the inherited block
  still in place, the child calls `sigaction` (or `signal`) on `SIGINT`, `SIGTERM` and
  `SIGHUP` with `SIG_DFL`, and it resets `SIGPIPE` to `SIG_DFL` with them, because the
  parent leaves that one at `SIG_IGN` (below) and `SIG_IGN` **is** inherited across `exec`
  — not a disposition the resolver should start with; only then does it call
  `sigprocmask(SIG_SETMASK, &saved, NULL)`. The reason the order is stated rather than left
  to the plan is one sentence long: a signal that is already pending on the child would, if
  the mask were restored first, run the *parent's* inherited handler inside the child — and
  that handler kills process groups and `_exit`s, from the wrong process. With the resets
  first there is nothing left of the parent's handler for a newly unblocked signal to reach.

  Both halves are needed, for two different reasons, and the plan should carry both
  reasons rather than one. The mask **is** inherited across `exec`, so a child that kept
  the parent's block would start the resolver with `SIGTERM` blocked and would ignore the
  parent's own `kill(-pgid, SIGTERM)` until something unblocked it — turning the first
  signal of the group sequence into a no-op and leaving the `SIGKILL` to do all of the
  work. The dispositions are **not** inherited across `exec`, so the `SIG_DFL` resets are
  not about the resolver at all; they are about the handful of statements the child runs
  between `fork` and `execve` — `setpgid(0, 0)`, the two `dup2` calls, the two `close`
  calls and `apply_child_limits` (`:440-443`) — during which an inherited handler would
  otherwise run the parent's group sequence from inside the child. Resetting under the
  block is what makes that second reason hold across the whole window rather than most of
  it: with the resets first, there is no instant between `fork` and `execve` in which the
  child can both take one of the three signals and still have the parent's handler
  installed.

  After the `waitpid` on a pre-resolver child returns, `pre_child` is cleared back to `0`
  with no mask around the clear, and that is deliberate rather than an omission. The worst
  a handler can do with a stale pid it read just before the clear is signal a process that
  no longer exists: the `kill` fails with `ESRCH` and the `waitpid` after it with `ECHILD`,
  and the handler ignores the return value of both — stated here as a requirement rather
  than left to the plan, because there is nothing useful a handler on its way to
  `_exit(128 + signal)` can do with either error. For the pid to name something else the kernel would
  have to recycle it within the few instructions between the reap and the clear, and the
  parent forks nothing in that span — it reaps each pre-resolver child before it forks the
  next one.

  The handler then chooses on those two, in this order. If `pgid != 0`, it runs the group
  sequence exactly as above: `kill(-pgid, SIGTERM)`, a brief wait, `kill(-pgid, SIGKILL)`,
  reap. Else if `pre_child != 0`, it signals that **one** pid and no group —
  `kill(pre_child, SIGTERM)`, a brief wait, `kill(pre_child, SIGKILL)`, reap — because a
  digest tool or a `jq --version` is a single short-lived process with no group of its own
  worth naming. Else there is nothing to kill, and the handler kills nothing. In all three
  cases it then writes its one `parent-signal:` line (below) and `_exit(128 + signal)` — in
  that order, killing and reaping before writing anything, for the reason the line's own
  block gives — and that status is the same one the group branch already produced and the
  same number the entry reports (R1).

  **The handler never calls `kill(0, …)` or `kill(-0, …)`, and the reason is the whole point
  of the branch.** Both forms signal the caller's own process group, which in the shipped
  path is the operator's shell or the loop that invoked the entry, and in R10 is the test
  itself — so an implementation that let a zero `pgid` fall through to `kill(-pgid, …)`
  would, at best, kill the test that was checking it and, at worst, take down the caller's
  session. There is no case in this requirement where signalling the parent's own group is
  the right thing to do. The handlers are installed as the **first statements of `main`**,
  each with `sigaction` and each with the three-signal `sa_mask` above,
  before any pin work, any digest and any argument checking, so the window in which a
  signal still finds the default disposition is as small as a process start rather than as
  long as a pin pass; R10 says what the test does about that window and why it cannot be
  narrowed further for a test's benefit.

  **The handler says which branch it took, on the parent's own stderr, mirroring the entry's
  `entry-signal:` line — and it says it after the killing is done, not before.** An earlier
  round of this spec had the handler write first, which put a write that can block ahead of
  the only work the handler exists to do: stderr may be a pipe nobody is draining, or any
  other descriptor whose write blocks, and a handler that diagnosed first would then hang
  with the resolver group still alive and the entry still waiting on it. Since this whole
  path exists to guarantee cleanup on `INT`, `TERM` and `HUP`, the diagnostic is the least
  important thing in it and goes last: branch, kill, reap, write, `_exit`.

  **The line is best-effort, and what that means is stated rather than left to the plan.**
  The handler puts stderr into non-blocking mode for that one write —
  `fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)` inside the handler, with no restore
  afterwards because `_exit(128 + signal)` follows immediately — and it emits the line with
  a **single `write(2)` call**, not the copied
  `write_all(STDERR_FILENO, …)` (`portable-profile-resolution-launcher.c:164`) the copied
  file uses for every stderr write of its own, because `write_all` loops until the whole
  buffer is out and on a non-blocking full pipe that loop is a spin rather than a write.
  A short write, an
  `EAGAIN` or an `EPIPE` is ignored — no check of the return value and no retry — so a
  truncated line, or no line at all, is an accepted outcome where a hung termination is
  not. `SIGPIPE` is **ignored**, not blocked: the parent sets it to `SIG_IGN` in the same
  first statements of `main` that install the three handlers, so a write to a closed stderr
  returns `EPIPE` to a handler that already ignores errors instead of killing the parent
  in the middle of terminating a group. Blocking it instead would only defer the kill — a
  blocked `SIGPIPE` stays pending and is delivered the moment anything restores a mask,
  including the child's own mask restore above — which is why the disposition and not the
  mask is the right tool here. It is still not a buffered `fprintf`, for the same reason
  the `runtime-pgid:` line below is not one:

  ```
  parent-signal: <NAME> group <pgid>
  parent-signal: <NAME> no-runtime
  ```

  `<NAME>` is `INT`, `TERM` or `HUP` — the name, not the number, exactly as the entry's line
  carries it. The group form is written when `pgid != 0` and names the group it has just
  terminated; the `no-runtime` form is written in both of the other two branches, because
  what a reader needs to know is that no resolver group existed, not which pre-resolver tool
  happened to be running. Four conventions were checked against it, the way the
  `runtime-pgid:` line was. The copied `sanitized_error` (`:118-165`) validates the *child's*
  captured `child.stderr` bytes and never reads what the parent wrote to its own stderr, so
  this line sits outside it. R10's group-2 refusal cases still see exactly one `E_*` line and
  nothing else on the parent's stderr: every R5 refusal happens before the `fork`, and this
  line is written only when a signal actually fires, which no refusal case does. R6's
  byte-identical claim is about stdout, where this line does not appear. And R10's
  command-word allowlist is untouched, because a `write(2)` is C and starts no process. On
  the pass-through side it is the same distinction the entry's line already relies on: this
  is the parent's own line on the parent's own stderr, not a byte added to or removed from
  anything a child wrote, and the entry relays it unchanged like every other `E_*` line
  (R1).

  **The entry side does not change, and the two lines compose.** The entry's forwarded
  branch is exactly as R1 states it: forward the signal to the parent, wait for the parent
  to exit, chmod the run directory back to 0700, remove it, and only then write
  `entry-signal: <NAME> forwarded <pid>` before exiting with the parent's status. The
  diagnostic is last there for the same reason it is last here: bash's `printf` to a stderr
  nobody is draining can block, and a line written first could hold up the forward the
  parent is waiting for and the cleanup it exists to describe (R1). What this block adds is
  that a forward landing in the pre-fork
  window now ends cleanly rather than ambiguously: the parent kills at most its own one
  pre-resolver child, then writes `parent-signal: TERM no-runtime`, and exits
  `143`, so the entry's wait returns that status and the caller sees the entry's
  `entry-signal: TERM forwarded <pid>` line beside the parent's `no-runtime` line and an
  exit of `143`. Nothing is left running and no group anywhere was signalled.

  **The parent names the resolver's process group on stderr, so nothing downstream has to
  guess which child is which.** The parent runs children before the resolver — the
  platform's SHA-1 tool for each blob-id pin, its SHA-256 tool for the jq digest, and the
  bound jq for the `--version` probe (R7) — so "the parent's child" does not identify the
  runtime, and anything picking a process by parentage could pick a digest tool instead.
  Rather than have a reader infer it, the parent reports it. After the `fork`
  (`portable-profile-resolution-launcher.c:432`), the `setpgid(child, child)` the copied
  supervisor already does from the parent side (`:450`), the `pgid` assignment, and the
  `sigprocmask(SIG_SETMASK, &saved, NULL)` that ends the blocked-signal region those three
  sit in — **outside** that region, deliberately, for the reason the region's own block
  gives above — and before it enters the poll loop, the parent writes exactly one line to
  its own stderr:

  ```
  runtime-pgid: <n>
  ```

  `<n>` is the child's pid in decimal, which is also the process group id: the child makes
  itself a group leader with `setpgid(0, 0)` (`:440`) and the parent sets the same thing from
  its side (`:450`), so the group id equals the child pid whichever of those two calls won
  the race, and it is a number the parent already holds.

  **The write is made the same way the handler's `parent-signal:` line is made, and for the
  same reason.** It is a `snprintf` into a small buffer and then a **single `write(2)`**
  with stderr in non-blocking mode for it: `fcntl(STDERR_FILENO, F_GETFL, 0)` to read the
  flags, `fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)` before the write, and the saved
  flags put back with a second `F_SETFL` after it — two `fcntl` calls here where the handler
  needs only one, because the parent goes on to supervise a whole resolution on that same
  descriptor while the handler `_exit`s immediately after its own line. A short write, an
  `EAGAIN` or an `EPIPE` is ignored: no check of the return value and no retry. `SIGPIPE` is
  already `SIG_IGN` from the first statements of `main` (above), so a closed stderr returns
  `EPIPE` to code that ignores it rather than killing the parent. It is neither the copied
  `write_all(STDERR_FILENO, …)` (`:164`) — which loops until the whole buffer is out, and on
  a non-blocking full pipe that loop is a spin rather than a write — nor a buffered
  `fprintf`, so the line is on the descriptor before the poll loop starts and a reader
  watching stderr sees it while the resolution is still running.

  **Say plainly what that costs.** Because the write is best-effort, a caller draining
  stderr through a pipe that happens to be full at that moment can get a truncated line, or
  no line at all. That is accepted, and it is accepted because nothing in the shipped path
  depends on the line: it is a courtesy for whoever is reading stderr, the exit status is
  still the result (R9), and no check, branch or cleanup in either shipped file ever reads it
  back. The one thing that does read it is R10's mid-run signal case, which redirects the
  entry's stderr into a plain file in the test's own scratch — a regular file, where a write
  can neither block nor return `EAGAIN` — so that case is unaffected by the line being
  best-effort, and R10 says so where it describes the read. This is a named deviation from
  the copied launcher, which prints nothing there.

  **Why stderr, and what it does and does not disturb.** Stderr is already the parent's
  diagnostic channel: every `E_*` refusal line goes there (R5), and the entry passes it
  through to the caller unchanged (R1). Four conventions were checked against this line and
  none of them conflicts. The copied `sanitized_error` (`:118-165`) validates the *child's*
  captured `child.stderr` bytes before relaying them — one line, a known `E_*` first word, a
  restricted character set — and it never reads, validates or is affected by what the parent
  itself has already written, so this line sits outside everything that function checks.
  Every R5 refusal happens before the `fork`, so a refusal's stderr still carries exactly one
  `E_*` line and nothing else, which is what R10's group-2 cases assert. The byte-identical
  claim is about stdout, where this line does not appear (R6). And it is not a new write
  root: stderr is a descriptor the caller handed in, the same one the `E_*` lines already
  use, and R7 counts write roots on the filesystem — this adds no file anywhere. What does
  change is that a successful run now prints one line on stderr where it printed nothing, so
  a caller who reads any stderr output as failure would be wrong; R9's documentation says the
  line is informational and that the exit status is the result. The alternatives considered
  were a dedicated descriptor and a file inside the run directory, and both add a channel to
  a security wrapper in order to serve a test, where stderr is a channel it already has.
- **R3 — the environment is built from empty, with exactly this allowlist.** From
  `portable-profile-resolution-launcher.c:645-690`, and nothing else:
  `HOME=<sandbox>/home` and `TMPDIR=<sandbox>/tmp` (both created by the parent at mode
  0700 — with `mkdirat` relative to the output-directory descriptor it checked rather than
  the copied `mkdir` at `:645-647`, and under the `umask(077)` the parent sets among the
  first statements of `main`, which is what makes 0700 the mode that appears rather than
  the mode that was asked for, R5), `LC_ALL=C`,
  `PATH=<dir of the bound jq>:/usr/bin:/bin` (`:662-677`),
  `YSTACK_RESOLVER_TRUSTED=1`, `YSTACK_RESOLVER_HELPER=<absolute helper>`,
  `YSTACK_RESOLVER_JQ=<absolute jq>` (`:678-680`), `GIT_TERMINAL_PROMPT=0` (`:681`), and
  on Darwin only `MallocNanoZone=0` (`:682-685`). The two test variables
  `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS` and `YSTACK_RESOLVER_TEST_GIT_STOP` (`:686-689`)
  are never set by the shipped parent; the runtime refuses the launch if either appears
  alone (`scripts/lib/profile-resolution.sh:656-659`). No caller variable is copied
  through, and the parent closes every inherited descriptor above 0/1/2 before `execve`.
- **R4 — the same resource limits, unchanged.** In the child before `execve`
  (`portable-profile-resolution-launcher.c:388-398`): `RLIMIT_CPU` 300s, `RLIMIT_AS`
  536870912 (non-Darwin), `RLIMIT_FSIZE` 67108864, `RLIMIT_NOFILE` 64. In the supervisor
  (`:33-36,456-503`): at most 32 processes in the child's process group, a 300-second
  wall clock, and on Darwin a polled 512 MiB private address-space bound. Exceeding any
  of them kills the group and prints one `E_LIMIT` line.
- **R5 — refusals, each with an `E_*` line on stderr and a non-zero exit.** The parent
  refuses before `execve` when: the runtime file is not a regular non-symlink absolute
  path (`:635`) **or its mode is not 0644** — today that assertion lives only in the test
  (`portable-profile-resolution.test.sh:608-614`), and moving it into the parent is a
  named deviation; any file in the parent-pinned subset — files 1, 2 and 3 of the loaded
  set below, and no others — does not match its pinned blob id; the jq at the bound path
  does not match the pinned SHA-256 for the platform or does not answer `jq-1.6`
  (`portable-profile-resolution.test.sh:96-105,112-129`, mirroring
  `shadow/v1/reproduce.sh:113-118`); the helper fails the run-directory checks below;
  any allowlisted value is not an absolute
  regular path, or is too long for the fixed buffer it is copied into (`:641`, `:662-665`
  — a guard that is reachable for the output path and, for the reason R10 gives,
  unreachable for the jq path); the request or repository-map
  argument is not an absolute regular non-symlink file — the copied launcher checks only
  the leading slash on those two (`portable-profile-resolution-launcher.c:636`), so this
  is new code; or the caller's output directory
  is not a directory the caller owns at mode 0700 holding no entry other than `.run`, with
  that `.run` entry being the same object as the run directory the parent was handed —
  the same object by descriptor identity, with no symlink followed anywhere in the
  comparison, which the block after this one specifies in full — which mirrors the sandbox
  rule the test uses
  (`portable-profile-resolution.test.sh:219-222`), allowing for the one entry the run
  directory now occupies there (R1). Three orderings inside this are fixed here rather than
  left to the plan: the length guard on the output path (`:641`) runs before any of it, so
  an overlong output path is refused without the parent looking for `.run` at all — R10's
  overlong case depends on that order; the whole output-directory check runs before
  the parent creates `home` and `tmp` there (`:645-647`, which the parent replaces with
  `mkdirat` on the descriptor that check opened, below), so a refused run leaves the output
  directory exactly as it found it; and the `.run` identity comparison runs before the
  helper, binary and run-directory checks below, for the reason the block after this one
  gives.

  **That containment check is descriptor identity, and it follows no symlink anywhere.**
  An earlier round of this spec wrote it as a string comparison of two `realpath` answers,
  and that is wrong in exactly the way the check exists to catch: `realpath` resolves
  *through* a symlink, so an output directory whose only entry is a `.run` symlink pointing
  at a well-built run directory somewhere else resolves to that other directory on both
  sides and compares equal. The containment the requirement is trying to enforce — the run
  directory is inside the output root the caller was judged on — would then be satisfied by
  the link rather than by the directory. So the parent compares no resolved paths here. It
  does this instead, in this order:

  1. `open(<output>, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` — the same
     descriptor the owner, mode and listing checks use and the same one the four sandbox
     entries are later created relative to (below), opened once.
  2. `fstatat(out_fd, ".run", &st, AT_SYMLINK_NOFOLLOW)`, which must succeed and must
     report `S_ISDIR`. A symlink there is a refusal whatever it points at, and so is a
     regular file, a fifo, a socket, a device or anything else that is not a directory.
     This is the step that refuses the attack, and it refuses it before anything is
     resolved.
  3. `openat(out_fd, ".run", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`, then
     `fstat` on the descriptor it returns.
  4. `open(<run-directory argument>, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`,
     then `fstat` on that one.
  5. The two `struct stat`s must agree on `st_dev` **and** `st_ino`. Anything else — a
     failure at any of the three opens, an `ELOOP` from `O_NOFOLLOW`, a non-directory, or
     an identity mismatch — is the refusal this requirement already uses everywhere else:
     one `E_RUNTIME` line on stderr and a non-zero exit, before the `fork` and before
     anything is created.

  Two mechanism notes the plan should not have to rediscover. The explicit `S_ISDIR` test
  in step 2 is what carries the symlink refusal, not the `O_NOFOLLOW` flags: the copied
  launcher's portability shim defines `O_NOFOLLOW` to `0` when the platform does not have
  it (`portable-profile-resolution-launcher.c:30-31`), and a flag that can compile away to
  nothing is not where a security refusal belongs — the flags stay, as the second line they
  are. And the rest of this check reads the directory through the descriptor too, never
  through the path: the "no entry other than `.run`" listing is `fdopendir` on a `dup` of
  `out_fd` — a `dup` because `fdopendir` takes ownership of the descriptor it is handed and
  is closed by `closedir`, while the parent needs `out_fd` alive afterwards for the
  `mkdirat` and `openat` calls below — and the owner and mode facts are an `fstat` on
  `out_fd` itself.

  **The order matters as much as the identity does.** The comparison happens before the
  parent trusts anything *inside* the run directory: the helper, the compiled parent binary
  and the run-directory mode checks below all run after it, so they are made against an
  object already proved to be the `.run` of the output root the parent checked, rather than
  against whatever the run-directory argument happened to name. And the descriptors stay
  open — the run-directory descriptor from step 4 is the one those later checks use, with
  `openat` relative to it instead of fresh path resolutions, so the object checked is the
  object used and no name is resolved a second time between the check and the use. That is
  the same names-to-descriptors discipline the sandbox creations and the supervisor's reads
  follow, stated here for the check that admits the run directory in the first place.

  **The parent's version of the output-directory rule is a re-check, not the only check.**
  The entry refuses the same output root — absolute, a real directory with no symlink
  component, caller-owned, mode exactly 0700, empty — before it creates `.run` or compiles
  anything (R1), which is where that refusal belongs, because everything the entry would
  otherwise have written lands in the directory being judged. The parent then repeats owner,
  mode and the not-a-symlink fact on a descriptor it opened itself
  (`O_DIRECTORY|O_NOFOLLOW`), which is what makes its pass authoritative rather than
  advisory — a path-based check in a shell script can be raced, an `fstat` on your own
  descriptor cannot — and it adds the one fact that did not exist when the entry looked:
  that `.run` is the only entry, and that it is the run directory the parent was handed. A
  caller who drives the parent directly gets only this pass; that is why group 2 proves the
  parent's copy and group 1 proves the entry's, separately (R10).

  **The parent creates its sandbox relative to the descriptor it checked, not by path.**
  The `fstat` pass above buys less than it looks like it does if what follows goes back to
  names, and in the copied launcher it does: `home` and `tmp` are built with `snprintf` and
  `mkdir(2)` (`portable-profile-resolution-launcher.c:645-647`), and `child.stdout` and
  `child.stderr` with `open(2)` (`:413-421`), all four by path. In the window between the
  parent's `fstat` on the output directory and those four creations, a same-uid process can
  rename that directory away and leave a symlink to somewhere else under the same name, and
  every one of the four then follows the name to the new object. The `O_NOFOLLOW` already on
  the two `open` calls does not help here: it refuses a symlink at the last component,
  `child.stdout`, and says nothing about a symlink in the directory component above it.

  So the parent keeps the descriptor it opened with `O_DIRECTORY|O_NOFOLLOW` and did its
  `fstat` on, and creates all four entries relative to that descriptor:
  `mkdirat(dirfd, "home", 0700)` and `mkdirat(dirfd, "tmp", 0700)` in place of the two
  `mkdir` calls, and `openat(dirfd, "child.stdout", O_RDWR | O_CREAT | O_EXCL |
  O_CLOEXEC | O_NOFOLLOW, 0600)` and the same for `child.stderr` in place of the two `open`
  calls — `O_RDWR` where the copied code has `O_WRONLY`, for the reason the paragraphs
  after this one give. The names are then single components resolved against the checked descriptor
  rather than against the caller's string, so the directory the four entries appear in is
  the directory that was checked. Two
  consequences to carry into the plan: the descriptor stays open for the life of the
  supervisor, so it is passed into the copied `supervise` (`:400-532`), which is the one
  signature change this forces; and the four entries are still refusals rather than
  overwrites on collision, because `mkdirat` and `O_CREAT|O_EXCL` fail on an existing name
  exactly as the calls they replace did.

  **And the parent calls `umask(077)` as one of the first statements of `main`, for the
  same reason the entry does.** A mode argument to `mkdirat` or `openat` is a request, and
  the kernel subtracts the process umask from it, so `mkdirat(dirfd, "home", 0700)` gives
  0700 only when the umask allows it. The parent inherits its umask from whatever started
  it, and nothing between the caller and `main` resets it: the environment the entry builds
  for the launch (R3) names variables, and a umask is not a variable — it survives `execve`
  like the process's other attributes. Under a permissive caller umask the four sandbox
  entries would appear at 0777 and 0666 instead of 0700 and 0600, in a directory the parent
  has just certified as caller-owned and 0700; under a restrictive one they would appear
  unusable and the run would fail late instead of not at all. The copied launcher has no
  `umask` call anywhere in its 702 lines (verified: the name does not appear in the file),
  which is safe there only because the test script sets `umask 077` for the whole suite
  before it ever runs the launcher (`portable-profile-resolution.test.sh:5`) — a property
  of the harness, not of the launcher, and exactly the kind of thing that must not be left
  behind in the harness when the code ships. So this is a named deviation from the copied
  file: one call, before any check and before any creation, with no `chmod` or `fchmod`
  anywhere after it. The entry sets the same umask (R1), so in the normal path the parent
  inherits 077 and sets it again; the call is there for the caller who drives the parent
  directly, which is the same caller every other check in this requirement exists for.

  **Creating those two files fd-relative is only half of the fix, because the copied
  supervisor reads them back by path.** After the child exits it goes back to the two path
  strings it built with `snprintf`, and it does so in three different places:
  `empty_regular_file` `lstat`s the name again
  (`portable-profile-resolution-launcher.c:112-116`, called on `stderr_path` and
  `stdout_path` at `:505,518,522,526`); `stream_file` re-`open`s the name to copy the
  resolved profile to the parent's stdout (`:84-86`, called as
  `stream_file(stdout_path, STDOUT_FILENO)` at `:506`); and `sanitized_error` re-`open`s
  the name to read the child's `E_*` line (`:118-120`, called as
  `sanitized_error(stderr_path)` at `:518`). Every one of those is a fresh resolution of
  `<output>/child.stdout` or `<output>/child.stderr` through a directory component the
  parent has no claim on any more — the same race the creation move just closed, reopened
  at the point where the bytes are actually trusted, which is the worse of the two places
  to have it. The `O_NOFOLLOW` on those two `open` calls and the `S_ISREG` tests do not
  help: they judge whatever object the name resolves to now, not the object the parent
  created.

  So the parent keeps the two descriptors it created with `openat(..., O_CREAT | O_EXCL |
  O_NOFOLLOW)` and does all three jobs on those descriptors, never re-opening by name. The
  emptiness test becomes an `fstat` on the kept descriptor — `S_ISREG` and `st_size == 0`
  off one `struct stat`, which proves strictly more than the copied `lstat` did, since a
  descriptor cannot be a dangling symlink. Reading the two files back becomes
  `lseek(fd, 0, SEEK_SET)` followed by the copied `read` loop on that descriptor:
  `stream_file` and `sanitized_error` lose their `const char *path` parameter, take an
  `int` instead, and lose their own `open` and `close` bookkeeping with it — the supervisor
  owns those two descriptors from `openat` to the end of the run. One consequence to carry
  into the plan and not discover during it: the two descriptors are the write ends the
  child inherited, opened `O_WRONLY` today and positioned at end of file, so they become
  `O_RDWR` for the parent to read back through them at all. That is the one widening this
  forces, and it is named here because it is a mode change on files the child also writes.

  **What is fd-bound after this, stated exactly.** The parent's four sandbox creations, its
  emptiness tests, its stdout streaming and its error-line read are all either relative to
  or directly on descriptors it opened and checked itself, and no path string is resolved a
  second time anywhere between the output-directory `fstat` and the end of the run. What
  stays path-free for a different reason is the child's own writing: it writes stdout and
  stderr through descriptors 1 and 2 that it inherited across `execve`, which is a
  descriptor handoff already and never names a file. What remains genuinely path-bound is
  not the parent's doing — `HOME=<output>/home` and `TMPDIR=<output>/tmp` are strings the
  resolver resolves by name, which is the residual stated next.

  The creations and the reads are one named deviation from the copied source, not two, and
  Copy versus adapt lists them as one item: it is a single move from names to descriptors
  applied to every place the copied supervisor touches those four entries. Splitting them
  is how the first version of this deviation came out half-done.

  **Stated residual — the child still receives paths.** `HOME=<output>/home` and
  `TMPDIR=<output>/tmp` are strings in the environment the parent builds (R3), and the
  runtime resolves them by name like any other program. So the fd-relative creation closes
  the race on the parent's own four writes and not on the resolver's later use of those two
  directories. Closing that one would mean the runtime accepting descriptors instead of
  paths — a change to `scripts/lib/profile-resolution.sh` and to the launch contract this
  initiative does not touch, the same shape as the helper residual below. It is recorded
  here, not promised.

  **The entry pins the loaded set, not just the entry point.** Pinning the runtime file alone
  buys almost nothing, because the runtime is a dozen lines of binding and then a
  `source`. It reads `scripts/lib/profile-resolution.sh` into its own shell
  (`resolver/v1/profile-resolve-runtime.sh:19`, guarded only by `[ -f ]` and `[ ! -L ]` at
  `:12-13`), and that library evaluates the resolver's jq program with `-f`
  (`scripts/lib/profile-resolution.sh:156`, with module path `-L <repo>/resolver/v1` at
  `:154`, guarded only by `[ -f ]` and `[ ! -L ]` at `:697-699`). Neither of those two
  files is pinned by anything today. The whole set of files the runtime executes or
  evaluates, read out of the code:

  1. `resolver/v1/profile-resolve-runtime.sh` — the script `/bin/bash` is handed as its
     first argument (`portable-profile-resolution-launcher.c:652-657`).
  2. `scripts/lib/profile-resolution.sh` — sourced by it
     (`resolver/v1/profile-resolve-runtime.sh:19`).
  3. `resolver/v1/profile-resolution.jq` — the jq program the library evaluates
     (`scripts/lib/profile-resolution.sh:154-157`). It contains no `include` or `import`
     today, so the `-L` directory contributes no further file; the `-L` is still a load
     path, and a future `include` there would widen this set silently.
  4. `scripts/core-contract.sh` — run as `/bin/bash "$profile_resolution_core"`
     (`scripts/lib/profile-resolution.sh:163`).
  5. `core/v2/generations/<generation>/core-ingress.sh` — sourced by it
     (`scripts/core-contract.sh:267`).
  6. `core/v2/generations/<generation>/contracts.jq` — the jq program that ingress
     evaluates (`scripts/core-contract.sh:239`, `core-ingress.sh:297`).
  7. `core/v2/generation-registry.json` — the one entry here that is neither executed nor
     evaluated: nothing in the resolver path reads its content, and the library only
     hashes it (`scripts/lib/profile-resolution.sh:712`) as a provenance assertion about
     the generation. It is listed because it is part of the trusted set the library pins,
     not because the runtime loads it.
  8. The five jq modules under `core/v2/generations/<generation>/modules/` —
     `schema.jq`, `profile_graph.jq`, `stage_request.jq`, `result_facts.jq`,
     `result_truth.jq` — imported by `contracts.jq:1-5` off the module path
     `-L .../modules` (`core-ingress.sh:295,329`), and checked only for existence and
     non-symlink by `scripts/core-contract.sh:250-259`.
  9. The compiled `resolver/v1/nofollow-snapshot.c` helper, executed by path
     (`scripts/lib/profile-resolution.sh:209`) — already pinned by the entry (R1).

  Files 4 through 7 are already pinned by blob inside the library itself
  (`scripts/lib/profile-resolution.sh:711-714`, against the constants at `:7-10`), and
  those pins are worth something only once the library that holds them is itself pinned.
  So the set has two owners, and which one owns what is stated once here and used in
  those words everywhere else in this spec. **The entry pins the git blob id of every
  file in that set** — 1, 2, 3, the five modules of 8, and its own two C sources — as
  constants carrying the same `# pinned at <commit>` header, checked before any compile
  against a blob id the entry computes itself (R1), a mismatch being `E_RUNTIME` before the
  compile. Each of those ten checks is written the way R1 requires of every external
  command in the entry — the digest command's status captured, then `checkpoint`, then the
  refusal on that status, never a `|| refuse` beside the command — so a pin check that a
  terminal `Ctrl-C` killed exits `128 + signal` with an `entry-signal:` line rather than
  reporting a blob mismatch that did not happen. **The parent
  re-pins exactly files 1, 2 and 3, and nothing else; call those three the parent-pinned
  subset.** All three are reachable from the runtime path the parent is handed, using the
  runtime's own `${dir%/resolver/v1}` repository-root rule
  (`resolver/v1/profile-resolve-runtime.sh:9-10`), and a mismatch on any of the three is
  `E_RUNTIME` before `execve`. The parent does not re-pin the five modules, because
  reaching them needs the generation id, which lives in the library; those five are
  entry-owned. Every sentence in this spec about a parent blob refusal says "the
  parent-pinned subset (files 1-3)" and means only those three — the parent never claims
  to check the loaded set.

  **What a caller who drives the parent directly loses.** That caller — the group-2 test
  cases in R10, or an operator who invokes `trusted-launch` without the entry — gets the
  parent-pinned subset and no other pin. Files 4 through 7 are still covered, because the
  library's own blob checks fire at run time
  (`scripts/lib/profile-resolution.sh:711-714`) and the parent's pin of file 2 is what
  makes those checks trustworthy. The five module bodies are the actual gap: in that path
  nothing checks their content at all — `scripts/core-contract.sh:250-259` checks only
  that each one exists and is not a symlink. So the residual is exact: bypass the entry
  and the modules are unpinned. R10 states it in those terms rather than implying the
  parent covers the set. The focused test asserts every pinned constant equals the working
  tree's `git hash-object` output — the test may run git, the shipped files may not (R1) —
  so an edit that forgets a pin fails CI rather than
  shipping.

  What this buys, plainly: the trusted set is explicit and finite. Go through the entry
  and the launch is exactly these committed bytes or it is nothing; go straight to the
  parent and it is the parent-pinned subset plus whatever the library checks for itself.
  What it costs: any change to
  resolver code moves pins in the same pull request, and a new core generation moves five
  module pins at once. That cost is the repository's existing pattern, paid in the library
  today (`scripts/lib/profile-resolution.sh:7-10,711-714`).

  **The helper's run-directory checks, and what they are worth.** The runtime executes
  the helper *by path*: `scripts/lib/profile-resolution.sh:209` runs
  `"$YSTACK_RESOLVER_HELPER" snapshot-repository ...`, and its only check on that path is
  `[ -x ] && [ ! -L ]` (`:664-667`) at launch-check time, not at exec time. So whatever
  the parent checks, the file the runtime finally executes is re-resolved from the path
  later. The parent's job here is therefore not to bind what the runtime executes; it is
  to fail closed on any tampering observable before the launch. It refuses unless, on
  file descriptors it opened itself and checked with `fstat` — path-based `stat` is not
  used, so nothing the parent itself checks can be swapped for something else between its
  own check and its own read of that object:

  - the helper is a regular, non-symlink, executable file, owned by the current uid, at
    mode exactly 0500;
  - the compiled parent binary in the same directory is likewise owned by the current uid
    at mode exactly 0500. This does not protect the already-running parent — it is a
    tamper indicator for the directory: if that file has been loosened or replaced, so
    could the helper beside it have been, and the parent refuses rather than launching;
  - the directory holding them is a real directory, not a symlink, owned by the current
    uid, at mode exactly 0500 — so it admits no new entries and no renames — and is
    exactly the run directory the entry named, which is the caller's output directory's own
    `.run` read from the other side (R1). That last fact is the output-directory check
    above and is established the way that check establishes it: equal `st_dev` and `st_ino`
    between the descriptor opened on the run-directory argument and the descriptor
    `openat`ed on `.run` relative to the output-directory descriptor, with nothing resolved
    through a symlink on either side. An earlier round of this spec wrote both halves of
    the comparison with `realpath`, and both halves carried the one flaw described up
    there. The helper and the compiled binary are then checked with `openat` relative to
    that same run-directory descriptor, so the directory proved to be `.run` is the
    directory their checks read from.

  There is no identity probe to add. The runtime gives jq a `--version` probe (`:668-671`)
  but gives the helper none, and the helper has exactly one subcommand,
  `snapshot-repository`, with a fixed nine-argument shape
  (`resolver/v1/nofollow-snapshot.c:2678-2682`), so there is nothing safe to call for an
  identity answer.

  **Stated residual — a same-uid process that can write the output directory can swap
  `.run` out from under all of this.** An earlier round of this spec said a replacement
  "needs a `chmod` first". That is true only of the files inside the run directory, and an
  attacker does not have to touch them. The 0500 modes stop an in-place write to one of
  those four files and a rename of an entry *inside* the run directory. They say nothing
  about the directory one level up: `<output>` is mode 0700 and owned by the same uid, so a
  process running as that uid can rename `<output>/.run` aside and put a directory of its
  own in its place — its own helper, its own jq, its own awk — after the entry's checks and
  after the parent's, with no `chmod` anywhere.

  Nothing in the parent's descriptors stops that swap from taking effect, because the
  runtime resolves what it runs from *strings*: `YSTACK_RESOLVER_HELPER`,
  `YSTACK_RESOLVER_JQ` and the first `PATH` element are all `<output>/.run/...` paths (R3),
  and `scripts/lib/profile-resolution.sh:209` execs the helper by that path. The parent's
  descriptor still refers to the original directory and the original files, and it can prove
  they were right when it looked; it cannot make the runtime use them. The fd-relative
  sandbox creation above closes the race on the parent's own four writes and is not claimed
  to close this one — same shape as the `HOME`/`TMPDIR` residual stated just above it.

  **So the boundary carries a second assumption, and it is stated next to the first.** The
  accepted resolver spec already assumes the security boundary begins in a trusted parent
  process that was already running before any hostile input arrived, and that a helper
  newly started from a hostile environment is not that parent
  (`work/portable-profile-resolution/spec.md:219-222`). This spec adds one: **no hostile
  same-uid process is active in the caller's output root while the run is in progress.**
  Every mode and ownership check here is against the current uid, so a process already
  running as that uid is inside all of them; what the checks buy is tamper detection at
  check time, not exclusion. Root is outside all of it as well — root can write into any
  directory and replace any file regardless of mode.

  What the checks do buy: the entry compiled both binaries this invocation from sources
  whose blob ids match the pins, into a directory it created; the parent refuses to launch
  if, at check time, anything about those files or that directory has been loosened or
  moved. After that, the runtime's own `[ -x ] && [ ! -L ]` is the last line, and the spec
  says so rather than pretending otherwise.

  Closing the residual properly needs the runtime to accept already-opened descriptors
  from the parent instead of path strings — for the helper, and for jq beside it — so that
  the object checked and the object used are the same object and there is no window in
  which a path can be made to name something else. That is a change to
  `scripts/lib/profile-resolution.sh` and to the resolver's launch contract, both of which
  this initiative explicitly does not touch, so it is a separate initiative and is recorded
  under Out of scope as the recommended follow-up. It is not promised here.
- **R6 — the output is the runtime's bytes.** Success writes exactly the canonical
  `resolved_profile` the runtime prints on stdout (`scripts/lib/profile-resolution.sh:973`),
  streamed unchanged (`portable-profile-resolution-launcher.c:504-511`). For the same
  request the shipped parent and the test launcher produce byte-identical **stdout**; the
  focused test runs both and `cmp`s them. Stdout is the whole of this claim and stderr is
  deliberately outside it: the shipped parent prints one `runtime-pgid: <n>` line there that
  the test launcher has no counterpart for (R2), so a `cmp` of the two stderrs would fail on
  a line that carries no profile bytes.
- **R7 — the shipped path never touches the network, and widens nothing.** No network, no
  credential, and **exactly one write root: the output path the caller named** — for
  everything this initiative adds, on every supported platform, and for the unchanged
  runtime on Linux, where R10 asserts it mechanically in CI. On Darwin the runtime's own
  `git` calls leave one known write outside that root; the Darwin paragraph below states it
  exactly, DR-2 accepted it on 2026-09-10, and the intent now names it as the one accepted
  exception to its own constraint. The one
  root is what the intent asks for — "no writes outside the caller's own output"
  (`work/resolver-trusted-parent/intent.md:36-45`) — and an earlier round of this spec did not
  deliver it, because its run directory under the caller's `TMPDIR` was a second write
  root. Inside the one root there are two write areas, named exactly:

  1. *`<output>/.run`, the run directory the entry creates for this invocation*, including
     its `tmp` and `home` subdirectories: the two compiled binaries, the jq and awk copies,
     the compiler intermediates that `TMPDIR=<output>/.run/tmp` keeps inside it, and
     anything the toolchain writes into the `HOME=<output>/.run/home` the compile line hands
     it (R1). Both subdirectories are emptied and removed once compilation is done, before
     the 0500
     tightening; the rest goes when the entry's trap removes `.run`, which happens before
     the entry exits, so nothing of the run directory survives a run whose end the entry
     can observe.
  2. *The output path itself, which the parent also uses as the sandbox root*: the `home`
     and `tmp` directories the parent creates there at mode 0700 (R3), the supervisor's
     captured `child.stdout` and `child.stderr`
     (`portable-profile-resolution-launcher.c:413-414`), and the runtime's own `mktemp -d`
     scratch under that sandbox `TMPDIR`, which is `<output>/tmp`. The resolved profile gets
     no file of its own: its bytes are what the supervisor captured in `child.stdout` and
     then streamed to the parent's stdout, which the entry passes through unchanged (R6).

  The four sandbox names — `home`, `tmp`, `child.stdout`, `child.stderr` — cannot collide
  with `.run`: none of them begins with a dot, and the parent creates each one relative to
  the output-directory descriptor it has already checked, with `mkdirat(2)` and with
  `openat(2)` carrying `O_CREAT|O_EXCL|O_NOFOLLOW` — a named deviation from the copied
  `mkdir(2)` at `:645-647` and `open(2)` at `:413-421`, which build the same four by path
  (R5). Every one of those four calls fails on an existing entry rather than reusing it, so
  a name collision here could only ever be a refusal, never a silent overwrite of something
  the entry put there.

  One thing the move does not widen: the launched resolver can reach the run directory
  either way. It is handed absolute paths into it in `YSTACK_RESOLVER_HELPER`,
  `YSTACK_RESOLVER_JQ` and the first `PATH` element (R3), and it runs as the same uid, so
  `.run` sitting beside its `HOME` and `TMPDIR` tells it nothing it was not already told.
  What stops it writing there is the 0500 modes, and those are unchanged.

  Nothing this initiative adds writes outside the caller's output path — not the entry, not
  the compiler it runs, not the parent, not the compiled helper, not the jq and awk copies.
  Not the caller's `TMPDIR`, which the
  shipped path no longer uses as a write location at all: the run directory moved inside
  the output root for exactly that reason, and the compile line sets the compiler's own
  `TMPDIR` inward for the same one. Not the caller's home directory, which that same line
  replaces with `<output>/.run/home`, so a toolchain that writes a cache or a log into
  `$HOME` writes it inside the run directory and it goes with the rest. Not the repository
  working tree, not a cache, not a
  dotfile, not a temporary file anywhere else on the filesystem.

  **On Darwin one write outside that root remains, and it belongs to the unchanged runtime
  rather than to anything this initiative adds.** Part of this was already settled and
  stands. `/usr/bin/cc` and `/usr/bin/git` on Darwin are one and the same `xcrun` shim, and
  the shim writes a tool-lookup cache — a single `xcrun_db` file in the per-user temp
  directory the platform reports, not in the `TMPDIR` the compile line sets. An earlier
  round admitted that as a residual of the *entry*, and the round after it removed the
  cause instead of narrowing the claim: on Darwin the compiler is the CommandLineTools
  clang invoked directly, which execs its own linker and never the shim, and the blob ids
  are computed from a size and the platform's SHA-1 tool so that neither the entry nor the
  parent runs `git` at all (R1, both measured). All of that is still true.

  What that round missed is the one process in the picture it does not get to write.
  **The resolver runtime runs `/usr/bin/git` itself**, and this spec does not change the
  runtime — that is a constraint of the intent rather than a choice it made
  (`work/resolver-trusted-parent/intent.md:32-33`, "the resolver runtime and its rules do
  not change. This adds the missing parent, not a new resolver behaviour"). The runtime
  runs it for every repository read, under the hardened wrapper that execs
  `/usr/bin/git --git-dir=…` (`scripts/lib/profile-resolution.sh:313-323`), and again for
  the four blob pins it checks for itself at load time (`:711-714`) — the same reads the
  read list below already attributes to the library. On Darwin every one of those calls is
  the shim, and the shim can write `xcrun_db` in the per-user temp directory. The parent
  builds the runtime's environment from empty and controls every variable in it (R3), so it
  can point the runtime's `HOME` and `TMPDIR` wherever it likes — but the cache is not in
  `TMPDIR`, which is exactly what R1's measurement establishes, so no environment the
  parent can hand the runtime prevents a fixed-path shim from writing its own cache.
  Nothing short of changing the runtime's git path closes it, and changing the runtime is
  the one thing this initiative may not do.

  So the claim is narrowed, and the narrowing is exact rather than a hedge. For everything
  this initiative adds — the entry, the compiler it runs, the compiled parent, the compiled
  helper, and the jq and awk copies — the single write root holds on both platforms, and
  for the runtime it holds on Linux, where R10 asserts it mechanically in CI. On Darwin the
  one known write outside the caller's output path is the shim's `xcrun_db` under the
  per-user temp directory, attributable to the runtime's own `git`. That is the whole of the
  residual: one file, mode 0600, in a per-user directory, written by a process this spec
  leaves alone.

  **That residual is no longer a deviation the spec is carrying on its own: it is an
  accepted exception the intent now names.** The operator decided DR-2 on 2026-09-10,
  choosing option (a) — accept the residual, name it, and measure exactly it — and the
  decision was carried into the chain by intent pull request `#282`, which amends the
  intent's write-root constraint and changes nothing else. This spec pins that amended
  intent: the `intent-blob` in the frontmatter is
  `eaa322c405502cc0ca7c453814ca0f005f11b48f`. The amended constraint reads, in full
  (`work/resolver-trusted-parent/intent.md:36-45`):

  > No network, no credentials, no writes outside the caller's own output. One
  > accepted exception, decided as DR-2 on #271: on Darwin the resolver runtime,
  > which this initiative leaves unchanged, itself runs `/usr/bin/git`
  > (`scripts/lib/profile-resolution.sh:313-323` and `:711-714`), and that binary is
  > the xcrun shim, which may write its `xcrun_db` cache in the per-user temp
  > directory outside the caller's output. That write belongs to the unchanged
  > runtime, not to the parent this initiative adds; the parent, the entry, the
  > compiler, the helper and the copies write only inside the caller's output on
  > both platforms, and on Linux the runtime does too. A later intake may move the
  > runtime off `/usr/bin/git` on Darwin.

  Read that beside the two paragraphs above and the intent and this spec say the same
  thing in the same shape: one file, written by the unchanged runtime's own `git`, on
  Darwin only, with everything this initiative adds inside the caller's output on both
  platforms. The Darwin operator run measures exactly this and nothing wider (R10). The two
  alternatives an earlier round of this spec held open against a refusal — widening E to
  move the runtime off `/usr/bin/git` on Darwin, or dropping the Darwin claim and shipping
  Linux-only — are history rather than live options, and neither is carried further here.
  The follow-up that would close the residual for good is the one the amended constraint
  itself names: a later intake moving the runtime off `/usr/bin/git` on Darwin. It is
  recorded under Out of scope and is not promised here.

  **Reads, stated precisely.** The blanket "no read outside the repositories named in the
  map" is wrong as written, because the entry and the parent read local files before the
  resolver ever runs. Two separate claims:

  1. *The resolver's content reads* are confined to the repositories the request's
     repository map names. A repository root is only ever obtained by looking the
     repository id up in the map snapshot
     (`scripts/lib/profile-resolution.sh:193-198`), a snapshot is refused if the lookup
     yields nothing (`:205-206`), and every Git read runs as
     `git --git-dir=<mapped root's gitdir>` under the hardened wrapper (`:313-323`).
  2. *The entry and the parent additionally read a fixed, listed set of trusted local
     inputs*, and nothing else: the two committed C sources
     `resolver/v1/trusted-launch.c` and `resolver/v1/nofollow-snapshot.c` (hashed and
     compiled by the entry); the twelve files of the loaded set enumerated in R5 —
     the runtime file `resolver/v1/profile-resolve-runtime.sh`, the library
     `scripts/lib/profile-resolution.sh`, the resolver jq program
     `resolver/v1/profile-resolution.jq`, `scripts/core-contract.sh`, the generation's
     `core-ingress.sh`, `contracts.jq` and five jq modules, and
     `core/v2/generation-registry.json` — eight of them read by the entry to be hashed,
     the three that form the parent-pinned subset read again by the parent to be hashed
     (and the runtime file among those three also mode-checked), the
     remaining four hashed by the library itself at run time (`:711-714`), and all of them
     bar the registry then read by the resolver under the bound `/bin/bash`; the request
     file and the repository-map file named on the command line; the jq binary supplied as
     an argument; `/usr/bin/awk`, which the entry reads on Linux for the one purpose of
     copying it into the run directory, and does not read at all on Darwin, where it
     writes a shim naming that path instead (below); the caller's output directory; and
     the entry's own run directory.

     **The executables, listed exactly.** The previous round's list was short enough to be
     wrong. It named seven — the compiler, `/bin/bash`, `/bin/mkdir`, `/bin/cp`,
     `/bin/chmod`, `/usr/bin/git` and the SHA-256 tool — and left out four the spec's steps
     needed then: `/usr/bin/uname` for the platform case, `/usr/bin/mktemp` for the run
     directory, `/bin/rm` for the cleanup, and `/usr/bin/printf` for the `E_*` lines. It
     also left `/usr/bin/awk` ambiguous, mentioning it as a file to copy without saying
     whether anything runs it. That correction made the count twelve; the round after it
     eleven, when the run directory became the fixed `<output>/.run` made with `/bin/mkdir`
     and `/usr/bin/mktemp` stopped being run at all (R1); then thirteen, when the entry
     gained `/usr/bin/env` — to build the explicit environment its pin
     checks, its two compiles and the parent launch all run under — and `/usr/bin/stat`, to
     read the output root's owner and mode before writing anything there. A later round
     moved the list in both directions, which was a first: `/usr/bin/git` left it, because
     the blob ids are computed rather than asked for; `/bin/cat` and the platform's SHA-1
     tool joined it as that computation's two new commands; and the compiler became a
     per-platform pair rather than a single path, since Darwin runs
     `/Library/Developer/CommandLineTools/usr/bin/clang` where `/usr/bin/cc` would be the
     `xcrun` shim (R1). That took it to sixteen. **This round `/usr/bin/awk` leaves it**,
     and the correction is to the twelve-count round above rather than to anything since:
     that round found the ambiguity and resolved it the wrong way. Neither shipped file
     ever runs host awk. The entry puts an awk inside `.run` so the *runtime* has one on
     the `PATH` it is given — a copy on Linux, and on Darwin a two-line shim that names
     the host path — and it is that entry in `.run` the resolver executes, long after the
     entry has tightened the directory to 0500 — so
     `/usr/bin/awk` is a data path in these two files, in the same class as the SDK root
     and the `/proc` templates, and it is listed with them below and in R10's pass 1
     rather than among the words either file may execute. Counted the way R10's grep
     counts — one word per distinct absolute path, so both compilers and all three digest
     tools count separately — that is
     **fifteen command words**, and R10 lists the same fifteen, so the two can be checked
     against each other rather than drifting. Every external
     command either file runs, with the fixed absolute path it runs it by:

     *The entry, `resolver/v1/resolve-profile.sh`* — `/usr/bin/uname` (`-s` and `-m`, for
     the platform case); `/usr/bin/stat`, for two jobs and no others: the owner and mode of
     the caller's
     output root (`-c '%u %a'` on Linux, `-f '%u %Lp'` on Darwin, chosen in the same `case`,
     R1), and the byte size of each pinned file, which the blob-id header needs
     (`-c '%s'` and `-f '%z'`, same `case`); the platform's SHA-256 tool,
     `/usr/bin/shasum -a 256` on Darwin
     and `/usr/bin/sha256sum` on Linux, chosen in the same `case` that chooses the jq
     digest pin; the platform's SHA-1 tool, `/usr/bin/shasum -a 1` on Darwin and
     `/usr/bin/sha1sum` on Linux, chosen in the same `case`, for the ten computed blob-id
     pins; `/bin/cat`, which joins the `blob <size>\0` header to the file bytes on the way
     into that tool (R1) and is run for nothing else;
     `/bin/mkdir`, for the run directory `<output>/.run` and the `tmp` and `home`
     subdirectories inside
     it; `/usr/bin/env`, which is the entry's *first* external command — it performs the
     re-exec into an empty environment — and afterwards prefixes every pin check, both
     compiles and the parent launch with `-i` and an explicit variable list (R1); the
     compiler, which is `/usr/bin/cc` on Linux and
     `/Library/Developer/CommandLineTools/usr/bin/clang` on Darwin, where `/usr/bin/cc`
     would be the `xcrun` shim (R1); `/bin/cp`,
     for the jq and awk copies;
     `/usr/bin/printf`, for the `E_*` lines and, on Darwin, for writing the awk shim;
     `/bin/chmod`, for the 0500 pass and the trap's 0700 restore; `/bin/rm`, for the `tmp`
     subdirectory and the run directory; `/bin/bash`, which is its own interpreter and the
     target of its own re-exec (R1) — it is also the shebang of the Darwin awk shim, but
     that line is text the entry writes and the *runtime* acts on, so it is not why
     `/bin/bash` is listed here; the bound jq,
     for the `--version` probe; and the compiled parent
     inside the run directory, which it runs as its child. The order matters as much as the
     list: `/usr/bin/env` runs before `/usr/bin/uname`, and the builtin scrub ahead of it
     runs no command at all (R1), so every entry in this list except `env` itself is
     executed from an environment the entry wrote. `umask` is not on the list and does not
     belong on it: it is a bash builtin, like `printf`, `[`, `cd` and `pwd` elsewhere in
     this requirement, so the `umask 077` the entry sets beside its scrub (R1) forks
     nothing and R10's command-word grep drops it by name from `compgen -b`.

     *The parent, `resolver/v1/trusted-launch.c`* — `/bin/bash`, `execve`d with the fixed
     argv R2 gives (`portable-profile-resolution-launcher.c:652-657,701`); the same
     per-platform SHA-1 tool, for the computed blob ids of the parent-pinned subset — and
     it needs neither `stat` nor `cat` for that, having the size from its own `fstat` and
     writing the header and the bytes to the tool's stdin itself; the same per-platform
     SHA-256 tool,
     for the jq digest; and the bound jq, for its own `--version` probe. Nothing else. The
     sandbox `home` and `tmp` directories come from `mkdirat(2)` on the descriptor the
     parent checked (R5), not from `mkdir(2)` on a path (`:645-647`) and not from
     `/bin/mkdir`, at the mode they ask for because of the parent's own `umask(077)` (R5);
     and every mode and ownership check is an `fstat` on a descriptor the
     parent opened, not a call to `/usr/bin/stat`.

     **Where `/usr/bin/awk` does appear, and why the bound jq is the opposite case.** The
     entry's source names `/usr/bin/awk` in exactly two places, both of them argument
     positions and neither of them a command. On Linux it is the source argument of the
     copy — `/bin/cp /usr/bin/awk <run>/awk`, the shape the test uses at
     `scripts/test/portable-profile-resolution.test.sh:136`. On Darwin it is text inside
     the single-quoted string the entry hands to `/usr/bin/printf`, which writes the
     two-line `#!/bin/bash` and `exec /usr/bin/awk "$@"` shim the test writes at `:138`;
     that shim is executed by the *resolver*, out of `.run`, long after the entry has
     tightened the directory to 0500, and the entry never runs it. Nothing else touches
     the path: awk is not one of the ten computed blob-id pins and it is not the SHA-256
     digest pin — that one is jq's — so it is not an input to either digest pipeline
     either. R10's pass 1 therefore lists it with the data paths, and the assertion there
     pins those two positions rather than only reclassifying the path, because a
     classification on its own would let an accidental `/usr/bin/awk '{print $1}'` in
     command position through the very grep that exists to catch it.

     The bound jq is the opposite case, and the two are set side by side here so a plan
     cannot conflate them. The entry both **reads** jq — `/bin/cp` copies it into `.run`
     and the platform's SHA-256 tool digests it for the jq pin — and **runs** it, for the
     `jq-1.6` `--version` probe; the parent runs its own probe on the same binary. So jq
     stays a command word for both files while also being a data path, and that is not a
     contradiction, only two uses of one file. It never reaches pass 1 of R10's grep in
     either role, because neither file names it by an absolute path: the entry assigns it
     from its own argument and the parent receives it as one, so pass 3 is what covers
     it, by variable name.

     Seven choices inside that list are named because each is a place the shipped path
     deliberately differs from the code it copies:

     - **The compiler is a fixed path chosen per platform, and `$CC` is not
       honoured.** The test script uses `${CC:-/usr/bin/cc}` on Linux and
       `${CC:-/usr/bin/clang}` on Darwin
       (`scripts/test/portable-profile-resolution.test.sh:95,102`, invoked at `:146-149`).
       A caller-chosen compiler is a caller-chosen trust base, so the entry drops the
       override — and it drops both of the test's Darwin choices with it, because
       `/usr/bin/cc` and `/usr/bin/clang` there are a single inode and both are the `xcrun`
       shim. Darwin runs `/Library/Developer/CommandLineTools/usr/bin/clang` with an
       explicit `-isysroot` and refuses when the Command Line Tools are absent; Linux keeps
       `/usr/bin/cc`, where it is a real compiler (R1). This is a named deviation from the
       test.
     - **No `git` in either shipped file.** The pin checks compute the git blob id
       themselves — `blob <size>\0` plus the file bytes, through the platform's SHA-1 tool
       — rather than running `git hash-object` (R1). On Darwin `/usr/bin/git` is the same
       shim inode as `/usr/bin/cc`, so keeping it would have added ten shim invocations and
       a cache write of this initiative's own on top of the one the runtime already makes;
       on Linux it is a large dependency for nine
       bytes of header and a hash. The runtime still runs `/usr/bin/git` for itself, which
       is where the Darwin residual above comes from; what this deviation removes is the
       entry's and the parent's own use of it. The focused test still runs git, to assert
       the computed
       ids match `git hash-object` (R10). This is a named deviation from both the test
       script and `shadow/v1/reproduce.sh`.
     - **The SHA-256 tool is chosen per platform, at a fixed path, and never searched
       for.** The test script's `sha256_file` searches `PATH` with `command -v sha256sum`
       (`:31-37`), which the shipped path must not do, and
       `shadow/v1/reproduce.sh:18` uses `/usr/bin/shasum -a 256` on both platforms, which
       is right on Darwin but not guaranteed on Linux, where `/usr/bin/sha256sum` is the
       native tool and `/usr/bin/shasum` ships only with perl. Hence the pair above.
     - **No `awk` process is spawned at all, to read a digest or for anything else.**
       `reproduce.sh:18` pipes the
       SHA-256 tool through `/usr/bin/awk '{print $1}'`; the entry takes the first field
       with a bash parameter expansion and the parent parses it in C. That was the last
       place either shipped file would have run awk, so `/usr/bin/awk` is off the command
       list entirely and appears only as the file copied in for the runtime's benefit —
       the paragraph above says where, and R10's pass 1 and its position assertion are
       what hold it there.
     - **No `mktemp`.** `shadow/v1/reproduce.sh:94-142` and the test script both make their
       scratch with `mktemp -d` under the caller's `TMPDIR`. The entry's run directory is
       the fixed `<output>/.run` instead (R1), so `/usr/bin/mktemp` is neither run nor
       listed. A random name buys nothing in a directory the parent already requires to be
       caller-owned, mode 0700 and otherwise empty, and a fixed name is what lets the
       parent check that the run directory it was handed is that entry.
     - **No `find`, and `stat` for exactly two jobs.** The 0500 pass names the four files it
       tightens — the compiled parent, the compiled helper, the jq copy, the awk copy —
       instead of discovering them, which is the same fact as the run directory holding
       exactly those four and no subdirectory at launch (R1), so `/usr/bin/find` is neither
       run nor listed. `/usr/bin/stat` is listed, and the entry runs it for two things: the
       owner and mode of the caller's output root, read once before the entry writes
       anything there, and the byte size of each pinned file, which the blob-id header
       needs (R1). The second one reads a path the SHA-1 tool then reads again, and that is
       safe for the reason R1 gives — the size is inside the hashed header, so two reads
       that disagree produce a refusal rather than a passing pin.
       Nothing else is `stat`ed by either shipped file — the parent's every mode and
       ownership check is an `fstat` on a descriptor it opened, never `/usr/bin/stat` on a
       path it will later hand on by name, and the parent takes its blob sizes from `fstat`
       rather than running `stat` at all.
     - **The environment is scrubbed by builtins and re-exec'd empty before any of these
       commands runs, and every compiler invocation, every pin check and the parent launch
       still go through `/usr/bin/env -i`.** The test script and `shadow/v1/reproduce.sh`
       compile under whatever environment the caller happened to have. The entry does not,
       and the reason is two-sided: `CPATH`, `C_INCLUDE_PATH`, `LIBRARY_PATH`, `SDKROOT`,
       `DEVELOPER_DIR` and `MACOSX_DEPLOYMENT_TARGET` steer any C compiler here even with
       `$CC`
       ignored, and `LD_PRELOAD` and `DYLD_INSERT_LIBRARIES` are acted on by the loader of
       every process here — the parent's, before its `main` is entered, and equally
       `env`'s, `uname`'s, `stat`'s, `cat`'s, the SHA tools' and the compiler's. Both are
       handled the same way — by
       naming the whole environment rather than clearing the part somebody remembered — and
       the scrub is first because an `env -i` prefix cannot protect the `env` that carries
       it (R1). This is a named deviation from the test, and the scrub and re-exec are
       copied verbatim and adapted from
       `adapters/local-git-materializer/v1/materialize.sh:1,4-13,22-29`.

     That is the whole list, and R10 turns it into a checked invariant rather than prose:
     the focused test greps both shipped files for every command word and fails if any
     absolute executable path outside this list appears. Neither file reads a
     configuration file, a dotfile, a cache, a credential store, or any path derived from
     caller environment. What the compiler reads from its own installation — headers, the
     assembler, the linker — is outside this list and outside the claim; the compiler is
     trusted unverified, as Areas of concern says.

  3. *The copied supervisor additionally reads host process-table state.* That is neither a
     repository read nor a file in the list above, and the two claims as written left it
     out, which made them look narrower than the shipped parent is. Exactly what it reads,
     per platform:

     - *Linux.* `process_group_count`
       (`portable-profile-resolution-launcher.c:176-231`) opens `/proc` with `opendir`
       (`:178`), walks it with `readdir` (`:193`), and for every numeric entry builds
       `/proc/<pid>/stat` (`:204`), opens it and reads that file's first line
       (`:209-213`), from which it takes one field, the process group (`:218-220`).
     - *Darwin.* `process_group_count` (`:233-265`) asks `libproc` for the machine's pid
       list with `proc_listallpids` (`:235,247`) and calls `getpgid` on each pid (`:255`).
       The address-space poll `process_group_address_space_exceeded` (`:335-380`) repeats
       that enumeration (`:337,348`) and then, for group members only, calls
       `proc_pidinfo` with `PROC_PIDTASKINFO` and `PROC_PIDREGIONINFO`
       (`:279-280,286-287`) to total that process's private regions.

     Both run inside the supervisor's poll loop, roughly every 10 ms for the life of the
     resolution (`:411,456-489`; called at `:460,469,474`). The enumeration is host-wide
     because neither kernel offers a narrower way to ask "which processes are in this
     group": both list every pid on the machine and then keep only the pids whose process
     group is the child's. What leaves the block is only the group's own accounting — a
     count compared against the 32-process limit, and a yes/no on the Darwin 512 MiB bound
     (R4). Nothing about any other process is retained, printed or passed on.

     **These reads take no file content.** On Linux the only bytes read are the first line
     of each `/proc/<pid>/stat`, which is process-table state the kernel renders as a file
     rather than content stored on disk; nothing else under `/proc` is opened, and no
     process's memory, command line or environment is read anywhere in the parent. (The
     focused test does read `/proc/<child pid>/environ`, but that is the test asserting R3,
     not the shipped parent.) On Darwin nothing is opened at all — the reads are `libproc`
     calls.

     Of R7's three read claims this is the one with no mechanical check. R10's allowlist
     grep matches command words, so it says nothing about a syscall or a `libproc` call,
     and no test observes what the supervisor reads. The coverage is code review of the
     copied block — the same block the existing resolution test already exercises — and
     the review has one thing to confirm: that `process_group_count`,
     `process_group_address_space_exceeded` and `darwin_private_virtual_size` come over
     verbatim, and that no other reader of host state is added beside them.

  No network is true by construction, not by
  policy: neither shipped file contains a downloader, and every input the shipped path
  needs — the jq binary, the C sources, the runtime — is either handed in as an argument
  or already committed in this repository. The runtime's own guarantees are restated, not
  extended: git runs with system and global config disabled,
  `protocol.file.allow=never` and `GIT_NO_LAZY_FETCH=1`
  (`scripts/lib/profile-resolution.sh:313-322`); every working file goes into the
  runtime's own `mktemp -d` scratch at umask 077 under the sandbox `TMPDIR` the parent set,
  which is `<output>/tmp` and so inside the one write root
  (`:688-692`), removed on exit; repository reads go through `git --git-dir` on mapped
  roots (`:323`). The spec adds no claim beyond restating them.
- **R8 — platforms.** Supported: `Darwin:arm64`, `Darwin:x86_64`, `Linux:x86_64` — the
  same set the test and `shadow/v1/reproduce.sh:113-116` support, with the same two
  pinned jq digests. Anything else refuses with `E_RUNTIME` before doing work — a refusal
  proved by reading the entry's platform `case`, not by a runtime test case, for the
  reason R10 states.
- **R9 — documentation and manifest.** `docs/components.md:33-39` stops saying the test
  is the only shipped launcher and names the two new files, says this spec supersedes the
  accepted resolver spec's "a production trusted parent is not implemented" sentence
  (`work/portable-profile-resolution/spec.md:256-257`), and repeats what the proof does and
  does not cover. `README.md:252` gets the updated resolver row. `RESTORE.md:43-46` counts
  the resolver files correctly. The entry's documentation states the two supported
  invocation forms — both of which carry `-p` — says the marker word is not a public entry
  point and that a marker invocation without `-p` exits 78 without doing anything, and
  names the Darwin
  prerequisite: the Command Line Tools must be installed, because the entry compiles with
  `/Library/Developer/CommandLineTools/usr/bin/clang` rather than the `xcrun` shim at
  `/usr/bin/cc`, and refuses `E_RUNTIME` when they are absent (R1). It also states that a
  successful launch prints one informational `runtime-pgid: <n>` line on stderr — best-effort,
  so a caller whose stderr is a pipe it is not draining may not see it (R2) — and that an
  interrupted one prints one `parent-signal: <NAME> group <pgid>` or
  `parent-signal: <NAME> no-runtime` line beside the entry's own `entry-signal:` line (R2),
  so
  output on stderr is not by itself a failure signal — the exit status is the result. Both new
  files plus the new test are appended at the END of `ci/required-files.txt`. The accepted
  resolver spec itself is not edited.
- **R10 — the focused test.** `scripts/test/resolver-trusted-launch.test.sh` provisions
  the pinned jq the way `scripts/test/shadow-slice.test.sh:24-51` does, runs the shipped
  entry with that binary and a fresh empty mode-0700 output directory as its arguments,
  builds a resolution request naming the real
  committed `profiles/default/v1` profile and manifest objects with this repository as
  the mapped root, resolves it through the shipped parent and through the test launcher,
  and `cmp`s the two outputs. The refusals fall into three groups, and the test labels
  which owner each one belongs to, because the groups prove different things.

  **Group 1 — entry-owned refusals**, driven through the shipped entry: a jq whose SHA-256
  does not match the platform pin; an edited `resolver/v1/nofollow-snapshot.c` whose blob
  id no longer matches its pin; an edited `scripts/lib/profile-resolution.sh` and an
  edited `resolver/v1/profile-resolution.jq`, same thing; an edited jq module under
  the generation's `modules/` directory, which the entry pins and the parent does not
  (R5); an output path too long to hold the run
  directory, refused by the entry's own length guard before anything is created (R1), which
  is the entry-side half of the overlong case group 2 drives at the parent; and five
  output-root cases, which are the entry's validate-first checks (R1):

  - an output path that is a symlink pointing at a real, otherwise perfectly acceptable
    directory — refused on the `[ ! -L ]` and `cd -P` comparison;
  - one that is group-writable, mode 0750 instead of 0700;
  - one that already holds an ordinary file;
  - one that already holds a `.run` entry, which the emptiness check now refuses before the
    plain `mkdir` would — the `mkdir` stays as the second line, for the case where something
    creates `.run` between the check and the create;
  - one owned by another uid. This case needs no privilege to build, because it does not
    need to *create* a not-owned directory, only to name one, and the refusal happens before
    any write: the test points the entry at a root-owned system directory it never writes to
    (`/usr/bin` serves on both platforms) and asserts the ownership refusal, which the entry
    runs before the mode check so a directory that is both not-owned and not 0700 still
    refuses on ownership. The one case where that does not hold is a suite running as root,
    where every directory is owned by the caller; there the case skips with a printed reason
    saying the suite is running as root, and the check's coverage falls back to code review.

  Each of those five asserts more than the `E_RUNTIME` line and the non-zero exit: it
  asserts the target was never written to — no `.run` in it, and its entry set exactly what
  the test put there — because the whole point of moving the check into the entry is that
  the refusal comes before the writes. Those five are the only cases in the test that can
  assert that. The pin-check cases listed above them run the other way round: the run
  directory is created before the pins are checked (R1), so each of them asserts the
  refusal and, afterwards, that the trap removed `.run` — and the wrong-digest jq case among
  them is where the cleanup list below states those assertions in full, as its case 2.
  Every case here and in
  group 2 that needs an edited
  repository file edits a copy of the repository tree and points the entry or the parent
  at the copy; the test never modifies the working tree.

  **The unsupported-platform refusal is not in that list: it is proved by reading the
  code, not by running it.** The previous round listed it as a sixth group-1 case, where
  it was untestable. The entry reads the platform from the fixed path `/usr/bin/uname`
  with no override — the shape is
  `case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in Linux:x86_64) … ;;`
  `Darwin:x86_64|Darwin:arm64) … ;; *) E_RUNTIME ;; esac`, mirroring
  `scripts/test/portable-profile-resolution.test.sh:90-107` and
  `shadow/v1/reproduce.sh:113-118` — so there is no input CI can supply that drives the
  `*)` arm on a machine CI runs on, and shadowing `uname` on `PATH` would prove nothing
  about a script that never consults `PATH`. Making the arm reachable would mean adding a
  test-only platform override to the security wrapper, and a shipped override is a
  permanent way to tell the entry it is on a platform it is not — a worse trade than
  leaving the branch untested. So the coverage is code review, and the review has two
  things to check. First that `case`: two matching arms that between them name exactly the
  three tuples R8 supports — `Linux:x86_64` alone, and `Darwin:x86_64|Darwin:arm64`
  sharing one arm because they share one jq digest — and a `*)` arm that refuses with
  `E_RUNTIME` before any pin check, any compile and any run directory. Second the negative
  fact that makes the refusal total: those same three tuples, and no others, are the whole
  of every per-platform table in the entry — the jq digest pin (two digests, three
  tuples), the SHA-256 tool choice, the SHA-1 tool choice, the compiler path with its
  `-isysroot`, the two `/usr/bin/stat` format choices (R1), the awk branch —
  so an unrecognised platform has no
  digest, no hashing tool of either width, no compiler, no `stat` format and no awk branch
  to fall through to even if the
  `*)` arm were deleted. Anyone reviewing the `case` should read those tables in the same
  pass; all seven must agree on the same three tuples. R8 says the same, and neither the test
  nor this
  spec claims a runtime case for it.

  **Group 2 — parent-owned refusals, each proved by invoking `trusted-launch` directly**,
  bypassing the entry. This group carries the weight: the entry refuses a bad jq before
  the parent ever runs, so an entry-level case alone proves nothing about the parent's own
  copy of that check. For each case the test makes an empty mode-0700 output directory,
  builds `<output>/.run` inside it by hand the way the entry would, compiles the parent and
  the helper into it, tightens the modes, and then invokes the parent directly — one case
  each for:

  - a runtime file whose blob id does not match the pin (one byte changed);
  - a runtime file at mode 0755 instead of 0644, the check the parent takes over from the
    test script (R5);
  - a `scripts/lib/profile-resolution.sh` whose blob id does not match the pin, and a
    `resolver/v1/profile-resolution.jq` whose blob id does not match the pin — the two
    sourced-and-evaluated files that, with the runtime file above, are the whole
    parent-pinned subset (R5), reached by handing the parent a runtime path inside a copied
    repository tree whose library or jq program has been edited;
  - a jq whose SHA-256 does not match the platform pin;
  - a jq that does not answer `jq-1.6`;
  - a request path that is not absolute, a request path that is a symlink to a real
    request, and a repository-map path that is a symlink — three cases, because the copied
    launcher checks only the leading slash on those two arguments
    (`portable-profile-resolution-launcher.c:636`) and the regular-non-symlink check on
    them is new code;
  - an allowlisted path value too long for the fixed buffer it is copied into, aimed at
    the one value where that guard is reachable: an output path longer than
    `PATH_MAX - 16` and shorter than `PATH_MAX`, refused by the copied guard at
    `portable-profile-resolution-launcher.c:641` — see the note below on why it is not
    aimed at the jq path;
  - a compiled parent binary in the run directory whose mode is not 0500;
  - a helper outside the run directory it was given, a helper whose mode is not 0500, and
    a run directory whose mode is not 0500;
  - an output directory holding an entry other than `.run`; one whose mode is not 0700;
    one whose `.run` is not the run directory the parent was handed — a decoy `.run`
    beside an equally well-built run directory somewhere else; one whose only entry `.run`
    is a **symlink** to a real, correctly built, correctly moded run directory elsewhere,
    which is the case a `realpath` comparison passes and the `fstatat(out_fd, ".run", …,
    AT_SYMLINK_NOFOLLOW)` plus `S_ISDIR` test refuses (R5) — the directory it points at is
    built exactly the way every other group-2 case builds one, so the link is the only
    thing that distinguishes it from a run that should succeed, which is what makes the
    case a test of the containment rule rather than of a broken fixture; and one whose only
    entry `.run` is a regular file, the non-directory half of the same test. Those two
    assert more than the `E_RUNTIME` line and the non-zero exit: they assert the parent
    touched nothing — no `home`, no `tmp`, no `child.stdout`, no `child.stderr`, in the
    output directory or in the run directory the link points at, whose entry set is exactly
    what the test built. The last three of these five are the containment check R5 adds now
    that the run directory lives in the output root; the first two are the entry-set and
    mode halves of the same output-directory rule.

  Each case asserts the parent's own `E_*` line on stderr and a non-zero exit, so it fails
  if a check is ever quietly left to the entry. Every refusal in this group happens before
  the `fork`, so each case asserts that the `E_*` line is the *only* thing on the parent's
  stderr: the one `runtime-pgid: <n>` line R2 adds cannot appear in a refusal, and a case
  that saw it would mean a check had moved to the wrong side of the launch. Those cases, and
  no others, are what "the
  parent's R5 refusals are proved" means here; the spec claims nothing wider.

  **Why the overlong case aims at the output path and not at the jq path.** The previous
  round aimed it at a bound jq whose path exceeds `PATH_MAX`, and that case cannot fire.
  `main` validates `regular_absolute(argv[4], 1)` at
  `portable-profile-resolution-launcher.c:636`, which `lstat`s the path; a path longer
  than `PATH_MAX` fails that `lstat` with `ENAMETOOLONG`, so the argument is refused as
  not a regular file at `:635-638` and the `strlen(argv[4]) >= sizeof(tool_path)` guard at
  `:662-665` is never reached. That guard stays in the parent — it is copied code, it
  costs nothing, and it is the right thing to have if the check order ever changes — but
  it is defence in depth, proved by reading the code, not by a runtime case.

  The output path is the reachable one. It is the argument that replaces
  `YSTACK_TEST_SANDBOX` (`:640-644`, Design step 1), and the copied guard on it is
  `strlen(sandbox) > PATH_MAX - 16` (`:641`) — a threshold sixteen bytes *below*
  `PATH_MAX`, because the parent then builds `<output>/home` and `<output>/tmp` into
  `char home[PATH_MAX]` and `char temp[PATH_MAX]` with `snprintf`
  (`:537-538,645-647`), and those derived names are not opened before the guard runs. So
  there is a real window: a directory whose absolute path is longer than `PATH_MAX - 16`
  and shorter than `PATH_MAX` is a perfectly openable, empty, caller-owned mode-0700
  directory that passes every semantic check the parent makes on it, and is refused by the
  length guard alone. The order of the guard against the empty-and-0700 check does not
  matter for this case, precisely because such a directory passes that check. The test
  builds one — nested directories sized from the platform's `getconf PATH_MAX /`, 1024 on
  Darwin and 4096 on Linux, each component well inside `NAME_MAX` — hands it to the parent
  as the output path, and asserts the parent's `E_RUNTIME` line and a non-zero exit. If a
  platform will not let the test create such a directory, that is a test failure with a
  message saying so, not a skip.

  Moving the run directory inside the output root (R1) has two consequences for this case,
  and both are why it stays a direct-parent case. The entry now refuses such an output path
  first, with its own stricter guard, so an entry-level version of this case would prove
  the entry's guard and nothing about the parent's — group 1 has that case separately. And
  the run directory for this case cannot live under a near-`PATH_MAX` output path at all:
  the test builds it in a short directory of its own and relies on the order R5 fixes,
  where the length guard at `:641` fires before the parent looks for the output directory's
  `.run` entry. So the refusal asserted here is the length guard's alone, not the
  containment check's.

  What group 2 also shows, by omission, is the residual R5 states: a caller who reaches the
  parent directly has only the parent-pinned subset — files 1, 2 and 3 — so there is no
  module pin anywhere in that path. Files 4 through 7 still get the library's own blob
  checks at run time (`scripts/lib/profile-resolution.sh:711-714`), which the parent's pin
  of file 2 is what makes worth having; the five module bodies get only existence and
  non-symlink (`scripts/core-contract.sh:250-259`). The edited-module case therefore sits
  in group 1, driven through the entry, and the test comment says why it cannot sit in
  group 2.

  **Group 3 — a runtime refusal, labelled as one.** A malformed request document is not an
  R5 case at all: the parent accepts it as a canonical regular file and passes the path
  through, and the runtime is what refuses it. The test keeps the case, because it is also
  the deepest cleanup case below, and labels it a runtime refusal so nobody reads it as
  proof of a parent check.

  **The R3 no-copy invariant is not a refusal, and is proved differently.** There is no
  "leaked caller variable" refusal to test for: the parent builds the environment from
  empty (R3), so a leak would be a missing deletion, not a check that failed to fire.
  Three things carry that claim instead. First, the environment block is copied verbatim
  from the test launcher (`portable-profile-resolution-launcher.c:645-690`), so it is the
  same code the existing resolution test already exercises. Second, the direct-parent run
  is repeated with a deliberately polluted caller environment — `FOO=bar`, a `BASH_ENV` and
  an `ENV` both naming a script that would print a marker, a `PATH` naming a directory of
  decoy tools, and both
  `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS=1` and `YSTACK_RESOLVER_TEST_GIT_STOP=1` — and
  the test asserts its stdout is byte-identical to the clean run's.

  **Loader variables are deliberately not in that list, and moving them out was a
  correction.** An earlier round put `LD_PRELOAD` and `DYLD_INSERT_LIBRARIES` in the
  direct-parent pollution set, which cannot prove what it claims: the dynamic loader reads
  those variables and maps whatever they name before the parent's `main` is entered, so a
  parent started directly with them set has *already run the injected code*, and the test
  would be asserting that the injected library chose not to change the output — after
  running it. Nothing the parent contains can change that. So loader variables move one
  process outwards, to the only place that can defend against them. The entry scrubs its
  environment with builtins and re-execs itself under `/usr/bin/env -i` before it runs
  anything else, and later starts the parent the same way (R1), so the entry is
  what the test pollutes: it runs a full resolution through the shipped entry twice, once
  from a clean caller environment and once with `LD_PRELOAD`, `LD_LIBRARY_PATH`,
  `DYLD_INSERT_LIBRARIES` and `DYLD_LIBRARY_PATH` set, and asserts the two stdouts are
  byte-identical and both exits are 0.

  The values name a real, harmless library the test builds, whose constructor appends one
  line to a marker file in the test's scratch for every process it is loaded into — its own
  `argv[0]` and its pid — so the assertion has teeth rather than resting on the run merely
  succeeding. **The assertion is on the count: the marker file holds at most one line.**
  That one line, if present, names `/bin/bash` and is the entry's own first process, the
  one the caller started, whose loader ran before the entry's first statement. Nothing after
  it may appear — not the `/bin/bash` the re-exec starts, not `/usr/bin/env`,
  `/usr/bin/uname`, `/usr/bin/stat`, `/bin/cat`, the SHA tools or the compiler, not
  `trusted-launch`, not the second `bash` running the runtime, not `jq`. Counting is what
  makes this checkable: the re-exec'd bash has the same `argv[0]` as the first one, so no
  assertion about names can tell them apart, while a second line can only mean that
  something below the first process still had a loader variable. It is also what gives the
  test its bite — under the order an earlier round of this spec used, `uname`, `stat`, the
  ten pin checks and both compiles would each have added a line.
  On Darwin the file may be empty instead, because the
  platform strips insertion variables for system binaries like `/bin/bash`; the assertion
  is "at most one line, and nothing below the entry's first process" either way, which
  holds in both cases. And it is exactly the claim R1 makes and no more: the test does not
  assert that the first process is clean, because it is not. Beyond the entry
  there is nothing left to test, and the boundary note says so: the entry's own loader does
  run under the caller's environment, so the strong claim holds only when the process that
  starts the entry is trusted — the operator's shell or the trusted lane (Areas of concern).

  Third, on Linux CI
  only, the test reads `/proc/<child pid>/environ` of the launched runtime while it runs
  and asserts the environment is exactly R3's allowlist — no extra entry and no missing
  one. Darwin has no unprivileged equivalent, so there the claim rests on the verbatim
  copy plus the byte-identical output, with the exact-allowlist assertion coming from
  Linux CI. That third assertion is also what proves the test-only variables cannot be
  inherited: they are absent from the child's environ even when both are set in the
  caller's.

  **The forged clean-marker invocation is tested in two halves, and neither of them claims
  the branch survives pollution.** A caller can reach the clean path directly by supplying
  the marker word (R1), and R1 answers that with a refusal — the branch's first statement
  exits 78 unless `$-` carries a `p` — plus a re-run of the scrub behind it. The two halves
  test those two things separately, because they hold on different invocations.

  *The supported half: the marker branch with `-p`, polluted.* It runs `/bin/bash -p
  <entry> __resolve_profile_clean <jq>
  <output> <request> <map>` from a caller environment carrying exported shell functions
  named `pwd`, `cd` and `find` — each appending a line to a marker file and returning
  success — alongside a `BASH_ENV` that would define an alias and the same polluted
  variables the R3 run uses. Those three names are the ones worth hijacking: the output-root
  validation runs `(cd -P "$out" && pwd)`, and `cd` and `pwd` are builtins that a function
  of the same name shadows, which is how a wrong output root could be made to compare equal
  to itself. Two assertions: the resolution succeeds with stdout byte-identical to an
  ordinary clean run's, and the marker file was never created. Say exactly what that
  proves, because it is less than an earlier round of this spec claimed for it: on this
  invocation privileged mode already refused to import those functions and already refused
  to read that `BASH_ENV`, so the assertion covers the branch's behaviour on a supported
  arrival — the scrub that runs behind the refusal is a second layer, and the case shows
  the two layers together leaving nothing for a hijacked `cd` to do. It does **not** show
  that the scrub would have removed hostile functions before validation on an arrival where
  the shell had imported them; nothing in this suite shows that, and R1 no longer says it.

  *The unsupported half: the marker branch without `-p`, clean.* It runs
  `/bin/bash <entry> __resolve_profile_clean <jq> <output> <request> <map>` — no `-p` — and
  asserts the exit status is exactly 78 and the output directory is untouched, with no
  `.run` and no entry of any kind created in it. This half runs from a **clean**
  environment on purpose. The assertion is about the refusal line and nothing else: adding
  pollution here would make the case's own result depend on whether the pollution could
  shadow `case` or `exit`, which R1 says outright it can in a non-privileged process, so a
  polluted version of this case would be asserting against the very thing that is out of
  the boundary. What the pair of cases establishes together is the boundary itself — the
  supported arrivals behave, and the unsupported arrival is turned away before it touches
  anything — not that the unsupported arrival is safe. It is not, the direct marker form
  without `-p` is unsupported (R1), and the process's loader has already read the caller's
  variables before any statement of the entry runs.

  **A polluted compiler environment is tested too, because ignoring `$CC` was never the
  whole of it.** The entry compiles under the `env -i` line quoted verbatim in R1, and the
  test proves the line is doing work. The pollution fixture is one directory the test
  builds, `<poison>`, holding a single file: a `stdio.h`, a header both C sources include,
  which defines a marker string and is deliberately not a working `stdio.h` — so a compile
  that reads it fails outright, and a compile that somehow got the marker through would
  carry it. The caller environment for the polluted runs carries `CC=/nonexistent/cc`,
  `CPATH=<poison>`, `C_INCLUDE_PATH=<poison>`, `LIBRARY_PATH=<poison>`,
  `SDKROOT=/nonexistent/sdk`, `DEVELOPER_DIR=/nonexistent/dev`,
  `MACOSX_DEPLOYMENT_TARGET=1.0`, and a `TMPDIR` and `HOME` pointing at two directories the
  test watches. Two halves, because they can prove different things:

  1. *Through the shipped entry, behaviour.* The same successful resolution runs twice, once
     from a clean caller environment and once from the polluted one, and the test asserts
     both exit 0, their stdouts are byte-identical, the marker string appears in neither
     run's output, and the watched `TMPDIR` and `HOME` are untouched afterwards — which is
     the same fact R7's one-write-root claim makes about the compile step, asserted here
     rather than stated. **On Darwin the case measures one thing more, and it measures
     exactly the narrowed claim rather than a wider one.** The narrowing is R7's: everything
     this initiative adds writes only inside the output path, while the unchanged runtime's
     own `/usr/bin/git` is the Darwin `xcrun` shim and can write its `xcrun_db` cache in the
     per-user temp directory, which is the residual DR-2 accepted and the intent now
     records (R7). An
     earlier round of this spec asserted that `xcrun_db` came back *unchanged* across a full
     entry run, and that assertion is wrong for this half, because this half runs a real
     resolution and the runtime behind it runs git. So the recipe is a difference, not an
     equality, and it is written out here because the operator runs it by hand:

     - Before the run, record two things in the per-user temp directory — the directory
       `/usr/bin/getconf DARWIN_USER_TEMP_DIR` reports: the state of `xcrun_db` itself,
       which is either *absent* or *present with a size, an mtime and a SHA-1 of its bytes*
       (**absent is a state, not a reason to skip** — a skip there would throw away the
       strongest evidence available), and a listing of the whole directory with each entry's
       name, size and mtime.
     - Run the resolution. Then record both again.
     - The case passes when the only difference between the two listings is `xcrun_db` —
       created where it was absent, or changed in any of size, mtime and digest where it was
       present — and nothing else in the directory is new or modified. **Any other new or
       modified file is a failure**, and so is any change anywhere else the case already
       watches: the caller's `TMPDIR` and `HOME` must still be untouched.
     - The same recipe runs around the entry's own pre-launch steps, where the claim is
       still the strong one: the pin checks and both compiles run no `git` and no shim
       (R1), so across those `xcrun_db` must come back in the state it started in, absent
       included. Half 2 below is where that is measured without a runtime behind it.

     **A cache already primed on the operator's machine may show no write at all**, because
     the shim writes only when its lookup misses, and the same run on a cold cache would
     write. That is precisely why the claim is narrowed rather than reported as "measured
     clean": a clean measurement here is evidence about one machine's cache state, not about
     the shipped path, and treating it as the latter is the mistake the earlier round made.
     What the recipe does prove is the part that matters — that the write, when it happens,
     is that one file and nothing else. The recipe is Darwin-only because Linux has no such
     file and no shim that would write one, and there the one-write-root claim covers the
     runtime too and CI asserts it. What this
     half cannot do is compare the built binaries:
     the entry's
     trap removes `.run` and everything in it before the entry returns, and a way to keep
     the binaries would be a debug mode in a security wrapper — a worse thing to ship than a
     behavioural assertion.
  2. *In the group-2 style, where the test owns the run directory, the binaries themselves.*
     The test builds a run directory by hand as group 2 already does and runs the `env -i`
     compile line of R1 into it twice — once from a clean caller environment, once from the
     polluted one — then compares the two binaries' SHA-256 digests, which must be equal.
     They should be: both compiles use the same pinned sources, the same fixed flags, the
     same fixed compiler path for the platform and an environment that is identical by
     construction, and the
     only difference is the `-o` destination, which a compile without `-g` does not record
     in its output. **This is where the strong Darwin cache assertion lives**, because there
     is no runtime behind these compiles and therefore no git anywhere in them: on Darwin the
     test records `xcrun_db`'s state before the two compiles and requires the identical state
     after — absent stays absent, present stays byte-identical in size, mtime and digest —
     with no skip either way. A change here means the shim got back into the compile line,
     which is the one thing R1 says must not happen. Alongside it the test runs one control
     compile of the same source under
     the polluted environment *without* the `env -i` prefix, and requires that one to fail
     or to carry the marker — the fixture has to be shown to be poisonous, or the digest
     equality above proves nothing. If a toolchain turns up where the two digests differ for
     a reason the plan judges benign, the behavioural assertions in half 1 carry the claim
     on their own and the digest comparison is relaxed to them, with the reason recorded in
     the plan rather than dropped quietly.

  **Cleanup is asserted, using refusals that happen after the run directory exists.** The
  entry runs the parent as a child and removes `<output>/.run` in its `EXIT` trap (R1), and
  the caller's `TMPDIR` is not a write location any more, so every cleanup assertion is
  about the output directory: the test gives the entry a fresh empty mode-0700 output
  directory of its own and asserts exactly what that directory holds once the entry
  returns. Which refusal is used matters, and the check order R1 fixes changes the answer
  from what an earlier round of this spec said. Under that order the pin checks ran before
  `.run` was created, so a wrong-digest refusal proved only that the entry had created
  nothing — not that the trap removes anything — and the case was explicitly not cited as
  cleanup evidence. The run directory and its `tmp` and `home` subdirectories are now
  created *before* the pin checks, because the pin checks run under the `env -i` line that
  points `TMPDIR` and `HOME` inside them (R1), so a wrong-digest pin refusal now fires with
  `.run` on disk and the trap already installed. It is therefore a cleanup case, and the
  strongest one available for a refusal the *entry* owns.

  The refusals that still happen before any write are exactly the output-root validations —
  the five group-1 cases above, which assert the target was never written to — and nothing
  else. **Four cases carry the cleanup claim**, and in all four the first assertion is that
  no `.run` entry remains; three of them are refusal cases the lists above already include,
  and the cleanup claim adds the output-directory assertions to them:

  1. *A successful resolution.* The run directory existed, was tightened to 0500, and is
     gone afterwards — which also proves the trap's `chmod 0700` is there, because without
     it the entries of a 0500 directory cannot be unlinked. What the output directory holds
     is the parent's sandbox and nothing else: `home`, `tmp`, `child.stdout` and
     `child.stderr` (R7). The test asserts that exact set of four entries with no `.run`
     among them, asserts `child.stdout` is byte-identical to the entry's own stdout, and
     asserts `child.stderr` and `tmp` are empty — `tmp` because the runtime removes its own
     scratch under it on exit (`scripts/lib/profile-resolution.sh:688-692`). It makes no
     claim about `home` being empty, because nothing in this initiative's control governs
     what a future git might drop into a `HOME` it was handed.
  2. *A refusal by the entry, at the pin check.* The wrong-digest jq case from group 1. The
     entry has by then validated the output root, installed the trap, and created `.run`
     with its `tmp` and `home` subdirectories at 0700, and refuses before either compile. The
     trap therefore fires against a run directory that exists, is still 0700, and holds two
     subdirectories and no compiled file — the one shape none of the other three cases
     reaches. The output directory is asserted **completely empty** afterwards: no `.run`,
     and nothing else either, because the parent never ran and so never created its
     sandbox. This case is also what proves the trap covers the pin checks at all, which is
     only true because of the order R1 fixes.
  3. *A refusal by the parent, after the run directory and the trap both exist.* The test
     hands the entry a runtime file copied to mode 0755 instead of 0644, so the entry
     checks every pin, compiles both binaries, removes `tmp` and `home`, tightens
     everything to 0500 and launches, and the parent refuses on the runtime-mode check it owns (R5). The trap
     therefore fires against a fully built, fully tightened run directory. Here the output
     directory is asserted **completely empty** afterwards — no `.run`, and no `home`,
     `tmp` or `child.*` either, because every refusal check the parent makes runs before it
     creates its sandbox there (R5).
  4. *A refusal by the runtime, deeper still.* A malformed request document, which the
     parent accepts as a canonical regular file and passes through and the runtime refuses.
     The child exits non-zero only after the resolver has run and created its own scratch
     under the sandbox, and the output directory afterwards holds the same four sandbox
     entries as case 1 and no `.run` — this time with `child.stderr` carrying the runtime's
     error line and `child.stdout` empty, and `tmp` empty again, which is the resolver's own
     scratch cleanup asserted in the same place.

  **A fifth case was considered and is not written, and the reason is said out loud.** The
  order R1 now fixes arms the traps before the `mkdir` so that a failure of the `tmp` or
  `home` creation, or a signal landing while `.run` exists and nothing is registered to
  remove it, still cleans up. The case that would prove it directly is one where `.run` is
  created and `tmp` cannot be, and there is no deterministic way to build that from
  outside the entry. The entry creates `.run` itself at 0700 in a root it has just
  validated as caller-owned, 0700 and empty, so every route to a failing `mkdir` of `tmp`
  needs either a privilege the suite does not have (a read-only or quota-bound mount under
  a directory that still passes those validations) or a same-uid process racing a `chmod`
  into the microseconds between the two `mkdir` calls, which is a flaky test dressed as a
  deterministic one. A test-only hook inside the entry is the thing this spec refuses
  everywhere else. So the arming order is covered the way R2's mask window is: by reading,
  with the plan quoting the statements in order — the four empty initialisations
  `entry_signal=''`, `run_created=''`, `entry_status=''` and `parent_pid=''`, then the
  `trap` lines, then the `[ -e ]`
  refusal, then `/bin/mkdir -- "$run"` with the guard set from its captured status, then
  the two subdirectories — and the
  reviewer checking that those four initialisations all precede the `trap` builtins, so
  that no variable a trap, a checkpoint or the `EXIT` trap reads can be unset when `set -u`
  meets it, that no statement between them can create `.run` without the guard,
  and that no signal trap body does anything but record a name. One more line joins that
  list this round, and it is a position rather than a value: **the `EXIT` trap's body runs
  `trap '' INT TERM HUP` after its status capture and ahead of the first external command
  the trap runs** — ahead of the `chmod` and ahead of the `/bin/rm` — which is what makes
  those two inherit the ignore rather than the caller's third `Ctrl-C`, with the capture
  first because `trap` would otherwise clobber the status (R1). The status rule is
  part of what is read too: a status above 128 with `.run` present sets the guard, because
  the producer was killed after it had created the directory (R1).
  What the four cases above still carry is everything downstream of that: case 2 proves
  the `EXIT` trap is armed and removes a `.run` that holds `tmp` and `home` and no compiled
  file,
  and the pre-parent signal case below proves a signal arriving with `.run` on disk and no
  parent takes the branch that removes it.

  No entry output is needed for any of this, and the entry is not asked to print its run
  directory path — which is no longer worth asking for, since it is always `<output>/.run`.
  The test also asserts the entry's exit status is 0 in case 1, the entry's own non-zero
  `E_RUNTIME` status in case 2, where no child ever ran, and the child's own non-zero
  status in cases 3 and 4.

  **The caller's umask cannot change the run tree's modes, and one case proves it from
  both ends.** Every mode this test already checks — `.run` and its `tmp` and `home` at
  0700 in cleanup case 2, the four files and the directory at 0500 in cleanup case 1 and in
  the group-2 fixtures, the parent's sandbox `home` and `tmp` at 0700 in cleanup cases 1
  and 4 — is a mode that only appears if the process asking for it has a umask that permits
  it, and nothing in the environment scrub resets a umask (R1, R5). So the test runs the
  entry twice more, in a subshell that sets the caller's umask first:

  - *With `umask 000`.* The run completes and exits 0, and the assertions of cleanup case
    1 all hold. The entry's own tree is read while it still exists, with the mechanism the
    pre-parent signal case already uses: the test polls the output directory in the
    background until `<output>/.run/home` appears, and reads the modes of `.run`, `.run/tmp`
    and `.run/home` at that moment. `home` is the right thing to poll on because it is
    created immediately after `.run` and removed before the 0500 pass, so its presence is
    exactly the window in which the run directory is still 0700 (R1) — and the window is
    two C compiles wide, not a few instructions. All three must read exactly 0700. Without
    the entry's own `umask 077` all three would read 0777, which is what makes this an
    assertion rather than a formality. If the poll misses the window the case retries the
    run, bounded the way the stopped-parent case is, and a case that never catches it fails
    with a message saying so rather than passing quietly.
  - *With `umask 777`.* The same run and the same three reads, with the same answer: 0700,
    and exit status 0. This is the half that proves the entry *set* its own umask rather
    than inheriting a convenient one. Under an inherited 777 the `mkdir` would produce a
    directory the entry cannot enter, so the very next step — creating `tmp` inside it —
    would fail and the run would refuse `E_RUNTIME` long before it reached a compile. A run
    that completes at all under `umask 777` is only possible because the umask was replaced.

  Both halves also assert the parent's side, since the parent is launched from that same
  process and inherits from it: after each successful run the output directory's `home` and
  `tmp` are 0700 and `child.stdout` and `child.stderr` are 0600, whichever umask the caller
  set. That is the entry's umask being inherited rather than the parent's own being proved,
  so the parent's `umask(077)` (R5) gets its own reading in group 2, where the test invokes
  the parent directly and can therefore set the caller's umask on it: the group-2 fixture
  builder runs one of its successful direct-parent invocations under `umask 000` and
  asserts the same four modes. The whole case is cheap — two umasks, one entry run each,
  one direct-parent run, and mode reads the test already does elsewhere — and it is the
  only place in R10 that would notice a shipped file losing its `umask` line, because every
  other mode assertion runs under a suite that sets `umask 077` for itself the way
  `portable-profile-resolution.test.sh:5` does.

  **A signal mid-run is tested, and the test is deterministic because it freezes the
  resolver before signalling.** R2's group termination has no other proof, so the signal
  path has to run every time rather than whenever the timing happens to work out. The test
  starts the entry in the background on a real resolution — the default profile request
  with this repository as the mapped root — with the entry's stderr redirected into a file
  in the test's own scratch, and then, before it signals anything, waits for the resolver to
  exist: it polls that file for a line matching `^runtime-pgid: [0-9]+$` up to a bounded
  number of short waits, and takes `<n>` from it.

  **It reads the group id from that line and not from the process table, because only the
  parent knows which child is the runtime.** The parent runs the two digest tools and the jq
  `--version` probe before it forks the resolver (R7), so an earlier round's
  `pgrep -P <entry pid>` chain — the entry's only child, then that child's own child — could
  legitimately return a digest tool that happened to be alive when the poll looked, and
  freezing *that* group would prove nothing while looking exactly like success. So the
  identification moves to the one process that cannot get it wrong: the parent reports its
  own `runtime-pgid: <n>` immediately after the fork (R2), and the test reads that.
  `pgrep -P` is gone from this test, and there is no `ps -o pgid=` fallback either — a
  fallback here would be a second, worse identification competing with a correct one.
  Capturing the entry's stderr to a file and polling the file is enough, for two reasons
  stated in the requirements it depends on: the parent writes the line unbuffered before it
  enters the poll loop (R2), and the entry passes stderr through unchanged rather than
  capturing or buffering it (R1). That the line is a best-effort non-blocking write a full
  pipe could lose (R2) is exactly why this case redirects stderr into a plain file rather
  than reading it through a pipe: on a regular file the write can neither block nor return
  `EAGAIN`, so the line this poll waits for is always written. A FIFO the test creates and
  reads, or a `tail -f` on the
  redirected file, would do the same job; the plan may use any of the three, and the plain
  file is the simplest because it needs no reader process to start or clean up. What it must
  not do is wait for the entry to finish before reading, since the whole point is to read
  the line mid-run.

  Once the line is in hand the test sends `SIGSTOP` to the group `<n>` names, and requires
  both that the `kill` succeeds and that the group still has a member afterwards. A
  stopped group cannot make progress and cannot finish, so from that moment the run will
  not end on its own and there is no race left to lose. Only then does the test send
  `SIGTERM` to the entry.

  What must follow, in order: the entry forwards `SIGTERM` to the parent and waits; the
  parent's handler sends `kill(-pgid, SIGTERM)`, waits briefly, then sends
  `kill(-pgid, SIGKILL)`, which is what actually kills the frozen group, reaps the child
  and exits `128 + 15`; the entry's wait loop finds the pid reaped and ends, its trap
  chmods the run directory
  back to 0700 and removes it, and the entry exits `143`. The test asserts the three
  observable ends of that: `pgrep -g <n>` finds no process and `kill -0` on the group
  fails, the output directory it gave the entry holds no `.run` entry so the run directory
  is gone, and the entry's exit status is `143`, which is `128 + SIGTERM`. `pgrep -g` stays
  in the test where `pgrep -P` is gone, and the difference is worth naming so the plan does
  not remove the wrong one: `-g` asks whether a group the test has already identified is now
  empty, which is an assertion about a known number, while `-P` was being asked to work out
  which process the runtime was.

  **If the group is gone before the freeze lands, the test fails.** There is no fallback in
  which a completed run counts as signal coverage, because a run that finished before the
  freeze proves nothing about group termination. Two outcomes are failures here rather than
  skips. The bounded poll for the `runtime-pgid` line expiring is one: it means the parent
  never got as far as forking the resolver, so there was no group at any point the test could
  see. A `SIGSTOP` that finds the group already empty is the other — the `kill` failing with
  no such process, or no member left immediately after it — which means the resolution
  finished on its own between the line and the freeze. Both print a message saying the
  fixture was too short on this machine. The fix is one
  of two, decided in the plan rather than papered over at run time: enlarge the fixture so
  the resolution takes long enough for the freeze to land, or drive the parent
  directly in the group-2 style with a deterministic pause in the launched runtime so the
  group is guaranteed to be alive when the test signals. Either way the `SIGSTOP` freeze
  runs, and the mid-run path is exercised on every platform the test runs on.

  **A second signal during that termination is the same case run once more, and it is this
  round's find.** The mid-run case above sends one `SIGTERM` and the entry's wait loop
  never has to survive a second interruption, so nothing in the suite covers the thing a
  user actually does: pressing `Ctrl-C` again because the first press did not appear to do
  anything. The window is real and wide — the parent is inside its
  `SIGTERM`-then-wait-then-`SIGKILL` sequence against a group that has been `SIGSTOP`ped,
  so it cannot finish quickly — and the failure it guards against is the worst one this
  requirement has: an entry that takes a second wait's `128 + signal` for the parent's
  status, exits, and lets its `EXIT` trap remove `.run` out from under a resolver that is
  still alive (R1).

  So the test runs the mid-run case a second time, identically, up to the point where it
  signals: same fixture, same live read of the `runtime-pgid:` line, same `SIGSTOP` on the
  group with the same two requirements before it proceeds. Then it sends `SIGTERM` to the
  entry, waits 100 ms, sends a **second** `SIGTERM`, waits 100 ms more, and sends a
  **third** — that last one to the entry's whole process group rather than to its pid, for
  the reason the last paragraph of this case gives. A variant sends `SIGINT` as the
  second signal instead. Both runs need the entry in a process group of its own —
  `set -m` in the test shell, the way the group-signal case below already does it — the
  variant because a shell starts an asynchronous child with `SIGINT` ignored when job
  control is off, and a signal ignored at entry cannot be trapped at all (R1's measurement
  records that, and a variant that skipped the detail would assert against a signal the
  entry never received), and every run because the third signal is aimed at a group and
  would otherwise be aimed at the test's.

  It asserts the same three observable ends as the mid-run case — `pgrep -g <n>` finds no
  process and `kill -0` on the group fails, the output directory holds no `.run`, and the
  entry's exit status is `143` — and two more that are what this case exists for.

  **Four: `.run` is never gone while the parent is alive.** The test records the order
  rather than inferring it. Before it sends the first signal it takes the parent's pid —
  the entry's only child at that moment, by R1's rule that the entry runs no pre-parent
  child in the background and by the parent being alive, which is what the
  `runtime-pgid:` line already proved — and from the first signal until the entry exits it
  polls, every few milliseconds, two facts together: `kill -0 <parent pid>` and whether
  `<output>/.run` exists. A sample that finds `.run` gone while the parent still answers
  is a failure, and the case fails on the first such sample rather than at the end. Using
  the entry's child here is not the `pgrep -P` the mid-run case bans above: that ban was
  about
  identifying the *runtime*, where the parent's own digest and `--version` children made
  the answer ambiguous, and this question — which process is the entry's child — has
  exactly one answer by construction. The test proves it took the right one anyway, by
  requiring the pid it polled to equal the pid in the `entry-signal: TERM forwarded <pid>`
  line the entry writes on the way out. Say plainly what a sampler can and cannot do: it
  can catch an entry that exits on the second wait, because that leaves the parent alive
  for as long as its `SIGKILL` sequence takes, which is hundreds of milliseconds here and
  so tens of samples wide at a few milliseconds each; and it cannot prove the ordering at
  instants it did not sample. The
  guarantee itself comes from R1's loop, which a reviewer reads; this assertion is what
  fails loudly if a plan writes two `wait` calls instead.

  **Five: exactly one `entry-signal:` line, and it names the first signal.** The entry's
  stderr, read from the plain file this case already redirects it to, holds one
  `entry-signal:` line and no more, and that line is `entry-signal: TERM forwarded <pid>`
  in both the repeated-`TERM` run and the `TERM`-then-`INT` variant — `TERM` in the
  variant too, because the traps keep the first name (R1). Nothing asserts what became of
  the second signal, because nothing observable should depend on it: the entry does not
  re-forward it and does not record it, and R1 says so in those words.

  **And a third signal, sent to the whole group, with an honest statement of what it does
  and does not prove.** The window this round's other fix protects is the inside of the
  `EXIT` trap: a signal landing there reaches the `chmod` and the `/bin/rm` as well as the
  shell, which is why the trap ignores all three before it runs either (R1). So the case
  sends a third signal — `TERM` to the entry's whole process group, the way a terminal
  sends one, which is what puts it in front of the cleanup's children rather than only the
  shell — a further 100 ms after the second. Both runs therefore need the entry in a
  process group of its own, so the `set -m` the `SIGINT` variant already required now
  covers the plain repeated-`TERM` run too; without it the third signal would reach the
  test's own shell. Then the case asserts nothing new: the same
  `.run`-is-gone, dead-group, status-`143` and one-`entry-signal:`-line assertions the case
  already makes, all of which a broken cleanup fails, since a `/bin/rm` stopped part-way
  leaves the run directory behind. What the case cannot do is guarantee the third signal
  lands *inside* the trap rather than before or after it. Making that deterministic needs a
  slow removal — a run tree large enough that `rm` takes visible time, or a pause inside
  the trap — and the second is the test-only hook this spec refuses everywhere, while the
  first buys minutes of CI time for a race it still would not pin down. So the coverage is
  split and said out loud: the third signal is a cheap extra shot at the window on every
  run, and the actual proof is the read above — the `trap ''` line precedes the first
  external command of the trap body — beside the two repeated-signal assertions, which
  already fail loudly on the neighbouring bug.

  **A signal that arrives before the parent exists is tested as its own case, because the
  entry's other branch is reachable.** The traps are installed ahead of the `mkdir` that
  creates `.run`, and both are ahead of the pin checks and the two compiles (R1), so there
  is a real window in which
  the entry has a run directory and no parent, and the branch that handles it — the trap
  records the name, the next checkpoint exits `128 + signal`, and the `EXIT` trap chmods,
  removes and writes one `entry-signal:` line, with nothing forwarded to anybody —
  has no coverage from the mid-run case above. So the test runs the same real resolution in
  the background a second time, with the entry's stderr redirected into a plain file in the
  test's own scratch, polls the output directory for the `.run` entry with a bounded number
  of short waits — 10 ms each, say —
  and sends `SIGTERM` to the entry as soon as it appears. Polling for the directory rather
  than for a process is what makes this land in the window without slowing anything down:
  `.run` is created before the first pin check, and ten pin checks and two compiles run after
  it.

  **Four assertions, and the first two are what make it a test of the branch.** One: the
  entry's stderr holds exactly one `entry-signal:` line, and that line is
  `entry-signal: TERM no-parent` (R1) — the entry saying, in the one process that knows, that
  it took the no-parent branch. Two: no `runtime-pgid:` line was written at all, which is the
  separate and stronger statement that the parent never got as far as forking a resolver
  (R2). Three: the exit status is `143`, which is `128 + SIGTERM`. Four: the output directory
  is **completely empty** — no `.run`, and nothing else either. An earlier round of this
  spec asserted only the last two, and that was not enough: an empty output
  directory cannot tell "no parent existed" from "a parent started and had not created its
  sandbox yet", because the second leaves nothing in the directory to see either, so the
  case could pass without ever entering the branch it exists to cover. Only the stderr line
  separates them. If the parent did start, that line reads `forwarded <pid>` instead — and
  if it got as far as forking, the `runtime-pgid:` assertion fails beside it — and the case
  fails with the landed-too-late message below rather than passing on a side effect.

  **The test waits for the entry with a bounded timeout rather than expecting it to exit at
  once.** The signal is deferred: bash runs the recording trap only after the foreground
  child the entry is currently waiting on completes, and the checkpoint that acts on the
  recorded name comes after that (R1); at the moment the signal lands that child may be
  a compile. So the timeout has to exceed one compile on a slow machine — the plan measures
  that step and sets the number from the measurement rather than guessing it — and the
  timeout expiring is a failure, not a skip. The test reads the stderr file after the entry
  has exited, which is the one place this case is simpler than the mid-run one: there is
  nothing to read mid-run here, because the line it asserts is written by the `EXIT` trap on
  the way out, so no live read, FIFO or `tail -f` is needed.

  The remedy for landing outside the window is unchanged, and it is not the same as the
  mid-run case's, because this failure means the poll was too *late* rather than the fixture
  too short: a shorter poll interval, or a wider pre-parent window —
  the ten pin checks and both compiles are already in it — decided in the plan, and never a
  skip. What the case
  deliberately does not assert is *which* step the signal interrupted —
  a pin check, either compile, or the mode pass, whichever the machine happened to be on —
  because the branch under test is the same one in every case and the claim is about what it
  says and what it leaves behind.

  **A terminal signal to the whole foreground group is the fourth case, because that branch
  is reached two different ways and the case above drives only one of them.** The
  pre-parent case sends `SIGTERM` to the entry's pid alone, which is what a plain `kill`
  does and is not what a `Ctrl-C` at a terminal does: a terminal signals the entire
  foreground process group, so the pin check, the compile or the `cp` the entry is waiting
  on gets the signal too and exits non-zero because of it. That is the path on which a
  refusal written beside the command — `cmd || refuse E_RUNTIME` — turns an interrupted
  run into an `E_RUNTIME` report and loses the signal exit the caller is owed (R1), and no
  case above can catch it, because a signal delivered to one pid leaves the foreground
  child untouched and its status is whatever it would have been.

  So the test runs the same real resolution a third time, with the entry in a process
  group of its own — `set -m` in the test shell, or any equivalent that puts the
  background entry in a fresh group, with the group id recorded — polls the output
  directory for `.run` exactly as the case above does, waits until a compile is the
  foreground step, and then sends `SIGTERM` to the **group**: `kill -TERM -<pgid>`, not
  `kill -TERM <pid>`. How it knows a compile is running is the plan's to settle from the
  same measurement the pre-parent case's timeout needs — the compiler's `-o` target appearing inside
  `.run` is the cheap answer, a short fixed delay after `.run` appears is the other — and
  landing outside that window is a failure with the same remedy as the case above, never a
  skip.

  Four assertions, and the third is the one this case exists for. One: the exit status is
  `143`, which is `128 + SIGTERM`. Two: the entry's stderr holds exactly one
  `entry-signal: TERM no-parent` line — the same branch the case above proves, reached by
  the other route. Three: that stderr holds **no** `E_RUNTIME` line at all, which is the
  assertion that fails if a compile's signal death was reported as a runtime refusal.
  Four: the output directory is completely empty. The bounded wait for the deferred trap,
  the reading of stderr from a plain file in the test's own scratch, and the
  landed-too-late message are the pre-parent case's, unchanged; what differs is the
  signal's target and the third assertion.

  **A fifth signal case drives the parent directly, for the window in which the parent
  itself has no runtime group yet.** The four cases above are all about the entry. None
  reaches R2's `no-runtime` branch: the two mid-run cases signal after `runtime-pgid:` has
  been
  read, so `pgid` is set, and neither pre-parent case starts a parent at all. The branch
  in between — a parent that is running, has installed its handlers, and has not yet forked
  the resolver because it is still doing blob and jq checks (R2) — needs the parent on its
  own, so this case is written in the group-2 style with a run directory the test builds by
  hand.

  The sequence is three signals, and it is as close to deterministic as this branch can be
  driven from outside the parent — which is not all the way, for the reason the retry
  paragraph below gives. The test starts the
  parent in the background and **immediately** sends it `kill -STOP`, so it cannot make
  progress past process start; then `kill -TERM`, which stays pending on a stopped process;
  then `kill -CONT`, which is what lets the installed handler run. Alongside the parent, and
  before any of that, the test starts a sentinel `sleep` in the **same process group as the
  parent** — the test's own group, which is what a plain background child joins.

  Three assertions, and they are the assertions of an attempt that actually reached the
  branch; an attempt that ends in either of the two outcomes below is retried before any of
  them is treated as a failure. One: the parent's exit status is `143`, which is `128 + SIGTERM`. Two:
  its stderr holds `parent-signal: TERM no-runtime` and **no** `runtime-pgid:` line — the
  first says the handler ran and took the branch, the second says there was no resolver
  group for it to take the other one. Three: the sentinel `sleep` is still alive afterwards,
  which is the assertion that actually earns the case — it fails if the handler ever reached
  the caller's process group, whether through a zero `pgid` or a literal `kill(-0, …)`, and
  it fails loudly because the group in question is the test's own (R2).

  **Two outcomes are not proof, and both of them are retried rather than failed on.**
  The first is a `runtime-pgid:` line: the `SIGSTOP` landed after the fork, so the parent
  got all the way through its pre-resolver checks and started the resolver before the stop
  took effect, and the attempt exercised the group branch, which already has its own case.
  An earlier round of this spec made that outcome an immediate failure, and that was wrong:
  nothing in the test can guarantee the stop lands first. The `kill -STOP` is sent by the
  test shell after the parent has been started in the background, so between the two there
  is a fork, an exec and however long the scheduler takes to run either process — and on a
  fast machine, or a loaded one where the test shell is the process that gets descheduled,
  the parent can be through its checks by then. It is a scheduling artefact of driving
  another process from a shell, not a fault in the implementation, and a correct
  implementation will still produce it sometimes on a busy runner. Failing on it makes this
  case flaky in CI for a reason that says nothing about the code under test.
  The second outcome is a parent that died with no `parent-signal:` line at all: the
  `SIGTERM` was delivered before the handlers were installed and the default disposition
  killed it — the process-start window R2 keeps as small as it can. That one was already
  retried and stays retried.

  So the two share one budget and one mechanism. The test **retries the whole attempt** on
  either outcome, bounded to a stated number of attempts: twenty, written into the test
  rather than left open, and the twenty are the total across both outcomes rather than
  twenty of each. Every retry prints which of the two ended the attempt — the stop landing
  late, or the signal landing early — so a run that is drifting toward flaky says so while
  it is still passing. The case fails only when the budget is exhausted without a single
  proving attempt, and the failure message carries the count of each outcome, so the
  operator reading it knows which way to move the timing: a shorter path to the `kill -STOP`
  if the stops are late, a wider gap before the `kill -TERM` if the signals are early.
  Neither outcome is ever counted as a pass.

  Say plainly what the retry costs and why it is the right trade: it is the honest price of a
  window the shipped code must not widen for a test's convenience. Making either outcome
  impossible would mean a pause, an environment variable or a test-only argv
  mode inside a security wrapper, which is the thing this spec refuses everywhere else, and
  neither window can be closed from outside: the early-signal one cannot be shortened below
  a process start because the handlers are already the first statements of `main` (R2), and
  the late-stop one cannot be widened without the parent agreeing to wait, which is exactly
  the test-only hook that is refused. **One success proves the branch**, and the
  branch is the same one every attempt aims at, so twenty attempts is a scheduling
  allowance, not twenty different tests.

  **The fork-and-publish window is proved by reading, not by a signal case of its own.** The
  gap R2 closes with the signal mask is a few instructions wide and lies between a `fork`
  and the assignment that publishes what it returned. Nothing a test can do puts a signal
  in it on demand: there is no stop point in there to reach without a test-only pause
  inside the security wrapper — the thing this spec refuses everywhere else — and a
  poll-and-signal loop aimed at it would miss on essentially every attempt while proving
  nothing on the attempts it missed, so a case built that way would pass by not landing in
  the window, which is worse than having no case. The coverage is therefore stated
  honestly: the plan quotes the sequence for every fork the parent performs —
  `sigprocmask(SIG_BLOCK, …)`, `fork`, `setpgid`, the `pgid` or `pre_child` assignment,
  `sigprocmask(SIG_SETMASK, …)`, and then, outside the region, the `runtime-pgid:` line;
  with on the child's side the `SIG_DFL` resets first and the mask restore after them,
  before `execve` — and the
  reviewer checks
  that every fork in the file sits inside one such region, and that nothing which can
  block — the `runtime-pgid:` write above all — sits inside one with it (R2). The same
  reading covers the handler installations themselves, and for the same reason: the
  reviewer checks that all three `sigaction` calls set `sa_mask` to `SIGINT`, `SIGTERM` and
  `SIGHUP` and leave `SA_RESTART` unset, because a sibling signal re-entering a handler
  that is part-way through the kill and the reap is the other way this state can be raced,
  and no test can put one there on demand either (R2). The five
  signal cases above
  are unchanged by the mask and must still pass exactly as written, which is the other
  half of the check: the mask changes *when* a pending signal is delivered, never which
  branch the handler takes once it runs.

  **The same is true of the diagnostics moving after the cleanup, and each of the five
  cases was checked rather than assumed.** R2's handler and R1's `EXIT` trap write their
  `parent-signal:` and `entry-signal:` lines last, after the killing and the removal, so
  the assertions above are worth re-reading in that order. This round's redesign of the
  entry's signal path — traps that only record, a main flow that acts at checkpoints (R1) —
  changes none of the three either: it moves where each step is written, not which steps
  run, in what order, or what any of them leaves observable. The mid-run case does not read
  either line — it reads the `runtime-pgid:` line, which is still written on the normal path
  before the poll loop. That line did move: out of the blocked-signal region, to after the
  mask restore, and onto the same best-effort non-blocking write (R2). The case is
  unaffected by both halves of that, and neither is taken on trust — the line is written
  before the poll loop exactly as it was, so the poll still finds it, and the case reads it
  from a plain file where a non-blocking write can neither block nor fail. Its three
  assertions are about a dead group, a gone run directory and a status of `143`, all of
  which the new order reaches sooner rather than later. The pre-parent case still finds
  exactly one
  `entry-signal: TERM no-parent` line and no `runtime-pgid:` line, because the `EXIT` trap
  writes that line after the chmod and the removal and still before its `exit`, and the case
  already reads the file only after the entry has exited; the plain file it reads is also
  why that last-position write cannot hang here at all (R1). The group-signal case added
  this round reads the same line out of the same kind of plain file and the same sentence
  covers it; its extra assertion is a negative one, about an `E_RUNTIME` line the entry
  must never write on a signal path, which no ordering of the diagnostics can affect.
  The repeated-signal case added this round reads the `entry-signal:` line from that same
  plain file after the entry has exited, so the same sentence covers it too; its two extra
  assertions are untouched by where the diagnostics are written, and one of them is
  strengthened by it. The count-and-name assertion is about a line the `EXIT` trap writes
  once whatever else happened, and the ordering assertion compares `.run` against the
  parent's liveness, which is settled before either line is written — the trap's line is
  the last statement before the entry's own `exit`, so no diagnostic can sit between the
  parent's exit and the removal in either direction (R1).
  The stopped-parent case
  still finds `parent-signal: TERM no-runtime`, because that branch kills nothing and
  reaps nothing, so "after the killing" is immediately, and its sentinel assertion is
  about what the handler did not signal rather than about when it wrote. No assertion is
  dropped or weakened; only the order the prose describes changes.

  The test also
  asserts every pinned blob constant equals the working tree's `git hash-object` output —
  the two C sources and all eight files of the runtime's loaded set that R5 enumerates as
  entry-pinned, and separately, in the parent, the three constants of the parent-pinned
  subset. **And it asserts the computed id equals `git hash-object` for every one of those
  files.** Neither shipped file runs git any more; each builds the blob id from a size and a
  SHA-1 (R1), and the only thing keeping that construction honest is checking it against
  the tool it replaces. So for each pinned file the test computes the id the way the entry
  does, and requires the computed id, `git hash-object`'s answer and the pinned constant to
  agree — three values, not two. The test may run git freely: it is not a shipped file, and
  the allowlist grep below covers the two shipped files only.

  **The read allowlist is a grep, not a promise, it covers external command words only, and
  the mechanism is settled here rather than left to the plan.** The list it checks against is
  R7's: `/bin/bash`,
  `/bin/mkdir`, `/bin/cp`, `/bin/chmod`, `/bin/rm`, `/bin/cat`, `/usr/bin/uname`,
  `/usr/bin/printf`, `/usr/bin/env`,
  `/usr/bin/stat`, the compiler pair `/usr/bin/cc` and
  `/Library/Developer/CommandLineTools/usr/bin/clang`, and the three digest tools
  `/usr/bin/shasum`, `/usr/bin/sha256sum` and `/usr/bin/sha1sum` — fifteen command words.
  `/usr/bin/awk` is deliberately not among them: neither shipped file executes host awk,
  and pass 1 below classifies it as data and then says where it is allowed to stand.
  An earlier round of this spec described the sweep as "every absolute path under
  `/usr/bin`, `/bin` or `/Library/Developer/CommandLineTools/usr/bin`, and every bare command
  name", which is not something a test can be written from. Taken literally it fails on `cd`,
  `printf`, `umask` and `[`, which are bash builtins the entry uses and not external
  commands at all,
  and it misses an absolute path under a fourth prefix. The invariant is about what these two
  files **execute**, so the grep has to separate three things: an absolute path that names an
  executable, a builtin or reserved word that starts no process, and an absolute path that is
  data rather than a command, and it needs a fourth thing that is none of those three — a
  variable expansion standing where a command word goes. Three documented sweeps over both
  shipped files do that.

  1. *Absolute-path tokens.* Every token beginning with `/` is extracted, and each one must
     be either one of the fifteen words above or one of the five absolute paths these files
     name as data rather than as commands: the SDK root passed to `-isysroot`
     (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, R1), the `PATH` value
     `/usr/bin:/bin` the entry writes into its own environment and into every `env -i` line,
     the two `/proc` paths the copied Linux `process_group_count` uses — `/proc` itself
     (`portable-profile-resolution-launcher.c:178`) and the `/proc/%s/stat` template
     (`:204`) — and `/usr/bin/awk`, which the entry copies and names in the Darwin shim
     text and never executes (R7). Anything else fails, whatever prefix it carries. Matching
     on the leading slash
     rather than on a list of directories is the point: the Darwin compiler took the prefix
     set to three, and a grep that knew only the prefixes somebody told it about would
     silently pass a shipped file that had grown a fourth.

     **And `/usr/bin/awk` gets a position assertion of its own, because a data
     classification alone would weaken this invariant rather than strengthen it.** The
     other four data paths cannot be run by accident — an SDK root, a `PATH` value, a
     directory and a `printf` template are not executables — but awk is, and a slip back
     to `reproduce.sh:18`'s `… | /usr/bin/awk '{print $1}'` would now pass pass 1 as a
     listed data path and pass 2 as no bare word at all. So the test asserts the two
     positions R7 enumerates and no others: every occurrence of `/usr/bin/awk` in the
     entry is either the second word of a `/bin/cp` command whose third word is inside the
     run directory, or inside the quoted shim text passed to `/usr/bin/printf`, and none
     of them is the first word of a command — which is the same command-position
     extraction pass 2 already performs, run a second time and asked for the opposite
     answer. The C parent must not contain the token at all. That is what makes an
     accidental host-awk invocation a CI failure rather than an allowlisted path in a new
     place. The test may still run awk freely for its own parsing, the way the existing
     test does at `scripts/test/portable-profile-resolution.test.sh:448-449`, for the
     same reason it may run git: the sweeps cover the two shipped files only.
  2. *Bare words in command position, in the entry only.* The C file has none — it names its
     executables as string literals, which pass 1 already covers. The entry does, so the
     test takes the first word of each command in it and drops every name `compgen -b`
     reports (the builtins: `cd`, `pwd`, `exec`, `wait`, `trap`, `set`, `unset`, `export`,
     `builtin`, `shopt`, `unalias`, `printf`, `read`, `local`, `return`, `exit`, `[` and the
     rest) and every name `compgen -k` reports (the reserved words: `if`, `then`, `else`,
     `fi`, `case`, `esac`, `for`, `while`, `do`, `done`, `function`, `[[`, `]]`, `!` and the
     rest). Deriving both sets at run time from `/bin/bash` rather than hard-coding them is
     the choice this spec makes, and the reason is drift: `/bin/bash` is the same interpreter
     the entry runs under, so the exclusion set is exactly that shell's and cannot fall out
     of step with a list somebody typed into the test. What must remain after those two drops
     is **nothing at all**, because every external command the entry runs it runs by absolute
     path — so any surviving bare word is either a `PATH` search or a new external command,
     which is precisely what this invariant exists to catch. Variable expansions in command
     position (`"$compiler"`, the chosen SHA tool, the bound jq, the compiled parent inside
     the run directory) are not bare words and are not swept here; pass 3 covers them.
  3. *Variable expansions in command position, checked by name.* Pass 2 has to let those
     through, and on its own that would leave a hole big enough for the exact thing R7's
     compiler bullet forbids: `${CC:-/usr/bin/cc}` is neither a bare word nor an
     unlisted absolute path, so it would slip past both sweeps while handing the caller the
     compiler back. So the test collects the parameter *names* that appear in command
     position and requires every one of them to be a name the entry itself assigns — the
     chosen compiler, the chosen SHA-1 and SHA-256 tools, the bound jq, and the compiled
     parent inside the run directory, a short list the plan fixes and the test spells out.
     A name the entry never assigns fails, `CC` above all, and so does a default-value
     expansion on any of them, since `${x:-…}` reintroduces exactly the override this
     forbids. What pass 3 does not check is *values*: what those names hold comes from the
     per-platform `case` and from the run directory's own path, and reading those tables is
     a review item (R8, and the platform-matrix concern).

  The grep is deliberately not a parser. `shellcheck -f json` was considered as a way to get
  command positions for free and rejected: it would put a linter's syntax tree in the middle
  of a security invariant, and the invariant would then be only as strong as that tool's
  version and warning set. Three sweeps, one of them with a runtime-derived builtin list,
  can be checked by reading them. `bash -n` stays where it already is — the entry has to parse — and is no part
  of this invariant.

  **This round the list loses a word, and it loses it to the other side of the same
  grep.** `/usr/bin/awk` moves from the command words to pass 1's data paths, with the
  position assertion above holding it there, because neither shipped file ever runs host
  awk — the entry copies the file in, or on Darwin writes a shim that names it, so that
  the runtime can execute the copy from `.run` (R7). Sixteen becomes fifteen, and it is
  the first word to move since the mechanism above was settled; no round between the two
  moved one. Three
  changes came with the round before it, all from the same two findings. `/usr/bin/git`
  **left the list**, because the two shipped files compute blob ids instead of running
  `git hash-object`. The Darwin compiler joined as
  `/Library/Developer/CommandLineTools/usr/bin/clang`, the first time the
  grep had to look outside `/usr/bin` and `/bin`. And `/bin/cat` and `/usr/bin/sha1sum`
  joined as the blob-id construction's two new tools (R1).
  `/usr/bin/env` and
  `/usr/bin/stat` joined the round before that (the explicit compile and launch environment,
  and the output-root owner and mode check, R1); `/usr/bin/mktemp` left a round earlier
  still,
  when the run directory became `<output>/.run`, and `/usr/bin/find` was never on it.
  Anything else — a new tool, a bare name that
  would be resolved through `PATH`, a `${CC:-…}` style override — fails CI, which is what
  makes R7's list an invariant rather than a paragraph someone has to keep true by hand.
  What it cannot make an invariant is the third read claim in R7: the supervisor's
  process-table reads are `opendir`, `fopen`, `proc_listallpids` and `proc_pidinfo`, not
  command words, so no grep sees them and they rest on code review of the copied block.
  The downloader grep that was already here gets simpler rather than staying alongside it.
  It existed because `/usr/bin/git` was on the allowlist: `curl`, `wget` and `nc` failed
  the allowlist as unlisted commands, but `git fetch` and `git clone` needed their own
  assertion that no subcommand other than `hash-object` appeared. With git off the list
  entirely, `git` fails the allowlist exactly as the three downloaders do — bare `git` is a
  pass-2 word that is neither a builtin nor a reserved word, and `/usr/bin/git` is a pass-1
  token that is neither one of the fifteen nor one of the five data paths — and the
  subcommand assertion goes away — one fewer invariant to keep true by hand, and a
  stronger claim than the one it replaces. The test
  is shellcheck-clean,
  leaves the schema guard at zero failures, and passes
  `scripts/test/v2-check-rename.test.sh`.

## Design

Order, each step checkable before the next:

1. **`resolver/v1/trusted-launch.c`** — copy the test launcher's supervisor, limit,
   error-sanitising and environment-construction code verbatim under the copied-from
   header; delete the test-only argv modes (`trap-child`, `limit-child`, `limit-control`,
   `loader-control`, `resolve-missing-helper`, `resolve-git-wall`,
   `portable-profile-resolution-launcher.c:547-631`); replace the
   `YSTACK_TEST_SANDBOX` variable (`:640-644`) with a required output-path argument; take
   the run directory as a further argument and add the R5 checks, including the helper's
   run-directory and mode-0500 checks, the output-directory rule that admits exactly a
   `.run` entry and requires it to be the run directory the parent was handed — which
   re-checks on an opened descriptor what the entry already refused by path (R1, R5), and
   which proves that last fact by `fstatat(out_fd, ".run", …, AT_SYMLINK_NOFOLLOW)` with an
   `S_ISDIR` test and then equal `st_dev`/`st_ino` off two `fstat`s, never by comparing
   `realpath` answers, with the listing done by `fdopendir` on a `dup` of that descriptor
   (R5) — and
   the check order R5 fixes (length guard, then the output directory with its identity
   comparison, then the helper and run-directory checks, then the sandbox
   creation) — checks that the test script performs today or cannot perform at all.
   Every mode and ownership check is done with `fstat` on a descriptor
   the parent opened (`O_DIRECTORY|O_NOFOLLOW` for the run directory), never with `stat`
   on a path it will later hand on by name; `umask(077)` is called among the first
   statements of `main`, before any check and before any creation, where the copied
   launcher has no `umask` call at all and relies on the test harness setting one
   (`portable-profile-resolution.test.sh:5`), so the modes below are the modes that appear
   rather than the modes that were asked for (R5); and the sandbox's four entries —
   `home`, `tmp`,
   `child.stdout`, `child.stderr` — are created with `mkdirat` and `openat` relative to the
   output-directory descriptor the check opened, in place of the copied `mkdir` at
   `:645-647` and `open` at `:413-421`, which build them by path (R5). That descriptor is
   passed into the copied `supervise` (`:400-532`) and stays open for its life, which is
   the one signature change the deviation forces. The same move applies to the
   supervisor's reads back: `empty_regular_file` becomes an `fstat` on the kept
   `child.stdout` or `child.stderr` descriptor rather than an `lstat` on the path
   (`:112-116`, called at `:505,518,522,526`), and `stream_file` (`:84-86`, called at
   `:506`) and `sanitized_error` (`:118-120`, called at `:518`) take an `int` descriptor in
   place of their `const char *path`, `lseek` it to zero and keep the copied `read` loop,
   losing their own `open`/`close` bookkeeping; the two descriptors are opened `O_RDWR`
   rather than `O_WRONLY` so the parent can read back through them (R5). Two blocks here have no counterpart in the
   copied source and are written fresh: the blob-id pins for the three loaded files the
   parent re-checks (the runtime, `scripts/lib/profile-resolution.sh` and
   `resolver/v1/profile-resolution.jq`, all located from the runtime path with the
   runtime's own repository-root rule, `resolver/v1/profile-resolve-runtime.sh:9-10`), and
   the `INT`/`TERM`/`HUP` handlers that terminate the child's process group with
   `kill(-pgid, SIGTERM)` then `kill(-pgid, SIGKILL)`, reap, and exit `128 + signal` (R2).
   Those handlers are installed as the first statements of `main`, before any pin or digest
   work, each by a `sigaction` whose `sa_mask` is the whole set `SIGINT`, `SIGTERM`,
   `SIGHUP` — so a sibling signal cannot re-enter a handler that is part-way through the
   kill and the reap, and is discarded by the `_exit` every branch ends in — with
   `SA_RESTART` unset and `SA_SIGINFO` unused, and they carry the two
   `volatile sig_atomic_t` variables R2 specifies — `pgid`,
   `0` until it is assigned right after the `fork` (`:432`) and the parent-side `setpgid`
   (`:450`), and `pre_child`, the pid of the
   pre-resolver child currently being waited on (a SHA-1 tool, the SHA-256 tool, the jq
   `--version` probe), set before its `waitpid` and cleared after — with three branches on
   them: the group sequence when `pgid != 0`, `SIGTERM`-then-`SIGKILL` on that one pid when
   only `pre_child != 0`, and nothing to kill otherwise, never `kill(0, …)` or
   `kill(-0, …)` in any of them. Every `fork` the parent performs — the resolver's
   (`:432`) and each pre-resolver child's — is wrapped in
   `sigprocmask(SIG_BLOCK, &three, &saved)` before it and
   `sigprocmask(SIG_SETMASK, &saved, NULL)` after the parent has done its `setpgid` and
   assigned `pgid` or `pre_child`, so no handler ever
   runs between a `fork` and the publication of what it returned — and nothing else goes
   inside that region, the `runtime-pgid:` line being written after the restore rather than
   in there, because a stderr write that blocks with the three signals blocked would stop
   the handler running at all; on the child's side the
   three dispositions are reset to `SIG_DFL` **first, while the three are still blocked**,
   with `SIGPIPE` reset beside them, and the same mask is restored only after that — the
   resets because the child runs C code before `execve` and a pending signal unblocked
   ahead of them would run the parent's handler inside the child, the mask restore because
   the mask is inherited across `exec` (R2). Each branch ends by writing one line —
   `parent-signal: <NAME> group <pgid>` or `parent-signal: <NAME> no-runtime`, which is
   what R10's stopped-parent case asserts — **after** it has killed and reaped, not before,
   with stderr put into non-blocking mode and a single `write(2)` rather than the copied
   `write_all` (`:164`), a short write or `EAGAIN`/`EPIPE` ignored, and `SIGPIPE` set to
   `SIG_IGN` among the same first statements of `main`, so a blocking or closed stderr can
   never hold up the termination this path exists to guarantee (R2). One further line has no counterpart either: the single `runtime-pgid: <n>` written
   straight to stderr after the `fork` (`:432`), the parent-side `setpgid` (`:450`), the
   `pgid` assignment and the mask restore — **outside** the blocked-signal region, and
   best-effort in the same way the handler's line is, with stderr made non-blocking for one
   `write(2)` and the saved flags put back by a second `fcntl` afterwards, and a short write
   or `EAGAIN`/`EPIPE` ignored — and before the poll loop, so a reader can
   identify the resolver's process group without guessing at the process table (R2).
2. **`resolver/v1/resolve-profile.sh`** — in this order, each step refusing with
   `E_RUNTIME` before the next. **Scrub, then re-exec, before any external command** — the
   builtins-only scrub copied verbatim from
   `adapters/local-git-materializer/v1/materialize.sh:4-13` under the same `#!/bin/bash -p`
   shebang (`:1`), then `exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p
   "$script_path" __resolve_profile_clean "$1" "$2" "$3" "$4"`, adapted from `:22-29` in the
   marker word, the arity, the `-p` that carries privileged mode across the re-exec where
   the materializer drops it, and what the marker branch does as its own first
   statements — `case $- in *p*) ;; *) exit 78 ;; esac`, so an arrival that is not one of
   the two supported invocations is turned away before anything else in the branch is
   parsed, and only then the same builtin scrub plus `builtin unalias -a` and `builtin
   shopt -u
   expand_aliases` as defence in depth, and `umask 077` last among them, copied from
   `materialize.sh:31`
   because the scrub resets variables and not the process umask (R1), and then, still
   before the first external command, the four variables every trap and checkpoint reads
   declared empty — `entry_signal=''`, `run_created=''`, `entry_status=''`,
   `parent_pid=''` — so that under `set -u` a signal-free run's first checkpoint and a
   pre-directory refusal's `EXIT` trap read set names rather than aborting on an unbound
   one (R1) — with the clean path
   refusing unless its first argument is the marker
   word (R1), and the direct marker invocation documented as unsupported. Everything below
   runs in that second process. Then: resolve the
   repository root from its own `BASH_SOURCE`
   the way the runtime does (`resolver/v1/profile-resolve-runtime.sh:4-16`); refuse an
   unsupported platform, from a `case` over `/usr/bin/uname -s` and `-m` with one arm per
   supported tuple and a refusing `*)` arm, which is the branch R10 covers by review
   rather than by a test case; **validate the output root, before anything is written into
   it** — absolute path, the `PATH_MAX` guard (`<output>/.run/tmp/` plus a `NAME_MAX` name
   must fit), a real directory with no symlink component (`[ -d ]`, `[ ! -L ]`,
   `(cd -P … && pwd)` equal to the argument), owned by the current uid, mode exactly 0700
   read with the platform's `/usr/bin/stat` format, and empty by a `dotglob nullglob` glob
   (R1);
   then install the `EXIT`/`INT`/`TERM`/`HUP` traps **before** anything creates the run
   directory — and after the four empty initialisations above and after `run` itself is
   assigned from the validated output root, so nothing any trap reads is unset when it is
   armed (R1) — the three signal traps recording the **first** signal's name in
   `entry_signal` with an assign-if-empty, `: "${entry_signal:=TERM}"` and its two
   siblings, so a repeat or a second, different signal cannot overwrite a name the entry
   has already acted on (R1), and
   doing nothing else, and the `EXIT` trap's removal guarded by a `run_created` variable
   that stays unset until the directory is the entry's own; then refuse a pre-existing
   `.run` with `[ -e ]`; then create the run directory `<output>/.run` at mode 0700 with a
   plain `/bin/mkdir -- "$run"`, no `-p` and no `-m` — 0700 comes from the umask set above,
   not from the command — and set the guard from its captured status in the
   main flow — set on status 0, set also on a status above 128 with `.run` present, because
   `/bin/mkdir` exits 0 or 1 of its own accord so anything higher is the shell reporting
   that the caller's group signal killed it after it had created the directory, and left
   unset on any other non-zero status, which is `E_RUNTIME` (R1, measured); then create the
   0700 `tmp`
   and `home` subdirectories inside it for compiler scratch and the compiler's `HOME`,
   at 0700 by that same umask, a failure of either refusing `E_RUNTIME` into the trap that
   is by then already armed.
   That `EXIT` trap captures the status it was entered with, then sets `INT`, `TERM` and
   `HUP` to ignore with a bare `trap '' INT TERM HUP` — that order, because `trap` is a
   builtin and would otherwise overwrite the status, and this order still puts the line
   ahead of every external command in the body, so the `chmod` and the `/bin/rm`
   below inherit the ignore and a further signal to the foreground group cannot stop the
   removal half-done (R1); then
   removes the whole run directory whenever the guard is set (chmodding the directory
   back to 0700 first,
   because by launch time it is 0500 and a 0500 directory will not let its entries be
   unlinked), then writes one line to the entry's own stderr when `entry_signal` is set,
   then exits with `entry_status` if the main flow recorded one, else `128 + signal` if a
   signal was recorded, else the captured status. The main flow is what acts on a recorded
   signal, at
   a `checkpoint` — `[ -z "$entry_signal" ] || exit` — placed after the `mkdir`, after each
   pin check, after each compile, after the copies and immediately before the launch, and
   again around the wait on the parent. Every external command in this entry — each pin
   check, both compiles, both copies, and every `$(...)` that runs a tool — is written in
   three statements rather than two: run it with its status captured, then `checkpoint`,
   then the refusal on that captured status. `cmd || refuse` is forbidden here, because a
   terminal signal reaches the foreground command too, so its non-zero status would
   otherwise be reported as an `E_RUNTIME` refusal in place of the `128 + signal` exit and
   the `entry-signal:` line the caller is owed (R1). The two branches are `parent_pid`
   empty or not.
   With a parent, the wait is a loop rather than a fixed pair of `wait` calls: each
   `wait "$parent_pid"` that a trap interrupts returns `128 + signal` of its own with the
   parent still alive, and the loop tells that apart from a wait that reaped the parent by
   asking `kill -0 "$parent_pid"` — a live or zombie parent answers, a reaped pid gives
   `ESRCH`. While the parent answers, the entry forwards the recorded signal once with
   `kill -"$entry_signal"` (a `last_forwarded` variable keeps a further interrupted wait
   from re-sending it) and waits again; when the pid no longer answers, that wait's status
   is the parent's own, and the entry records it in `entry_status`, breaks and exits. So
   nothing is
   removed until the parent has actually been reaped, however many signals arrive,
   because the parent is what terminates the
   resolver's process group; without one, no group exists
   and there is nothing to forward to, so the checkpoint exits
   `128 + signal` and the `EXIT` trap removes the run directory — or nothing at all,
   if the guard is still unset. The line the `EXIT` trap writes names the branch —
   `entry-signal: <NAME> forwarded <pid>` or
   `entry-signal: <NAME> no-parent`, which is what R10's pre-parent case asserts — and it is
   the **last** step before the final exit, after the forward and after the removal, because bash's
   `printf` to a blocked pipe can hang and a diagnostic must not be able to delay the
   cleanup or the forward (R1). No child of the entry's own is alive to race that removal because
   bash defers a trapped signal until the foreground command it is waiting on finishes,
   which also means the checkpoint can be reached up to one compile late — R1, R2;
   **then the pin check** — verify the jq passed as an argument
   against this
   platform's SHA-256 and `jq-1.6` (`shadow/v1/reproduce.sh:113-118`), and verify the blob
   ids of both C sources and of the eight loaded files R5 lists
   as entry-pinned against the pinned constants, each id computed from the file's `stat`
   size and the platform's SHA-1 tool rather than by running `git hash-object` (R1), the way the
   runtime pins its own dependencies (`scripts/lib/profile-resolution.sh:711-717`), every
   one of those commands run under the `env -i` line R1 quotes, which is why this step
   comes after the run directory and not before it: that line points `TMPDIR` and `HOME`
   at `<output>/.run/tmp` and `<output>/.run/home`, and both have to exist (R1). A refusal
   here is cleaned up by the trap installed above, which R10 asserts;
   **compile** — both C files from those pinned sources into the run directory with the
   exact flags the test uses, `-std=c11 -O2 -Wall -Wextra -Werror -pedantic`
   (`portable-profile-resolution.test.sh:146-149`), invoking the platform's fixed compiler
   rather than the test's `${CC:-…}` (`:95,102`; R7) — `/usr/bin/cc` on Linux, and on
   Darwin `/Library/Developer/CommandLineTools/usr/bin/clang` with the fixed
   `-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, refusing `E_RUNTIME`
   when the Command Line Tools are absent rather than falling back to the `xcrun` shim at
   `/usr/bin/cc` (R1) — each compile run under
   the `env -i` line quoted verbatim in R1 — `PATH`, `LC_ALL`, `TMPDIR=<output>/.run/tmp`,
   `HOME=<output>/.run/home` and nothing else — with an `-o` path inside the run directory,
   plus `-pipe` where
   the compiler accepts it, so no compiler intermediate is written outside the run
   directory and no caller variable steers the compile; then copy in jq and the platform's
   awk the way the test does (`:130-143`);
   **tighten** — remove the `tmp` and `home` subdirectories and their contents, then
   `chmod 0500` every
   remaining file in the run directory and then `chmod 0500` the run directory itself, so
   the R5 checks pass and nothing further can be added or replaced there without a
   `chmod`; this step comes after both compiles for exactly that reason; **then run the
   parent as a
   child** — not `exec`, so the trap survives to clean up — under
   `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C` and nothing else, rather than clearing
   named `LD_*`/`DYLD_*`/`BASH_ENV`/`ENV` variables as an earlier round said (R1), handing
   it the helper path,
   the run directory, and the output directory the run directory sits in;
   **then wait**, pass the child's stdout and stderr through unchanged,
   and exit with the child's status (`128 + signal` if it was signalled). No step reaches
   the network.
3. **`scripts/test/resolver-trusted-launch.test.sh`** — R10.
4. **Docs and manifest** — R9, in the same pull request as the code.

**Distribution** (intent open question 2): build on every invocation from the committed C
sources into a fresh private run directory, never cached and never reused. No binary is
committed and no binary digest is pinned, because a compiled binary differs per platform
and toolchain; identity comes from the pinned source blob plus a fixed compiler
invocation, and behaviour is proved by R10 rather than asserted by a digest. This matches
the pattern already in the repo — `packaging/v1/build-release.sh:90-103` validates with
the validator *as committed*, and `shadow/v1/reproduce.sh:113-118,141-142` pins the one
genuinely fixed artefact, jq, by digest. Compiling every time costs a few seconds and
buys the provenance claim in R5: there is no cached binary whose history anyone has to
trust.

**Request shape** (intent open question 1): the parent accepts any request the resolver
accepts. It is transport, not policy — it checks that the request is a canonical regular
file and passes the path through. The focused test uses the default profile request.

**Shadow driver integration** (intent open question 3): out of scope here, carried
forward to #264. The self-host run consumes a resolved profile as a file the operator
produced with this entry script.

**Gate.** High risk, so a plan-only pull request on `ystack/plan/resolver-trusted-parent`
whose commits touch only `work/resolver-trusted-parent/plan.md`, then independent review,
then green CI, then **the operator merges it**. Opening the pull request ends the agent's
authority; no agent merges this (`AGENTS.md:404-408`), which is also what the merged
intent says for this change. Only after the operator's merge does
`ystack/impl/resolver-trusted-parent` open and code start.

## Out of scope

- Any change to `resolver/v1/profile-resolve-runtime.sh`, `scripts/lib/profile-resolution.sh`,
  `resolver/v1/profile-resolution.jq`, or `resolver/v1/nofollow-snapshot.c`.
- Any change to `work/portable-profile-resolution/spec.md`; accepted artifacts are not
  edited. The supersession is recorded here and in `docs/components.md`.
- Profiles other than `profiles/default/v1` in the focused test.
- Shadow driver or input-assembler wiring (#264).
- A committed binary or a pinned binary digest.
- Fetching, installing, caching or vendoring jq; the caller supplies the pinned binary.
- Launch-evidence records, profile activation, or any live-qualification claim.
- **Closing the same-uid swap window on the helper — the recommended follow-up, not done
  here.** The residual stated in R5 exists because the runtime takes the helper as a path
  and re-resolves it at exec time
  (`scripts/lib/profile-resolution.sh:209,664-667`). Closing it means changing the runtime
  to accept an executable descriptor from the parent — a `fexecve`-style handoff, or an
  `/dev/fd` path the parent opened — so the object checked and the object executed are the
  same. That is a change to the runtime and to the resolver's launch contract, both listed
  above as untouched, so it belongs to a separate initiative. This spec records it as the
  recommended next step and promises nothing about it.
- **Moving the runtime off `/usr/bin/git` on Darwin — the follow-up the amended intent
  itself names, not done here.** It is the only thing that would close the accepted
  residual R7 states: the runtime runs `/usr/bin/git` for every repository read and for
  its own blob pins (`scripts/lib/profile-resolution.sh:313-323`, `:711-714`), that path
  is the `xcrun` shim on Darwin, and the shim writes its cache where no environment the
  parent builds can redirect it. Every route to closing it changes the runtime, which the
  first bullet above puts out of scope and the intent puts out of scope for this
  initiative (`work/resolver-trusted-parent/intent.md:32-33`). The amended write-root
  constraint says the same in its last sentence — "A later intake may move the runtime off
  `/usr/bin/git` on Darwin" (`:44-45`) — and *may* is the right word: this spec records
  the follow-up and promises nothing about it.

## Areas of concern

- **This is the security boundary, which is why risk is `high`.** The accepted resolver
  spec says the boundary begins in the trusted parent
  (`work/portable-profile-resolution/spec.md:217-262`). A mistake here does not produce a
  wrong answer; it produces an answer that looks right without the boundary behind it.
- **What the proof covers after this lands, exactly.** The shipped parent's output equals
  the test launcher's output for the default profile request, and the refusals enumerated
  in R10's three groups fire — those cases, not "every R5 refusal" in the abstract. Two
  refusals are deliberately outside the runtime list and rest on code review instead, and
  R10 says so in both places rather than letting the group lists imply coverage they do
  not have: the unsupported-platform refusal, which no CI input can drive because the
  entry reads `/usr/bin/uname` at a fixed path, and the jq-path length guard at
  `portable-profile-resolution-launcher.c:662-665`, which an earlier `lstat` makes
  unreachable. A third claim rests on code review for a different reason: R7's third read
  item, the supervisor's host process-table reads on both platforms, which are syscalls and
  `libproc` calls that no grep and no test in R10 observes. That is all. There is no
  third-party audit, no fuzzing, no formal argument
  that the allowlist is complete, and no launch-evidence record — nothing this produces is
  live-qualified (`work/portable-profile-resolution/spec.md:264-271`). The executable
  allowlist is the one read claim here with a mechanical check behind it: R10's command-word
  grep fails CI on any executable path outside R7's list.
- **Network: none, and the cost of that.** The shipped path cannot reach the network
  because neither file has anything that would — the jq binary arrives as an argument and
  everything else is committed. The cost lands on the caller, who must fetch and verify
  jq 1.6 first; the pattern is in `scripts/test/shadow-slice.test.sh:24-51` and the
  focused test uses it, but an operator who skips it gets a refusal rather than a
  working command. That trade is deliberate: a shipped security component that downloads
  a dependency has a network dependency in its trust base, and this one does not.
- **What helper provenance proves, and where it stops.** The entry checks the source
  blobs, compiles into a fresh private directory, tightens everything there to 0500, and
  hands the parent both the helper path and that directory; the parent refuses to launch
  unless those modes and owners are still exactly right at check time. What that is worth:
  tampering that is observable before launch fails closed. What it is *not*: it is not a
  binding between what the parent checked and what the runtime executes. The runtime takes
  the helper by path and re-resolves it at exec time
  (`scripts/lib/profile-resolution.sh:209`), with only `[ -x ] && [ ! -L ]` of its own
  (`:664-667`), so a same-uid process can still swap the file in the window between the
  check and that exec — by loosening modes with `chmod`, or, without touching a mode at all,
  by renaming `<output>/.run` aside and putting its own `.run` in its place, which the
  mode-0700 output directory it owns allows — the runtime resolves the helper, jq and its
  `PATH` from `<output>/.run/...` strings, so the swap takes effect even though the parent's
  descriptor still points at the original. That is why R5 now states a second assumption
  beside the accepted spec's trusted-parent one: no hostile same-uid process is active in
  the caller's output root while the run is in progress. The plan must carry both, in these
  words. That
  residual is stated in R5 and is unchanged from the boundary the accepted resolver spec
  already assumes (`work/portable-profile-resolution/spec.md:219-222`); the follow-up that
  would actually close it — a descriptor handoff instead of a path — is under Out of scope.
  Root is outside all of it, and so is the compiler, which is trusted unverified. The plan
  must repeat these limits in these words rather than imply the check is stronger than it
  is; no wording in the plan may say the parent "binds" or "guarantees" what the runtime
  executes.
- **Pinning the whole loaded set is real maintenance.** Ten pinned blob ids across two
  files, each of which must move in the same pull request as the code it pins, and a new
  core generation moves five at once. What it buys is that the trusted set stops being
  implicit — today nothing pins `scripts/lib/profile-resolution.sh` or
  `resolver/v1/profile-resolution.jq`, so pinning the runtime alone proves only that a
  dozen lines of `source` chain are the committed ones. The defence against a forgotten
  pin is the CI assertion in R10, and it is worth saying that the defence is one test.
  Worth saying too: only three of the ten are re-checked by the parent — the parent-pinned
  subset — so the module pins exist only on the path that goes through the entry.
- **Signals are the newest code in the most sensitive place.** Group termination on
  `INT`/`TERM`/`HUP` (R2) is copied from nothing — the test launcher installs no handler
  at all — so it gets none of the benefit of the "copy what is already proved" argument
  the rest of the parent rests on, and it fails in the worst direction either way: a
  resolver left running under a deleted run directory, or a group killed that should not
  have been. Its tests are at least deterministic, and there are five of them now: one per
  branch that exists, plus a second route into the entry's no-parent branch, which is
  reachable two ways and had only one of them driven, plus this round's repeat of the
  mid-run case with a second signal sent while the parent is still terminating. R10 stops
  the resolver's process group with `SIGSTOP` before signalling the entry, so the mid-run
  path is exercised on every run, and it takes that group from the parent's own
  `runtime-pgid` line rather than from the process table, so it cannot freeze some digest
  tool's group and read the result as success; a run that finishes before the freeze lands
  fails the test rather than passing on a weaker claim. The second test is that same case
  with a second `SIGTERM` — and, in a variant, a `SIGINT` — sent 100 ms after the first,
  while the parent is still working through its `SIGTERM`-then-`SIGKILL` sequence against
  the frozen group, and it is this round's find: the entry's wait on the parent is a loop
  that ends only when the parent has actually been reaped, so the case polls the parent's
  liveness against the existence of `.run` and fails on any sample that finds the run
  directory gone with the parent still alive, and it asserts that the one
  `entry-signal:` line still names the first signal (R1, R10). The third test drives the
  entry's
  other branch — a signal that arrives after `.run` exists and before any parent does, where
  no group exists and there is nothing to forward to (R1) — by signalling as soon as `.run`
  appears, and it asserts that branch by the `entry-signal: TERM no-parent` line the entry
  writes rather than by an empty output directory, which cannot tell that branch from a
  parent that had only just started. The fourth is that same branch signalled the way a
  terminal signals it — to the whole foreground process group, so the compile the entry is
  waiting on dies too — and it is this round's find: its extra assertion is that no
  `E_RUNTIME` line came out, because a refusal written beside a foreground command is what
  would report an interrupted compile as a runtime failure and swallow the signal exit
  (R1, R10). The fifth covers the window between the entry's two branches, which is
  the one an earlier round found open: a parent that is alive and has not yet forked the resolver,
  so its `pgid` is still zero. That is the most dangerous of the five to get wrong, because
  a handler that let a zero `pgid` reach `kill(-pgid, …)` would signal the caller's own
  process group rather than a resolver's, and the case asserts against exactly that with a
  sentinel process in the test's own group that has to survive (R2, R10). The plan
  should treat this as the highest-risk new code here and say what it does on `EINTR` in
  `waitpid`, on an already-reaped child, on a
  group whose members are stopped when the handler fires, and on a signal that reaches the
  entry while a compile is still running and no parent pid has been recorded — where bash
  defers the signal until that compile finishes and the entry's next checkpoint is what
  acts on it (R1), which is what keeps the removal off a
  live child and what the test's wait timeout has to be wide enough to absorb. The pre-fork
  window inside the parent is no longer one of the plan's open questions: R2 states the two
  `volatile sig_atomic_t` variables, the three branches and the prohibition on
  `kill(0, …)`/`kill(-0, …)` outright, because that is not a detail an implementation should
  be left to invent, and neither is the window an earlier round found inside it: a signal that
  lands between a `fork` and the assignment that publishes its pid would take the
  no-runtime branch and exit with the child it just forked still running, so R2 blocks
  `INT`, `TERM` and `HUP` across every fork the parent performs and its publication, and in
  the child resets the three dispositions to `SIG_DFL` before it restores the mask — that
  order, because unblocking first would let a pending signal run the parent's handler
  inside the child and kill groups from the wrong process. That fix is the one thing in this bullet
  with no test behind it — the window is a few instructions wide and nothing can put a
  signal in it on demand — so its coverage is a sequence the plan quotes and the reviewer
  reads, which R10 states in those words rather than implying a case exists. A second
  signal arriving while the handler is already running is no longer one of the plan's
  questions either, and it was an earlier round's find: the three handlers are installed with
  `sa_mask` set to all three signals, so a sibling is held until the handler `_exit`s and
  then discarded with the process, and nothing in this path has to be written to survive
  running twice (R2). That fix has no test behind it for the same reason the mask above
  does not, and it is read the same way. That round's other change was on the test side and
  an admission rather than a mechanism: the stopped-parent case used to fail outright
  when the `SIGSTOP` landed after the fork, which made a correct implementation flaky on a
  loaded runner, so both of that case's non-proving outcomes are now retried inside one
  bounded budget and counted in the failure message (R10). This round settles the entry's
  half of that same question, which was still open and did not look it: a second signal
  arriving while the entry is waiting on the parent interrupts that wait exactly as the
  first one did, so R1 makes the wait a loop that forwards once per recorded name, tells
  an interrupted wait from a reaping one with `kill -0` on the parent's pid, and takes the
  exit status only from the wait that actually reaped the parent — and unlike the two
  fixes above it does have a test behind it, the repeated-signal case in R10, because this
  window is hundreds of milliseconds wide rather than a few instructions.
  One more
  ordering belongs in this bullet, and it points the other way: the two diagnostic lines
  this path writes — the parent's `parent-signal:` and the entry's `entry-signal:` — are
  written **after** the killing and the cleanup rather than before, and best-effort, because
  stderr may be a pipe nobody is draining and a blocking write ahead of the kill would hang
  the very path that exists to guarantee cleanup (R1, R2). The plan should treat "the
  diagnostic never delays termination" as a rule of this component rather than a detail: the
  handler's line goes out with one non-blocking `write(2)` whose failure is ignored, and the
  entry's `printf` is the last statement of its `EXIT` trap, before that trap's own `exit`.

  One more thing about the entry's side belongs here, because it was a withdrawal rather
  than an addition. The entry's `INT`/`TERM`/`HUP` traps no longer
  do anything but record the signal's name; the forward, the cleanup, the diagnostic and
  the exit all happen in the main flow and in the `EXIT` trap (R1). The design that was
  withdrawn armed the cleanup from a command substitution —
  `run_created=$(/bin/mkdir -- "$run" && printf 1)` — and a signal to the whole foreground
  process group can kill that substitution's child after `mkdir` has created `.run` and
  before `printf` writes the `1`, which left the guard empty and the directory on disk: the
  exact leak the guard existed to prevent. Nothing observable changed with the redesign —
  same exit statuses, same removal, same one line last — which is what makes it safe to
  make at spec stage, and the plan should treat "no trap body does anything but record"
  as a rule of the entry rather than a style preference.

  This round finishes that split on the other side of it, and the fix is an ordering rule
  rather than new mechanism. Recording the signal in a trap and acting at a checkpoint
  only works if the checkpoint is what the entry reaches next, and the ordinary shell
  shorthand `cmd || refuse E_RUNTIME` puts a refusal in front of it. A terminal signal
  goes to the whole foreground group, so the pin check or the compile that was running
  dies on it and returns non-zero *because of the signal*; the refusal beside the command
  then fires first and the caller gets an `E_RUNTIME` line instead of `128 + signal` and
  the `entry-signal:` line — the wrong cause, and the signal lost. So R1 requires the
  three-step shape of every external command in the entry, `$(...)` substitutions
  included: capture the status, `checkpoint`, then refuse. The plan should treat
  "no external command is followed by `|| refuse`" as a rule of the entry beside the
  trap-body rule above, and R10's group-signal case is what proves it from outside,
  by asserting that no `E_RUNTIME` line appears on a signalled run.
- **Cleanup is best-effort, and the extra process is the price.** Waiting instead of
  `exec`ing is what makes cleanup possible at all, but a trap is not a guarantee: `SIGKILL`
  on the entry, or a power loss, leaves the run directory behind, and its 0500 mode makes
  the leftovers slightly annoying to delete by hand. What the trap does now
  cover, which an earlier round of this spec left open, is the moment `.run` comes into
  existence: the traps are installed before the `mkdir` rather than with it, the entry
  refuses a pre-existing `.run` before it creates anything, and the guard that arms the
  removal is set in the main flow from the `mkdir`'s own status — including a status above
  128, which means the caller's group signal killed `mkdir` after it had created the
  directory. So there is no ordering in which a
  failed `tmp` or `home` creation, or a signal arriving just after `.run` appears, finds
  the directory on disk and nothing registered to remove it (R1). This round closes the
  last version of that hole, and it was on the inside of the trap rather than in front of
  it: the `chmod` and the `/bin/rm` are external commands, a terminal signal goes to the
  whole foreground group, and a trap that only records a name protects the shell and not
  its children — so a third `Ctrl-C` could stop the removal part-way and leave behind the
  directory the trap exists to remove. The `EXIT` trap now runs `trap '' INT TERM HUP`
  straight after its status capture and before it touches the disk, and an ignored
  disposition is the one thing children inherit, so
  both commands run to completion however many signals arrive (R1). Nothing is given up by
  ignoring there: by then the signal has been recorded, forwarded once and the parent
  reaped, and the exit status is already decided. `SIGKILL` on the entry cannot be
  forwarded either, so in that case the parent keeps running and its own handlers never
  fire — the resolver group is reaped by the parent's normal exit rather than by a signal,
  which is the right outcome, but nothing removes the run directory afterwards.
  The leftovers are inert — compiled
  binaries, copies of jq and awk, and, if the kill landed mid-compile, whatever the
  compiler had written into the `tmp` and `home` subdirectories, all inside the one `.run`
  directory in
  the caller's own output directory — but they are leftovers, and the honest statement is
  "removed on every exit the entry can observe", not "never leaks". Putting `.run` in the
  output root rather than under `TMPDIR` (R1) changes what a leftover costs in one useful
  way: the next run against that same output directory refuses on the entry's emptiness
  check, before it compiles anything, so a leftover is loud rather than silently reused
  (the plain `mkdir` behind that check would refuse it too), and the caller deletes it —
  after a `chmod 0700`, since it is 0500 — or names a fresh output directory.
  Not `exec`ing also
  leaves one extra shell in the process tree for the life of the resolution; it holds no
  state and does nothing but wait, and it is outside the sandbox and the parent's
  limits, so it does not widen what the resolution can do.
- **The entry script is a convenience, and the loader is why it still matters.** The
  accepted spec says a helper newly started from a hostile environment is not the trusted
  parent. The C parent's own dynamic loader runs, and acts on what it is told, before the
  parent's `main` is entered — so a caller who controls `LD_PRELOAD`,
  `DYLD_INSERT_LIBRARIES` or their library-path siblings at that moment is inside the
  boundary already, and no code the parent contains can change it: the injected library has
  already run. Only the process that starts the parent can defend against that, which is
  what the entry does by starting it under `/usr/bin/env -i` with an environment it wrote
  itself (R1), rather than by clearing the variables somebody remembered to name.

  **The same argument applies one process further out, and that is the limit of it.** An
  `env -i` prefix cannot protect the `env` that carries it, and `env` was not even the first
  external command in an earlier round of this order — `uname`, `stat`, `git` and `cc` ran
  ahead of it, each one an external process started under whatever the caller had. So the
  entry scrubs its own environment with builtins first, forking nothing
  (`adapters/local-git-materializer/v1/materialize.sh:4-13`), and then re-execs itself under
  an empty environment (`:22-29`), so that every command it runs after that point starts
  from an environment it wrote (R1). What is left over is the entry's *own first process*:
  the caller started it, its loader read the caller's variables, and any injected library
  has already run by the time the scrub's first line executes. The scrub stops that from
  spreading; it cannot unrun it.

  This round makes the marker branch stop pretending otherwise, which is the same
  statement applied to the one door that bypasses the re-exec. That branch used to open
  with `builtin unalias -a` and the re-run scrub and let the reader conclude the branch had
  cleaned house before it validated anything. It had not, and it could not: a process
  started as plain `/bin/bash <entry> __resolve_profile_clean …` from a polluted
  environment has already imported the caller's exported functions and already sourced
  their `BASH_ENV` before the first `builtin` is parsed, so a function or alias named
  `builtin` — or `exit`, or the reserved word `case` — is in place ahead of the scrub that
  was supposed to remove it. The fix is a refusal rather than a better scrub: the branch's
  first statement is `case $- in *p*) ;; *) exit 78 ;; esac`, both supported invocations
  set `-p` (the shebang, and now the re-exec too), and privileged mode is precisely the
  state in which bash reads no `BASH_ENV` and imports no function, so on every arrival the
  branch admits, the pollution is gone before the branch begins (R1). The scrub stays
  behind the refusal as a second layer, and the spec now says that is all it is. The
  residual is unchanged and is the same one this bullet has always carried: a caller who
  starts the entry from a hostile environment is inside the boundary, and the refusal turns
  that caller away rather than defeating them.

  So the claim, in the words the plan must use: **the parent must be started by a trusted
  process — the entry when used as designed, or the operator's own shell for the step-7 run
  — and the entry must itself be started by a trusted process for the same reason, because
  its first process has no loader-variable defence either. A parent, or an entry, invoked
  from a hostile environment has none at all.** R10 tests it at exactly that boundary and
  nowhere else: loader variables are
  polluted in the caller of the *entry*, never in the caller of the parent, because the
  direct-parent version of that test would run the injected code and then assert about the
  result. Its marker file may hold one line for that first process and must hold no more, so
  the test asserts what the scrub and the re-exec actually buy and does not assert that the
  first process is clean. The entry is the first trusted process, not a shield in front of
  an untrusted one.
- **Copy versus adapt.** The test launcher is 702 lines, and far less of it is test
  scaffolding than a glance suggests: only the argv modes at `:547-631` and the two
  test-variable lines at `:686-689` are test-only, so the parent copies roughly 605 lines
  of it (see the size derivation above). Copying the supervisor verbatim keeps the proven
  behaviour but carries code written for a test harness; adapting risks a subtle
  divergence in exactly the code that enforces the limits. The plan should list every
  deviation line by line. Ten are already known in the parent: the mode-0644 check moves
  from the test
  into the parent; inherited descriptors above 2 are
  closed explicitly rather than relying on the launcher's `O_CLOEXEC` on its own opens;
  the helper's run-directory and mode-0500 checks are new code with no counterpart in
  the test launcher, which simply trusts the path the test script hands it — and that item
  grows this round rather than an eleventh being added, because the output directory's
  `.run` rule is the same new block read from the other side: the entry is admitted by
  `fstatat(out_fd, ".run", …, AT_SYMLINK_NOFOLLOW)` with an `S_ISDIR` test and then proved
  identical to the handed run directory by `st_dev`/`st_ino` off two `fstat`s, where the
  launcher has no `realpath`, no `fstatat`, no `openat` and no `O_DIRECTORY` anywhere in
  its 702 lines (verified: none of those four names appears in the file, and its only
  `O_NOFOLLOW` uses are the two `open` calls at `:86,120` and the two at `:418-420`, with
  `:30-31` defining the flag to `0` when the platform lacks it), so there is nothing there
  to copy and the whole check is written fresh (R5); the blob pins
  for the runtime, `scripts/lib/profile-resolution.sh` and
  `resolver/v1/profile-resolution.jq` are new (R5); the request and repository-map
  arguments get a regular-non-symlink check where the launcher checks only the leading
  slash (`portable-profile-resolution-launcher.c:636`); the `INT`/`TERM`/`HUP`
  handlers with process-group termination are new (R2) — and that item grows again this
  round rather than a tenth being added, because it is all the same deviation: the handlers
  are installed by `sigaction` with `sa_mask` set to all three of `SIGINT`, `SIGTERM` and
  `SIGHUP` and `SA_RESTART` unset, so none of them can re-enter another, and they
  carry two `volatile sig_atomic_t` variables, three branches on them, a prohibition on
  `kill(0, …)`/`kill(-0, …)`, one `parent-signal:` line each branch writes — written last,
  after the kill and the reap, with stderr made non-blocking for a single `write(2)` whose
  short write or `EAGAIN`/`EPIPE` is ignored, and `SIGPIPE` left at `SIG_IGN` from the
  first statements of `main`, so the diagnostic can never hold up the termination — and a
  `sigprocmask(SIG_BLOCK, …)` around every fork the parent performs with the matching
  `sigprocmask(SIG_SETMASK, …)` after the pid assignment and nothing else inside the region
  with them — the `runtime-pgid:` line is written after that restore, not in there —
  plus the child's own `SIG_DFL` resets before that restore rather than after it — where the
  launcher forks at `:432` with no mask at all and contains no `sigprocmask`, no
  `sigaction` and no `signal()` anywhere in its 702 lines (verified: none of the three
  names appears in the file), so there is no handler and no mask discipline to grow from; the four sandbox
  entries `home`,
  `tmp`, `child.stdout` and `child.stderr`
  are created with `mkdirat` and `openat` relative to the output-directory descriptor the
  parent checked, where the launcher builds all four by path with `mkdir` (`:645-647`) and
  `open` (`:413-421`), which carries the descriptor into `supervise` (`:400-532`) as a
  signature change — *and*, extending that same deviation this round, the supervisor's
  reads back move onto those descriptors too: `empty_regular_file` becomes an `fstat`,
  `stream_file` and `sanitized_error` take a descriptor in place of a path and gain an
  `lseek`, and the two files are opened `O_RDWR` instead of `O_WRONLY`, where the launcher
  re-opens both by path at `:505-506,518,522,526` (R5). That counts as one item on purpose:
  it is a single move from names to descriptors, and splitting the creations from the reads
  is how it came out half-done the first time. The eighth came with the round before this
  one, its other change to
  the C file — the parent-pinned subset's blob ids are computed from an `fstat` size and
  the platform's SHA-1 tool, where nothing in the launcher pins anything and the obvious
  shortcut would have been `git hash-object` (R1, R7). The ninth is this round's only change
  to the C file: the one `runtime-pgid: <n>` line the parent writes to its own stderr after
  the fork and after the mask restore, best-effort with the same non-blocking single
  `write(2)` the handler's line uses, where the launcher writes nothing there and leaves the
  resolver's process group unnamed, so anything downstream had to work it out from the
  process table (R2). The tenth is this round's only change to the C file: `umask(077)`
  among the first statements of `main`, where the launcher has no `umask` call anywhere in
  its 702 lines (verified: the name does not appear in the file) because the test script
  sets one for the whole suite before running it
  (`portable-profile-resolution.test.sh:5`) — a property of the harness that does not ship
  with the code, so the parent sets its own and the modes it asks `mkdirat` and `openat`
  for are the modes that appear (R5). Eight more
  are in the entry rather than the parent: the run directory's files are 0500,
  where the test uses 0555 for the copied jq and awk
  (`portable-profile-resolution.test.sh:130-143`); the compiler is a fixed path chosen per
  platform with no `$CC` override — `/usr/bin/cc` on Linux, and on Darwin
  `/Library/Developer/CommandLineTools/usr/bin/clang` with an explicit `-isysroot` — where
  the test honours
  `${CC:-/usr/bin/cc}` and `${CC:-/usr/bin/clang}` (`:95,102`) and both of those Darwin
  paths are the `xcrun` shim, because a caller-chosen compiler
  would be a caller-chosen trust base and a shim writes outside the output root (R1, R7);
  the entry runs no `git` at all, the ten blob-id pins being computed from a `stat` size
  and the
  platform's SHA-1 tool where the test and `reproduce.sh` would reach for
  `git hash-object` (R1); and the run directory is the fixed
  `<output>/.run` inside the caller's output directory, where the test script and
  `shadow/v1/reproduce.sh:94-142` both use `mktemp -d` under the caller's `TMPDIR`, which
  would be a second write root (R1, R7) — and that item grows this round rather than a
  ninth being added, because the run directory's whole lifecycle is one deviation from the
  same lines: `reproduce.sh` cleans up inside its `EXIT`/`HUP`/`INT`/`TERM` trap bodies,
  where the entry's three signal traps only record the signal's name, its `EXIT` trap does
  the cleanup under a `run_created` guard, and the main flow does the forwarding and the
  leaving at `checkpoint` calls, with the guard set from `/bin/mkdir`'s own status behind
  an `[ -e ]` refusal rather than from a command substitution a group signal can kill
  mid-way (R1). Three are older: the pin checks,
  both compiles and the parent launch run under `/usr/bin/env -i` with a named variable
  list, where the test and `reproduce.sh` run all of it under whatever the caller had; the
  output root is validated — real directory, caller-owned, mode 0700, empty — before
  anything is written into it, where the test script leaves those facts to the launcher; and
  `/usr/bin/stat` is run for the owner and mode of that directory and for the pinned
  files' sizes, a command neither
  copied file runs. The eighth is the one item in this whole list
  that is a copy rather than new code — just from a third file: the entry opens with the
  builtins-only environment scrub, the empty-environment re-exec and the `umask 077` that
  follows them taken from
  `adapters/local-git-materializer/v1/materialize.sh:1,4-13,22-29,31`, deviating from *those*
  lines in the marker word, the arity, the `-p` added to the re-exec's `/bin/bash`, and the
  marker branch's own first statements — the `case $- in *p*) ;; *) exit 78 ;; esac`
  refusal, and behind it the scrub re-run with two alias-reset lines the copied bytes do
  not have (R1) — the umask
  is copied unchanged, in the same position relative to the scrub and ahead of the first
  thing created — where the
  test script and
  `reproduce.sh` scrub nothing at all and run every command under the caller's own
  environment.
- **Platform matrix.** Three tuples, but CI runs one. The other two are proved only when
  someone runs the test there, and the parent's Darwin memory bound is polled rather than
  enforced by the kernel (`portable-profile-resolution-launcher.c:381-386,390-392`). The
  fourth case — a platform that is none of the three — has no runtime coverage on any
  machine, because the entry reads `/usr/bin/uname` at a fixed path and nothing a test can
  set changes the answer. R10 makes that a code-review item rather than adding a test-only
  platform override to the security wrapper, and the plan should treat the `case` and the
  per-platform tables (jq digests, SHA-256 tool, SHA-1 tool, compiler path with its
  `-isysroot`, the two `/usr/bin/stat` formats, awk branch) as one
  thing to read
  together: all seven must agree on the same three tuples. Two of those tables are this
  round's, and they are why the Darwin question earlier rounds carried is now closed rather
  than open. That question was first whether `/usr/bin/cc` could find its SDK under the
  `env -i` compile line, and then whether the `xcrun` shim's cache write could be prevented
  at all. The answer to both, for the files this initiative adds, is that the shim is not
  run: Darwin compiles with
  `/Library/Developer/CommandLineTools/usr/bin/clang` and an explicit `-isysroot`, which
  execs its own linker and leaves `xcrun_db` untouched, and neither the entry nor the parent
  runs `git` anywhere (R1, both measured on a Darwin 27 machine). What replaces the question
  is a
  prerequisite and a refusal: Darwin needs the Command Line Tools installed, and the entry
  exits `E_RUNTIME` naming the missing path when they are not. The question does stay open
  for one process the initiative does not write — the runtime, which runs `/usr/bin/git`
  itself — and that is the residual in the bullet below rather than a gap in this one.
  Linux CI cannot exercise any of the Darwin side — not the compile line, not the refusal,
  not the cache measurement — so those three are confirmed only on an operator's Darwin run.
  That is the honest gap this concern carries.
- **One accepted residual on Darwin: the runtime's own git writes outside the output root,
  and the intent now records it as the one accepted exception.** This is the only place the
  single-write-root claim does not hold,
  and it is worth stating as a concern rather than only as a requirement clause. The
  resolver runtime runs `/usr/bin/git` for every repository read
  (`scripts/lib/profile-resolution.sh:313-323`) and for the four blob pins it checks at load
  time (`:711-714`). On Darwin that path is the `xcrun` shim, which can write its `xcrun_db`
  cache into the per-user temp directory — outside the caller's output path, and outside
  anywhere the parent can redirect, because the cache is not in `TMPDIR` (R1, measured). The
  parent controls the runtime's whole environment (R3) and still cannot prevent it. The
  residual belongs to the runtime and not to the parent, and the runtime is exactly what
  this initiative may not change (`work/resolver-trusted-parent/intent.md:32-33`), so it
  cannot be closed from where this spec stands. **The operator decided DR-2 on intake
  `#271` on 2026-09-10, choosing option (a): accept the residual, name it, and measure
  exactly it in the Darwin operator run (R10).** The decision is carried into the chain by
  intent pull request `#282`, which amends the intent's write-root constraint to name this
  residual as the one accepted exception and changes nothing else, and this spec pins that
  amended intent (`intent-blob: eaa322c405502cc0ca7c453814ca0f005f11b48f`). So this is an
  accepted, intent-recorded residual rather than an open question: it is a concern the plan
  and the reviewer should keep in view, not a decision anyone is still waiting on. R7 quotes
  the amended constraint verbatim beside its own statement of the residual, so the two can
  be read against each other. The two alternatives an earlier round held open against a
  refusal — widening E to move the runtime off `/usr/bin/git` on Darwin, or dropping the
  Darwin claim and shipping Linux-only — are history and are not carried further. The
  follow-up that would close the residual for good is the one the amended constraint itself
  names — a later intake moving the runtime's git invocation off the fixed shim path — and
  it is not promised here.
- **Test-only variables.** The runtime accepts `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS` and
  `YSTACK_RESOLVER_TEST_GIT_STOP` when both are `1`
  (`scripts/lib/profile-resolution.sh:656-659`). The shipped parent cannot set them, and
  the test must prove it cannot — otherwise a production path inherits a test escape. The
  proof is the R3 block in R10: both variables are set in the polluted caller environment,
  and the Linux `/proc/<child pid>/environ` read asserts the child's environment is exactly
  the allowlist, so their absence is asserted rather than assumed. On Darwin that
  assertion is unavailable and the claim rests on the copied environment block plus the
  byte-identical output — worth knowing, since Darwin is two of the three platforms.
