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
(that one is recorded on its own line in the size-exception waiver later in this
section). One concern: this is a single security-boundary component whose only honest
proof runs the real resolver twice and compares the output.

**Evidence-based range: 2091-2829 changed lines** (implementation). The derivation,
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
  the runtime mode-0644 and blob checks (~45), the blob checks for the other seven files
  of the parent-pinned set — `scripts/lib/profile-resolution.sh`,
  `resolver/v1/profile-resolution.jq` and the five jq modules, sharing the runtime's
  blob-id helper, so ~30 for
  the repository-root derivation, two constants and two comparisons in the round that
  wrote this line and ~25 more from round 40 for the five modules, itemised at the end of
  this bullet — the parent's own jq
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
  `strcmp` were three statements (R5). The round before this one added ~3 more, to ~1117:
  the
  three-signal `sa_mask` on each of the three `sigaction` installations, which is one
  `sigemptyset` and three `sigaddset` calls on a set the parent already builds for the
  fork mask, assigned into each `struct sigaction` before it is installed (R2). This round
  adds ~10 more, to **~1127**: the block around every reap. Five pre-resolver `waitpid`
  calls get a `sigprocmask` pair and a `pre_child = 0` between them, which is one shared
  two-line wrapper rather than five copies if the plan factors the reap the way it factors
  the fork (~4); the supervisor's poll-loop `waitpid` (`:457`) gets the pair with
  `pgid = 0` inside the `observed == child` arm (~3); the limit path's blocking `waitpid`
  (`:493-494`) gets the same (~2); and the `setpgid`-failure reap (`:451-452`) gets only a
  mask restore before its `return 70`, being already inside the fork region (~1). Nothing
  is added after the reap, because nothing there names a pid (R2). This round adds ~12
  more, to **~1139**: the startup close of inherited descriptors, among the first
  statements of `main` before any fork — the `sysconf(_SC_OPEN_MAX)` read, the
  `getrlimit(RLIMIT_NOFILE)` read and the smaller-of-the-two with its floor and ceiling
  (~7), the `for` loop with its ignored `close` (~2), and the comment saying why neither
  `closefrom` nor `close_range` is used, which a reviewer will otherwise ask about every
  time they read it (~3). The `~15` the bullet above already counts for closing inherited
  descriptors is the child's pre-`execve` close and is unchanged; this is the second
  place, not the same one moved (R3, R5). This round adds ~4 more, to **~1143**: the
  blocked region around the resolver's reap now runs on through the copied survivor check
  and the copied group kill, so the `sigprocmask(SIG_SETMASK, …)` and the `pgid = 0` move
  out of the `observed == child` arm and to after the `stopped != STOP_NONE` block, which
  needs one restore at the clean exit that leaves the loop without survivors and one after
  the group kill, plus the matching block on the limit path's entry at `:491` where a pair
  already stood inside it (~4). The copied statements themselves are untouched; this is
  the mask around them (R2). This round adds ~8 more, to **~1151**, in two places. ~2 are
  the handler's restore: the `fcntl(F_SETFL, flags)` with the saved value before the
  `_exit`, in each of the three handlers if they are written out and once if they share a
  body, plus the local the saved flags already needed for the `F_SETFL` above them — the
  `F_GETFL` was counted in the ~5 of the round that made the line non-blocking. ~6 are
  the fixed `envp`: one `static char *const helper_env[]` of two strings and a `NULL`
  built once near the top (~3), and the three `execve` call sites — the SHA-1 tool, the
  SHA-256 tool and the jq probe — passing it in place of `environ`, which is one argument
  each and free if the plan factors the helper fork the way it factors the reap (~3).
  Nothing is added for `execv`/`execvp`/`execlp`: they are absent already, and keeping
  them absent is a grep in R10, not a line in the parent (R2, R7). This round adds ~3
  more, to **~1154**: the `sigprocmask(SIG_BLOCK, &three, &saved)` and
  `sigprocmask(SIG_SETMASK, &saved, NULL)` that bracket the `runtime-pgid:` line's own
  `fcntl`/`write(2)`/`fcntl`, plus the local for the saved mask — the signal set itself is
  the one the fork and reap blocks already build, so it is two calls and a variable, and
  free if the plan factors the best-effort write the way it factors the fork and the reap.
  The handler's line needs none of it, its `sa_mask` already covering its own toggle, and
  no other write in the parent touches `F_SETFL` at all, so the rule reaches exactly one
  site today (R2). This round adds ~15 more, to **~1169**, all of it inside the three
  handlers. ~3 are the bounded wait: the `for` with its counter, the
  `waitpid(…, WNOHANG)` with its `break`, the `timeval` and the `select` — which replaces
  "a brief wait" and is the same shape a `nanosleep` would have been, so the cost is the
  statements and not the choice. ~12 are the `parent-signal:` assembly without
  `snprintf`: the three-entry static signal-name table (~3), the hand-written decimal
  routine for the pgid (~8 — the divide-by-ten loop, the reversal and the static buffer),
  and the `memcpy` joins that build the line before the single `write(2)` (~1), where one
  `snprintf` was one statement. Nothing else changes: the `fcntl` pair, the write and the
  `_exit` were all on the list already, and the `runtime-pgid:` write keeps its
  `snprintf` because it is not in a handler. The forbidden-call list is a reading and a
  grep in R10, not a line in the parent (R2). This round adds ~4 more, to **~1173**, all
  of it the `reaped` flag the bounded wait now carries: the local and its initialisation
  (~1), the `== target` test that sets it in place of the old `> 0` break (~1), and the
  `if (!reaped)` guards after the loop — one around the single-pid branch's `SIGKILL` and
  blocking reap, one around the group branch's blocking reap alone (~2). The group
  branch's `SIGKILL` gains no guard and no line: it stays unconditional, which is the
  half of this fix that costs nothing (R2). This round adds ~30 more, to **~1203**, in
  two blocks. ~18 are R5's two new checks on the bound tool root: the
  `openat(run_fd, "jq", …)` beside an `O_NOFOLLOW` open of the handed path, two `fstat`s
  and the `st_dev`/`st_ino` comparison (~5, the same shape as the `.run` comparison, so a
  second instance rather than a new mechanism), the `openat(run_fd, "awk", …)` with its
  regular-file, owner and mode tests (~4), and the byte comparison (~9 — the platform
  `#if`, the Linux `open` of `/usr/bin/awk`, the Darwin two-line constant, the size test,
  a fixed-buffer `read` loop over both sides and the `memcmp`, with one refusal line
  serving all of it). ~12 are the startup close becoming two steps: the
  `opendir`/`readdir`/`closedir` over `/dev/fd` with its all-digits test and its four-way
  skip (~8), the `E_RUNTIME` refusal when that `opendir` fails (~2), and the ceiling
  changing to `rlim_max`-or-`sysconf` with the 65536 cap (~2). The ~7 the round above
  counts for the soft-limit arithmetic is spent rather than returned: the `getrlimit`
  read stays and only which field it takes changes (R5). This round adds ~25 more, to
  **~1228**, all of it the parent-pinned set widening from three files to all eight: the
  five module blob-id constants and the five module names beside them (~10, ten one-line
  initialisers), the parent's own copies of the library's generation-id and schema-major
  constants (~2), the `snprintf` that builds each module path from the repository root and
  those two and the loop that walks the five names calling the blob-id helper the parent
  already has, with one refusal serving all five (~12), and one more `E_RUNTIME` message
  string naming the module pin (~1). The digest helper itself, the fork and reap wrappers,
  the fixed `envp` and the header-and-bytes construction are all counted above and are
  reused unchanged — the five extra children run through the same shared wrapper the
  round that blocked the reaps already paid for, which is why five more forks cost nothing
  here beyond the loop that starts them (R5, R7).
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
  scrub of variables does not cover a process attribute (R1) — round 31 moves that line
  above the scrub and out of the branch, which is a position and costs nothing here. The round before this one
  added nothing here and the figure stayed at ~397: both of its findings were in the
  parent and the test. The round before this one added ~8 more, to ~405: every external
  command in the
  entry gains a captured status and a `checkpoint` ahead of its refusal in place of a
  `cmd || refuse` written beside it — one extra statement each across the ten pin checks,
  the two compiles and the two copies, which comes to fewer lines than fourteen because
  the `checkpoint` calls were counted in the figure above already and the refusals only
  move (R1). This round adds ~4 more, to **~409**: the four empty initialisations
  `entry_signal=''`, `run_created=''`, `entry_status=''` and `parent_pid=''`, placed among
  the entry's first builtins after the `umask 077` and the descriptor close and before any
  trap is installed, so
  that `set -u` meets a set name at every checkpoint and in the `EXIT` trap on the paths
  where nothing has written one (R1). Four assignments is the whole cost; the rule they
  satisfy is stated in R1 and read in R10 rather than tested. This round adds ~6 more, to
  **~415**: the wait on the parent becomes a loop rather than two `wait` calls — the
  `while`, the test that tells an interrupted wait from a reaping one, the
  `last_forwarded` guard with its assignment beside the `kill`, and the `continue` and
  `break` — where two waits and one `kill` were three statements (R1). The traps changing
  from `entry_signal=NAME` to `: "${entry_signal:=NAME}"` costs nothing: the same three
  lines in a different form. This round adds ~3 more, to **~418**, and all three are single
  lines: `trap '' INT TERM HUP` as the first statement of the `EXIT` trap body, so the
  `chmod` and the `/bin/rm` inherit the ignore; `case $- in *p*) ;; *) exit 78 ;; esac` as
  the first statement of the marker branch; and the comment that says why a marker arrival
  without `-p` is refused rather than scrubbed (R1). The `-p` added to the re-exec's
  `/bin/bash` costs nothing — two characters on a line that was already there.
  This round adds ~2 more, to **~420**, both inside the wait loop: the
  `wait_interrupted=''` that clears the flag at the top of each iteration, and the
  `[ "$status" -ne 127 ] || { … }` guard for the coincidence case. The `kill -0` test the
  flag replaces was already counted, so swapping it for `[ -n "$wait_interrupted" ]` is
  free, and so is the `wait_interrupted=1` each of the three traps gains — the same three
  lines, longer. There is no fifth initialisation to pay for either: `wait_interrupted` is
  only ever read after the loop's own clear, so it stays off the initialise-before-arming
  list for the same reason `last_forwarded` does (R1). This round adds ~10 more, to
  **~430**, in two places. ~6 are the startup close of inherited descriptors: the `for`
  over the `/dev/fd/*` glob, the `${fd##*/}` strip, the one-line `case` that skips
  non-digits and 0, 1 and 2, the `eval "exec ${fd}>&-"` with its `2>/dev/null`, and the
  `done` (R1). ~4 are the job-table gate in the wait loop: the `case " $(jobs -l) "` line,
  its `Running` arm, the `;;` and the `esac` wrapped around the `kill` that was already
  there, plus the `if`/`break` for the not-interrupted branch moving to the top of the
  body, which is the same statements re-ordered and costs nothing of its own (R1). This
  round adds ~3 more, to **~433**: the `if [ -t 2 ] || [ -f /dev/fd/2 ] ||
  [ -c /dev/fd/2 ]` and its `fi` around the `EXIT` trap's one `printf` (~2), and the
  comment saying why a pipe is omitted rather than written to, which is the one line that
  stops a later reader deleting the condition as redundant (~1). The `printf` itself was
  counted rounds ago and only gains an indent (R1). (Round 40 cuts that condition to the
  single `[ -f /dev/fd/2 ]` and adds **nothing** here: two tests come off one line, the
  `if` and the `fi` stay, and the comment is reworded to say why a terminal is omitted as
  well as a pipe. The figure stands at ~433 for this item and the entry's total does not
  move for it.) This round adds ~4 more, to **~437**,
  all four inside the close loop: the `exec 3<"${BASH_SOURCE[0]}" || exit 79` above it
  (~1), the `[ "/dev/fd/$fd" -ef /dev/fd/3 ] && continue` inside it (~1), the
  `eval 'exec 3<&-' 2>/dev/null` below it (~1), and the comment saying why the reference
  exists at all, which is the one line that stops a later reader deleting three statements
  that look like ceremony (~1). Adding `3` to the `case` arm costs nothing — one character
  on a line that was already there. This is ~2 more than the decision that ordered the fix
  assumed, and the reason is that the measurement moved the rule: comparing against
  `${BASH_SOURCE[0]}` by pathname would have been the single line that decision costed,
  and it does not work on Darwin, so the reference has to be opened and closed (R1).
  This round takes ~1 back off, to **~436**, and it is the first entry-side figure in
  this list that goes *down*. All three statements above come out — the reference open,
  the `-ef` skip and the reference close (−3) — because a skip that cannot see a
  descriptor's access mode keeps a caller's writable handle on the entry script alive;
  and the headroom precondition goes in above the loop in their place:
  `nofile=$(ulimit -n)` with the `case` that maps `unlimited` and unparsable answers on
  the same line (~1) and the `[ "$nofile" -ge 64 ]` with its one `E_RUNTIME` line and
  exit (~1). Removing `3` from the `case` arm gives back the one character it cost. The
  comment is a replacement rather than an addition and costs nothing: the line that said
  why the reference existed now says why the precondition does and why nothing above 2 is
  skipped, which is the one line that stops a later reader deleting a statement that
  looks like ceremony and re-introducing a skip that looks like care (R1).
  This round adds ~3 more, to **~439**, all inside the wait loop and all of it the
  forward moving above the `wait`: the
  `if [ -n "$entry_signal" ] && [ "$entry_signal" != "$last_forwarded" ]; then` that now
  opens it and the `fi` that closes it (~2), and `last_forwarded=$entry_signal` standing
  as its own statement after the `case` rather than inside the brace group it used to
  share with the `kill` (~1). The `case`, its `Running` arm and the `kill` are the same
  three lines a pass earlier in the loop, the two `break` tests are the same statements
  lower down, and the `wait_interrupted=''` that moves from just above the `wait` to the
  top of the body is the same line in a different position — so the whole of the fix
  this round makes to the loop's behaviour costs three lines, and the matching fix to the
  traps costs none at all: `wait_interrupted=1` was already counted as part of each of the
  three bodies when the flag went in, and this round only makes that normative everywhere
  the bodies are quoted (R1).
  This round takes ~1 back off, to **~438**, and it is the second entry-side figure in
  this list that goes down. The round-35 precondition's two lines come out — the
  `nofile=$(ulimit -n)` assignment with its `case` on the same line (−1) and the
  `[ "$nofile" -ge 64 ]` refusal (−1) — and one line goes in where they stood:
  `ulimit -S -n 256 2>/dev/null || ulimit -S -n 64 2>/dev/null || { printf 'E_RUNTIME\n'
  >&2; exit 1; }`, which is the same `E_RUNTIME` brace group with a pair of builtins in
  front of it instead of a comparison. The comment beside the block is reworded again
  rather than added to, and it carries one more thing to say than it did — why the soft
  limit is set rather than read, and why the second attempt exists — which is a longer
  line and not another one. **This is ~1 less than the decision that ordered the fix
  assumed**, which costed it at −2 by counting the assignment and its `case` as the two
  statements they are; this list counts lines, and those two shared one, so the figure
  moves by one. The same divergence, in the other direction, was recorded two items above
  when a measurement made a fix cost ~2 more than its decision estimated (R1).
  This round adds ~2 more, to **~440**, both in the close loop's own block. ~1 is the
  statement that makes the unmatched glob fail closed —
  `case $fd in '/dev/fd/*') printf 'E_RUNTIME\n' >&2; exit 1 ;; esac`, the loop's first
  line, above the `${fd##*/}` strip. ~1 is the comment beside the block, which becomes two
  lines rather than one because it now has two things to say instead of one: why the soft
  limit is set rather than read, and why an expansion that matched nothing is a refusal and
  not an empty loop — the second being the line that stops a later reader deleting a `case`
  whose pattern looks like a typo for the glob above it. The precondition's third rung costs
  **nothing**: `ulimit -S -n 1024 2>/dev/null ||` goes in front of the two attempts already
  on that line, which is a longer line and not another one, and the `E_RUNTIME` brace group
  at the end of it is the same brace group (R1).
- **Focused test ~1049 lines.** For scale, the existing resolution test is 746 lines and
  `scripts/test/shadow-slice.test.sh` is 622. R10 is now at the same scale as both:
  jq provisioning the `shadow-slice` way (~30), request and map fixtures (~40), the two
  resolutions plus `cmp` (~30), twelve entry-level refusals in group 1 (~155 — the eleven
  that were there plus this round's edited-`trusted-launch.c` case at ~15: the one-byte
  append to the copied parent source, the background poll over `.run` for a compiler
  output that must never appear, the pin-naming stderr assertion and the empty-output-root
  assertion), the entry-driven loader-variable pollution run
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
  group-2 cases on top of it — twenty-one after the two module-pin cases this round's
  delta at the end of this bullet adds —
  (~150, the overlong-value case now building a near-`PATH_MAX`
  directory tree rather than naming a long path, and the two new `.run` containment cases —
  the symlinked `.run` and the regular-file `.run` — each asserting the refusal and an
  untouched target), the group-3 runtime refusal (~10),
  the R3 polluted
  environment run plus the Linux `/proc/<pid>/environ` allowlist assertion (~25), the
  five of the six signal cases — the mid-run one with its live read of the entry's stderr for the
  parent's `runtime-pgid` line, its `SIGSTOP` freeze and its group assertions (~40), the
  repeated-signal one that runs the mid-run case again and sends a second `SIGTERM`, and
  in a variant a `SIGINT`, 100 ms after the first — the second signal, the sampler that
  polls the existence of `.run` against the appearance of the parent's own
  `parent-signal:` line and fails on the first sample that finds the directory gone with
  that line still unwritten, the one-line count-and-name assertion, the `set -m`
  both runs need, and the third signal sent to the whole group 100 ms after
  the second (~21 — this round's rewrite of the sampler costs ~3: reading a line out of a
  file the case already has open takes a little more than a `kill -0` did, and the pid
  cross-check it drops gives one line back) — the
  pre-parent one that signals as soon as `.run` appears and asserts the trap's own
  `entry-signal:` line, with a bounded wait for the deferred trap (~30), the group-signal
  one that runs the entry in a process group of its own, waits for a compile to be the
  foreground step and signals the group rather than the pid, reusing that case's poll and
  its bounded wait and adding the assertion that no `E_RUNTIME` line was written (~12),
  and the stopped-parent one that drives the parent directly, sends `STOP`/`TERM`/`CONT`, asserts
  the `parent-signal: TERM no-runtime` line and a surviving sentinel in the test's own
  process group, and retries a bounded twenty times — both non-proving outcomes, the
  late stop as well as the early signal, each printed per attempt and counted in the
  message the exhausted budget fails with (~42, of which this round's ~2 are the `set +m`
  that puts the sentinel and the parent in one group and the `ps -o pgid=` equality check
  that proves it) — the cleanup assertions
  (~85 — four cases now rather than three, each asserting the exact entry set of the output
  directory rather than one emptiness test), the two-umask case (~15 — a `umask 000` run
  and a `umask 777` run, the background poll that reads `.run`, `tmp` and `home` while
  `home` exists, its bounded retry, and the `umask 000` direct-parent invocation that reads
  the parent's four sandbox modes), the inherited-descriptor cases (~35 — a shared
  helper that makes the fifo, starts the background reader, opens the write end on
  descriptor 7, starts the process under test, closes the test's own copy and reports
  which of the two events came first, at ~12; the entry half with its `.run` poll and its
  ordering assertion at ~7; the parent half, which reuses the group-2 fixture builder
  and reads for the `runtime-pgid:` line, at ~6; and this round's two further entry runs
  at ~10 — the same-file variant, which copies the entry into the test's scratch, adds
  `8>>` that copy beside the fifo on 7 and asserts the copy's size and digest afterwards
  as well as the ordering, at ~5, and the headroom pair, one run asserting the
  `E_RUNTIME` line, the non-zero exit and an output root that stays empty
  and one asserting the ordinary byte-identical success, at ~5, both of
  them reusing the helper and the `.run` poll rather than bringing machinery of their
  own, R1 — round 41 rewrites both fixtures from `ulimit -n 63`/`64` to the *hard* limit,
  `ulimit -S -n 63; ulimit -H -n 63` and `ulimit -S -n 64; ulimit -H -n 64`, which is two
  builtins on the one line each run already had and so leaves this ~5 where it is), the pin-constant assertions over thirteen pins — eighteen after this round's
  five, counted in the delta at the end of this bullet —
  (~35 — each one now a three-way check that the computed id, `git hash-object`'s answer
  and the pinned constant all agree, R1), the
  command-word allowlist grep in its three sweeps, with the `compgen -b` and `compgen -k`
  exclusion sets derived at run time,
  plus the downloader grep, which no longer needs a `git`-subcommand assertion now that
  `git` is off the allowlist, plus the `/usr/bin/awk` position assertion that comes with
  awk moving to pass 1's data paths — in the entry, every occurrence matched against the
  `cp` source and the Darwin shim text and none in command position; in the C file, every
  occurrence matched against the Linux `open` argument and the Darwin shim constant R5's
  awk verification needs, and none in any `execve` argument array
  (~46),
  exit-status assertions (~15), harness
  boilerplate (~30), the per-case temporary directory setup and teardown (~45), and this
  round's two additions (~25): the third direct-parent pollution run at ~15 — the Darwin
  `PERL5LIB` directory with its four-line `strict.pm`, the `PERL5OPT` beside it, the
  negative control that requires `/usr/bin/shasum -a 1 /dev/null` to print the marker and
  exit 3 before the real run is trusted, the polluted parent run itself, the
  byte-identical compare against the clean direct-parent run, the marker grep over
  stdout, stderr and the two capture files, and the Linux `case` arm, which is short
  because it reuses the loader marker library and its file and only changes the variable
  and what the marker file may hold; and the mid-run case's pipe variant at ~10 — the
  pipe, the background reader, the `dup` the test keeps, the rerun of the case body,
  and the `fcntl` probe, of which the probe is ~5 of C compiled beside the marker
  library and the rest is shell (R2, R7), and the sixth signal case (~12): the
  pipe, the fill-to-`EAGAIN` mode added to that same C probe (~3 — it already sets and
  reads flags on descriptor 3, so filling is a loop and an `errno` test rather than a new
  program), the entry run with the write end as its stderr, the `.run` poll and the
  `SIGTERM` reused from the pre-parent case, the bounded-timeout wait, and the three
  assertions — `143`, an empty output directory, and no `entry-signal:` line in what the
  test drains off the read end afterwards (R1, R10). This round adds ~6 more to that last
  case, to **~1049** for the bullet, and the ~3 of the withdrawn `EAGAIN` fill mode
  counted above is spent rather than returned — the probe keeps its flag-reading mode,
  which the case now calls one more time, and loses the writing one. The ~6 are the
  blocking filler in the background with its pid kept (~1), the fixed-delay wait and the
  `kill -0` that requires the filler to still be there with the `ps -o state=` read for
  its failure message and an outright case failure if the filler has exited (~3), the
  `fcntl` probe run against the write end before launch with its `clear` assertion (~1),
  and the teardown that kills the filler before it closes the pipe (~1). Nothing else in
  the case moves: the entry run, the poll, the `SIGTERM`, the bounded wait and the three
  assertions are the same statements they were (R1, R10). This round adds ~20 more, to
  **~1069**, in three places: the two group-2 bound-tool-root cases (~12 — the
  out-of-directory jq fixture with the `awk` script the test writes beside it, the
  negative control that requires that script to print its marker before the parent run is
  trusted, the marker grep over stdout, stderr and the two capture files, and the
  tampered-awk case, which is a `chmod`, a one-byte edit or an appended line, a `chmod`
  back and this group's two standard assertions), the second parent-half descriptor run
  (~5 — the `exec 300>` onto the fifo, the `ulimit -S -n 64` after it, and the same
  EOF-before-`runtime-pgid:` assertion the first run makes, whose helper and polling it
  reuses whole), and pass 1's awk position assertion widening to the C file (~3 — the two
  literals it may appear as, and the requirement that it appear in no `execve` argument
  array) (R5, R10). This round adds ~15 more, to **~1084**, in three places: the two new
  group-2 cases for the parent's module pins (~8 — the edited `schema.jq` in the copied
  tree with the unedited-library assertion beside it that proves the parent found the path
  from its own constants, and the sibling case whose library carries a changed generation
  constant and is refused on the library's own pin, both of them reusing the group's
  shared fixture builder and its two standard assertions), the pin-constant assertion
  growing from thirteen ids to eighteen and gaining the two generation-constant
  comparisons (~5 — the parent's five module pins joining the loop, and one `grep` each
  for the generation id and the schema major against the library's own lines), and the
  comment beside the group-2 fixture builder saying the group is the only legitimate user
  of the direct-invocation shape (~2) (R5, R10). This round adds ~10 more, to **~1094**,
  in the two descriptor runs R10 gains and nothing else: the filled-low-numbers success run
  (~5 — the `while` loop that opens 253 descriptors on 3 through 255 with the fifo's write
  end among them, the `ulimit -S -n 1024; ulimit -H -n 1024` pair on the same line ahead of
  it, and the three assertions, all of which reuse the fifo-and-reader helper, the `.run`
  poll and the byte-compare the suite already has) and the filled-below-the-cap refusal run
  (~5 — the same opening loop at 3 through 300 with `ulimit -S -n 1023; ulimit -H -n 1023`,
  the `E_RUNTIME` grep written to tolerate bash's own `redirection error` line beside it,
  the non-zero-exit check, the empty-output-root poll, and the comment saying the two
  numbers follow the ladder's rungs). Both reuse machinery rather than bringing any, which
  is why two runs cost ~10 and not ~25 (R1, R10). This round adds ~1 more, to **~1095**,
  and it is the whole of this round's implementation cost: pass 1 of the allowlist grep
  gains the `/usr/bin/printf` ordering assertion — one `grep -n` for the `env -i` re-exec
  line, one for every `/usr/bin/printf` occurrence, and a numeric comparison, written
  beside the `/usr/bin/awk` position assertion that already stands there and reusing its
  extraction (R7, R10).
- **Docs and manifest ~60 lines.** `docs/components.md:33-39`, the `README.md:252` row,
  `RESTORE.md:43-46`, and three lines appended to `ci/required-files.txt`.

Those four bullets now sum to about 2823 lines — added as they stand, ~1228 + ~440 +
~1095 + ~60, rather than carried forward: a round two back wrote the running
total as ~2730 and adding its own four bullets gave ~2771, so the figure is corrected here
in the same way an earlier round corrected ~2535 to ~2578. **This round's own delta is +1**,
and it is the smallest this spec has recorded: the round is three consistency fixes, two of
which change wording only — the parent's fork enumeration and the entry's soft-limit
postcondition both describe implementations this spec already required — and the third adds
one assertion to the test, the `/usr/bin/printf` ordering grep. Nothing in the parent,
nothing in the entry, nothing in the docs. The range does not move for it: ~2823 is still
under the 2829 top of the standing band, by six lines, which is now close enough that the
next round of any size should expect to move it. **The round before this one was +12**
— ~2 in the entry, the unmatched-glob refusal and the second comment line, and ~10 in the
test, the two descriptor runs — and left the range alone at ~2822 for the same reason,
by seven lines. The round before that one
recorded its own delta as −1 and left the range alone for the same reason in the other
direction. **The round before that one again moved the implementation range, for the first
time in fourteen rounds.** The convention held
until then was that the range is not re-derived from the sum each round: it was the ~2441
of the round it was set in, with ±15% at
both ends, and every round since recorded its own delta against that figure rather
than moving the range for it. That round's ~40 was ~25 in the parent and ~15 in the test,
with nothing in the entry and nothing in the docs bullet beyond its own rounding — the
entry already pins all eight loaded files and already writes its diagnostic under a
condition, so the widening landed on the C half and the narrowing cost no statements at
all — and it took the sum to ~2811, which was four lines past the 2807 top of the
range standing then. Four lines is not a real overrun and pretending it is inside the band
would be worse than moving the band, so the base became ~2460 and the range **2091-2829
changed lines**, which the top of this section and the waiver record in the same figures.
Nothing about the derivation changed; one addition took the sum over the edge of a band
that had absorbed thirteen rounds of deltas, and the honest move was to say so rather than
to round the sum down to fit. The round before that one added ~50, ~30 in the parent and
~20 in the test, and took the sum to about 13% above its base; the one before
that added ~18, ~3 in the
parent, ~3 in the entry and ~12 in the test, and took the sum to about 11%.
It grew from 1350-1800 thirteen rounds ago, then 1560-2120, then 1580-2130, then
1650-2240, then 1790-2420, then 1836-2484, then 1866-2524, then 1925-2605, then
1972-2668, then 1985-2685, then 2036-2754, then 2053-2777, then 2057-2783, then
2066-2796, then 2075-2807, and the
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
costs nothing, being the same statements in a different order. (Round 33 adds a second and
much shorter block around that line's own three statements. The position this paragraph
records is unchanged — the line still stands outside the fork region — and what round 19
ruled out was a *blocking* write in a blocked region, which this is not.) Nothing in the entry: the
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
(R5). ~2 in the entry: `umask 077` beside the scrub, copied from `materialize.sh:31`,
because a scrub that resets variables, functions
and aliases does not reset a process attribute and neither does an `env -i` re-exec —
placed in the marker branch when it was written and moved above the scrub in round 31 (R1).
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
ends only when the parent has been reaped — the `while`, the test that tells the two
kinds of return apart (that round asked `kill -0`, which this round replaces), the
`last_forwarded` guard that keeps a repeat from being forwarded twice,
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
was then ~2578 against the ~2420 the range is derived from, about 6% above it and so still
well inside the ±15% the range expresses, so the implementation range was unchanged. (That
round wrote the running total as ~2535; adding the four bullets as they stood gives ~2578,
and the figure is corrected here rather than carried forward wrong.)

This round adds ~47, and it touches all three files, from two P2s that have nothing to do
with each other beyond both being a protection written one step too late. ~10 in the
entry: the `/dev/fd/*` close loop among its first builtins (~6), and the
`case " $(jobs -l) " in *" $parent_pid Running"*)` wrapped around the `kill` in the wait
loop with the not-interrupted branch moved to the top of the loop body (~4) — a gate on a
statement that already existed rather than a new mechanism (R1). ~12 in the C parent: the
`close` loop from 3 to a ceiling among the first statements of `main`, with the
`sysconf`/`getrlimit` pair that gives it that ceiling and the comment saying why neither
`closefrom` nor `close_range` is portable enough to use (R5). ~25 in the test: the two
inherited-descriptor cases and the fifo-and-reader helper they share (R10). Nothing was
made cheaper to compensate — the job-table gate could in principle have paid for itself by
retiring the `wait_interrupted` flag, and it does not, because the two answer different
questions and the loop needs both. The sum of the four bullets was then ~2625 against the
~2420 the range is derived from, about 8% above it and so still well inside the ±15% the
range expresses, so the implementation range was unchanged.

This round adds ~19, in the C parent and the entry and nothing in the test, from one P1
and one P2 that share a shape worth naming: both are a call that looked safe in the place
it was written and is not safe in the place it actually runs. ~15 in the parent: the
bounded `waitpid(…, WNOHANG)`/`select` loop that replaces the handler's unspecified
"brief wait" (~3), and the `parent-signal:` line assembled from a static signal-name
table and a hand-written decimal routine because `snprintf` is not async-signal-safe
(~12). ~4 in the entry: the reference open on descriptor 3, the `-ef` skip, the close and
the comment that keeps the three from being tidied away, which together stop the close
loop shutting the descriptor bash reads the script from. **All four of those entry lines
are withdrawn by the round after this one, and the claim below about the test is
withdrawn with them**: the skip could not tell a caller's read-only handle on the entry
script from a write handle on it, so the entry now closes every descriptor above 2 with
no exception and pays a headroom precondition instead, and the test does gain cases for
it. Nothing in the test, and that is
a claim rather than an omission — the entry-side descriptor case is unchanged except for
one condition on its fixture that the fifo already satisfies, and both new properties are
on R10's proof-by-reading list for reasons that section gives: a handler's undefined
behaviour cannot be provoked on demand, and a silently truncated entry produces neither
an error nor a status any assertion here reads. Nothing was made cheaper to compensate.
Re-derived from the four bullets as they now stand rather than carried forward — the
running total above had not been re-added since two rounds moved the bullets under it —
the sum is ~2699 (~1169 + ~437 + ~1033 + ~60) against the ~2420 the range is derived
from, about 12% above it and so still inside the ±15% the range expresses, so the
implementation range is unchanged.

This round adds ~9, in the entry and the test and nothing in the C parent, from one P2 in
exactly the place the round above put its own fix: the close loop's one exception. **−1 in
the entry**, which is the first negative figure in this list. Three statements come out —
the reference open on descriptor 3, the `-ef /dev/fd/3` skip and the reference close — and
two go in above the loop: `nofile=$(ulimit -n)` with the `case` that maps `unlimited` and
unparsable answers, and the `[ "$nofile" -ge 64 ]` refusal that writes one `E_RUNTIME`
line and exits. (**Round 41 replaces those two lines with one**, a builtin-only
`ulimit -S -n` pair that sets the headroom rather than reading it, and takes the entry
figure down by one again — the `case` and the comparison go with the variable they
existed for.) The comment on the block is reworded rather than added to. **~10 in the
test**, in two runs that reuse the fifo-and-reader helper and the `.run` poll the suite
already has: the same-file variant, which runs a copy of the entry with `8>>` that copy
open beside the fifo on 7 and asserts the copy's size and digest as well as the ordering
(~5), and the headroom pair at `ulimit -n 63` and `64` (~5). **Nothing in the parent**,
and that is a claim rather than an omission: the parent's startup close is a C `close`
loop over a numeric range with no `/dev/fd` glob, no shell `eval` and no script
descriptor to protect, so the finding does not reach it and R5 is unchanged. Nothing was
made cheaper to compensate, though the entry paid for its own fix and then some. The sum
of the four bullets is ~2708 (~1169 + ~436 + ~1043 + ~60) against the ~2420 the range is
derived from, about 12% above it and so still inside the ±15% the range expresses, so the
implementation range is unchanged.

This round adds ~10, in the C parent and the test and nothing in the entry, from two P2s
that are both a setup step undoing the property the step after it meant to prove. **~4 in
the parent**: the handler's `reaped` local with its initialisation, the `== target` test
that sets it where the loop used to break on `> 0`, and the `if (!reaped)` guards after
the loop — one over the single-pid branch's `SIGKILL` and blocking reap, one over the
group branch's blocking reap alone, the group `SIGKILL` staying unguarded (R2). **~6 in
the test**: the full-pipe case's filler becomes a background blocking writer with its pid
kept (~1), a fixed-delay `kill -0` requires it to still be blocked with a `ps -o state=`
read for the message and an outright failure if it has exited (~3), the `fcntl` probe
gains a pre-launch run with its `clear` assertion (~1), and the teardown kills the filler
before it closes the pipe (~1); the ~3 the withdrawn `EAGAIN` fill mode cost is spent
rather than given back, because the probe keeps the flag-reading mode the case now calls
one more time and only loses the writing one (R10). **Nothing in the entry**, and that is
a claim rather than an omission: R1's omission rule is the thing under test and it is
unchanged — what moved is how the test sets up the pipe it is tested on, plus a
re-measurement of R1's own paragraph on a real `pipe(2)` behind a blocking filler, which
is prose about the entry and not a statement in it. Nothing was made cheaper to
compensate. The sum of the four bullets is ~2721 (~1173 + ~439 + ~1049 + ~60) against the
~2420 the range is derived from, about 12% above it and so still inside the ±15% the range
expresses, so the implementation range is unchanged.

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
`work/README.md:71-73` asks for the value itself to be recorded rather than inferred, so
here it is for this pull request, on its own line:

`review_size: accepted-exception` (this spec PR)

One concern: **the launch boundary as a security control**. Evidence-based range:
**7999-10822 lines** — this file's measured 9410 lines plus or minus 15%, rounded. That
token is this spec pull request's; the `review_size: accepted-exception` recorded at the
top of this section is the *implementation* pull request's, and the two are never compared
or summed.

The `AGENTS.md:102-106` soft budget of ~300-400 net lines applies to artifact pull
requests too, and this one exceeds it by about ten times: `wc -l
work/resolver-trusted-parent/spec.md` is 9410 lines. Accepted as one concern — the
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
that scrub cut back to what it is, beside every `waitpid` that reaps a tracked
child brought inside the same signal block, with the id it reaps zeroed before the mask is
restored, so a pid the kernel has already handed to some other process on the machine can
never be the one a handler signals, and this round the entry's wait loop deciding what
interrupted it from a flag its own traps set rather than by asking whether the parent's
pid still answers, so the discriminator stops being a question about a number the kernel
may already have given to somebody else, with the test's sampler moved off that pid for
the same reason, beside the pin on the parent's own source exercised for the first time,
so the one check standing between an edited `trusted-launch.c` and a launched altered
parent cannot be missing while the suite passes, beside the sentinel that proves the
parent never signals the caller's process group placed in that group by turning job
control off for its case, so it can no longer survive the mistake it exists to catch,
and this round the entry's wait loop forwarding only while bash's own job table still
lists the parent's job as running, so a signal that lands after the reap can no longer
send a `kill` at a number the kernel may already have handed to somebody else, beside both
shipped files closing every descriptor they inherited above 2 before they fork anything at
all, so a caller's credential, socket or write handle outside the output root can no
longer ride into a SHA tool, a compiler or a `cp` and be a write root nobody declared,
and this round the parent keeping the resolver's process-group id live until the survivor
check and any kill of that group are finished, so a signal that lands while the parent is
walking the process table can no longer take the nothing-to-kill branch and leave a
surviving resolver group behind, beside the entry's descriptor close moving ahead of the
copied scrub and the re-exec, with the privileged-mode refusal moved to the first
statement in the file to make that safe, so nothing the entry forks or execs — the
scrub's own process substitutions and the `env` and second bash included — ever holds a
descriptor the close did not shut first, and this round the parent's signal handler
putting stderr's file status flags back before it exits, so a flag it set for one
best-effort line can no longer break the entry's own diagnostic and the caller's output
on a descriptor none of the three own alone, beside every helper the parent runs before
the resolver exists — the two digest tools and the jq probe — `execve`d with a fixed
two-variable environment instead of the caller's, so a `PERL5LIB` aimed at Darwin's
perl-script `shasum` can no longer run the caller's code inside the tool whose answer
decides whether the pins hold, and this round the parent's one flag-toggling diagnostic
outside a handler performed with the three signals blocked, so a handler that fires
between the set and the restore can no longer save the toggled flags, restore them as the
original and leave a shared descriptor non-blocking behind it, beside the entry's own
diagnostic omitted wherever bash cannot write it without the risk of never returning, so
a caller who pipes stderr into a reader that is not draining gets the `128 + signal` exit
this path promises rather than a finished cleanup and a hung entry, and the round before
this one the entry's close loop made to skip the descriptor bash is reading the script
from, by an
identity test against a reference the entry opens on its own script rather than by the
pathname comparison that is measurably false on Darwin, so a caller with a low
`RLIMIT_NOFILE` could no longer make the entry stop part-way through itself and exit `0`
having done nothing, beside every call in the parent's three signal handlers held to the
POSIX.1-2017 async-signal-safe list by name, so the wait between the `SIGTERM` and the
`SIGKILL` and the line that reports the branch cannot be written with the `nanosleep` and
the `snprintf` the rest of the file may use and deadlock the process in the middle of the
cleanup they exist to describe, beside that skip withdrawn and replaced by a
descriptor-headroom refusal above the loop, because an identity test on the open file
cannot tell a caller's read-only handle on the entry script from a write handle on it and
so kept a writable descriptor outside the output root alive across the re-exec and into
every child, where closing every number above 2 without exception and letting bash
relocate its own script input — with a headroom precondition first, refusing where the
relocation has no free number to use — shuts the write handle and keeps the
entry running to its end, beside the entry's signal traps setting the wait loop's
flag as part of recording the signal and that loop forwarding an already-recorded signal
before each `wait` rather than only after an interrupted one, so a signal delivered while
the entry sits in `wait` can no longer be read as the parent's own exit and one delivered
before the loop began can no longer be left unsent while the entry blocks for the parent's
whole natural life and then reports the status of a run nobody interrupted, and this round
the handler's bounded wait recording whether it actually reaped the target, so the
single-pid branch stops sending a `SIGKILL` to a number the kernel took back a moment
earlier while the group branch keeps sending its own unconditionally, the survivors that
kill exists for being the one thing a handler has no safe way to check, beside the
full-pipe case filling its pipe with a blocking writer rather than a non-blocking one, so
the flag the old filler left behind on the shared open file description can no longer turn
the entry's unconditional write into a fast `EAGAIN` and pass the single case in this
suite that exists to catch that write, beside this pull request's own
`review_size` value written out as the exact token the plan gate names, beside the one
concern and the range, so a reviewer or a check looking for the record finds the value
rather than prose it would have to read the value out of, and cannot take the
implementation's token for this one, and this round the bound jq required to be the run
directory's own and the `awk` beside it verified byte for byte before any fork, so a
caller who hands the parent a genuine pinned jq out of a directory of their own can no
longer have the resolver execute their `awk` from the tool root it derives from that one
path, beside the parent's startup close enumerating `/dev/fd` and treating the caller's
soft limit as a ceiling nowhere, so a descriptor opened high and left above a lowered
`RLIMIT_NOFILE` can no longer ride into every digest tool the parent forks, beside the
documentation's promise of an `entry-signal:` line carrying the same omission condition R1
states, so a caller who pipes stderr is no longer told to expect a line the entry
deliberately does not write, and this round the parent pinning every one of the eight
files the runtime executes or evaluates rather than three of them, with direct invocation
stated as test-only and unsupported beside it, so an edited jq module can no longer reach
the runtime through a caller who skipped the entry and the one thing that path still lacks
— the helper's provenance, which no binary pin could give it — is named as the reason the
entry is the only supported launch, beside the entry's own diagnostic narrowed to a
regular file alone, so the line can no longer be written to a terminal whose output is
flow-controlled or whose pty master nobody is reading and hang the exit the whole signal
path exists to deliver, beside the entry's descriptor-headroom precondition
setting the soft limit with a builtin instead of reading it through a command
substitution, so no child of any kind exists above the close loop and the boundary R7
states — every process in this tree starting after the caller's descriptors are shut —
is true as written rather than true but for one short-lived bash child, and this round the
entry's close loop refusing outright when its `/dev/fd` glob matches nothing, with the
precondition trying the largest cap first so that normalising the soft limit raises a
caller's room where it can rather than always cutting it to 256, so a caller who has
already filled the low descriptor numbers is either served with every one of them shut or
turned away before anything is created, and can no longer be handed a run that closed
nothing, kept their credential open inside every child and reported success, and this round
three statements this spec made when a number was smaller brought back into step with the
number: the parent's blocked-signal rule naming all eight of its hash children rather than
the three it had when the rule was written, so the five module-hash forks cannot be read as
standing outside the window that exists to stop a handler killing a child whose pid has not
been published; the entry's soft-limit postcondition stated as the three rungs the ladder
actually leaves rather than the two it used to, so no plan or test asserts a limit the
entry stopped setting; and the external `printf` restricted to the data writes it performs,
with every refusal line the builtin's and an ordering assertion behind it, so the boundary
R7 states — the first external command the entry runs is `/usr/bin/env` — cannot be broken
by an implementer who took an allowlist entry at its word).
The same record again here, where the count it rests on is derived, on its own line:

`review_size: accepted-exception` (this spec PR)

One concern: **the launch boundary as a security control**. Evidence-based range:
**7999-10822 lines** — this file's measured 9410 lines plus or minus 15%, rounded. That
token is this spec pull request's; the `review_size: accepted-exception` recorded at the
top of this section is the *implementation* pull request's, and the two are never compared
or summed.

That range is the artifact pull request's own, recorded in the same words in the waiver
above and in the waiver at the end of this section; the implementation pull request's
range is the separate figure above. It was
553 lines and 470-636 fourteen rounds ago, then 783, then 847, then 1012, then 1202, then
1503, then 1764, then 1955, then 2245, then 2512, then 2636, then 2933, then 3168, then
3295, then 3409, then 3642, then 3866, then 4013, then 4128, then 4293, then 4476, then
4773 — one round appended none of its own and both were restored the round after — then
5023, then 5153, then 5448, then 5897, then 6140, then 6415, then 6767, then
7173, then 7420, then 7690, then 7878, then 7914, then 8242, then 8637, then 8867,
then 9271; where each block of growth went is worth naming so it can be checked rather
than trusted.
The 230 lines
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
account of why the status alone cannot tell an interrupted wait from a reaping one, a
`kill -0` discriminator with a zombie argument under it and a note claiming pid reuse was
impossible inside the loop — all three of which this round withdraws, because bash reaps
its own children and there is no zombie — the forward-once rule with both choices stated
and the quieter one
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
how it was entered: the branch's first statement is
`case $- in *p*) ;; *) exit 78 ;; esac` — round 31 moved that same line to the top of the
file, so read this as where it was put first rather than where it is — the
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

This round is +130 net over one P2, and it is the other half of a rule an earlier
round wrote for forks and did not write for reaps: the parent blocked the three signals
while a pid was being published and left it unblocked while the same pid was being given
back. About 41 go to R2's new reap block. The rule itself is four statements — block,
`waitpid`, zero the id, restore — but most of those lines are the correction underneath
it, because the sentence being replaced was not merely incomplete, it argued the gap was
safe: pid reuse is system-wide, so the parent forking nothing in that span says nothing
about whether the number is still the parent's, and a handler that ran there could send
`SIGTERM` and `SIGKILL` to a process belonging to somebody else. The cost of the fix is
stated rather than skipped — a forwarded signal waits for the child being reaped, which is
milliseconds for a digest or a `--version`, bounded by nothing in this spec, and accepted
because these are tools the parent already trusts by path and by digest. The resolver's
three reap sites are named with their lines: the poll loop's `WNOHANG` call, the limit
path's blocking wait after the group `SIGKILL`, and the `setpgid`-failure reap that is
already inside the fork region and needs only the mask restored — with the rest of the
poll loop deliberately left outside the block, so responsiveness does not change and each
blocked window is microseconds. About 18 go to what happens after the reap: no `kill` may
name the old `pgid`, the streaming and classification read descriptors rather than
processes, and the one place the reaped number is still used — the copied survivor check
immediately after `observed == child` — is named as a read whose worst case is a
misclassified exit, kept as copied on the supervisor's local `child` and explicitly not
"fixed" by reaching for a `pgid` that is `0` by then. That last sentence is the part of
this round that did not survive: round 31 found that the same survivor check is where the
cleared `pgid` does damage, and moved the check — and the group kill behind it — inside
the block, with the clear last. Read this paragraph as the history of the reap rule, not
as the current ordering. The earlier `ESRCH`/`ECHILD`
sentence is corrected rather than kept: the ids are never stale, so the error no longer
stands for a pid that might belong to a stranger, only for a child that died between the
handler's read and its `kill` and is a zombie this parent owns. The remaining ~71 are the
ripples and the bookkeeping, and one of them carries mechanism: R10's proof-by-reading
sequence gains the reaps, with the reason no test is written for them — the failure needs
the kernel to hand the pid to another process at the instant a signal arrives, which no
test can arrange, so a case aimed at it would pass by missing. The rest are the two
variables' own bullets in R2, Design step 1's handler clause, the Copy-versus-adapt
handler item growing again rather than a new deviation being added, the
accepted-concern list at the top, and the re-derived size figures here and for the
implementation, whose range moves by the ~10 the parent gains.

This round is +295 net over three P2s, and the first of them is a correction to the
fix the round before last made: the loop that round wrote is right about *when* to stop
and was wrong about *how* it decided. About 126 go to R1's wait on the parent. The
discriminator changes from `kill -0` on the parent's pid to a `wait_interrupted` flag the
three recording traps set and the loop clears before every `wait`, which is two shipped
lines; the rest is the withdrawal underneath it, because the sentence being replaced did
not merely pick a weak test, it argued from a zombie that is not there. Bash reaps its own
children asynchronously and keeps the status in its job table, so the pid is gone — and
free for the kernel to hand to anyone — before the `wait` that reports the status returns.
Both halves of that were measured on the same bash 3.2 rather than reasoned about: an
exited, never-waited-for background child answers `kill -0` with `ESRCH` and shows nothing
in `ps`, and a sixty-attempt coincidence run caught the old loop reading `143` off an
interrupted wait for a parent that had exited `7`. The measurement paragraph is rewritten
around that: three columns per line — the flag, `jobs -p`, and what the old loop asked —
so the candidate taken, the candidate rejected and the test withdrawn can be compared on
the same events. `jobs -p` is recorded as workable and rejected on cost, which is the
honest reason rather than a manufactured defect — and the round after this one takes it
after all, for the second of the two decisions the loop makes, so that verdict stands here
as the history it is rather than as advice. The coincidence brings one new shipped
line, the `[ "$status" -ne 127 ] || { … }` guard, and one new admission: in that instant
the parent's own status can be lost and `128 + signal` is what the entry reports. A second
admission replaces a claim — the forward-once rule used to end "pid reuse is impossible
inside this loop", and now bounds the hazard instead of denying it, one `kill` in one
instant against a loop that used to re-send for as long as a stranger answered.
About 45 go to R10's new group-1 refusal: an edited `resolver/v1/trusted-launch.c`, which
the suite had never exercised, with the compile-never-ran assertion, the honest limits of
the poll that makes it, and the reason the parent cannot stand in for the entry here —
by the time it runs it *is* the source it would be checking. About 35 go to the
repeated-signal case's sampler, which polled the same pid R1 has just stopped trusting and
in exactly the window where it is least trustworthy; it now watches the parent's own
`parent-signal:` line against the existence of `.run`, with the reason that line cannot be
written early. About 30 go to the stopped-parent case's sentinel: `set +m` for that case
with the measurement that explains it, the `ps -o pgid=` equality assertion before any
signal is sent, and the check of the other two job-control cases, which keep `set -m`
because they aim at a group and have no sentinel to strand. The remaining ~59 are the
ripples and the bookkeeping: Design step 2's wait clause, R1's initialise-before-arming
paragraph, which now names the new flag and says why a variable only traps write is
outside the rule, the signals bullet under Areas
of concern, two earlier rounds' accounting paragraphs corrected where they asserted the
zombie as fact, the accepted-concern list at the top, and the re-derived size figures here
and for the implementation, whose range does not move because the ~22 the entry and the
test gain is under one per cent of the sum it comes from.

This round is +449 net over two P2s, and both are the same shape as the last three
rounds' findings: a defence that is in the right file and one step too late in it. About
150 go to the entry's wait loop, and most of that is the two decisions being separated
from each other. The loop now answers "should I leave" with the `wait_interrupted` flag —
with the reviewer's rule written out, that an uninterrupted wait is a reaped parent and
forwards nothing — and "should I forward" with `$(jobs -l)`, forwarding only while the
parent's job is listed as `Running`, because the flag is set by a signal that lands after
a reaping wait just as it is by one that cuts a wait short, and a `kill` on that path goes
to a number the kernel may have handed to somebody else. The rest of the 150 is the
evidence and the withdrawal: why the job table is immune to pid reuse where `kill -0` was
not, the three job states measured and what each one means, the stopped-job reading that
a script's `jobs` does not see, the re-run two-`TERM`, `INT`, exit-`42` and control
variants with a `running=` column in place of the old `jobs -p=` one, a sixty-attempt
coincidence run that caught the reviewer's case 27 times and forwarded on none of them,
and the round-before-last's "workable, rejected on cost" verdict on the job table
withdrawn in the open, with the subshell question it left hanging answered by measurement.
The residual paragraph is rewritten rather than deleted: one `kill` in the instant between
the table check and the `kill` itself, shown in the measurement as a line where the table
said `Running` and the `kill -0` a breath later said the pid was gone. About 115 go to
the inherited descriptors. Both shipped files now close everything above 2 before they
fork anything: the entry with a `/dev/fd/*` glob, an all-digits check and an
`eval "exec ${fd}>&-"`, because bash 3.2 has no `{fd}>&-`, measured with a fifo whose
reader sees end-of-file before `.run` exists; the parent with a `close` loop from 3 to a
ceiling from `sysconf(_SC_OPEN_MAX)` capped by `getrlimit(RLIMIT_NOFILE)`, with `closefrom`
and `close_range` ruled out by name for not being portable to both pinned platforms. The
resolver child's pre-`execve` close stays as the second line, R3's one-sentence claim says
both, R5 confirms the four descriptors the parent deliberately holds are all opened after
startup and so untouched, and R7 admits that its one-write-root claim had been resting on
the caller's descriptor hygiene without saying so. About 85 go to R10: the two
descriptor cases with the EOF-before-marker reasoning and the honest note that the
parent's half is bounded by the resolver fork rather than the first fork, the
repeated-signal case's statement that the table gate changes nothing it asserts and why,
and three more lines on the proof-by-reading list. The remaining ~80 are the ripples and
the bookkeeping: Design steps 1 and 2, the Copy-versus-adapt descriptor item growing
rather than an eleventh being added — with the launcher verified to contain no startup
close, no `closefrom`, no `close_range`, no `sysconf` and no `getrlimit` — the
accepted-concern list at the top, and the re-derived size figures here and for the
implementation, whose range does not move because the ~47 the three files gain is inside
the ±15% band the range expresses.

This round is +243 net over one P1 and one P2, and both are the previous two rounds'
own fixes found to be one statement out of place. About 95 go to the P1 in R2. The
blocked region around the resolver's reap now runs on through the copied survivor check
at `:460-462` and, when that check finds survivors, through the copied
`kill(-child, SIGKILL)` and `kill(child, SIGKILL)` at `:491-492` and the wait behind them,
with `pgid = 0` last and the mask restored after it. Most of those lines are the failure
being written out rather than the rule, because the rule is a moved statement: round 28
cleared `pgid` the instant the reap returned, so a signal delivered during the
process-table scan took the handler's `no-runtime` branch and left a surviving resolver
group running while the entry removed `.run` — the exact outcome the whole requirement
exists to prevent, reached this time through the one case the previous round's fix had
turned into a blind spot. The cost is stated rather than skipped: the handler waits for
one `process_group_count` walk on every normal exit, and rarely for a group `SIGKILL` as
well. The limit path is checked for the same ordering and written out beside it so the two
cannot drift, and the copied code's own pid-reuse exposure between `:457` and `:491-492` is
named honestly as unchanged rather than left to be discovered. Round 28's accounting
paragraph, which recorded the survivor read as kept-as-copied and explicitly not fixed, is
marked as history rather than left standing. About 90 go to the P2 in R1, and most of
that is a reordering with its reason. The entry's `/dev/fd/*` close loop moves ahead of
the copied scrub and the re-exec, because the scrub's two `done < <(builtin compgen …)`
process substitutions fork bash children and the re-exec execs `/usr/bin/env` and a second
bash, so a caller's credential, socket or write handle was live in four processes before
the point R10 observes it shut. Two statements move with it: the `case $-` privileged-mode
refusal goes from the marker branch to the first statement in the file, which is what
makes it safe to run `eval` and the rest before the scrub — no imported function, no
`BASH_ENV` alias — and now covers the plain four-argument arrival as well as the forged
marker one; and `umask 077` goes above the scrub with them. Nothing shipped is added: the
copied bytes are untouched and only their position relative to the entry's own three
statements changes, which is recorded that way in Copy-versus-adapt. R10 keeps the
EOF-before-marker case and gains the honest note that its tightness dates from this round
rather than the last, plus the close-precedes-the-scrub-and-the-re-exec line on the
proof-by-reading list. The C parent's half of the same question was checked and is clean:
`umask` and `sigaction` fork nothing, so its startup close really is before its first
child. The remaining ~58 are the ripples and the bookkeeping: Design steps 1 and 2,
the Copy-versus-adapt handler and entry-copy items growing rather than new deviations
being added, R1's initialise-before-arming paragraph, R7's command-list note on what runs
before the scrub, R9's documentation line, R10's
forged-marker paragraph, two earlier rounds' accounting paragraphs marked where they
recorded a position that has since moved, the handler's contract sentence gaining the
word "group", the accepted-concern list at the top, and the re-derived size
figures here and for the implementation, whose range does not move because the parent's
~4 is the whole implementation cost of the round.

This round is +275 net over two P2s, and both are the same mistake in two places: a
defence that stopped at the process boundary when the thing it was protecting crosses it.
About 55 go to R2's handler. The fix is one statement — `fcntl(F_SETFL, flags)` with the
saved value before the `_exit` — and nearly all the lines are the withdrawal of the
sentence it replaces, which did not merely omit a restore but argued one was unnecessary
because `_exit` follows immediately. That reasoning takes the flag for a property of the
process. It is a property of the open file description, which the parent shares with the
entry that started it and with whatever started the entry, so the parent exiting leaves
the flag exactly where it put it and the entry's `EXIT` trap writes its `entry-signal:`
line through it afterwards; on a pipe, that is a truncated line and a caller whose own
writes start failing. (Round 33 withdraws the first half of that example: the entry now
omits its line entirely when stderr is a pipe, so what a left-set flag breaks there is the
caller's own writes, which was always the stronger half. The conclusion is unchanged and
R2 now rests it on the caller alone.) The restore is required unconditionally, including after a write
that failed, and the `runtime-pgid:` line's own restore — which was justified narrowly, by
the parent still being alive — is re-justified on the same wider ground. About 90 go to
R7's fixed `envp`. The three children the parent forks before the resolver exists — a
SHA-1 tool per pin, the SHA-256 tool, the jq probe — were being `execve`d with whatever
the caller set, which R3's array does not cover because R3's array is built later and for
the resolver alone. Each now gets `PATH=/usr/bin:/bin`, `LC_ALL=C` and nothing else, the
same pair the entry launches the parent under (R1), and `environ` is handed to no child of
this parent ever. Most of those lines are the evidence and the narrowing: Darwin's
`/usr/bin/shasum` is a perl script, and a `PERL5LIB` with a `strict.pm` in it makes it
print a marker and exit 3 instead of a digest — measured, with the `env -i` form measured
beside it returning the right forty hex digits with the pollution still set — plus the
reason `TMPDIR` and `HOME` are on R1's compile line and deliberately not here, which is
that nothing in these three reads either, the entry's two directories are already removed
by the time the parent runs, and the parent's own sandbox pair is created after the pin
checks on purpose, so a refused run leaves the caller's output directory untouched.
About 70 go to R10: the third direct-parent pollution case with its per-platform fixture
and, more to the point, its negative control, because a case whose assertion is that a
marker never appears passes on any machine where the marker could never appear; the
mid-run signal case's pipe variant, which asserts the flag rather than the line, with both
weaker tests written out and rejected — a drained pipe passes on the broken parent, and a
plain file ignores `O_NONBLOCK` entirely, which is why the suite already in place could
not have caught this; and two more lines on the proof-by-reading list, the handler's three
`fcntl`s and a grep for `environ`/`execv`/`execvp`/`execlp`. The remaining ~60 are the
ripples and the bookkeeping: R2's pre-resolver child list, R3's no-caller-variable
sentence, R5's descriptor-close block gaining the environment as the other half of the
same claim, R1's "needs no `HOME` and no `TMPDIR`" sentence, Design step 1's handler and
exec clauses, the Copy-versus-adapt handler item and the blob-pin item growing rather than
an eleventh deviation being added — with the launcher verified to contain no `environ`, no
`execv`, no `execvp` and no `execlp`, and both of its exec sites already passing explicit
arrays — the accepted-concern list at the top, and the re-derived size figures here and
for the implementation.

This round is +352 net over two P2s, and they are one rule reaching the two sides of the
process boundary: a diagnostic must be *incapable* of blocking, and putting it last is
not the same thing. About 85 go to R2's `runtime-pgid:` line. The line was already
non-blocking and already outside the fork region, and what was missing is that the
`F_SETFL` toggle around it is itself a window: a handler firing between the set and the
restore reads `flags | O_NONBLOCK`, takes that for the original, restores it before its
`_exit`, and leaves the flag on a description the entry and the caller share — the round
before this one's fix defeated through the one path that fix cannot see. The write now
runs between a `sigprocmask(SIG_BLOCK, …)` and its restore, and most of those lines are
reconciling that with round 19, which moved this line *out* of a blocked region: the
hazard there was a `write_all` that can wait, the write here returns immediately, the
line's position has not changed, and the rule that covers both is written down once —
no blocking write inside a blocked region, no shared-flag toggle outside one. The
enumeration behind the claim that the rule reaches one site is written down too, because
"apply this everywhere" is worth nothing without a list: two flag-toggling writes in the
parent, the handler's already held by `sa_mask`, every other stderr write going out
through the copied `write_all` and touching no flag. About 155 go to the entry's line.
The finding is that the `EXIT` trap's `printf` can hang forever on a full undrained pipe,
and that the sentence this spec used to close that question — written last, "a hung write
can only delay the exit status" — is simply wrong: a `printf` that never returns means
the entry never reaches `128 + signal` and the caller's `wait` never returns either, with
the cleanup already done and the whole promise of the path unkept for the sake of a
courtesy. Bash 3.2 cannot set `O_NONBLOCK`, so there is no version of the parent's fix to
copy, and the decision is to write the line only where a write cannot block — a terminal,
a regular file, a character device — and omit it on a pipe, a FIFO or a socket.
**Round 40 narrows that set to the regular file alone**, because a terminal's write can
block too — flow control, an unread pty master — so the condition this paragraph records
as three tests is one test from that round on, and the interactive case it admitted is the
half that was wrong. Most of
those lines are what makes that a decision rather than a hunch: the measured table of
what `[ -t 2 ]`, `-f /dev/fd/2` and `-c /dev/fd/2` answer for each of seven kinds of
stderr — which round 40 keeps as its own evidence, reading one column of it — the
argument that the condition is a whitelist so an unrecognised object omits
rather than writes, the measurement that an unconditional `printf` into a 65536-byte
full pipe had not returned after five seconds while the guarded one exited `143` in
0.01 s, the cost stated plainly (a draining pipe loses the line too, and no test can tell
a draining pipe from a full one without performing the write that is the hazard), and the
statement that this is the one rule the two shipped files do not share. About 55 go to
R10: the sixth signal case with its pre-filled pipe and its three assertions, the
reading of the parent's six statements added to the proof-by-reading list, and the
re-check of the cases that already assert the entry's line — all of which read it from a
plain file, which was a readability choice and is now load-bearing, said here rather than
left to be discovered by moving one of them onto a pipe. The remaining ~57 are the
ripples and the bookkeeping: R2's restore justification withdrawing the half of its
example the omission rule invalidates and resting on the caller instead, R2's
two-lines-compose paragraph, R1's `EXIT` trap step list and its reading note on the
"one `entry-signal:` line" shorthand used elsewhere, Design steps 1 and 2, the
Copy-versus-adapt handler and `runtime-pgid:` items growing rather than new deviations
being added, the Areas-of-concern diagnostics bullet, round 19's and round 32's
accounting paragraphs marked where each recorded something this round narrows, the
accepted-concern list at the top, and the re-derived size figures here and for the
implementation, whose range does not move because the round's ~18 leaves the sum at about
11% of the ~2420 it is derived from.

This round is +406 net over one P1 and one P2, and the two share a shape: a
call or a statement that is correct where it was written and unsafe where it actually
runs. About 155 go to R1's close loop. The finding was that the loop shuts bash's own
script descriptor because only 0, 1 and 2 are skipped, and most of those lines are the
measurements, because the measurements moved the fix twice. The first moved the *hazard*:
closing that descriptor does not normally make bash fail, it makes bash relocate its
script buffer onto a free descriptor — measured moving from 255 to 12 to 13 across two
runs of the loop, with a 68 KiB script reaching its last line every time — and it fails
only where `RLIMIT_NOFILE` leaves no headroom, where it fails *silently*: at
`ulimit -n 12` the script stopped at the end of what bash had buffered and exited `0`,
which is worse than the failure the finding described, because an entry that skips the
scrub, the re-exec and every check below and reports success is the one outcome no
refusal in this spec covers. The second measurement moved the *fix*: the natural test,
`[ "/dev/fd/$fd" -ef "${BASH_SOURCE[0]}" ]`, is false on Darwin for the descriptor it is
meant to catch, because `/dev/fd` there is an `fdesc` filesystem that reports the
underlying file's inode and its own device number, and `-ef` needs both — a rule that
would have parsed, read correctly, done nothing on one of the two shipped platforms, and
been true on the one CI runs. What works is comparing two `/dev/fd` entries against each
other, so the entry opens its own script on descriptor 3 and the loop skips 3 and anything
`-ef` it, with 3 chosen because bash's script descriptor is the top of the table and never
below 4 in any environment where bash starts at all. **The round after this one withdraws
that skip and everything in the next sentence that rests on it**, because the "honest
edge" it names turned out to be the finding: an identity test on the open file cannot see
a descriptor's access mode, so the survivor is not reliably read-only and the skip
preserved a caller's *write* handle on the entry script across the re-exec. The rest of
those lines are the honest edges: the one descriptor this keeps open that it did not open (a caller's own
handle on the entry's script, read-only, none of the three things the loop exists to
stop), the two rejected alternatives with the measurement that rejects each, the `79`
refusal when the reference cannot be opened, and the `exec`-with-`2>/dev/null` trap —
measured, because `exec 3<"${BASH_SOURCE[0]}" 2>/dev/null` points the shell's own stderr
at `/dev/null` for the rest of the run and would delete every `E_*` line below it. About
100 go to R2's handlers. The finding was that "a brief wait" inside a signal handler
constrains nothing, and the answer is the bounded
`waitpid(…, WNOHANG)`/`select`-at-50 ms loop written out, with the authority named:
POSIX.1-2017 XSH 2.4.3 carries `select`, `pselect`, `poll`, `sleep`, `waitpid`, `kill`,
`write`, `fcntl`, `sigprocmask`, `_exit`, `memcpy` and `strlen`, and does not carry
`nanosleep`, `usleep` or `snprintf`. Both of those absences are load-bearing rather than
trivia: the copied supervisor has a `nanosleep` at `:488` that a plan would copy into the
handler by reflex, and the `runtime-pgid:` line has an `snprintf` this spec explicitly
tells the plan to make the handler's line "the same way" as — so the handler's line is
respecified as a static signal-name table plus a hand-written decimal routine, and the
`runtime-pgid:` block gains the paragraph saying which half of "the same way" does not
carry. A few of those lines reconcile the standard against the platform's own
`sigaction(2)`, which reproduces the POSIX.1-1990 list and has no `select` on it: that is
an older list rather than a contradiction, `sleep(1)` is named as the fallback if it ever
turns out to be one, and saying so is cheaper than leaving a reviewer to find two lists
and assume a conflict. About 36 go to R10: two readings on the entry's loop, one of them
a grep for the `exec` redirection trap, one reading and one eight-name grep on the handler
bodies scoped so the legitimate `snprintf` and `nanosleep` elsewhere in the file do not
trip it, and the one condition added to the entry-side descriptor case's fixture, which
the fifo already satisfies. The remaining ~115 are the ripples and the bookkeeping: Design
steps 1 and 2, the Copy-versus-adapt handler item and the entry's third
above-the-scrub statement both growing rather than new deviations being added, the
accepted-concern list at the top, and the re-derived size figures here and for the
implementation — whose running total is re-added from the four bullets rather than
carried forward, because it had not been since two rounds moved them.

This round is +247 net over one P2, and it is the unusual case where a round takes a
line *out* of a shipped file and puts the argument for its absence in. About 100 go to
R1's close loop, and almost all of it is measurement, because the decision rests on a
bash internal rather than on anything documented. The finding was that the round-34
`-ef /dev/fd/3` skip preserves a caller's descriptor on `resolve-profile.sh` whatever
mode it was opened in, so a write handle outside the output root survives the loop and
reaches the re-exec and every child. The skip is withdrawn rather than tightened, and the
lines say why a tightening was available on one platform and refused: `[ -w /dev/fd/N ]`
discriminates open mode correctly on Darwin — measured, `--w-------` against `-r--r--r--`
on one 0644 file with `7>>` and `8<` — and follows the symlink to the file's own
permission bits on Linux, which is where CI runs, and this spec has already had to take
back one rule that behaved differently on its two platforms. With the skip gone the loop
closes bash's own script descriptor, and the lines that make that safe rather than lucky
are the relocation: `check_bash_input` calling `save_bash_input` with
`fcntl(fd, F_DUPFD, 10)`, named so a plan can confirm it on the CI image's bash; the
argument that a relocation target is free at that instant and therefore either absent
from the glob's snapshot or already closed by the loop, which holds whatever order the
loop runs in; the lexicographic glob order spelled out anyway (`10`, `11`, …, `2`, `255`,
`3`) because a reader will check it against the traces; and the traces themselves, on a
70 KiB script with a marker on its last line and the caller holding 4, 5, 7, 10 and 11
with 7 a write handle on the running script — every caller descriptor shut, the same-file
write handle with them, the marker printed, the file byte-identical, and the relocation
visible at `/dev/fd/12`. The rest of R1's lines are the precondition and its price. The
hazard re-measured with it removed: marker at `ulimit -n 14` and above, silent truncation
with exit `0` at 13 and 12, and `SIGSEGV` with status `139` at 11 — the middle of which is
the outcome no refusal in this spec covers. The floor of 64 justified as margin rather
than as a threshold, since the threshold moves with the caller's own descriptors and with
the one or two numbers the closing statement is itself holding (measured: `10` is taken
inside `eval … 2>/dev/null`, which is why the relocation lands on 11, 12 or 13 and not on
10). The `case` that maps `unlimited` and unparsable answers, because
`[ unlimited -ge 64 ]`
is not a false comparison but an error that would refuse the roomiest environment there
is. And the one cost stated rather than rounded away: `nofile=$(ulimit -n)` forks, which
is one bash child above the close holding the caller's descriptors — detected by the thing
that makes it visible, a `/dev/fd` listing inside the substitution that shows the caller's
five and not bash's `255`. (**Round 41 stops paying that cost rather than restating it**:
the precondition sets the soft limit with a builtin instead of reading it, the `case` goes
with the variable, and the listing-inside-the-substitution measurement survives as the
evidence for what was removed.) About 40 go to R10: two new entry runs (the same-file variant
with `8>>` a copy of the entry beside the fifo, and the `ulimit -n 63`/`64` pair with its
empty-output-root assertion), the round-34 fixture condition withdrawn with the exception
that made it necessary, and the proof-by-reading list's two round-34 entries *replaced*
rather than added to — the reviewer now reads for the absence of a fourth pattern in the
`case` arm and for the precondition's position. The remaining ~55 are the ripples and the
bookkeeping: Design step 2 and the Copy-versus-adapt entry item, where the precondition is
a fourth above-the-scrub statement rather than growth in a third and the loop's own text
shrinks; the statement counts that follow from that, three becoming four in five places
and six opening steps becoming seven; the Areas-of-concern descriptor bullet, which now
names the one fork above the close instead of claiming none (and which round 41 puts back
to none, because by then there is none); round 34's two accounting
paragraphs marked where each recorded something this round withdraws; the accepted-concern
list at the top; and the re-derived size figures here and for the implementation, whose
range does not move because −1 in the entry and +10 in the test leave the sum at about 12%
of the ~2420 it is derived from.

This round is +270 net over two P2s, and both are one finding in two places: a
statement sitting in the right block and in the wrong position relative to the `wait` it
exists to protect. About 55 go to the traps. The normative form is now the two-statement
`: "${entry_signal:=TERM}"; wait_interrupted=1`, written that way in the traps-only-record
block, in the first-signal-wins block and in Design step 2, with the flag write stated to
be part of *recording* rather than an exception to it, and with the failure a
record-only body produces written out rather than left to the loop: a signal arriving
inside `wait` leaves the flag empty, the loop reads that wait's `128 + signal` as the
parent's status, breaks, and the `EXIT` trap removes `.run` with the parent possibly still
alive. The name stays first-wins and the flag is said to be latest-wins on purpose, since
the loop clears it itself every pass. About 135 go to the loop's order. The five steps are
numbered and fixed — clear, forward, `wait`, clear-flag break, `127` break — the forward
moves above the `wait` and the clear to the top of the body, and the three arrival times
are worked through one at a time: recorded before the loop began, where step 2 of the
first pass sends it; landing between the clear and the `wait`, where the flag survives
because the clear is no longer the statement above the `wait`; and landing inside the
`wait`, which is the one arrival the old order also handled, now one pass later and no
slower. The measurement is re-run from scratch under the new order rather than
re-labelled, and it carries the finding in two blocks on one event: `entry status=143`
with the parent signalled and its marker on disk, against the old order's
`entry status=0` on the same event, with the `TERM` sent, nothing forwarded and the
stand-in's handler never entered. Beside it go a probe that widens the gap between the
clear and the `wait` with a `sleep` and drops a signal into it, the `INT`, exit-`42` and
no-signal-control variants re-run, and the sixty-attempt coincidence run kept as it is
with the reason its verdict survives the move — the same read of the same table, one
statement earlier on the following pass. Two limits go in with the fix rather than being
left to be found: a trap consumes the signal, so the `wait` entered after it is not
interrupted and the forward waits on that wait's return, which is why the gap is called
narrow — two builtins and a subshell — rather than closed; and a signal that lands after
the parent's own exit is forwarded to nobody, with both of the statuses a caller can see
there named and each tied to which `wait` answered. The remaining ~80 are the ripples and
the bookkeeping: Design step 2's trap and wait clauses, R10's read-and-check list, which
now reads the trap bodies for two statements and the loop for its five steps in order,
because both of the windows those positions close need a signal delivered between two
adjacent statements and so cannot be tested; the repeated-signal case's job-table
paragraph; the Copy-versus-adapt trap item; the signals bullet under Areas of concern; the
accepted-concern list at the top; and the re-derived size figures here and for the
implementation, whose range does not move because the entry's ~3 is the whole
implementation cost of the round.

This round is +188 net over two P2s, and the two share a shape that is worth naming
because it is not the usual one: each is a *setup* step that quietly undoes the property
the step after it was going to prove. **About 50 go to the handler's `reaped` flag.** The
bounded wait sets it when its `waitpid` returns the target, and the two branches then
part company: the single-pid branch sends its `SIGKILL` and does its blocking reap only
inside an `if (!reaped)`, because a pid that has already been reaped is back in the
kernel's pool and signalling it is the stale-pid stranger-kill the rest of this design
closes; the group branch sends `kill(-pgid, SIGKILL)` regardless, because survivors are
the whole reason a group kill exists and a handler cannot run the process-table scan that
would tell it there are none. The residual that leaves is written out rather than rounded
off — a group id outlives its leader and is recycled only once every member has exited, so
the group kill could reach a stranger only if the whole group emptied inside the one-second
window *and* the kernel handed that exact number to a new group leader — and the
non-handler survivor path from round 31 is cross-checked beside it, because that path
*does* run the scan under the block and the difference between the two is deliberate.
`target` becomes the leader's pid on the group branch, which is the same number `pgid`
already holds. **About 115 go to the full-pipe case's filler.** The `O_NONBLOCK` filler is
withdrawn with the reason stated plainly — a copy of the write end shares the open file
description, the flag lives on the description, so that filler handed the entry a
non-blocking stderr and an unconditional `printf` then failed fast with `EAGAIN` instead
of hanging, which would have passed the case on a broken entry — and a blocking writer
takes its place: `/bin/dd if=/dev/zero bs=65536 count=2` on the write end, a fixed-delay
`kill -0` that requires the filler to still be blocked and fails the case outright if it
has exited, a `clear` assertion from the round-32 `fcntl` probe *before* the entry is
launched, and a teardown that kills the filler before closing the pipe. Both halves are
measured rather than argued, and R1's own measurement paragraph is re-measured on a real
`pipe(2)` behind a blocking filler for the same reason: the old filler blocks (still alive
at one second and at two, `ps -o state=` `S`) and leaves the flags reading `clear`, the
unconditional `printf` into that pipe is killed by a `perl alarm 3` at exit `142` with its
write still outstanding, the guarded body exits `143` at once having written nothing, and
the withdrawn filler reports `filled 65536 bytes, then EAGAIN`, leaves the probe reading
`nonblock` and lets the same unconditional `printf` run straight on to its `exit 143`. The
remaining ~23 are the ripples and the bookkeeping: Design step 1's branch clause and its
wait clause; R10's proof-by-reading list, which now reads for the flag and for the
asymmetry of the two guards, because the failure needs the kernel to reissue the pid in the
instants between the loop's `waitpid` and the `kill` and so cannot be tested; the
accepted-concern list at the top; and the re-derived size figures here and for the
implementation, whose range does not move because +4 in the parent and +6 in the test leave
the sum inside the ±15% it already expresses.

This round is +36 net over one P2, and all of it is this pull request's own
bookkeeping: the exact `review_size: accepted-exception` token for this spec pull request
now stands on its own line in the artifact-PR waiver and again in the self-count
paragraph, in the same words both times, with the one concern and the range beside it and
one sentence in each place saying which token belongs to which pull request, so the
implementation's token at the top of this section cannot be read as this one's. The rest
is the accepted-concern list at the top and the re-derived size figures here and in the
waiver below. Nothing in the shipped design moves, so the implementation range does not
move either.

This round is +328 net over one P1, one P2 and one P3, and the first two share a shape
worth naming: each is a check that was correct about the object it named and silent about
a second object reachable from it. **About 170 go to the bound tool root.** The parent
checked the helper and its own binary inside `.run` and said nothing about the jq path it
is handed — and the runtime derives its whole tool root from that one string:
`${YSTACK_RESOLVER_JQ%/*}`, then `$tool_root/awk`, checked with `[ -x ]` and `[ ! -L ]`
and nothing else and then executed
(`scripts/lib/profile-resolution.sh:673-676` and `:99`, read on `origin/main` rather than
carried over from an earlier round), with the parent's own `PATH` for the child built from
the same string (`portable-profile-resolution-launcher.c:662-677`). So a genuine pinned jq
sitting in a directory of the caller's own put the caller's `awk` inside the boundary with
every check the parent already makes satisfied. Two refusals close it before any `fork`:
the jq argument must be `.run/jq` by `st_dev`/`st_ino` identity against the
run-directory descriptor the parent has already proved, and `.run/awk` must be a regular
caller-owned mode-0500 file whose bytes the parent has compared in full — against
`/usr/bin/awk` on Linux, against the entry's own two-line 35-byte shim on Darwin, read
through descriptors with no child process anywhere in it, because awk's bytes are whatever
the host's OS build shipped and cannot be pinned the way jq's digest is. The ripples are
named rather than absorbed: R7's read list gains `/usr/bin/awk` for the parent on Linux,
R7's awk data-path paragraph gains the parent's one occurrence, R10's pass 1 replaces "the
C parent must not contain the token at all" with a position rule in that file too, R1's
copy paragraph says what the two destinations are so the parent's check has something to
be the other half of, and Copy-versus-adapt's run-directory item grows a third time rather
than an eleventh deviation being added — with the clean negative result recorded beside it,
that the launcher holds no `awk` token anywhere in its 702 lines and does nothing with
`argv[4]` but a `strlen`, a `strrchr` and the `PATH` it builds from the result.
**About 85 go to the startup close.** Its ceiling was the smaller of
`sysconf(_SC_OPEN_MAX)` and `rlim_cur`, and `rlim_cur` is not a ceiling on what is open: a
caller opens a high descriptor, lowers the soft limit under it, `exec`s, and the loop walks
straight past a descriptor every SHA-1 tool, SHA-256 tool and jq probe then inherits. So
the parent enumerates `/dev/fd` first — all-digit entries closed except 0, 1, 2 and
`dirfd`, with an `E_RUNTIME` refusal if the `opendir` fails, because a parent that cannot
read what the caller left open cannot make this requirement's claim — and sweeps 3 to
`rlim_max`-or-`sysconf` capped at 65536 second, as a belt for a `/dev/fd` that lists
incompletely. The "why not `closefrom`" paragraph loses its argument that the parent "does
not need" the directory, and the paragraph that says the launcher has no startup close
gains the note that `opendir` does appear there once, on `/proc`, in the copied
process-table scan. R10 gains the case the finding describes: the fifo's write end on
descriptor 300, `ulimit -S -n 64` after it, the parent exec'd, and the
EOF-before-`runtime-pgid:` observation required to hold for 300.
**About 12 go to the documentation line.** R9 promised the caller an `entry-signal:`
line beside the parent's on an interrupted launch, and R1 omits that line on a pipe, a
FIFO or a socket, so an implementation following R1 would have shipped documentation that
was false for every piped caller. The line now carries R1's condition in the same
three-and-three words, and R1's own reading note says why this one mention writes the
condition out instead of taking the shorthand: a reading note settles things inside the
spec and settles nothing for someone reading the shipped documentation. (Round 40 cuts
R1's condition to the one `[ -f /dev/fd/2 ]` test, so the documentation line it fixes
carries one kind rather than three-and-three; the rule that the documentation states the
condition in full rather than promising the line is this round's and is unchanged.)
The remaining ~61 are the ripples and the bookkeeping: two more entries on the
proof-by-reading list — the enumeration being first, its refusal existing at all, and the
two new checks standing before the `fork`, none of which a case in this suite can reach;
Design step 1's close clause and its check clause; the inherited-descriptor group going
from five runs to six; the accepted-concern list at the top; and the re-derived size
figures here and for the implementation, whose range does not move because +30 in the
parent and +20 in the test leave the sum inside the ±15% it already expresses.

This round is +395 net over one P1 and one P2, and the two are unrelated except in
both being a claim that was true of the object it named and false of the one beside it.
**About 240 go to the launch boundary.** The P1 was that `trusted-launch`, invoked
directly — which this spec said the operator and R10 both do — gets files 1, 2 and 3
pinned and nothing else, so a caller-owned 0500 helper or an edited jq module could pass
every parent check and then be executed or evaluated by the runtime. The fix is two moves
and needs both. **The parent's pin list widens from three files to all eight the runtime
executes or evaluates**, using the same SHA-1 blob-id children it already runs for three —
eight children where three ran, each under the fixed `envp` and inside the same
block-fork-publish and block-reap-zero shape — so an edited module is now refused by the
parent as well as by the entry. The reason an earlier round gave for not doing this is
withdrawn on a reading of the library rather than on an argument: the generation id it
said the parent
could not reach is a *constant* in the library
(`scripts/lib/profile-resolution.sh:5,11`), so the parent carries its own copy, builds the
five module paths from it, and cannot drift from the library's own because it pins the
library's blob id. **And direct parent invocation becomes test-only and unsupported**,
stated in R5, carried into R7's direct-parent paragraph, R9's documentation, R10's group 2
and its operator Darwin recipe — which is rewritten so every run in it goes through the
entry — Areas of concern and Out of scope. The reason it cannot be made equivalent is
said plainly instead of implied: the helper is a compiled binary whose bytes no constant
can name, so a direct caller who builds `.run` can put any 0500 helper in it, and only the
entry, compiling from a pinned source into a directory it made, establishes that
provenance. The boundary is documentary and says so — the parent detects nothing about who
started it, because every marker it could test is one a caller controls, which is R1's
own reason for refusing a nonce on the marker word — and R10's group 2 is its only
legitimate user, which the test says in a comment beside the shared fixture builder.
**About 85 go to the entry's diagnostic.** The P2 was that the `entry-signal:` line's
condition admitted a terminal and a character device beside a regular file, and a
terminal write can block: a tty's output queue is finite, `IXON` flow control stops it
draining, and an unread pty master fills as a pipe does — so the `128 + signal` exit and
the caller's `wait` were still behind a write that might never return, on the one kind of
stderr an interactive caller actually has. The condition becomes `[ -f /dev/fd/2 ]` alone
in R1, R9's documentation line, R10's cases, Design step 2 and the Areas-of-concern
bullet; the measured seven-row table from round 33 stays exactly as it is, because the new
rule is one column of it read on its own; and what is given up is named — a terminal and
`/dev/null` lose the line, `/dev/null` only to keep the rule one test wide, with the exit
status and the parent's `parent-signal:` line remaining the record. R10's cases already
read the line from a plain file, so not one assertion moves. The remaining ~69 are
the ripples and the bookkeeping: R7's read list noting that the set of files read does
not change and only which process reads them does; the pin-constant assertion going from
thirteen blob ids to eighteen and gaining the two generation-constant comparisons; two
new group-2 cases and one group-1 case reclassified as the entry's half of a pin the
parent now holds too; Design step 1's pin clause; the Copy-versus-adapt pin item growing
rather than an eleventh deviation being added; a new Areas-of-concern bullet for the
boundary itself and the maintenance bullet re-counted; round 33's and round 39's
accounting paragraphs marked where each recorded something this round narrows; the
accepted-concern list at the top; and the re-derived size figures here and for the
implementation — where the range does move this round, because +25 in the parent and +15
in the test take the sum four lines past the top of the standing band, and moving the band
is more honest than rounding the sum down to fit it.

This round is +230 net over one P2, and it is the second time in this spec that
answering a finding makes a shipped file *shorter* rather than longer. **About 92 go to
R1's precondition.** The finding was against R7 rather than R1, and it was an overclaim
that this spec had written the evidence for itself: R7 says both shipped files close every
inherited descriptor above 2 before they fork anything, while R1 said in as many words that
the round-35 headroom precondition's `nofile=$(ulimit -n)` is a command substitution and
that bash 3.2 forks for one — so on a supported invocation where the caller held a
credential, a socket or a write handle on descriptor 7, one bash child did inherit it above
the close, and a plan could satisfy R1 to the letter while R7's sentence was false. Two
answers were available and the weaker one is refused: R7 could have carried the one-child
residual, the way Areas of concern already did, or the precondition could stop forking. It
stops forking. `nofile=$(ulimit -n)` with its `case` and its comparison becomes
`ulimit -S -n 256 2>/dev/null || ulimit -S -n 64 2>/dev/null || { printf 'E_RUNTIME\n' >&2;
exit 1; }` — one line, builtins only — and the reason it can be both the check and the fix
is a rule about the limit rather than a trick: an unprivileged process may set its soft
limit anywhere up to its hard limit, so the first form succeeds whenever the hard limit is
at least 256, the second whenever it is at least 64, and the two fail together only below
64, which is the round-35 floor with the round-35 argument for it unchanged. Most of those 92
are measurement, because three separate claims needed one: the four-fixture
table at hard 512, 128, 63 and unlimited, with the round-35 shape beside this one, which
shows the refusal preserved at 63 and a caller at soft 12 now *served* rather than refused;
the three end-to-end runs on the 80,994-byte marker script, where the soft limit is
normalised to 256 or 64, bash's script descriptor is shut at 127, 99 or 11 and relocated to
12, 12 or 13, the marker prints and the file is byte-identical — the first of those being
the only case where the precondition lowers the limit under an already-open descriptor, and
it works because `RLIMIT_NOFILE` bounds allocation and closes nothing; and the fork itself,
measured from both sides, the old shape's listing inside the substitution showing the
caller's 4, 5 and 7 with bash's `255` absent, and the new shape's soft limit readable as 256
in the shell afterwards, which a subshell could not have done for it. The `2>/dev/null` on a
builtin is measured rather than asserted too — a later `printf` to stderr still reaches
stderr, so the redirection is the temporary dup it is supposed to be and not a fork.
The 92 carries two neighbours of the precondition too: R1's "what it buys" paragraph,
which stops stating the exposure above the close exactly and states zero, and the plan's
CI confirmation, now run at `ulimit -H -n 64` and checking that rule on that bash too. It
also carries one correction nobody asked for and the block needed: R1's ordered list of
the entry's opening statements read six and omitted the precondition, which round 35's own
accounting had recorded as fixed; it reads seven now, and says that it was wrong.
**About 14 go to R7's own paragraph**, which is where the finding was raised: the claim
is now true as written, and the paragraph says so, names the round that made it true, and
names what it was carrying until then rather than quietly dropping the qualification.
**About 22 go to R10**, all of it two case rewrites and one reading. The headroom pair's
fixtures move from the soft limit to the hard limit (`ulimit -S -n 63; ulimit -H -n 63` and
the same pair at 64), because a precondition that raises a low soft limit makes a
soft-limit fixture prove nothing — and the extra `ulimit` each fixture needs is measured
too: a bare `ulimit -H -n 63` under a higher soft limit is refused by bash itself. The
proof-by-reading list's precondition entry gains the shape beside the position, with the
reason spelled out: no case in this suite can see a child that runs one builtin and exits,
so the absence of a substitution above the loop is a reading or it is nothing. And the
EOF-before-`.run` paragraph, which had claimed since round 35 that the close precedes the
entry's first fork of anything, is corrected to say that it took two rounds to become
true. **The remaining ~102 are the ripples and the bookkeeping**: the
Areas-of-concern descriptor bullet, whose one-child residual goes back to none; Design step
2's precondition clause; the Copy-versus-adapt entry item; round 35's two accounting
paragraphs marked where each recorded something this round withdraws; the accepted-concern
list at the top; and the re-derived size figures here and for the implementation, where the
entry bullet goes down by one — the two precondition lines out and one back in — and the
range does not move, because a −1 needs no band. (**Round 42 adds a third rung to that one
line and a refusal inside the loop below it**, because setting the limit turned out to be
able to take away the very numbers the loop needs; the builtin-only shape and the fork-free
claim this round bought are unchanged and the rung is free.)

This round is +404 net over one P1, and it is the third time in this spec that a
statement written to make the entry safe is what makes it unsafe in some caller's hands.
**About 100 go to R1's close loop.** The finding is that the loop can be handed nothing to
close and say nothing about it: `/dev/fd/*` is a glob, `nullglob` is off, and an expansion
that matches nothing leaves its own literal word in the `for` list — which is exactly what
a caller who has filled every descriptor below the normalised soft limit produces, because
reading a directory needs a descriptor too. The round-41 text then ran one pass over the
word `/dev/fd/*`, threw it away on the all-digits arm, closed nothing, and went on to the
scrub, the re-exec, the compiles and the `cp`s with the caller's credential, socket and
write handle still open, exiting `0`. So the loop's first statement is now a `case` on the
unstripped word against the quoted literal, writing one `E_RUNTIME` line and exiting. Most
of those 100 are measurement, and the rest is why this shape and not another: the literal
test is exact where an `[ -e "$fd" ]` proxy is not, which is measured from both sides — the
word `/dev/fd/*` matches the pattern and `/dev/fd/7`, `/dev/fd/255`, `/dev/fd/` and a bare
`*` do not, and `/dev/fd` cannot hold a file named `*` for a matching expansion to have
produced it, `: > /dev/fd/x` answering `No such file or directory`. The finding's own
fixture is measured twice at the round-41 cap, once with the refusal and once without —
253 descriptors on 3 through 255, hard and soft 1024 — giving one glob word, nothing closed
and exit `0` without it, and `E_RUNTIME`, exit 1 and nothing created with it; and a
3-through-200 fixture beside them shows the ordinary case unchanged, 203 words, 198
descriptors shut and the relocated `/dev/fd/12` alone left above 2.
**About 84 go to the precondition's ladder**, which is the other half of the same
finding and is where the fix actually lands for most callers. Normalising *downward* is
what created the broken caller, so the entry now tries `1024` before `256` before `64`, on
the rule the round before this one already rested on: an unprivileged process may set its
soft limit anywhere up to its hard limit, so the three fail together only below 64, and the
round-35 floor, the 63 refusal and the argument for both survive untouched. Measured as six
fixtures with the round-41 shape beside this one, where only the two rows at a hard limit
of 1024 or more move — soft 256 becomes soft 1024 — and end to end on the finding's own
fixture, where the ladder turns the refusal into an ordinary success with all 253
descriptors shut. The ordering question the finding invites is measured rather than argued:
a 118,131-byte script with the loop first and no precondition above it, started with the
caller holding 3 through 9, reaches its marker at soft 11 and at 14 and above and
**silently truncates at 13 and at 12 with exit `0`**, which is the round-35 hazard — so
raising first is what makes the close safe, and neither order is safe without the refusal.
The two shapes the ladder does not save are measured and named: a hard limit between 256
and 1023, where the second rung still lowers under a full low range and the refusal catches
it, and a caller who has filled every number below the *hard* limit, where the `ulimit`
attempts fail on their own `2>/dev/null` and the precondition refuses one statement
earlier. (**Round 43 changes nothing about this ladder and fixes what it left behind**:
the two paragraphs elsewhere that still stated the postcondition as the old two rungs, one
of them the sentence a plan or a test would read. The rungs, the floor and the refusals
here are untouched.) **About 18 go to R7**, whose claim now reads "closed or refused" and never
"silently skipped", with the arrangement it used to admit written out rather than a
qualification quietly dropped; the parent's half is unaffected, its own enumeration having
been fail-closed since round 39. **About 41 go to R10**, in two new descriptor runs rather
than a rewrite of the four it had: the filled-low-numbers success run at 3 through 255
under hard and soft 1024, which fails on the round-41 text and passes on the ladder, and
the filled-below-the-cap refusal run at 3 through 300 under hard and soft 1023. **The
second of those departs from the decision that ordered this round**, which costed two cases
from the two measured fixtures and expected the first of them to be a refusal; the ladder
makes it a success, so the refusal needs a fixture of its own, and the smaller
3-through-200 shape is left as a measurement in R1 rather than run twice in the suite. Two
things about the refusal run are stated where a plan would otherwise guess. Its stderr
assertion is deliberately weaker than its neighbour's, for a measured reason: on a table
that full bash cannot save a descriptor to perform `>&2` and writes one
`redirection error: cannot duplicate fd` line of its own, so the case greps for the
`E_RUNTIME` line where the hard-limit-63 case can still demand exactly one line. And it is
the one run in that group with no fifo, because there is no ordering to observe when the
entry refuses before its first external command. **The remaining ~161 are the
ripples and the bookkeeping**: the proof-by-reading list, which gains the three things to
read about the literal `case` — that it is its own statement, that it refuses rather than
`continue`s, and that the `*` is quoted — and has its precondition entry rewritten to
three rungs; Design step 2's precondition clause and its close-loop clause; the
Copy-versus-adapt entry item, where the loop's text grows back by one statement after
round 41 shrank it by three; the Areas-of-concern descriptor bullet, which now says the
loop can be handed nothing and that the answer is a refusal rather than a residual; R1's
own "what it buys" paragraph, which states the two-outcome boundary in the words R7 uses;
round 41's accounting paragraph marked where it recorded a line this round adds to; the
accepted-concern list at the top; and the re-derived size figures here and for the
implementation, where the entry bullet goes up by ~2 and the test bullet by ~10, and the
range does not move because ~2822 is still inside a band whose top is 2829 — by seven
lines, which is close enough that the next round should expect to move it.

This round is +139 net over three P2s, and all three are the same kind of finding
rather than three different ones: a statement this spec made when a number was smaller and
did not revisit when the number grew. No design changes, nothing new is required of any
shipped file, and the only implementation line anywhere is one test assertion.
**About 30 go to R2's fork set.** The mask-publish rule enumerated the pre-resolver
children as "the SHA-1 tool for each of the three blob-id pins", which was true until R5
widened the parent-pinned set to eight files, and left the five module-hash forks readable
as outside the region — forked and published with `INT`, `TERM` and `HUP` unblocked, which
is the exact window the rule exists to close. The enumeration now names all eight, and the
count is written down once where a reader meets it: eight SHA-1 children, one SHA-256
child, one jq probe, ten pre-resolver children, eleven forks in a run. The same count goes
into the R2 summary bullet, into `pre_child`'s definition and the reap block that clears
it, and into R10's proof-by-reading list, where it turns a judgement into arithmetic — a
file with ten regions has left one fork out. Nothing about the mechanism moves; the parent
already had to do this for every fork, and R5 already costed the five extra children at
"the same shape, five more instances of it".
**About 20 go to R1's soft-limit postcondition.** Round 42 put a 1024 rung above the two
the precondition had, and two paragraphs went on saying the limit past that line is 256 or
64 — one of them the postcondition sentence itself, which is what a plan or a test would
read. The postcondition is now stated once, normatively, in R1's requirement text: exactly
one of 1024, 256 or 64, the first rung the hard limit allows, with the note that an
assertion still written against "256 or 64" is testing the ladder this one replaced. The
two stale paragraphs and R10's fixture preamble follow it. The round-41 measurements that
record "normalised to 256 or 64" are left alone: they are what that round measured on the
two-rung form, and rewriting them would be inventing a measurement.
**About 40 go to R7's printf split and the assertion that holds it.** The allowlist listed
`/usr/bin/printf` "for the `E_*` lines", and an implementer who took that literally for the
refusals above the scrub — the `ulimit` ladder's and the close loop's unmatched-glob
`case` — would run an external binary in front of `/usr/bin/env`, which R7 names as the
entry's first external command. The list now says what the external one is for, which is
data: the `blob %d\0` header bytes into the SHA-1 pipeline, and the Darwin awk shim text.
Refusal lines are the builtin's, everywhere in the file, above and below the re-exec, so
there is no second question about which side of the boundary a given `E_*` line is on, and
the marker branch's `exit 78` writes nothing at all. R10 gains the one thing that keeps
this from being prose: pass 1 records the line number of the `env -i` re-exec and requires
every `/usr/bin/printf` occurrence to sit below it. Line-number ordering inside the one
file is the chosen mechanism and a marker comment is the rejected one, for the reason the
pass gives — a marker is a second thing to keep in step. Pass 2 keeps dropping the builtin
`printf` from `compgen -b`, which is what lets the refusals through and is why the ordering
assertion is the half that catches the mistake.
**The remaining lines are the bookkeeping**: round 42's accounting paragraph marked where
its three-rung line is now the postcondition's, the accepted-concern list at the top, the
test bullet at +1 with the sum and its band, and the re-derived self-count and range here
and in the two waivers.

This waives only the soft line signal for this artifact pull request, and
`work/README.md:71-73` requires the two things it is waived against to be recorded rather
than inferred, so both are recorded here in the waiver itself. **The one concern is the
launch boundary as a security control** — the single concern this whole spec has, named at
the top of this section and carried by every requirement in it. **The evidence-based range
for this spec pull request is 7999-10822 lines**, which is this file's measured
9410 lines plus or minus 15%, the same two figures the self-count paragraph above
states. **The exact value is `review_size: accepted-exception` (this spec PR)**, recorded
on its own line in the artifact-PR waiver at the start of this exception and in the
self-count paragraph above. That is the *spec* pull request's range and nothing else's: the
2091-2829 changed lines derived at the top of this section belong to the *implementation*
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
  `HUP`, and those three traps do one thing only, and do it in two statements: they record
  the *first* signal's name in an `entry_signal` variable and set the `wait_interrupted`
  flag the wait loop below reads. Everything else happens in the main flow afterwards, at the
  checkpoints set out below. When a parent exists the entry **forwards the same signal to
  the parent, waits for the parent to exit, and only then** lets the `EXIT` trap remove the
  run directory, and it exits `128 + signal`. That order is the whole point: the parent,
  not the entry, terminates the resolver's process group (R2), so the entry must never
  remove the run directory while a resolver could still be running out of it. A bash `wait`
  interrupted by a trapped signal returns at once with `128 + signal` of its own rather
  than the child's status, and a second signal interrupts the next `wait` the same way, so
  the main flow does not wait a fixed number of times: it waits in a loop that forwards a
  recorded signal once — ahead of each `wait` rather than only after one has been cut
  short — ignores every further interruption, and ends only when the parent has
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

  So the signal path is split in two. **The three traps are exactly two statements each,
  and this is the normative form every place in this spec that quotes them uses** —
  `: "${entry_signal:=TERM}"; wait_interrupted=1`, and its `INT` and `HUP` siblings, which
  differ in the name and in nothing else —
  and nothing else: no
  forward, no chmod, no removal, no write, no exit. The flag write is *part of* recording
  rather than an exception to it: the assign-if-empty records **which** signal arrived and
  `wait_interrupted=1` records **that** one did, and the wait loop below needs both
  answers. A trap body carrying only the assignment is the bug that reading makes easy to
  miss, so it is spelt out here rather than left to the loop: a signal arriving while the
  entry is inside `wait "$parent_pid"` would leave the flag empty, the loop below would
  read that wait's `128 + signal` return as the parent's own status, break, and let the
  `EXIT` trap remove `.run` while the parent — and therefore possibly the resolver's
  process group — was still alive, which is the one ordering this whole requirement exists
  to prevent. Two statements, three times, and nothing else in any of them.
  The `EXIT` trap does the cleanup, and
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
  `wait_interrupted=1` standing beside it is a plain assignment on purpose and is not
  given the same treatment: it is a fact about the wait the loop is in the middle of, not
  about which signal was first, and the loop clears it itself at the top of every
  iteration, so a second arrival is *supposed* to set it again. The name is first-wins,
  the flag is latest-wins, and the two statements sit side by side in every one of the
  three bodies. The
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
  `entry_status=''`, `parent_pid=''` — among its first builtins, after the seven opening
  steps below — the `-p` refusal, the `umask 077`, the descriptor-headroom precondition,
  the descriptor close, the scrub, the
  re-exec and the marker branch — and before it runs any external command, and the
  `trap … EXIT` line and
  the three recording traps are installed after them. `run` is the fifth name the `EXIT`
  trap reads, and it is not initialised empty but assigned, from the output root the entry
  has by then validated; that assignment precedes the `trap` builtins for the same reason.
  The rule is one line long and the plan should carry it as one: **no trap is installed
  until every variable that trap, the checkpoint or the `EXIT` trap can read has been
  assigned.** The `last_forwarded` variable the wait loop below uses is deliberately not
  in that list and does not belong among these four: no trap, no checkpoint and no part
  of the `EXIT` trap reads it, it is assigned empty on the statement immediately above the
  loop, and nothing under `set -u` can reach a read of it before that.
  `wait_interrupted` is outside the rule too, and for a sharper reason: the three traps
  *write* it, and a write is not a read, so `set -u` has nothing to say about it however
  early a signal arrives. Its only read is the loop's own `[ -n "$wait_interrupted" ]`,
  which is always preceded in the same iteration by the loop's `wait_interrupted=''`.
  The rule above is about reads, and those two variables are the check that it is being
  applied rather than recited.

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
  everything in it; then, **if `entry_signal` is set and stderr is a kind of object a
  write cannot block on**, write the one `entry-signal:` line
  described below to the entry's own stderr; then exit. The
  `chmod` is a harmless no-op when the signal arrives before the mode pass, while the
  directory is still 0700. With `run_created` unset the trap touches nothing on disk, which
  is the normal case for a refusal that happens before the directory exists. With
  `entry_signal` unset it writes nothing, which is every non-signal exit. With stderr on a
  pipe, a FIFO or a socket it writes nothing either, and the block below says why that
  second condition exists and what it costs.

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
    wait_interrupted=''
    if [ -n "$entry_signal" ] && [ "$entry_signal" != "$last_forwarded" ]; then
      case " $(jobs -l) " in
        *" $parent_pid Running"*)
          kill -"$entry_signal" "$parent_pid" 2>/dev/null || :
          ;;
      esac
      last_forwarded=$entry_signal
    fi
    wait "$parent_pid"; status=$?
    if [ -z "$wait_interrupted" ]; then
      entry_status=$status
      break
    fi
    [ "$status" -ne 127 ] || { entry_status=$((128 + $(kill -l "$entry_signal"))); break; }
  done
  ```

  **The order of those five steps is the whole of the loop's correctness, so it is written
  out as an order rather than left to be read off the block.** Per iteration, and in this
  sequence and no other: (1) `wait_interrupted=''` clears the flag; (2) if `entry_signal`
  is set and differs from `last_forwarded`, consult the job table and send
  `kill -"$entry_signal" "$parent_pid"` — only when `$(jobs -l)` shows that pid `Running`
  — then record the attempt in `last_forwarded`; (3) `wait "$parent_pid"; status=$?`;
  (4) if `wait_interrupted` is empty this wait was not cut short, so it reaped the parent:
  `entry_status=$status` and break; (5) if `status` is `127` the parent was reaped during
  an interrupted wait and its own status is gone, so `entry_status` is
  `128 + <signum of entry_signal>` and the loop breaks on that instead; otherwise go round.
  The forward is step 2 and not a step after the `wait`, and the clear is step 1 and not
  the statement before the `wait` — those two positions are what this round fixes, and the
  paragraphs below say which window each one closes.

  The three recording traps set `wait_interrupted` as well as the name, which is why each
  of them is the two-statement `: "${entry_signal:=TERM}"; wait_interrupted=1` stated
  above and not the assignment alone.
  That the trap body's own success does not become `$?` is bash's rule rather than an
  accident of writing — the shell saves the exit status before it runs a trap and restores
  it afterwards — and it is the rule `status=$?` depends on here, so the measurement below
  checks it rather than citing it: every interrupted wait in it reports `143` or `130`,
  not the `0` the trap's last assignment would have left.

  **Three arrival times, and the order above is what makes all three come out right.** An
  earlier round of this spec forwarded *after* the `wait` and cleared the flag on the
  statement before it, and two of the three were wrong there.

  1. **A signal recorded before the loop begins** — between `parent_pid=$!` and the first
     iteration, which is a real window because the traps have been armed since before the
     `mkdir` and bash defers a trapped signal until the foreground command it is waiting
     on finishes, so the trap can run on the statement that starts the parent. Step 2 of
     the **first** pass forwards it, because step 2 asks whether a name is recorded rather
     than whether a `wait` was interrupted. A loop that only forwarded after an
     interrupted wait forwards nothing here: nothing interrupted anything, the first
     `wait` blocks for as long as the parent takes, and the entry then reports the
     parent's ordinary completion — measured below as an entry that exits `0` on a run the
     caller sent a `TERM` to, with the parent never signalled at all.
  2. **A signal landing between step 1 and step 3** — after the clear, during the
     `$(jobs -l)` or the `kill` or in the instant before `wait` blocks. It sets the flag,
     and because the clear is step 1 rather than the statement immediately above the
     `wait`, that flag is still set when step 3 returns. So step 4 does not mistake the
     return for a reap, and the next pass's step 2 forwards the name. A loop that cleared
     the flag last erases exactly this arrival, and one that carried the flag from the
     previous iteration has the mirror-image fault: a stale `1` on a wait nothing
     interrupted, read as an interruption. One honest limit belongs with this one, and it
     is the shell's rather than the design's: a signal *consumed by a trap* leaves nothing
     pending, so the `wait` step 3 enters is not interrupted and the next pass is reached
     only when that `wait` returns — when the parent exits, or when a further signal cuts
     the wait short. Bash gives a script no way to test the flag and block atomically (no
     `sigsuspend`, and `wait` takes no timeout in 3.2), so the window between step 1 and
     step 3 is narrow — two builtins and one subshell around a builtin — rather than
     closed. Inside it the forward waits on the parent's own exit, which the probe below
     provokes with a `sleep` in that gap and measures: the flag survives, the status
     reported is the parent's real one, and nothing is sent at a reaped pid. Everything
     the `EXIT` trap promises still holds there — the removal follows the reap — and what
     is late is the forward, not the cleanup.
  3. **A signal landing while step 3 is blocked** — the ordinary `Ctrl-C` case. `wait`
     returns `128 + signal` with the flag set, step 4 keeps the loop, step 5 is not taken,
     and the next pass's step 2 forwards. This is the one arrival the old order also got
     right, and it costs one extra pass round the loop to get it right this way, which is
     one `wait` call and no external command.

  **The residual is one arrival and it is stated rather than argued away: a signal that
  lands after the parent has already exited on its own, but before the loop observes it.**
  It is forwarded to nobody, and correctly so — the job table does not say `Running`, so
  step 2 sends nothing at a pid the shell has given back. What the caller sees then
  depends on which wait the signal landed across, and both answers are honest ends rather
  than failures. If the parent's status is still in bash's job table — which it is on the
  bash this entry ships against — the next `wait` hands it back with the flag clear and
  step 4 reports **the parent's own status**: the parent finished its work before the
  signal existed, and that is what the caller is told. If the status has been consumed
  instead, the interrupted wait answers `127` and step 5 reports **`128 + signal`** for the
  recorded name. The first is what all sixty coincidence attempts below produced and what
  the gap probe below produced; the second is the branch the `127` guard exists for, dead
  code on bash 3.2 and kept for a bash that discards a collected status — which is one of
  the two lines the plan re-measures on the CI image's bash and records the answer for.
  Neither answer is `128 + signal` *and* a forwarded signal, because there was nothing
  left to forward to; the entry's promise of `128 + signal` covers the signals it can
  still act on, and this one arrived after the thing it would have acted on was gone.

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
  **`wait_interrupted` is what tells them apart**, and it is set by the same traps that
  record the name: the loop clears it at the top of each iteration, so finding it set
  afterwards means a trap ran at some point after that clear — while the `wait` was
  blocked, or in the two builtins between the clear and it — and finding it empty means
  nothing at all has run a trap this iteration, so the `wait` returned because the parent
  was reaped and `status` is the parent's own. The clear is at the *top* of the iteration
  rather than immediately above the `wait` on purpose, because the statements in between
  are the forward, and a clear below them would erase a signal that arrived while they
  ran.
  **`entry_status=$status; break`** therefore runs at one moment only, and the `EXIT`
  trap's removal of `.run` can never precede the parent's exit, however many signals
  arrive.

  **Two separate decisions come out of that, and this round is where they stop being one.**
  An earlier round wrote the loop as though the flag answered both, and it does not.

  1. **Whether to leave the loop is the flag's decision, and an uninterrupted wait is a
     reaped parent.** `[ -z "$wait_interrupted" ]` is the first test after the `wait`,
     ahead of everything else that return could mean, and on it the entry records `status`
     as the parent's own and breaks.
     Nothing is forwarded on that path, because there is nothing left to forward to: the
     parent has been reaped, and `parent_pid` is a number bash has already given back.
  2. **Whether to forward is bash's job table's decision, and only a job listed as
     `Running` is forwarded to.** The flag cannot make this one. It says a trap ran since
     the last clear; it does not say the parent was alive when it ran. A signal
     delivered after a `wait` has already reaped the parent but before the loop looks at
     the return sets the flag on a wait whose `status` is the parent's real status — the
     reviewer's case, and the measurement below catches it 27 times in 60 — and a loop
     that forwarded on the flag alone would `kill` a pid the shell has already reaped,
     which after pid reuse is a signal at an unrelated process and is the very hazard the
     surrounding text says this loop avoids. So the `kill` sits inside a
     `case " $(jobs -l) " in *" $parent_pid Running"*)` and runs nowhere else — and that
     `case` now stands *above* the `wait` rather than below it, which changes what asks
     the question and not what the question is: a recorded name the loop has not forwarded
     yet, checked against the table, on every pass including the first.

  **Why the job table and not something else.** It is the only thing in a shell that knows
  the difference, and it is immune to pid reuse by construction: bash answers `jobs` from
  its own table, and it removes a job from that table when it collects the status, so the
  table can never be describing a stranger who happens to hold the same number — which is
  exactly what `kill -0` on `parent_pid` does, and why no version of it survives in this
  loop. `$(jobs -l)` is a subshell around a builtin, like `$(kill -l …)` two paragraphs
  down, so it forks no external command and adds nothing to R7's command-word list or
  R10's grep. The three states the match distinguishes are all measured below: a live
  parent is `[1]+ <pid> Running …`, a parent bash has noticed but not yet been asked about
  is `[1]+ <pid> Exit <n>`, and a parent whose status a `wait` has already collected is
  absent from the table entirely. Only the first forwards; the other two loop round, and
  the next `wait` is what ends the run. Two mechanism details the plan needs and this spec
  measured rather than assumed: reading the table does **not** consume the saved status —
  three `wait`s after two `$(jobs -l)` reads all returned the same `7` — and the pattern
  matches on the pid-and-state pair `" <pid> Running"` rather than on the pid alone,
  because the job line also carries the command text the entry launched the parent with,
  where a bare pid could in principle appear as a substring of a path.

  **An earlier round of this spec used `kill -0 "$parent_pid"` as that discriminator, and
  it was wrong in both directions.** The claim it rested on was that an exited child stays
  visible as a zombie until `wait` reaps it, so a successful `kill -0` proved the parent
  was still there and a failing one proved this `wait` had just reaped it. Neither half
  survives contact with the thing actually doing the reaping. Bash reaps its own children
  asynchronously in its `SIGCHLD` handling and keeps the status in its job table until a
  `wait` asks for it, so the zombie is gone — and the pid with it — well before the `wait`
  that reports the status returns. The measurement below records both failures on the same
  bash 3.2. A pid whose exited background child had never been waited for answers `kill -0`
  with `ESRCH` and shows nothing at all in `ps`, not state `Z`; and in the coincidence run
  — a parent exiting by itself at the instant a signal lands — the interrupted wait
  returned `143` and `kill -0` said the pid was gone, which is precisely the reading that
  makes the old loop take `143` for a parent that in fact exited `7`. The other direction
  is the reviewer's: once bash has reaped the parent, the kernel is free to hand
  `parent_pid` to any other process on a busy same-uid host, and a `kill -0` that succeeds
  on that stranger would keep the loop spinning and could forward the recorded signal to
  it — the same pid-reuse hazard R2 closes for the parent's own reaps. So `kill -0` is
  gone from this loop, and no sentence anywhere in this spec claims it distinguishes a
  live parent from a reaped one.

  **The coincidence case is the one the flag alone does not settle, and it is what the
  table check is for.** If the parent exits in the same instant a signal lands, the `wait`
  can return the parent's real status *and* have run a trap, so
  `wait_interrupted` is set on a wait that was not really cut short. The loop does not
  forward there: the pass that could send it is the one *after* that wait, since the name
  was not yet recorded when this pass's step 2 read it, and by then the table does not say
  `Running` — the job is `Exit <n>` or gone,
  and the `case` falls through — so no `kill` is sent at a pid the shell has given back.
  It holds the forward and waits again, and what that next `wait` answers decides the
  status. On the bash this entry ships against it answers with the parent's saved status,
  because bash 3.2 keeps a terminated job's status in its job table and hands it back to
  every `wait` that asks: the measurement below ran the coincidence sixty times and the
  second wait returned the real `7` on all sixty. The `[ "$status" -ne 127 ]` guard is for
  the other answer, which a bash that discards the status after the first `wait` would
  give: `127` means "not a child of this shell", and after an interrupted wait the only
  way to reach it is that the parent was reaped during that wait. It is never a reused
  pid, because bash answers `wait` from its own job table and never from the process
  table. On that branch the entry says plainly what it lost: the parent's own status is
  unavailable, so the entry reports `128 + signal` for the first recorded signal — the
  same number the parent would have given had it died of the forwarded signal, and the
  number this requirement promises on every other signal path.
  Nothing in the loop is an external command — `wait`, `kill`, `jobs`, `[` and `kill -l`
  are bash
  builtins, `case` is a reserved word, and `$(kill -l "$entry_signal")` and
  `$(jobs -l)` are subshells around builtins rather than a
  `/bin/kill` or a `/bin/ps` — which is why the three-step rule above does not apply to
  them and why R7's
  command-word list and R10's grep are untouched by them.
  `wait_interrupted` is deliberately outside the initialise-before-arming rule, for the
  same reason `last_forwarded` is: `set -u` bites on reads, and the only read of it is
  inside the loop, after the loop's own `wait_interrupted=''` has set it. The traps write
  it from the moment they are armed, which is safe whether or not the loop has run yet.

  **Forwarding is once per new signal, and a repeat is not re-forwarded.** The
  `[ "$entry_signal" != "$last_forwarded" ]` test is what makes that true: without it every
  pass with the parent still listed as `Running` would send another `kill`, so
  a user holding `Ctrl-C` would produce a
  stream of signals at a parent that is already terminating — and with the forward moved
  above the `wait`, "every pass" is what it would mean, since the loop no longer needs an
  interruption to reach the `kill`. `last_forwarded` records the *attempt* rather than the
  send: it is assigned after the `case` whether or not the table let the `kill` through,
  and that loses nothing, because the only way the table withholds it is that the parent
  has already exited, and a parent that has exited does not come back. The guard does more than keep
  the noise down. Bash reaps the parent the instant it exits, before
  the `wait` that reports its status returns, so from that instant `parent_pid` is a number
  the kernel may give to anybody — and a `kill` the loop sends afterwards is a `kill` at
  whatever now holds it. One forward per recorded name is what bounds that, and the table
  check above is what makes the bound narrow rather than merely finite. The loop sends
  at most one signal in the whole run; it sends it on the first pass that finds a recorded
  name it has not already forwarded and the parent's job listed as `Running`, which is the
  pass after the one a signal cut short, or the very first pass when the signal was
  recorded before the loop began — and which
  in every ordinary case is while the parent is still running its termination sequence.
  Since the traps keep the *first* name (above), `entry_signal` never changes
  after it is set, so in practice the loop forwards exactly once per run — but the
  comparison is not therefore redundant, because what it suppresses is the re-forward on
  every subsequent pass, not a second name.

  **What that leaves is one send in one instant, and it is stated rather than argued
  away.** The table check moves the question from "is this pid answering" to "is this job
  still mine and running", which no pid reuse can make true of a stranger — but it is a
  check, and the `kill` is the statement after it. Between the two the parent can exit, be
  reaped, and in theory have its pid recycled, and then the one `kill` goes to whoever now
  holds the number. The measurement below shows that gap directly rather than describing
  it: in the coincidence runs there are lines where the table said `Running` and the
  `kill -0` taken immediately afterwards already said the pid was gone. The residual is
  therefore real, and it is the smallest version of itself: one `kill`, of the signal the
  caller sent, inside the window between one statement and the next, on a host that must
  recycle that exact pid in that window. What this round removes from it is the whole
  class of sends the old loop made *after* the reap was already visible: 27 of the 60
  coincidence attempts below are interrupted waits where the table said the parent was
  gone, and the loop this round writes sends nothing on any of them, where the previous
  one sent on all of them. Closing the last instant entirely needs a handle
  the shell does not have: a pidfd, or a parent that reports its own exit through something
  other than its pid, and the second is the test-only channel this spec refuses everywhere.
  It is closed properly on the parent's side, in C, where R2's block-reap-zero-restore rule
  already means no handler can name a pid the kernel has taken back.

  Nothing is removed before that loop ends, which is the
  ordering the whole requirement exists for. On a forwarded signal the parent's own status
  is the `128 + signal` its handler exits with (R2), and a parent killed rather than exiting
  gives the shell the same number for the same signal, so the entry's status is
  `128 + signal` here too — the *parent's* number, arrived at by the wait that reaped it,
  not the number some interrupted wait returned.

  **This was measured rather than argued, on the same `GNU bash, version
  3.2.57(1)-release` the other measurement in this requirement used, and it was re-run
  from scratch this round because the order of the loop's own statements is what
  changed.** A script built as the five steps above describe — three traps that are the
  two-statement bodies this requirement fixes, a child standing in for the
  parent whose own `TERM` handler takes 0.6 s to finish terminating its group before it
  exits `143`, and the loop printing one line per pass — was started in the
  background of a driving shell with `set -m`, so the entry has a process group of its
  own, and signalled at chosen moments. Each line names its pass, so the pass a forward
  went out on is read off the output rather than inferred: `interrupted=` is the flag that
  decided whether to leave the loop, `entry_signal=` is the recorded name, and
  `forwarded=` is `last_forwarded` after that pass's step 2.

  Two `TERM`s during the wait, 0.1 s apart, is the ordinary case, and it takes three
  passes:

  ```
  pass 1: wait returned 143; interrupted=[1]; entry_signal=[TERM]; forwarded=[]
  pass 2: forwarded TERM to 84789
  pass 2: wait returned 143; interrupted=[1]; entry_signal=[TERM]; forwarded=[TERM]
  parent: got TERM
  pass 3: wait returned 143; interrupted=[]; entry_signal=[TERM]; forwarded=[TERM]
  parent marker at entry exit: present
  entry status=143
  ```

  The forward goes out at the top of pass 2 rather than at the foot of pass 1, which is
  the same instant in wall-clock terms — nothing stands between them but the loop
  header — and still a whole pass ahead of the reap. The second `TERM` interrupted
  pass 2's wait exactly as predicted, `143` with the flag
  set, and the loop went round instead of exiting on it; pass 3 is
  the wait that reaped the parent, and the marker the stand-in writes as it exits was
  already on disk when the entry left, so the cleanup could not have preceded the parent.
  Nothing was forwarded twice.

  **The signal that arrives before the loop starts is the run this round exists for, and
  the same event was measured under both orders.** The stand-in sleeps and then exits `0`
  of its own accord; a `sleep 0.5` stands between `parent_pid=$!` and the loop, in place
  of the statements the real entry runs there; the driving shell sends one `TERM` 0.25 s
  in, so the trap records while that sleep is the foreground command and the loop begins
  with the name already set and the flag already `1`. With the forward at step 2:

  ```
  pass 1: forwarded TERM to 84690
  parent: got TERM
  pass 1: wait returned 143; interrupted=[]; entry_signal=[TERM]; forwarded=[TERM]
  parent marker at entry exit: present
  entry status=143
  ```

  and with that same script's forward moved back below the `wait`, which is the loop the
  round before this one specified, on the same event:

  ```
  pass 1: wait returned 0; interrupted=[]; entry_signal=[TERM]; forwarded=[]
  parent marker at entry exit: absent
  entry status=0
  ```

  That is the finding in two blocks. The old order forwards nothing, blocks for the
  parent's whole natural life, reports the parent's ordinary `0` for a run the caller sent
  a `TERM` to, and leaves the stand-in's handler never having run — no marker, and in the
  shipped arrangement no group termination either. One more thing to read off pass 1 of
  the new run, because it is the clear rather than the forward: the flag the trap set
  during the `sleep` was cleared by step 1, so the wait that reaped the parent was read as
  a reap and the `143` reported is the *parent's own* status and not an interrupted wait's
  number.

  **The gap between the clear and the `wait`, widened on purpose.** A `sleep 0.4` was
  inserted between step 2 and step 3 of the first pass and a `TERM` sent into it, with a
  stand-in that exits `9` by itself 1.2 s in. The signal is consumed by the trap, so the
  `wait` that follows is not interrupted and blocks until the parent's own exit:

  ```
  pass 1: wait returned 9; interrupted=[1]; entry_signal=[TERM]; forwarded=[]
  pass 2: not forwarding TERM; job table does not say 84771 is Running
  pass 2: wait returned 9; interrupted=[]; entry_signal=[TERM]; forwarded=[TERM]
  parent marker at entry exit: present
  entry status=9
  ```

  Both halves of the residual are in those four lines. The flag survived the wait, so
  pass 1's `9` was not read as a reap even though it was one; the table refused the
  forward on pass 2, because by then the parent had gone; and the status the caller sees
  is the parent's real `9` rather than a `143` nothing earned. In the shipped loop that
  gap is two builtins and one subshell around a builtin, not 0.4 s.

  **Two more variants and a control, all under the new order.** With the second signal
  an `INT` rather than a `TERM`, pass 2's wait returns `130` with the flag set,
  `entry_signal`
  stays `TERM`, the `INT` is not forwarded, and the entry still exits `143` — a second,
  differing signal changes neither the line nor the status, and the run contains exactly
  one forward, which is the one forward per distinct recorded name the guard promises.
  With the stand-in parent
  exiting `42` instead of `128 + 15`, the entry exits `42`, which is the assertion that
  matters most here: the status comes from the wait that reaped the parent and not from
  either of the two that a signal interrupted. (The `INT` runs need the entry in a
  process group of its own — `set -m` in the driving shell — because a shell starts an
  asynchronous child with `SIGINT` ignored when job control is off, and a signal ignored
  at entry cannot be trapped.) A run with no signal at all and a stand-in that exits `7` by
  itself is the control, and it takes one pass and sends nothing, which is what proves
  step 2 is inert until a name is recorded:
  `pass 1: wait returned 7; interrupted=[]; entry_signal=[]; forwarded=[]`, entry
  status `7`.

  **The coincidence was provoked and run sixty times, and it is what the round before
  this one's finding lives in.** The stand-in was made to exit `7` on its own at 0.30 s and
  the driving shell
  sent one `TERM` at 0.31 s, which puts the signal in and around the window between the
  parent's exit and the loop's next statement. Every attempt was classified by its first
  wait, and the two classes were both hit. These sixty were run with the forward standing
  *below* the `wait`, which is the position this round moves, and they are kept rather than
  re-run because what they measure is the table gate's verdict on those events and the move
  does not change it: the same read of the same table, taken one statement earlier on the
  following pass, and a job the table did not call `Running` on one pass cannot be
  `Running` on the next. So read the output for the classification each line carries, not
  for where the forward line sits in it:

  ```
  delay=0.31 attempts=60
    A interrupted+table-Running (forward sent)      = 33
    B interrupted+table-not-Running (forward held)  = 27
    C not interrupted (plain reap)                  = 0
    127-after-interrupt = 0   final status 7 = 60   final status 143 = 0
  --- representative B run (the reviewer's case) ---
  wait 1 returned 7; interrupted=[1]; running=[no]; kill -0=no; entry_signal=[TERM]
  not forwarding: job table does not say 64481 is Running
  wait 2 returned 7; interrupted=[]; running=[no]; kill -0=no; entry_signal=[TERM]
  parent marker at entry exit: present
  entry status=7
  --- representative A run ---
  wait 1 returned 143; interrupted=[1]; running=[yes]; kill -0=no; entry_signal=[TERM]
  forwarded TERM to 64517
  wait 2 returned 7; interrupted=[]; running=[no]; kill -0=no; entry_signal=[TERM]
  parent marker at entry exit: present
  entry status=7
  ```

  Read the B run first, because it is the finding exactly as the reviewer stated it: the
  wait returned `7` — the parent's *real* status — and the flag was set anyway, because
  the `TERM` landed after that wait had reaped the parent and before the loop had looked
  at what it returned. A loop that forwarded on the flag alone sends a `kill` there, at a
  pid the shell has
  already given back. The table check holds it, the loop goes round, the second wait hands
  back the same `7`, and the entry exits `7`. Twenty-seven of the sixty attempts were that
  case; all sixty finished with the parent's own status.

  Then read the A run, because it is the residual in one line: the table said `Running`,
  the `kill -0` taken in the very next breath already said `no`. The parent exited between
  the two reads. That is the window no shell can close, and it is why the paragraph above
  states one send in one instant rather than none. What it is not is the old behaviour: the
  forward is one, it goes out while the table still said the job was the entry's own and
  running, and the twenty-seven B attempts produced no send at all.

  No attempt produced a `127`, which is the other
  half of the measurement: bash 3.2 keeps a terminated job's status and returns it to every
  `wait` that asks — a separate three-`wait` check on one reaped child returned `7` three
  times, and returned it after two `$(jobs -l)` reads of the same job, so consulting the
  table does not consume the status the next `wait` needs — so the `127` guard is dead code
  on this bash and
  is kept only for a bash that discards the status, where it is the difference between a
  correct `128 + signal` and a spin.

  **The job table's three states were measured directly, on the same bash.** A background
  child that exits `7` and has not been waited for is
  `[1]+ 59741 Exit 7   ( sleep 1; exit 7 )` in `jobs -l`, is absent from `jobs -lr`, and is
  gone from `jobs -l` entirely once a `wait` has collected it; while it runs it is
  `[1]+ 59741 Running`. So the `" $parent_pid Running"` match is true of exactly the state
  the forward is for. One state deserves naming because a reader will ask about it: a child
  a `SIGSTOP` has stopped is *still* reported `Running` by a script's `jobs -l` — measured,
  because a shell with job control off does not `waitpid` with `WUNTRACED` and so never
  learns about the stop — and the entry never turns job control on, so a stopped-but-alive
  parent is forwarded to rather than skipped, which is the answer this loop wants anyway.

  **The zombie claim the old loop rested on was checked on the same machine and is false
  for a bash-managed child.** A background child was allowed to exit and was never waited
  for; 0.3 s later, `kill -0 on un-waited, exited child: no (ESRCH)`,
  `ps says: no such process (no zombie)`, and `wait still returns 7`. Bash's own `SIGCHLD`
  handling had already reaped it, so there is no zombie for `kill -0` to see and the pid is
  free for the kernel to hand to somebody else from that moment — before the `wait` that
  reports the status has returned. That is the reviewer's pid-reuse hazard, measured rather
  than reasoned about, and it is why no version of `kill -0` on `parent_pid` is kept here.

  **The round before this one measured the job table beside the flag and then rejected it,
  and that judgement is withdrawn here rather than quietly dropped.** It was rejected on
  cost, and on one open question: a `$(jobs …)` is a subshell, and whether bash 3.2 keeps
  the parent's job table visible inside that subshell was called a question this spec would
  have to answer, with a file redirect as the alternative and a write on a signal path as
  the reason not to. Both halves are settled now. The question has an answer and it was
  measured: `$(jobs -l)` inside the entry's own shell lists the parent's job exactly as a
  bare `jobs -l` does, in every state, so no file and no write are needed and the
  disk stays out of it. And the cost was the wrong thing to weigh, because the two are not
  alternatives: the flag answers "was this wait cut short", which is the question the
  `break` needs, and the table answers "is the parent still mine and running", which is the
  question the `kill` needs. This round buys the second answer for one `case` and one
  command substitution, and keeps the first.
  The same script, with all three columns, is re-run
  against the Linux CI image's `/bin/bash` while the plan is written, for the same reason
  the other measurement is: bash 5 is not on the machine this was measured on. Two lines
  could differ there and the plan records which way each went — the `127` guard, and the
  rendering of `jobs -l`, whose `Running` word and pid column the `case` pattern depends on.

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
  yet created its sandbox. So the `EXIT` trap writes exactly one line, and only when two
  things are both true: `entry_signal` is set, so an exit with no signal behind it writes
  nothing, and the entry's stderr is a kind of object a write to it cannot block on, which
  the block after this one states, measures and justifies:

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
  alive and the run directory still on disk. Written last, it cannot delay the cleanup or
  the forward.

  **Last position is necessary and it is not sufficient, and the sentence that said it was
  is withdrawn here.** An earlier round of this spec finished the argument above with "a
  hung write can only delay the exit status", and that is too kind to it by one word. A
  `printf` into a pipe that is full and that nobody is draining does not return at all.
  The entry therefore never reaches its own `exit`, so the `128 + signal` this requirement
  promises is never produced, and the caller's `wait` on the entry never returns either:
  the run directory is gone, the resolver is dead, everything this path exists to
  guarantee has already happened, and the caller is hung on a courtesy. Position fixes the
  ordering. It does nothing about the block. So the line is conditional as well as last.

  **The entry writes the line only where a write cannot block, and omits it everywhere
  else.** The parent has a clean answer to this and the entry cannot use it: the parent
  sets `O_NONBLOCK` for one `write(2)` and accepts a short write (R2), and bash 3.2 has no
  way to set a file status flag on a descriptor at all — no `fcntl` builtin, no flag on
  `printf`, and no redirection form that reopens an inherited descriptor non-blocking. So
  the entry cannot make the write safe and must instead decline to make it when it is not.
  It asks what stderr is:

  ```
  if [ -f /dev/fd/2 ]; then
      printf 'entry-signal: %s no-parent\n' "$entry_signal" >&2   # or the forwarded form
  fi
  ```

  **A regular file is the only kind of stderr this entry writes to, and it is one test, not
  three.** An earlier round of this spec admitted a terminal and a character device beside
  it — `[ -t 2 ] || [ -f /dev/fd/2 ] || [ -c /dev/fd/2 ]` — on the reasoning that a tty
  consumes what is sent to it and `/dev/null` discards. The `/dev/null` half is true and
  the tty half is not. A terminal write is flow-controlled: a tty's output queue is
  finite, `IXON` flow control or a `Ctrl-S` at the keyboard stops it draining, and a pty
  whose master nobody is reading fills exactly the way a pipe does — the master side of a
  pty *is* a buffer with a reader that may not be there. So `printf` to a terminal can sit
  in its write as long as a `printf` to a full pipe can, and the `128 + signal` exit and
  the caller's `wait` are behind it in both cases. That is the whole of the guarantee this
  requirement exists for, and it is not worth a courtesy line.

  So terminals and character devices come out of the safe set, and the condition is the
  single test `[ -f /dev/fd/2 ]`. A regular file is safe for a reason that has no reader in
  it at all: the kernel writes the bytes into the file, there is no queue to fill and
  nobody on the other end whose absence could matter. `/dev/null` is harmless too and
  loses the line anyway, because the rule stays simple: one test with one reason behind it
  beats two more tests whose reasons have to be re-argued every time somebody reads them,
  and nothing is lost by omitting a line that was going to be discarded. A pipe, a FIFO, a
  socket, a terminal, `/dev/null` and anything else all fall to the `else`. Nothing else
  changes — the branch is still decided, the status is still `128 + signal`, the chmod and
  the removal still ran before this point.

  **The `/dev/fd/2` test had to be measured rather than assumed, because the question is
  whether it sees the underlying object or the `/dev/fd` entry itself.** The table below
  is the measurement the round that wrote the three-test condition made, and it is kept
  as it stands rather than trimmed to the one column the rule now reads: it is what the
  new rule is drawn *from*. Measured,
  bash 3.2.57 on `arm64-apple-darwin` (`Darwin 27.0.0`), one probe run per kind of stderr:

  ```
  stderr is         [ -t 2 ]  -f /dev/fd/2  -c /dev/fd/2  -p /dev/fd/2  -S /dev/fd/2
  regular file         no         yes            no            no            no
  /dev/null            no         no             yes           no            no
  tty (pty)            yes        no             yes           no            no
  pipe                 no         no             no            yes           no
  FIFO                 no         no             no            yes           no
  unix socket          no         no             no            no            yes
  closed (2>&-)        no         no             no            no            no
  ```

  Every row resolves to the underlying object, which is what the rule needs. Read the
  `-f /dev/fd/2` column on its own and it says exactly what the condition now says: yes on
  the regular file, no on every other row, including the tty — a terminal is a character
  device and was never a regular file, so dropping the `-t 2` and `-c` tests takes the tty
  and `/dev/null` rows out of the writing set and moves no other row. On Linux
  `/dev/fd` is a symlink to `/proc/self/fd` and the test follows it to the same objects;
  the plan re-measures there rather than inheriting this table, and R10's suite runs on
  both platforms, so both are exercised.

  **The condition is one safe answer and not a list of unsafe ones, and that
  is the whole of its safety argument.** Anything the test does not recognise —
  the tty row, the socket row, a closed descriptor, a platform whose `/dev/fd` is absent
  or answers
  something nobody predicted — falls to the `else` and omits. So the worst outcome of a
  wrong guess about an object this spec did not enumerate is a missing courtesy line, and
  never a hung entry. Getting that the other way round, with a blacklist of pipes and
  sockets, would make every unanticipated object a write — and the tty row is the proof
  that the blacklist would have been wrong, because a terminal is precisely the object
  everyone's intuition puts on the safe side.

  **Measured, so the rule is not an argument about what ought to happen.** On the same
  bash: with the entry's stderr on a real `pipe(2)` filled to capacity (65536 bytes on
  `Darwin 27.0.0`) by a **blocking** writer that is still sitting in its own `write`, with
  the read end open and never read, the unconditional `printf` never returns — a `perl`
  `alarm 3` had to kill it, exit `142`, with the write still outstanding — while the same
  body under the condition above exits `143` at once, having written nothing. That is the
  failure and the fix, one command apart. The filler has to be the blocking kind and this
  round says so here as well as in R10: a filler that reaches for `O_NONBLOCK` sets that
  flag on the open file description the entry is about to be handed, and the unconditional
  `printf` then fails fast with `EAGAIN` instead of hanging, which measures nothing about
  this rule at all.

  **What is given up is named, and this round it is more than it was.** A caller who pipes
  the entry's stderr to a reader gets no
  `entry-signal:` line, even when the reader is draining it and the write would have gone
  straight through. No test can separate those two cases without performing the write that
  is the hazard, so the conservative half is taken. **And now a caller at a terminal gets
  no line either, nor does one who sends stderr to `/dev/null`** — the interactive case is
  the one a reader will miss most, because it is where a person watching a `Ctrl-C` would
  like to be told which branch ran, and it is given up anyway for the reason above: a
  terminal's write can wait, and no test can tell a draining tty from a stopped one
  without performing the write. `/dev/null` loses the line for no reason of its own, only
  to keep the rule one test wide. It is the same trade the parent's line
  already makes and is accepted for the same reason: the exit status and the cleanup are
  what this requirement guarantees, and the line is a courtesy that says which branch
  produced them (R9). The branch stays observable exactly where a caller who wants it
  should put stderr — a regular file, which is what R10 does in every case that asserts
  the line, and what the documentation tells a caller to do (R9). The exit status and, on
  the forwarded branch, the parent's own `parent-signal:` line remain the record
  everywhere else; nothing that anything depends on is behind this condition.

  **The two halves of this component differ in exactly this one rule, and it is worth
  saying so rather than leaving a reader to wonder why the parent has no such condition.**
  The parent writes `runtime-pgid:` and `parent-signal:` from C, where `O_NONBLOCK` plus a
  single `write(2)` makes the write itself incapable of waiting, so it writes on every kind
  of stderr and accepts a truncated line or no line on a full pipe (R2). The entry writes
  from bash, which cannot set the flag, so it decides by the kind of object and writes
  nothing where the parent would have written best-effort. The guarantee is identical on
  both sides — no diagnostic ever delays or prevents the termination — and only the means
  differ, because the two languages have different tools for the same problem. One visible
  consequence is worth stating so nobody reads it as a bug: on an interrupted launch at a
  terminal the caller sees the parent's `parent-signal:` line and no `entry-signal:` line
  beside it, because the parent's write cannot wait and the entry's could.

  One reading note, so the condition does not have to be repeated at every mention.
  Everywhere else in this spec — the checkpoints above, the three-step command rule, R2's
  summary of the forwarded branch, R10's assertions — the shorthand "`128 + signal` and
  the one `entry-signal:` line" appears. Read it with this condition attached: one line
  when stderr is a regular file, and none on any other kind of stderr. The status half of that
  shorthand is unconditional and is the half anything ever depends on. One mention does
  **not** take the shorthand, deliberately: R9's documentation requirement writes the
  condition out in full, because that line is a promise to a caller reading the entry's
  documentation rather than a cross-reference between two requirements, and a caller who
  pipes stderr, or watches at a terminal, and then goes looking for a line the docs
  promised has been told something
  untrue. A reading note settles it inside the spec; it settles nothing for a reader of the
  shipped documentation.

  Nothing is lost for the tests
  that assert the line, and this is now load-bearing rather than incidental: R10 reads it
  from a plain file in the test's own scratch in every case that asserts it, and a regular
  file is the only kind that writes, so every one of those assertions stands
  exactly as written. That was true when the condition admitted three kinds and it is
  true of the one, which is why narrowing the rule this round moves no assertion in the
  suite: the cases were already reading the only kind that survives. R10 also adds the case that proves the omission rule keeps the exit
  promise — the entry signalled with its stderr on a full, undrained pipe, required to exit
  `143` with `.run` gone. It does not conflict with this requirement's claim that the entry passes the
  child's stdout and stderr through unchanged: this is the entry's own line on the entry's
  own stderr, not a byte added to or removed from anything a child wrote — exactly the
  distinction the parent's line already relies on. R10's command-word allowlist is
  unaffected, because `printf` is a bash builtin and pass 2 of that grep drops the builtins
  by name from `compgen -b`. R10's pre-parent case asserts this line, and that assertion is
  the case.

  **The entry's own first statements come before the copied ones, and no external command
  runs before any of them.** The order is fixed, and each position below says why it is
  where it is: the privileged-mode refusal, then `umask 077`, then the descriptor-headroom
  precondition, then the close of every inherited descriptor above 2, then the
  builtins-only scrub copied from the materializer, then the empty-environment re-exec,
  then the marker branch — and only after all seven the platform case, the output-root
  validation, the pin checks, the compiles and the launch. (That list read six and omitted
  the precondition until this round: a round-35 ripple recorded as done and not done. The
  statement itself has stood in that position since round 35 — only the list was wrong.)
  An earlier round of this spec put `/usr/bin/env -i` in front of the pin checks, both
  compiles and the parent launch and stopped there, which is not early enough for a reason
  worth stating plainly: `/usr/bin/env` is itself an external process, so the loader
  honours the caller's `LD_PRELOAD` and `LD_LIBRARY_PATH` on the way to running `env` —
  the very command that was supposed to remove them. Nor is `env` the first external
  command in that order. `/usr/bin/uname` runs for the platform case, `/usr/bin/stat` for
  the output root's owner and mode, and in the order an earlier round used `/usr/bin/git`
  and `/usr/bin/cc` ran too, every one of them an absolute path executed while the caller's
  loader variables were still in the entry's own environment and therefore inherited. That
  is why the scrub sits ahead of every external command. Why four statements of the
  entry's own sit ahead of the *scrub* is a later correction, and the next three blocks
  are its reasons — the last of them covering two statements, because the headroom
  precondition and the close loop it guards make no sense apart.

  **First statement in the file: the entry refuses any arrival that is not in privileged
  mode.** Nothing stops a caller from invoking the entry as `/bin/bash <entry>
  __resolve_profile_clean <jq> <output> <request> <map>` — five arguments whose first is
  the marker word — and landing on the clean path directly. The marker word is a literal in
  a committed file, not a secret. What such a caller reaches is the clean path running in a
  process whose loader consumed *their* environment, because the re-exec below, the only
  step that produces an environment built from nothing, is precisely the step a marker
  arrival skips: it is the branch the re-exec lands on. The same caller can also come in
  the plain four-argument way, `/bin/bash <entry> <jq> <output> <request> <map>`, with
  `BASH_ENV` read and exported functions imported before the entry's first line is parsed.
  So the entry does not assume it was started in a shape it can defend — it checks, and
  the check is the first statement in the file, ahead of everything else:

  ```
  case $- in *p*) ;; *) exit 78 ;; esac
  ```

  Both supported invocations set that flag. Executing the file starts bash from the
  `#!/bin/bash -p` shebang; the documented direct form passes `-p` on the command line; and
  the re-exec below passes it too, which is the third deviation from the copied lines and
  the reason it exists. So the entry's own arrival condition — privileged mode — is true on
  every path this spec supports and false on the one it does not. An earlier round of this
  spec put this same statement on the marker branch alone, which answered the forged-marker
  arrival and left the plain four-argument one to the scrub; it is at the top now because
  the two statements below it depend on it, and one line covers both arrivals where two
  would otherwise be needed. Measured, bash 3.2 on
  `arm64-apple-darwin`: with a `#!/bin/bash -p` shebang `$-` is `hpB`; with
  `env -i … /bin/bash -p <script>` it is `hpB`; with a plain `#!/bin/bash` shebang or a
  plain `/bin/bash <script>` it is `hB`. And privileged mode is worth having for itself,
  not only as a marker: in the same measurement, a `BASH_ENV` pointing at a file that
  echoes a line and defines an alias is executed under the plain forms and **not** read at
  all under either `-p` form, and an exported function (`BASH_FUNC_evilfunc%%` in the
  environment) is imported under the plain forms and **not** imported under either `-p`
  form. That is the whole shape of the pollution the scrub below was written against — and
  because this line turns those arrivals away, every statement after it runs in a shell
  that imported no function and read no `BASH_ENV`. That is what lets the next three
  statements run ahead of the scrub instead of behind it: there is nothing there to shadow
  `umask`, `ulimit`, `printf`, `eval`, `exec`, or either `case`.

  The statement is written the way it is because of what has run before it, which is
  nothing: `case`, `in` and `esac` are reserved words, and `$-` is a special parameter the
  shell maintains itself, so the test itself runs no command and reads no variable the
  entry has not been able to set. The one word in it that is neither is `exit`, a builtin
  and therefore shadowable by a function of that name — which is not patched over here,
  it is the subject of the scrub paragraph below, and the answer to it is that the only
  arrival that can install such a function is the one this line turns away. `78` is a bare
  literal for the same
  no-state reason — no name has been assigned at that point, and under `set -u` a symbolic
  `E_*` would be an unbound variable — and the number is chosen to be distinct from the
  entry's
  `E_USAGE` and `E_RUNTIME` status and from anything `128 + signal` can produce, so a test
  asserting it cannot be satisfied by an ordinary refusal.

  **Then `umask 077`, before anything at all is created and before anything at all is
  forked.** The scrub below resets variables, functions and aliases; it does not reset
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
  materializer's clean branch sets the same umask immediately after its own scrub and
  before its first creation (`adapters/local-git-materializer/v1/materialize.sh:31`) — and
  the only deviation is where it stands: the entry sets it above the copied scrub rather
  than below it, so that it is set in the first process as well as the second, and so that
  the four statements the entry adds of its own stand together at the top where a reader
  can check the order in one glance. `umask` is a bash builtin, so it forks nothing and
  keeps its place among the statements that run before the first fork of any kind. R10
  asserts the result rather than the line: the mode assertions on the run tree already
  check for 0700, and one case runs the entry with the caller's umask set to `000` and then
  to `777` and requires 0700 both times.

  **Then, before the copied scrub and before the re-exec, the entry closes every descriptor
  above 2 that it inherited.** A caller hands the entry three descriptors it is meant to
  have — stdin, stdout and stderr — and may hand it any number of others, because an open
  descriptor is inherited across `fork` and across `exec` unless it is marked
  close-on-exec, and nothing obliges a caller to mark anything. Those others are the
  caller's, not the entry's: an open credential file, a socket to something the entry has
  no business talking to, a write handle on a file outside the output root this
  requirement spends pages validating. Every one of them is inherited by every child the
  entry forks, and the entry forks a great many before the parent exists — the SHA-1 and
  SHA-256 pins over ten files, two compiler invocations, the `cp` copies, the `jq
  --version` probe, `/usr/bin/stat`, `/usr/bin/uname`, `/bin/mkdir`. A write handle
  outside the output root, held open across the compiler, is a second write root that R7's
  claim does not know about, and it is one nobody in this chain put there. So the entry
  shuts them, and shuts them at the top rather than at the bottom:

  ```
  ulimit -S -n 1024 2>/dev/null || ulimit -S -n 256 2>/dev/null || ulimit -S -n 64 2>/dev/null || { printf 'E_RUNTIME\n' >&2; exit 1; }
  for fd in /dev/fd/*; do
    case $fd in '/dev/fd/*') printf 'E_RUNTIME\n' >&2; exit 1 ;; esac
    fd=${fd##*/}
    case $fd in ''|*[!0-9]*|0|1|2) continue ;; esac
    eval "exec ${fd}>&-" 2>/dev/null
  done
  ```

  **The glob can fail to match, and this round the loop's first action is to refuse when it
  has.** `/dev/fd/*` is a glob, and with `nullglob` off — which it is, nothing in the entry
  sets it, and setting it would be a shell option the scrub below does not reset — an
  expansion that matches nothing leaves the word alone: the `for` list becomes the single
  literal string `/dev/fd/*`. There is one reason that happens here, and it is not a missing
  directory — `/dev/fd` is present on both supported platforms and its absence would be a
  broken system rather than a caller — it is that reading a directory takes a descriptor
  too, so with no free number below the soft limit the `opendir` fails and bash reports no
  match. (A refusal covers the broken-system case as well, which costs nothing and is the
  right answer there too: the loop cannot do its job either way.) That is a caller the entry
  can be handed. It is the caller who has already filled the numbers the entry would have
  used — 3 through 255 open, say, before the soft limit is normalised down to 256 — and it
  is the worst caller to be quiet about, because the loop then visits exactly one word, the
  literal, whose `${fd##*/}` is `*`, which the all-digits arm throws away. Nothing is
  closed. Every credential, socket and write handle this requirement exists to remove
  survives into the scrub's process substitutions, the re-exec, the compiles and the `cp`s,
  and the run reports success. So the loop tests for it, on the word and before anything
  else in the body: `case $fd in '/dev/fd/*') printf 'E_RUNTIME\n' >&2; exit 1 ;; esac`.
  **The literal test is the exact one and the `[ -e "$fd" ]` alternative is refused.** The
  pattern is the failed expansion itself, spelled out with the `*` quoted so it is a literal
  and not a wildcard, so it is true in exactly the case that produced it and false for every
  real descriptor path — measured on this bash: the word `/dev/fd/*` matches, and
  `/dev/fd/7`, `/dev/fd/255`, `/dev/fd/` and a bare `*` do not. The only way a *matching*
  file could produce that word is a file literally named `*` inside `/dev/fd`, which neither
  platform's descriptor filesystem can hold — measured: `: > /dev/fd/x` on Darwin answers
  `/dev/fd/x: No such file or directory`, the directory admitting numbers and nothing else.
  An `[ -e "$fd" ]` test would be a proxy for that fact rather than the fact, it would pay a
  `stat` on every descriptor in the ordinary case to catch a condition that has one word,
  and it answers the wrong question — a valid descriptor whose `stat` fails would refuse a
  run that should continue. The refusal is one `E_RUNTIME` line and a non-zero exit, and
  because the loop stands above the scrub, the re-exec and every external command, it
  happens before the run directory exists and before anything at all has been created: a
  caller who has filled the table gets a refusal, never a silent pass.

  **Measured, bash 3.2.57 on `arm64-apple-darwin` (`Darwin 27.0.0`), with the caller's
  descriptors opened in the shell that `exec`s the entry.** The fixture is the finding's
  own: 253 descriptors open on 3 through 255, hard and soft limit 1024, the loop run once
  without this round's refusal and once with it on the same script, each reporting which
  numbers above 2 it still holds after the loop:

  ```
  fixture                       without the refusal    with the refusal
  caller 3..255                 continue, exit 0       E_RUNTIME, exit 1
    glob words seen by loop     1 (the literal)        1 (the literal)
    descriptors closed          0                      0
    still open above 2          253 (3 … 255)          253 (3 … 255), untouched
    output root afterwards      empty                  empty, nothing created
  caller 3..200                 continue, exit 0       continue, exit 0
    glob words seen by loop     203                    203
    still open above 2          1 (the relocated 12)   1 (the relocated 12)
  ```

  **Both columns hold the soft-limit cap at 256**, which is the round-41 statement, so that
  what the two columns differ by is the refusal and nothing else. The cap itself is this
  round's other change and the block further down measures the same first fixture again
  under it: with the limit ladder in place that caller is *served* rather than refused, and
  the refusal is left holding the narrower set of callers the ladder cannot help. The second
  fixture is the ordinary case and is there to show the refusal is narrow even at the fixed
  cap: with
  198 caller descriptors and a free number left under the cap the glob expands normally, the
  loop shuts all 198 and bash's own script descriptor, and what remains above 2 is the
  relocated script input alone — `/dev/fd/12`, the same relocation the block below measures.
  The first fixture is the finding: one word, nothing closed, and the difference between the
  two columns is the whole of this round's change to the loop. One thing the first fixture
  shows that is worth stating rather than leaving for a reader to hit: on a table that full
  bash cannot save a descriptor to perform `>&2`, so it writes one
  `redirection error: cannot duplicate fd: Too many open files` line of its own before the
  refusal's line — the `E_RUNTIME` still arrives and the exit is still 1, but stderr carries
  two lines rather than one, and R10's assertion is written for that.

  **Why the limit step stands above the loop and not below it, with both orders needing the
  refusal.** Running the loop first and normalising afterwards looks like it would dodge the
  whole problem, since the glob would then run at the caller's own soft limit, which is
  higher in the case the finding names. It trades this round's failure for the round-35 one
  and that is a worse trade, because the round-35 failure is the silent one. Measured, on a
  118,131-byte script whose first statement is the close loop with no precondition above it
  and whose last line prints a marker, started with the caller holding 3 through 9:

  ```
  soft 11 -> CLOSE-LOOP-DONE, MARKER-END, exit 0
  soft 12 -> one 'redirection error: cannot duplicate fd' line, no CLOSE-LOOP-DONE,
             no MARKER-END, exit 0
  soft 13 -> CLOSE-LOOP-DONE, no MARKER-END, exit 0
  soft 14 -> CLOSE-LOOP-DONE, MARKER-END, exit 0
  ```

  The 13 row is the round-35 hazard exactly: the loop shut bash's script descriptor, bash
  had no free number at or above 10 to relocate onto, the script stopped at the end of what
  it had already buffered, and the status was `0` — an entry that skipped the scrub, the
  re-exec, every check and the whole resolution and reported success. The 12 row is worse
  again: nothing ran at all and the status was still `0`. The same script with the
  precondition back above the loop reaches its marker on every one of those fixtures —
  measured at soft 12, 13, 14 and 64, all four printing `CLOSE-LOOP-DONE` and `MARKER-END`.
  So the limit step goes first because it is what makes the close itself safe, and the
  refusal above is what covers the one case the limit step cannot buy its way out of.
  Neither order is safe without the refusal: a loop that ran before the limit step would
  meet the same unmatched glob whenever the caller's own soft limit left no free number, and
  would close nothing just as quietly.

  **Nothing above 2 is skipped, and the exception the round before this one added is
  withdrawn.** That round had the entry open its own script on descriptor 3 and skip any
  descriptor `-ef` it, so the loop could not shut the descriptor bash reads the script
  from. The test is an identity test on the open file and it does exactly what it says,
  which is the whole problem: `-ef` compares device and inode, and it cannot see how a
  descriptor was opened. A caller holding `resolve-profile.sh` open **for writing** on
  some other number is the same file by that test, so the skip preserved that descriptor
  — and preserved it across the re-exec and into every child below. That is a write
  handle on a path outside the output root, inherited by the compiler, which is one of
  the exact three things the paragraph above says the loop exists to stop. The round-34
  sentence calling the survivor "a read-only handle on a file every child below could
  open by name in any case" is **withdrawn**. It was true of the case that round
  measured and false in general, and a classification that is only sometimes right is
  worse than none, because it tells the next reader the descriptor has been thought
  about.

  **The skip cannot be repaired, only removed, and the reason is the same platform split
  that shaped it.** The obvious patch is to keep the identity test and add an access-mode
  test, skipping only a same-file descriptor that is read-only. On Darwin that works and
  it is measured: with `7>>` and `8<` on one 0644 file, `/bin/ls -l` reports `--w-------`
  for `/dev/fd/7` and `-r--r--r--` for `/dev/fd/8`, and the builtins agree — `[ -w
  /dev/fd/7 ]` is true and `[ -r /dev/fd/7 ]` false, `[ -w /dev/fd/8 ]` false and
  `[ -r /dev/fd/8 ]` true. `fdesc` is reporting the descriptor's own open mode. On Linux
  `/dev/fd/N` is a symlink into `/proc/self/fd` and `[ -w ]` follows it to the file, so
  the answer is the file's permission bits and a read-only descriptor on a writable file
  answers *yes* — the mirror image of the `-ef` split one paragraph up, and this time the
  platform it is wrong on is the one CI runs. This spec has already written one rule that
  behaved differently on its two platforms and had to take it back a round later; it is
  not writing a second. There is no mode test in bash 3.2 that is right on both, and the
  loop does not need one, because — as the rest of this block measures — closing bash's
  own script descriptor is safe by bash's design.

  **Where the descriptor is.** Under both supported invocations — the `#!/bin/bash -p`
  shebang and `/bin/bash -p <entry>` — bash puts the script on `255`, and `$0` and
  `${BASH_SOURCE[0]}` are the path the caller wrote either way. `255` is not a constant: it
  is the top of the descriptor table, and with `RLIMIT_NOFILE` lowered the number follows
  it down — 63 at `ulimit -n 64`, 15 at 16, 11 at 12, 9 at 10. It is also close-on-exec,
  which this round measured twice rather than once, because the answer is what the second
  bash depends on: a `/bin/ls /dev/fd` from inside the script lists the listing's own
  descriptors and nothing else, and a small C helper run as a child, asking
  `fcntl(fd, F_GETFD)` for each number, reports `EBADF` for `11`, `12`, `13` and `255`
  and finds exactly `0`, `1` and `2` open. So bash's script descriptor never reaches
  anything the entry `exec`s and is not itself one of the descriptors this loop exists to
  shut.

  **So the loop closes it, and bash moves its own input out of the way first.** This is
  the design, not a happy accident. When a redirection or a close targets the descriptor
  bash is reading the script from, bash notices before performing it and relocates the
  buffered input: `check_bash_input` in `input.c` calls `save_bash_input`, which
  duplicates the stream with `fcntl(fd, F_DUPFD, 10)` — the lowest free number at or
  above 10 — and reads on from there. That is the 255 → 12 → 13 relocation the round
  before this one measured while arguing *against* relying on it. Measured again this
  round, on a 70 KiB script (72,677 bytes) with the loop as its fourth statement and a
  marker on its last line, started with the caller holding descriptors 4, 5, 7, 10 and
  11 — and with 7 opened `>>` on the running script itself, so the write-mode same-file
  case the finding describes is the one under test:

  ```
  fds before: /dev/fd/0 /dev/fd/1 /dev/fd/10 /dev/fd/11 /dev/fd/2 /dev/fd/255 \
              /dev/fd/3 /dev/fd/4 /dev/fd/5 /dev/fd/7
  visiting 10 … 11 … 255 … 3 … 4 … 5 … 7
  fds after:  /dev/fd/0 /dev/fd/1 /dev/fd/12 /dev/fd/2 /dev/fd/3
  child /dev/fd via ls: 0 1 2 3 4
  MARKER-END reached
  exit status: 0
  script file unchanged (72677 bytes)
  ```

  Every caller descriptor gone, the script read to its last line, the same-file write
  handle shut with the rest, and the file itself byte-for-byte what it was — `/dev/fd/12`
  is bash's relocated input and `/dev/fd/3` is the listing's own, which is why the
  `after` line has five entries and the entry's children see three.

  **Why the relocation target can never be a number the loop goes on to close, whatever
  order it runs in.** The `for` list is expanded once, before the first pass of the body,
  so the loop works from a snapshot of the descriptors that were open at that instant. A
  relocation target is by definition a number that was *free* at the moment bash asked
  for it. A free number is either one that was never in the snapshot — in which case the
  loop never names it — or one that was in the snapshot and has already been closed by
  the loop, which is the only thing that could have freed it; and the loop visits each
  number once and never goes back. Either way the relocated descriptor is out of reach.
  The iteration order is worth spelling out even though the argument does not rest on it,
  because a reader will want to check it against the listings above: `/dev/fd/*` is a
  glob, so the numbers arrive in **lexicographic** order, not numeric — `10`, `11`, …,
  `19`, `2`, `20`, …, `25`, `255`, `26`, …, `3`, `4`. `255` therefore lands in the middle,
  after `25` and before `26` and `3`, which is exactly where the trace above shows it.
  Measured against the worst arrangement of it: with the caller holding 10 through 25 so
  that sixteen numbers at the relocation base are closed before `255` is reached, the
  script relocated to `12` — already visited, six numbers earlier — and ran to its last
  line.

  **The target is at or above 10 but not reliably 10, and the reason matters for the
  precondition.** Measured: a bare `exec 255>&-` relocates to `11`, the same close
  wrapped as `eval 'exec 255>&-' 2>/dev/null` relocates to `12`, and a second pass over
  the loop moves it to `13`. The statement performing the close is holding one or two
  saved descriptors in that range at the moment it runs — `10` is visibly taken inside
  `eval … 2>/dev/null`, which is bash saving the stderr it is about to redirect, at the
  same `F_DUPFD` base of 10. So bash does not need one free number at or above 10, it
  needs two or three, and a fix that budgeted for exactly one would be tuned to a bash
  version rather than to a rule.

  **With no headroom the relocation fails, and the failure is silent or worse.** This is
  the hazard the round before this one found, re-measured here against the same 70 KiB
  script with the precondition removed: at `ulimit -n 14` and above the marker printed;
  at 13 and at 12 the script stopped at the end of what bash had already buffered, the
  marker never printed, and the exit status was **`0`**; at 11 bash died of **`SIGSEGV`**
  and the status was `139`. The middle of those is the one no refusal in this spec covers
  — an entry that skips the scrub, the re-exec, every check below and the whole
  resolution, and reports success. The crash is ugly but at least it is loud. Neither is
  hypothetical from the entry's point of view: `RLIMIT_NOFILE` is inherited like every
  other process attribute, and this requirement's whole premise is that nothing obliges a
  caller to leave one alone.

  **So the entry sets the headroom it needs rather than reading it, and it refuses only
  when it cannot have it.** That is this round's change, and it is one line of builtins in
  place of two lines of arithmetic (`type -t ulimit` and `type -t printf` both answer
  `builtin`). What lets the one line do both jobs is a rule about the limit itself: an
  unprivileged process may set its *soft* limit to anything up to its hard limit. So
  `ulimit -S -n 256` succeeds whenever the hard limit is at least 256,
  `ulimit -S -n 64` succeeds whenever it is at least 64, and the two fail together only
  when the hard limit is below 64 — which is the one environment the round-35 precondition
  refused, refused here for the same reason, with the same single `E_RUNTIME` line and the
  same non-zero exit. The check and the fix are the same statement, and on every arrival
  that gets past it the soft limit is one of the ladder's own constants — 1024, 256 or 64,
  the first rung the hard limit allows, counting the third rung the block below adds above
  these two — so the headroom the loop below needs has
  stopped being a fact about the caller.

  **The `2>/dev/null` on each attempt is there for a reason and is not the trap the block
  below describes.** A `ulimit` that cannot do what it was asked writes a diagnostic of
  bash's own — measured: `ulimit: open files: cannot modify limit: Invalid argument`, with
  a return of 1 — and the first attempt is *expected* to fail whenever the hard limit sits
  between 64 and 255. A caller who gets past the precondition must not be handed a bash
  diagnostic about an attempt that was allowed to fail, and a caller who does not get past
  it must be handed exactly one line, `E_RUNTIME`, and no other. So both attempts are
  silenced and the refusal writes the only line. This is not the hazard the `eval`'s own
  `2>/dev/null` carries two blocks below: that one is dangerous because an `exec` with no
  command redirects *the shell*, permanently, and `ulimit` is not `exec` — a redirection on
  an ordinary builtin lasts for that builtin, which the measurements below confirm by
  writing to stderr afterwards and seeing it arrive.

  **The floor is still 64 and the argument for it is unchanged; what is gone is the
  arithmetic around it.** 64 is margin rather than a threshold: the measured failure point
  on this machine and this script is 14, and that number is not a constant — it moves with
  how many descriptors the caller left open, with how many saved descriptors the closing
  statement itself is holding, and with the bash version's own `F_DUPFD` bookkeeping, none
  of which the entry can see from where it stands. So 64 is still the smallest round number
  well clear of every measurement in this block, still far above the two or three free
  numbers at or above 10 that the relocation actually needs, and still leaves room for the
  handful of files the entry opens afterwards — the pinned jq, the ten pin reads, the two
  compiles, the copies. 256 is tried before 64 rather than instead of it, because it is the
  traditional Darwin soft default and so cannot be an unusual value for anything in this
  tree to run under, and because a caller who has lowered the *hard* limit into the range
  between 64 and 256 has narrowed the entry's room without breaking it. (**This round puts
  a third rung above both**, `ulimit -S -n 1024`, for the reason the block below gives; the
  argument for 256 and for the 64 floor is unchanged and they are now the second and third
  attempts of three.) Three statements of
  the round-35 shape are **withdrawn** with the reading: `nofile=$(ulimit -n)`, the `case`
  that mapped `unlimited` and unparsable answers, and the `[ "$nofile" -ge 64 ]`
  comparison. The hazard that `case` existed for goes with them rather than being handled
  again — measured then and still true, `[ unlimited -ge 64 ]` does not answer false, it
  writes `[: unlimited: integer expression expected` on stderr and returns `2` — because
  nothing reads the limit any more and there is no value for `[` to choke on. And what the
  refusal turns on is now the **hard** limit rather than the soft one, which is a widening
  and not a tightening: a caller whose soft limit is 12 and whose hard limit is the ordinary
  `unlimited` was refused by the round-35 shape and is *served* by this one, because the
  entry can simply take the headroom the kernel is willing to give it. A caller whose hard
  limit is 63 has done something deliberate, and that caller is still turned away.

  **Measured, bash 3.2.57 on `arm64-apple-darwin` (`Darwin 27.0.0`), with the hard limit
  set in the subshell the script is started from.** Four fixtures, the round-35 shape and
  this round's beside each other on the same script:

  ```
  fixture (hard, caller soft)   round-35 shape        this round's precondition
  512, 100                      continue, soft 100    continue, soft 256
  128, 128                      continue, soft 128    continue, soft 64
  63, 63                        E_RUNTIME, exit 1     E_RUNTIME, exit 1
  unlimited, 12                 E_RUNTIME, exit 1     continue, soft 256
  ```

  And end to end on the 70 KiB-script-with-a-marker shape the traces above use, rebuilt
  for this round at 80,994 bytes, with the caller holding 4, 5 and 7 and 7 an append
  handle on the running script — every continuing fixture reaches the marker and leaves
  the file byte-identical:

  ```
  hard 128, soft 128:      soft after precondition 64    script fd 127 → relocated to 12
  hard 512, soft 100:      soft after precondition 256   script fd  99 → relocated to 12
  hard unlimited, soft 12: soft after precondition 256   script fd  11 → relocated to 13
  fds after, all three:    /dev/fd/0 /dev/fd/1 /dev/fd/2 /dev/fd/3 plus the relocation
  all three:               MARKER-END reached, exit 0, 80994 bytes before and after
  ```

  The first row is the one to pause on, because it is the only case where the precondition
  *lowers* the soft limit while bash's script descriptor is already open above the new
  value. `RLIMIT_NOFILE` bounds the numbers a process may allocate and closes nothing
  already open — the same fact R5's parent-side close rests on — so 127 stays open and the
  loop shuts it; the relocation then needs a free number at or above 10 and below 64, and
  it lands on 12. The last row is the environment the round-35 shape refused outright and
  the one no precondition at all truncates silently.

  **This round the precondition tries 1024 before it tries 256, and the reason is exactly
  the caller the refusal above exists for.** Normalising downward is what created that
  caller. A caller holding 3 through 255 with a soft limit of 1024 has free numbers to
  spare; the round-41 statement took them away — it set the soft limit to 256, every number
  below 256 was already occupied, and the glob had nothing left to open. The round-41 text
  bought determinism there and paid for it with the entry's whole purpose. Adding a rung
  above it buys the determinism back without the bill, and it is the same rule that made one
  statement do two jobs in the first place: an unprivileged process may set its soft limit
  anywhere up to its hard limit, so `ulimit -S -n 1024` succeeds whenever the hard limit is
  at least 1024, `256` whenever it is at least 256, `64` whenever it is at least 64, and the
  three fail together only when the hard limit is below 64 — which is still the round-35
  floor, still refused with the same single `E_RUNTIME` line, and still the only environment
  the precondition turns away. The cost is one more builtin on a line that already had two,
  and no fork: `ulimit` is a builtin (`type -t ulimit` answers `builtin`), so the extra
  attempt opens nothing, execs nothing and creates no process, and the claim above about
  what stands between the entry's first statement and the loop's last pass is unchanged.

  **Measured, the same four fixtures as the block above plus the two the rung is for,
  round 41's shape and this round's side by side on the same script**, with the hard limit
  set after the soft one in the subshell the script is started from, because a bare
  `ulimit -H -n` under a higher soft limit is refused by bash itself:

  ```
  fixture (hard, caller soft)   round-41 shape        this round's ladder
  512, 100                      continue, soft 256    continue, soft 256
  128, 128                      continue, soft 64     continue, soft 64
  63, 63                        E_RUNTIME, exit 1     E_RUNTIME, exit 1
  1023, 1023                    continue, soft 256    continue, soft 256
  1024, 1024                    continue, soft 256    continue, soft 1024
  unlimited, 12                 continue, soft 256    continue, soft 1024
  ```

  Only the last two rows move, and they are the rows the finding is about: where the hard
  limit will allow 1024 the entry takes 1024 instead of cutting itself down to 256. Nothing
  below 1024 changes at all, so the 63 refusal, the 64 fallback and the argument for the
  floor are all untouched by the rung. End to end on the finding's own fixture — 253
  descriptors open on 3 through 255, hard and soft 1024 — the ladder turns the refusal
  measured two blocks above into an ordinary success:

  ```
  caller 3..255, hard 1024, soft 1024:
    round-41 cap 256:   glob expands to the literal, 0 closed, 253 still open, exit 0
    this round's cap 256 + refusal: E_RUNTIME, exit 1, nothing created
    this round's ladder:            soft stays 1024, glob sees 257 words, 253 closed,
                                    still open above 2: /dev/fd/12 alone, exit 0
  ```

  **What the rung does not buy, and where the refusal is still the answer.** Two shapes
  remain, and both fail closed rather than quietly. The first is the narrowed lowering
  window: a hard limit between 256 and 1023 with a caller soft limit above 256 still makes
  the second rung *lower* the limit, and a caller who has filled every number below 256
  there is the finding's caller again. Measured, hard and soft 1023 with the caller holding
  3 through 300: the first rung fails against the hard limit, the second succeeds and takes
  the soft limit from 1023 to 256, the glob then has no free number under 256 and expands to
  the literal — without this round's refusal the run continues with all 298 caller
  descriptors intact and exits `0`, and with it the entry writes `E_RUNTIME` and exits 1
  having created nothing. That is the price of normalisation, stated where it is paid: the
  entry still prefers one of three known soft limits to whatever the caller left behind, and
  where that preference costs a caller their run, the caller is told so rather than served a
  silent pass. The second shape is a caller who has filled every number below the *hard*
  limit, where no rung can help because there is no headroom to be had: measured, hard and
  soft 256 with the caller holding 3 through 254, all three `ulimit` attempts fail — not on
  the limit but on their own `2>/dev/null`, which needs a descriptor the caller has not left
  — and the refusal at the end of the chain writes `E_RUNTIME` and exits 1. Three bash
  `/dev/null: Too many open files` lines arrive with it, which is the same stderr residual
  the fixture two blocks above shows and is named again here rather than discovered later.
  Both shapes refuse; neither is skipped.

  **Normalising to 1024 rather than 256 is the same trade in the same direction, and the
  three places round 41 checked are still the places.** Past the precondition the entry and
  everything it starts run with a soft `RLIMIT_NOFILE` of 1024, or 256, or 64 — one of three
  constants in the shipped file rather than the caller's own number, which measured
  1,048,576 on this machine. Nothing downstream wants more and nothing downstream is
  starved: the parent's own startup close takes `rlim_max`-or-`sysconf` capped at 65536 as
  its ceiling and the soft limit as a ceiling nowhere (R5), the parent puts 64 under the
  resolver child whatever it inherited (R4), and the compiles, digest tools, `cp`s and jq
  probe open a handful of files each. What 1024 changes against 256 is the direction of the
  adjustment in the common case — on a machine whose hard limit is generous the entry now
  raises or holds where it used to cut — which is strictly more room for every child below
  and strictly fewer callers whose descriptors the entry has to refuse.

  **The precondition forks nothing, and that is the point of the rewrite.** The round-35
  shape opened with `nofile=$(ulimit -n)`, and bash 3.2 forks for a command substitution —
  measured there and re-measured here by the thing that makes it visible. With the caller
  holding 4, 5 and 7, a `/dev/fd` listing taken *inside* the substitution reports
  `/dev/fd/0 /dev/fd/1 /dev/fd/2 /dev/fd/3 /dev/fd/4 /dev/fd/5 /dev/fd/7` — the caller's
  three among them and bash's own `255` absent, so a different descriptor table and
  therefore a different process — and a variable assigned inside it is empty in the shell
  afterwards. That child held whatever the caller left open for the duration of one
  builtin, above the loop that exists to shut it, and every claim in this spec about what
  the entry's children can hold had to carry it. The replacement has no substitution in it,
  and the measurement that says so is the builtin's own effect: after the precondition the
  shell reads back its **own** soft limit as `256`, which a subshell could not have changed
  for it, and its descriptor list is the one it started with, `255` included. The
  `2>/dev/null` on each `ulimit` is not a hole in that — a redirection on a builtin is a
  temporary dup and restore inside the shell, not a fork, which the same measurement
  settles twice over: the limit changed in the shell, and a `printf` to stderr further down
  the script still reaches stderr, so nothing was permanently redirected and no process was
  made. Nothing above the close loop now forks, execs, opens or reads anything.

  **The fork-free alternative round 35 rejected is still rejected, and it is not this one.**
  That round considered probing the limit by opening a high descriptor — `exec 63</dev/null`,
  refusing if it fails — and turned it down because it writes to a descriptor number bash
  may itself be using at exactly the low limits the check exists for, and provokes the
  relocation it is trying to establish there is room for. None of that has changed. What
  changed is that a third option was there all along and neither round looked for it,
  because both were trying to *read* the limit: the entry never needed the number, only
  for the number to be big enough, and `ulimit -S -n` is the statement that makes it so.

  **Normalising the soft limit is a determinism gain rather than a cost, and the three
  places it could have been a cost are each checked.** Past the precondition the entry and
  everything it starts run with a soft `RLIMIT_NOFILE` of **exactly one of 1024, 256 or
  64** — the first rung the hard limit allows, which is the postcondition the whole ladder
  exists to produce and the one every assertion about this limit reads — instead of
  whatever the caller left behind, which measured
  1,048,576 on this machine and is something else again on a CI runner. Nothing downstream
  wants more. The parent's own startup close does not take the soft limit as a ceiling
  anywhere: it enumerates `/dev/fd` and uses `rlim_max`-or-`sysconf` capped at 65536 as its
  belt (R5), which is the round-39 fix and is untouched by this one. The resolver child's
  `RLIMIT_NOFILE` is set to 64 by the parent whatever it inherited (R4), and an inherited
  soft limit of 1024, 256 or 64 does not stop `setrlimit` putting 64 under it. And the compiles, the
  digest tools, the `cp`s and the jq probe open a handful of files each. The one property
  given up is named: the entry no longer passes the caller's soft limit down to its
  children, which is the same trade R3 already makes for every environment variable in the
  tree, and it is a trade this requirement is in the business of making.

  **The `2>/dev/null` belongs to the `eval` and must not be written on an `exec`.** The
  redirection on the loop's `eval` is a temporary one the shell undoes when `eval`
  returns, while the `exec` inside the quoted string is what makes the close permanent.
  An `exec` with no command is a redirection *of the shell*: `exec 9>&- 2>/dev/null`
  would shut descriptor 9 and point the shell's own stderr at `/dev/null` for the rest of
  the run, deleting every diagnostic below it, the `E_*` refusals included. That trap is
  smaller this round than last — there is no longer an `exec` of the entry's own outside
  the `eval` for a plan to attach two characters to — but it survives on the `eval`'s own
  line, where a plan tidying up a stray error message could move the redirection inside
  the quotes. The residual left by keeping it outside is small and stated: under a
  pathological `RLIMIT_NOFILE` the close can put one `redirection error: cannot duplicate
  fd` line on stderr that the `eval`'s redirection does not catch — and the precondition
  above now raises the limit out of those environments, or refuses them, before the loop
  runs at all, so the residual is
  narrower than it was.

  **The re-exec side needs nothing of its own, and the close-on-exec measurement is why.**
  Bash's script descriptor does not cross an `exec`, relocated or not, so the second bash
  starts with 0, 1, 2 and a fresh open of the script on its own high number; it inherits
  nothing from the first bash's table except what the first bash deliberately passes. The
  first bash's *own* relocated input is close-on-exec too — the `fcntl(F_GETFD)` helper
  above reports `EBADF` for it in a child — so there is no stray same-file descriptor to
  reason about on the far side, and even if some bash version left one there, the second
  bash's own loop closes every number above 2 without exception and shuts it. Measured
  end to end with the full re-exec form, `exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C
  /bin/bash -p "$0" __clean`, and the caller's 4, 5, 7, 10 and 11 open with 7 a write
  handle on the script: the first process listed `255` plus the caller's five and shut
  all five, the second process listed only `0`, `1`, `2`, its own `255` and the glob's
  own, the second bash's marker printed, the script's last line printed, and the exit
  status was `0`.

  **What the plan confirms on the other platform, named as one thing to check.** Every
  measurement in this block is bash 3.2.57 on `arm64-apple-darwin` (`Darwin 27.0.0`). CI
  runs `ubuntu-latest`, whose bash is 5.x, and the property the loop rests on is a bash
  internal rather than a documented interface. So the plan carries one confirmation, and
  it is specific: on the CI image's bash, that closing the descriptor bash is reading the
  script from relocates the input instead of truncating the read — the function to look
  for by name is `save_bash_input`, reached through `check_bash_input`, with its
  `fcntl(fd, F_DUPFD, 10)`. The confirmation is a run, not a source read: the same
  70 KiB-script-with-a-marker shape used here, at the image's default limit and at
  `ulimit -H -n 64` — the hard limit and not the soft one, since the precondition raises a
  low soft limit rather than living with it, so a soft-limit fixture would prove nothing
  about scarcity — asserting the marker prints. The same run confirms the second half of
  the precondition on that bash: that `ulimit -S -n 256` really does succeed against a
  larger hard limit and fail against a smaller one, which is POSIX for an unprivileged
  process but is worth one observation rather than an assumption. If some bash there does
  not relocate, the precondition is not the fix and the requirement changes rather than the
  number, which is why this is a plan step and not a line in the test.

  **The position is half the requirement, and an earlier round of this spec had it wrong.**
  That round put the loop after the copied scrub and after the re-exec, on the marker
  branch, which reads like the top of the file and is not. The scrub's two loops take their
  input from process substitutions — `done < <(builtin compgen -A function)` and
  `done < <(builtin compgen -e)` (`materialize.sh:5-10`) — and bash forks a child for each
  one, so two bash children run with the caller's descriptors still open; and the re-exec
  below then runs `/usr/bin/env` and a second `/bin/bash` (`:22-29`), both of which inherit
  them across the `exec` as well. On a supported entry invocation with one extra descriptor
  open, a credential, a socket or a write handle would therefore be exposed in four
  processes before the point R10 observes it shut, which is the boundary the intent draws
  in the words this spec is written against — no credentials, no writes outside the output
  root (`work/resolver-trusted-parent/intent.md:36-44`). Putting the loop above both closes
  that: nothing this entry forks or execs, on either path, has ever held a descriptor the
  loop did not shut first. The loop then runs a second time in the process the re-exec
  lands in, where it finds 0, 1, 2, that second bash's script descriptor and the glob's
  own — measured: `0`, `1`, `2`, `255`, `3` — and shuts the script descriptor, which that
  bash relocates exactly as the first one did. One substitution, one glob and a handful
  of builtins, which is cheaper than a condition that would skip the whole block and one
  fewer thing for a reader to have to check.

  **Each line of it is chosen for bash 3.2, and the loop itself forks nothing.** The
  enumeration is
  a glob over `/dev/fd`, which is a directory of the calling process's own open
  descriptors on both supported platforms, and a glob is the shell's own pathname
  expansion — no `ls`, no `find`, nothing on R7's command-word list, and nothing that could
  itself be the first external command this whole ordering exists to get ahead of. The
  `case` throws away anything that is not all digits before it reaches `eval`, which is
  what makes the `eval` safe: the only strings that get there are numbers the glob read out
  of a directory of numbers, and 0, 1 and 2 are skipped because they are the caller's three
  and passing them through is what R1's pass-through claim and R2's `entry-signal:` line
  both depend on. Nothing else is skipped: there is no fourth
  pattern in that arm and no test behind it, which is the round-35 change and the reason
  the arm is now three patterns and a number shorter than the block it replaces. The
  precondition above it is free in the same way from this round on — `ulimit` and `printf`
  are builtins and the round-35 command substitution that forked for one of them is gone,
  so it opens nothing, execs nothing, forks nothing and stays ahead of the entry's first
  external command like everything else at the top. Running ahead of the scrub costs that `eval`
  nothing, and the refusal at
  the top is the reason it can: `eval`, `exec` and `continue` are builtins and `case`,
  `in`, `esac`, `for`, `do` and `done` are reserved words, and on every arrival that gets
  this far bash imported no function and read no `BASH_ENV`, so there is no `eval` of the
  caller's to be called instead and no alias of the caller's to rewrite the line before it
  is parsed. The `eval` is needed rather than preferred — bash 3.2 has no `{fd}>&-`
  form, so the descriptor number has to be substituted into the redirection word before the
  shell parses it — and `2>/dev/null` absorbs the one ordinary failure, a number that named
  a descriptor the glob itself was using and that is gone by the time the loop reaches it.
  That descriptor is worth naming because a reader will see it in the measurement below:
  reading `/dev/fd` opens a descriptor to do it, so the listing always contains one entry
  that is the listing's own, and it does not survive the statement either way.

  **What it buys, and what it does not.** Every child the entry forks and every process it
  execs now starts with three descriptors, whatever the caller held: no credential, no
  socket, no write handle outside the root reaches the scrub's two process substitutions,
  the `env` and second bash of the re-exec, a SHA tool, a compiler, a `cp` or the jq probe,
  and the single-write-root claim in R7 and the no-caller-state claim in R3 stop depending
  on the caller's own hygiene. **Say the boundary the way this round makes it true: every
  descriptor above 2 is closed or the run is refused, and none is ever silently skipped.**
  That is one claim in two halves and the second half is this round's. The loop shuts every
  number it is given, with no exception of any kind; and in the one arrangement where it can
  be given no numbers at all — a caller who has filled every descriptor below the soft limit
  the precondition settles on, so that the glob's own `opendir` fails and the expansion is
  the literal word — the loop's first action is an `E_RUNTIME` refusal before anything has
  been created. There is no third outcome, and there used to be: the round-41 text let that
  arrangement through with every caller descriptor intact and a status of `0`.
  It does not replace the parent's close, which happens in the
  resolver child before `execve` (R3) — that one is the last line of defence and stays
  where it is — and it does not replace the parent's own startup close, which R5 now
  requires for the same reason on the direct-parent path (R10's group-2 cases start the
  parent with descriptors of their own, and the parent tests nothing about who started
  it). Two lines of defence, at the
  two process boundaries that exist. The one thing neither closes is a descriptor the
  caller marked close-on-exec, which needs no closing, and the entry's own first process
  before the loop's first pass — which is three statements wide, a `case` on `$-`, a
  `umask` and the headroom precondition. **All three fork nothing, exec nothing, open
  nothing and read nothing**, which is this round's change and is what lets the claim be
  stated without a residual: no process other than the entry itself has ever held a
  caller's descriptor by the time the loop's last pass ends. The round-35 precondition's
  one command-substitution child is gone, and the paragraph that used to state it exactly
  rather than round it to zero now states zero because zero is the measurement. The
  residual that remains at the top of the file is the loader's, the same one the scrub has,
  and it is stated in the same place.

  **Measured, on the same bash 3.2.** A driving shell opened the write end of a fifo on
  descriptor 7, started a script with it inherited, and had a reader watch for end-of-file.
  With the loop above as the script's first statement, `fds before:
  /dev/fd/0 /dev/fd/1 /dev/fd/2 /dev/fd/3 /dev/fd/7` and `fds after:
  /dev/fd/0 /dev/fd/1 /dev/fd/2 /dev/fd/3` — descriptor 7 gone, and `/dev/fd/3` the
  listing's own descriptor in both readings — and the reader saw EOF 0.3 s in, while the
  script still had two seconds of work left to do. Without the loop the reader saw no EOF
  until the script had exited, and in a third run, where the script forked a helper and
  exited immediately, the reader saw no EOF until the *helper* exited three seconds later:
  that third run is the finding in one observation, a forked child holding a caller's
  descriptor open after the shell that inherited it has gone.

  **Then the scrub, copied verbatim, with nothing of the caller's left for its own children
  to inherit.** It comes from the materializer's clean entry
  (`adapters/local-git-materializer/v1/materialize.sh:4-13`):
  `builtin unset -f` over every name `builtin compgen -A function` reports, then
  `builtin unset` over every name `builtin compgen -e` reports except `PATH`, then
  `PATH=/usr/bin:/bin`, `LC_ALL=C` and `export PATH LC_ALL`. Builtins only — no `env`, no
  `uname`, no external command of any kind — so there is no window in which an external
  command runs under a caller-set variable. It is not free of *processes*, though, and the
  block above is where that matters: its two `while … done < <(builtin compgen …)` loops
  are process substitutions and bash forks a child for each, which is a fork with no `exec`
  behind it and, now that the close has already run, with nothing of the caller's to carry.
  The shebang comes over with it, `#!/bin/bash -p`
  (`materialize.sh:1`), because privileged mode is what stops bash from sourcing `BASH_ENV`
  before the entry's first line — and it is the condition the refusal at the top tests for.

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
  themselves, and the third and fourth deviations are what this spec does about that.
  The third is the `-p` on the re-exec's `/bin/bash`, where the materializer
  writes a plain `/bin/bash` (`:27`): the entry's shebang is `#!/bin/bash -p` already,
  and the flag is added here so that privileged mode survives the re-exec instead of being
  dropped at the one hop that matters — the hop into the second process, where the refusal
  at the top of the file runs again and tests for it. It costs nothing else. Under `env -i`
  there
  is no environment left for privileged mode to refuse, so `-p` changes no behaviour on
  this path; what it changes is that `$-` carries a `p` in the second process, which is the
  fact that refusal acts on. The fourth is the four statements the entry puts above the
  copied scrub, none of which the copied file has in that position — the `case $-` refusal,
  the `umask 077` lifted from `:31`, the descriptor-headroom precondition and the
  descriptor close — together with the marker
  branch's own re-run of the scrub behind two alias-reset builtins, below. Everything
  else is the same:
  `$script_path` comes from `${BASH_SOURCE[0]}` and must be absolute (`:23-24`), and the
  re-exec is an `exec`, so no extra process is left behind. The literal
  `PATH=/usr/bin:/bin` above is not a further deviation: the materializer writes
  `PATH="${PATH:-/usr/bin:/bin}"` there (`:26`), and the scrub has just set `PATH` to
  exactly that value, so the two are the same line with the indirection spelled out.
  Every step this spec describes after this point — the platform case, the output-root
  validation, the pin checks, the compiles, the mode pass, the launch — runs in that second
  process, which was started with an empty environment.

  **The marker branch re-runs the scrub in full, as defence in depth.** First on that
  branch come `builtin unalias -a` and `builtin shopt -u expand_aliases` — two lines the
  copied bytes do not have, needed because the scrub unsets inherited functions and
  exported names and an alias is neither. They go before the rest because bash expands
  aliases as it reads
  each command, so the reset has to run before the shell parses what follows. Then the
  builtin scrub itself: `builtin unset -f` over `builtin compgen -A function`,
  `builtin unset` over `builtin compgen -e` except `PATH`, `PATH=/usr/bin:/bin`, `LC_ALL=C`,
  `export PATH LC_ALL`. `builtin` prefixes every one of these, so on any invocation that
  got past the refusal at the top of the file no function of that name can intercept the
  reset. The sibling
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
  statement of the file runs and can in principle shadow the refusal itself. Measured,
  same shell: an exported function named `exit` is called instead of the builtin, so the
  `exit 78` runs the caller's code and the file carries on; and a `BASH_ENV` that sets
  `expand_aliases` and aliases the reserved word `case` makes the whole refusal expand to
  something else entirely. Both of those need the plain form — under either `-p` form the
  `BASH_ENV` is not read and the function is not imported, so both attacks are gone before
  they start. This is not a hole being conceded for the first time: it is the same boundary
  the paragraph below draws and the same one the Areas-of-concern bullet on the entry's
  first process has drawn for several rounds — the entry's own loader runs under whoever
  started it, and no statement inside the entry can unrun that. What the spec stopped doing
  two rounds ago, and still does not do, is describe the marker branch's scrub as proof
  that hostile functions and aliases were removed before validation; it is what it is, a
  second layer on the invocations where the first layer already holds.

  **And the direct marker invocation is unsupported, which is the part that actually settles
  it.** There are two supported ways to run the entry: execute the file, so its
  `#!/bin/bash -p` shebang is what starts bash, or
  `env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p <entry> <jq> <output> <request> <map>`.
  Invoking the marker word directly is neither, this spec makes no safety claim about it,
  and R9's documentation says so: the marker exists so the re-exec has somewhere to arrive,
  not as a public entry point. What the entry does about it is the refusal above, and the
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
  imports. The parent re-checks all eight of them for itself (the parent-pinned set, R5),
  so the entry is not the only process that holds the loaded set to its committed bytes.
  What stays the entry's alone is the two C sources and, with them, the helper's
  provenance: the parent can pin no binary, so the compile from a pinned source into a
  directory the entry made is the only thing that says where the helper's bytes came from
  — which is why the entry is the only supported launch (R5). The pinned constants carry a
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

  The entry then copies in the bound jq and the platform's awk — the jq by `/bin/cp` into
  `<output>/.run/jq`, and the awk either by `/bin/cp` from `/usr/bin/awk` on Linux or, on
  Darwin, as the two-line `#!/bin/bash` / `exec /usr/bin/awk "$@"` shim `/usr/bin/printf`
  writes, the shapes the test uses at
  `scripts/test/portable-profile-resolution.test.sh:132-141`. Both destinations are fixed
  names inside `.run` and not paths the caller can influence, which is what the parent
  re-establishes from its own side before it launches anything: the jq argument it is
  handed must be that `.run/jq` by descriptor identity, and `.run/awk` must hold exactly
  the bytes this step wrote (R5). The entry's copy and the parent's check are the same fact
  stated by the two processes that each have to be able to state it alone. And then — only
  after both
  compiles have finished — the entry empties and removes the `tmp` and `home` subdirectories and
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
  stdout. Those two and the jq `--version` probe are `execve`d under this very pair of
  variables and no others, written by the parent rather than inherited, which is what
  keeps a caller's `PERL5LIB` out of Darwin's perl-script `shasum` on the path where no
  entry ran at all (R7).
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
  eight files of the parent-pinned set, the jq SHA-256 digest and the `jq-1.6`
  `--version` probe (R5, R7) — and every R5 refusal happens in that same stretch. That
  stretch is longer this round, ten children rather than five, which changes nothing about
  the branches below and does mean a forwarded signal is more likely to land in it. So a
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
    kills the group. It goes back to `0` the way it was set — under the three-signal block,
    before the mask is restored — but not at the instant of the reap: the block that covers
    the reap covers the survivor check and any kill of the surviving group with it, and the
    clear comes last, so `pgid` is non-zero for exactly as long as anything of the
    resolver's group can still be there to kill. The reap block below says that once for
    both variables.
  - `pre_child` is a second `volatile sig_atomic_t` holding the pid of the pre-resolver
    child that is running right now: each of the eight SHA-1 tool invocations, the SHA-256
    tool, and the
    jq `--version` probe. It is set in the parent immediately after that child's `fork`,
    inside the same blocked-signal region, and before the `waitpid` on it, and cleared
    back to `0` under the block around that `waitpid` and before the mask is restored, so
    at most one pid is ever live in it and it is `0` whenever no pre-resolver child exists.

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
  tool for **each of the eight blob-id pins of the parent-pinned set**, the three the
  parent has always held and the five module pins R5 added beside them, the SHA-256 tool
  for the jq digest, and the jq
  `--version` probe — the parent blocks `SIGINT`, `SIGTERM` and `SIGHUP` with
  `sigprocmask(SIG_BLOCK, &three, &saved)`, keeping the previous mask in `saved`. In the
  parent after `fork` returns, in this order: `setpgid(child, child)` (`:450`, the
  resolver's fork only); assign `pgid = child` for the resolver or `pre_child = child` for
  a pre-resolver child; then `sigprocmask(SIG_SETMASK, &saved, NULL)`. A signal that
  arrived while the three were blocked is delivered at that restore, when the handler
  already reads the published id and takes the branch that kills the child that exists.
  The forked-but-unpublished state is never observable by a handler, because no handler
  runs while it holds.

  **The count is stated once here so no reader has to work it out twice: eight SHA-1
  children, one SHA-256 child and one jq probe are ten pre-resolver children, and with the
  resolver's the parent forks eleven times in a run.** The number is worth writing down
  because it moved: R5 widened the parent-pinned set from three files to eight, which
  turned five pre-resolver children into ten, and an enumeration left at three would read
  as leaving the five module-hash children outside this region — forked and published with
  the signals unblocked, which is exactly the window the rule exists to close. There is no
  such gap and no second rule: the mask goes on before each of the eleven and comes off
  after the publication of each, and the reap block below covers all eleven the same way.

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

  **Every `waitpid` that can reap a tracked child is called with the three signals blocked
  too, and the id it reaps is set to `0` before the mask is restored.** An earlier round of
  this spec cleared `pre_child` outside any mask and defended the gap: the kernel would have
  to recycle the pid in the few instructions between the reap and the clear, and the parent
  forks nothing in that span. That defence was wrong, and the reason is one sentence. Pid
  reuse is system-wide, not per-parent: any process on the machine can fork in that window
  and be handed the number this parent has just given back, and a handler running there
  would read a non-zero `pre_child` and send `SIGTERM` and then `SIGKILL` to a stranger.
  Nothing about this parent's own forking habits bears on that. So the rule is stated for
  every reap instead of argued away — block, `waitpid`, zero the id, restore — and because
  the handler can only run after the restore, what it reads is either an id whose process is
  alive or is a zombie this parent has not yet reaped, or `0`. Never a reaped one.

  For a pre-resolver child — each of the eight SHA-1 tool invocations, the SHA-256 tool,
  the jq `--version` probe, ten of them — that is four statements in this order:
  `sigprocmask(SIG_BLOCK, &three, &saved)`, `waitpid(pre_child, &st, 0)`, `pre_child = 0`,
  `sigprocmask(SIG_SETMASK, &saved, NULL)`. The cost is worth stating plainly rather than
  leaving a reader to find it: while the three are blocked, a signal the caller forwarded
  waits until that child exits. These children are short and bounded by what they are — a
  digest of a file the parent has already `fstat`ed, or a `--version` that prints one line —
  so the wait is milliseconds. It is bounded by nothing else: `apply_child_limits`
  (`portable-profile-resolution-launcher.c:388-398`) and the supervisor's
  `INVOCATION_SECONDS` poll (`:456-489`) are the resolver's limits, and the pre-resolver
  children run under neither. So a pre-resolver tool that hung would hold the signal until
  it ended, and that is accepted here rather than papered over: these are the platform tools
  at fixed paths that this parent already trusts by path and by digest (R7), and the only
  alternative on offer is the stranger-kill above.

  For the resolver the same shape wraps every `waitpid` in the copied supervisor that can
  reap it, and there are three — with one extension the pre-resolver children do not need,
  because the resolver is the only child of this parent that leads a group. **The blocked
  region around the resolver's reap does not end at the reap. It runs on through the
  survivor check and through any kill of the surviving group that check provokes, and
  `pgid` is cleared last of all.** The poll loop's
  `waitpid(child, &status, WNOHANG)` (`:457`): block, call it, and when it returns the
  child, stay blocked for the survivor scan the copied loop runs on the next line —
  `process_group_count(child) > 0U`
  (`portable-profile-resolution-launcher.c:460-462`), which sets `stopped = STOP_PROCESS`
  and breaks — and, when that scan finds survivors, stay blocked through the kill the
  copied code then performs for it: `kill(-child, SIGKILL)` and `kill(child, SIGKILL)`
  (`:491-492`), with the wait behind them (`:493-494`). Only after that `pgid = 0`, and
  only then `sigprocmask(SIG_SETMASK, &saved, NULL)`.

  An earlier round of this spec cleared `pgid` the moment the reap returned and left the
  survivor check outside the block, and that left open the one case this whole requirement
  exists for. The resolver exits having spawned something that is still in its process
  group; an `INT`, `TERM` or `HUP` delivered while the parent is walking the process table
  finds `pgid == 0`, takes the handler's `no-runtime` branch, kills nothing and
  `_exit`s — and the surviving group keeps running while the entry's wait returns on a
  parent that is gone and its `EXIT` trap removes `.run` from under it. Keeping `pgid` live
  to the end of the cleanup closes it from both sides. While the three signals are blocked
  no handler runs at all, so saying that a handler in there would read a non-zero `pgid`
  and take the group branch is a statement about what the variable means rather than about
  anything that happens; and after the restore, a signal that was pending finds `pgid == 0`
  only once there is nothing of that group left for it to have killed.

  **Say the cost plainly: the handler is delayed by one process-table scan, and rarely by
  one group kill as well.** `process_group_count` is a `/proc` walk on Linux (`:177-231`)
  and a `proc_listallpids` sweep with a `getpgid` per pid on Darwin (`:233-265`), so on
  every normal exit a forwarded signal now waits for one of those before the handler can
  run — milliseconds, and the same scan this loop was already running once per poll
  interval. On the rare path where the scan finds survivors it waits for the group
  `SIGKILL` and the wait behind it too, which is as long as the kernel takes. That is
  accepted rather than papered over, because the alternative is the gap above and the
  handler exists precisely to leave nothing of the resolver behind.

  **The limit path is checked for the same ordering and made to match, so the two cannot
  drift.** The `while (waitpid(child, &status, 0) < 0 && errno == EINTR)` at `:493-494` is
  what the
  loop's other breaks reach — the process, memory and time limits at `:465-487` — and it
  follows the same `kill(-child, SIGKILL)` and `kill(child, SIGKILL)` (`:491-492`). An
  earlier round of this spec put the block around that wait alone and left the two kills
  in front of it outside, which is the same shape of mistake in a milder place: nothing
  there reads a cleared `pgid`, because the clear came after the wait, but the two
  arrangements would have been written differently for no reason a reader could see. So
  the block goes around all of it: `sigprocmask(SIG_BLOCK, …)` before the two kills, the
  wait,
  `pgid = 0`, then the restore. Both paths therefore leave the block at the same statement
  with the same thing true — the group is gone and `pgid` is `0` — and a plan has no
  ordering left to choose between. On this path the block costs nothing at all, because the
  group has just been sent `SIGKILL` and the wait is as long as the kernel takes to finish
  killing it.

  Everything else in the poll loop still runs **outside** the block: the
  `process_group_count` and address-space scans at `:469-483`, the clock check at
  `:484-487` and the `nanosleep` at `:488`. So responsiveness while the resolver is running
  is exactly what it was, and the one window this round widens is at the end of its life,
  where the thing being waited for is the cleanup itself. The `setpgid`-failure path's
  `kill(child, SIGKILL)` and
  `waitpid(child, &status, 0)` (`:451-452`) needs no block of its own: it sits inside the
  fork-and-publish region above, before `pgid` has ever been assigned, so it reaps under a
  block already held and leaves `pgid` at `0`. All it has to do is restore the mask before
  it returns 70.

  **After `pgid` goes back to `0`, no code path may use the old value for a kill.** The
  rule reads against the clear rather than against the reap, because the clear is now the
  last statement of the cleanup instead of the first thing after the `waitpid`. Between
  the reap and the clear are the survivor check and the group kill above, which name that
  group on purpose and are the reason the block was extended. After the clear there is the
  exit classification and the streaming back — `empty_regular_file`, `stream_file` and
  `sanitized_error` (`:504-531`), which after R5's change read the descriptors the parent
  already holds and name no process at all. So there is nothing to remove.

  The survivor check and the two kills keep using the supervisor's own local `child`
  rather than the shared `pgid`, exactly as copied; the variable that must not be read
  stale is the one the *handler* reads, and the block is what settles that. The copied
  code's own exposure is unchanged and is better stated here than discovered later: the
  pid is reaped at `:457` and read again at `:460` and killed at `:491-492`, so a kernel
  that recycled the number in that span would let a stranger's group turn this run's clean
  exit into `E_LIMIT process-limit` and, when the scan reports survivors, receive a
  `SIGKILL` meant for the resolver's. That is the copied supervisor's behaviour and this
  round neither widens nor narrows it — the same handful of instructions, now with the
  three signals blocked across them — and it is a different hazard from the one the block
  exists for, which is about a handler reading an id the parent has already given back.
  The plan should not reach for `pgid` to "fix" it: `pgid` is `0` only once that whole
  sequence is done, and that is the point.

  With those rules the handler's contract below needs no change and is finally true rather
  than nearly true, with one word chosen carefully: a non-zero `pgid` always names a
  process **group** this parent owns, and a non-zero `pre_child` a process it owns,
  running or a zombie it has not reaped. The group is the right unit, because the point of
  the extended block is the window in which the leader has been reaped and members of its
  group may still be alive — `pgid` is non-zero across that window on purpose, and the
  group branch is the branch it should select there, which is the property being
  preserved rather than an event that occurs, since the mask keeps every handler out of
  that window. The handler
  still ignores the result of its
  `kill` and of its reap, and the reason is narrower than an earlier round of this spec
  gave. The ids are never stale, so `ESRCH` no longer stands for "this number may belong to
  someone else now". It stands for the one case left: the child exited between the handler's
  read of the variable and its `kill`, leaving a zombie this parent owns which the outer
  run's own reap may already have taken — with `ECHILD` from the handler's `waitpid` for the
  same reason. There is nothing a handler on its way to `_exit(128 + signal)` can do with
  either, so it checks neither; that is a requirement here rather than a note for the plan.

  The handler then chooses on those two, in this order, and it carries one more piece of
  state across the choice: a local `reaped`, `0` before the bounded wait below and `1` only
  if that wait's `waitpid` actually returned the target. **The two branches spend that flag
  differently, and the difference is the point of this round.**

  If `pgid != 0`, it runs the group sequence: `kill(-pgid, SIGTERM)`, the bounded wait
  below on the leader, then `kill(-pgid, SIGKILL)` **whether or not the leader was
  reaped**, and then the final blocking reap only if `!reaped`. The group `SIGKILL` is
  unconditional on purpose: survivors in the group are the entire reason a group kill
  exists, the leader exiting says nothing about whether there are any, and the handler
  cannot look — the process-table scan that would answer the question is not
  async-signal-safe, so there is no way to ask from in here.

  Else if `pre_child != 0`, it signals that **one** pid and no group —
  `kill(pre_child, SIGTERM)`, the same bounded wait, and then, **only if `!reaped`**,
  `kill(pre_child, SIGKILL)` followed by the blocking reap. If the bounded wait already
  took the child, the handler sends nothing further and reaps nothing further, because
  there is nothing left that belongs to this parent: the pid went back to the kernel at
  that reap, it can be handed to any process on the machine by the next instruction, and
  `kill(pre_child, SIGKILL)` after that is the stale-pid stranger-kill this whole signal
  design exists to close — the same hazard the block-reap-zero-restore shape around every
  main-flow reap closes, arriving here by a different route. A digest tool or a
  `jq --version` is a single short-lived process with no group of its own worth naming, so
  once it has been reaped the branch has nothing left to do.

  Else there is nothing to kill, and the handler kills nothing. In all three
  cases it then writes its one `parent-signal:` line (below) and `_exit(128 + signal)` — in
  that order, killing and reaping before writing anything, for the reason the line's own
  block gives — and that status is the same one the group branch already produced and the
  same number the entry reports (R1).

  **The residual the group branch keeps is stated rather than smoothed over.** A process
  group id outlives its leader: the number stays allocated while any member of the group is
  alive, and the kernel can only recycle it once every member has exited. So
  `kill(-pgid, SIGKILL)` after the leader was reaped is not the single-pid hazard above.
  For the group id to name strangers, the whole group would have to have emptied inside the
  one-second grace window **and** the kernel would have to have handed that exact number to
  a new process that then became a group leader of its own. That is far narrower than the
  single-pid case, and it is not closable from inside a handler at all: closing it needs
  the process-table scan, and the scan is not on the list a handler may call from. **The
  two paths are deliberately different for exactly that reason.** The main flow *does* run
  the scan, and round 31 arranged it so: the three-signal block opened before the reap at
  `:457` stays held across the survivor check at `:460-462` and across the
  `kill(-child, SIGKILL)` and `kill(child, SIGKILL)` at `:491-492`, with `pgid = 0` last
  and the mask restored after it, so the scan runs where no handler can interleave with it.
  The handler is the path that cannot scan, so it trades a much narrower stranger-kill
  window for the guarantee that a surviving resolver group is killed; the main flow trades
  the other way because it is able to.

  **"A brief wait" is not a specification, and this round makes it one, because the wait
  happens inside a signal handler.** Everything between the first `kill` and the `_exit`
  runs in handler context, where the only calls a program may make are the ones POSIX lists
  as async-signal-safe; anything else is undefined behaviour, and the two ways it goes
  wrong are exactly the two ways a termination path must not — a deadlock on a lock the
  interrupted code was already holding, or a corrupted structure in a process that is
  part-way through killing a process group. So the wait is written out here rather than
  left to the plan:

  ```
  reaped = 0;
  for (i = 0; i < 20; i++) {
    if (waitpid(target, &st, WNOHANG) == target) { reaped = 1; break; }
    tv.tv_sec = 0; tv.tv_usec = 50000;
    select(0, NULL, NULL, NULL, &tv);
  }
  ```

  Twenty iterations of a 50 ms `select` with no descriptors in it — about one second in
  all — ending early the moment the reap succeeds. `target` is the child's own pid on both
  branches: `pgid` on the group branch, which is the same number as the leader's pid
  because the parent assigns it from what the `fork` returned, and `pre_child` on the
  other. What differs between the two is not the loop but what follows it, which the two
  branches above state — the group branch sends its `SIGKILL` either way and reaps only
  while `reaped` is `0`, the single-pid branch does neither once `reaped` is `1`. The flag
  is a plain local and needs no `volatile sig_atomic_t`: it is written and read inside one
  handler invocation and never shared with `main`.

  **Both of those calls are on the list, and the list is named here rather than left to be
  looked up.** POSIX.1-2017 (IEEE Std 1003.1-2017, XSH 2.4.3) is the standard this rests
  on, and it carries `select()`, `pselect()`, `poll()`, `sleep()`, `waitpid()`, `kill()`,
  `write()`, `fcntl()`, `sigprocmask()`, `_exit()`, `getpid()`, `getppid()` and `time()` —
  every call this handler makes, its stderr toggle and its `_exit` included. It does
  **not** carry `nanosleep()`, `usleep()` or `snprintf()`. That answers the finding's first
  half directly: `nanosleep` is the obvious way to write a 50 ms wait in C, the copied
  supervisor already has one at `portable-profile-resolution-launcher.c:488`, and a plan
  reaching for that line inside the handler would be reaching for a call POSIX does not
  permit there. The `nanosleep` at `:488` stays exactly where it is — it is in the poll
  loop, in ordinary code, and nothing about this rule reaches it.

  **The platform's own page lists less than that, and the difference is age rather than
  disagreement.** macOS `sigaction(2)` reproduces the POSIX.1-1990 list: `_exit()`,
  `alarm()`, `fcntl()`, `kill()`, `pause()`, `read()`, `sigprocmask()`, `sleep()`, `time()`,
  `waitpid()`, `write()` and the rest of that vintage, with no `select()`, no `pselect()`,
  no `poll()` and no `nanosleep()`. Read as a prohibition it would leave `sleep()` as the
  only wait available on both lists. It is not one — it is the shorter, older list, and the
  standard that supersedes it adds `select()` by name — and this spec says which authority
  it is using rather than letting a reviewer find the two lists and assume a conflict.
  `sleep(1)` is named anyway as the fallback a plan may take if a platform is ever found
  where `select()` in a handler is genuinely unsafe, and the reason it is not the first
  choice is responsiveness rather than safety: `sleep(1)` cannot return early, so every
  interrupt would cost a full second even where the group died at once, while the loop
  above returns as soon as the reap succeeds. Neither shipped file uses `alarm()` or
  `SIGALRM`, so the `sleep()`/`alarm()` interaction POSIX leaves unspecified is not a reason
  for the choice and is not being relied on in either direction.

  **The `parent-signal:` line is assembled without `snprintf`, and both halves are named.**
  The `runtime-pgid:` line below uses one and may, because it is written from `main` and
  not from a handler; the handler's line cannot, and "format it some other way" is not
  enough of an instruction to hand a plan. `<NAME>` comes from a `static const char *`
  table indexed by signal number — three entries, for `SIGINT`, `SIGTERM` and `SIGHUP`, no
  search and no formatting — and the pgid is rendered by a hand-written decimal routine
  into a `static char` buffer: the ordinary divide-by-ten loop that writes the digits
  backwards and reverses them, which calls nothing at all. The two are copied into one
  static buffer and go out in a single `write(2)`. The choice between rendering in the
  handler and pre-rendering the digits under the blocked region at the moment `pgid` is
  assigned is settled here rather than left open: **render in the handler**, because
  pre-rendering means a second piece of handler-visible state to keep in step with `pgid`
  and a second place the clear-to-`0` rule above would have to reach, where the routine
  that avoids it is a dozen lines touching nothing outside their own buffer. `memcpy()` and
  `strlen()` are themselves on the POSIX.1-2017 list — worth saying, because the shorter
  list on the platform's page implies otherwise — so the assembly rests on the same
  authority as the rest of the handler.

  **The rule, for the plan and for the reviewer, in one sentence: every call in the three
  handlers is checked by name against the POSIX.1-2017 list, and `snprintf`, `malloc`,
  `free`, `fprintf`, `printf`, `strerror`, `nanosleep` and `usleep` are forbidden there
  outright.** Six calls are the whole inventory today — `kill`, `waitpid`, `select`,
  `fcntl`, `write` and `_exit` — plus the `memcpy` in the assembly above, and a plan that
  needs a seventh names it and says where on the list it appears. The prohibition is
  written as a list of names rather than as a principle because every one of those is a
  call somebody reaches for by reflex when writing a diagnostic, and the handler is the one
  place in this file where the reflex is wrong.

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
  The handler puts stderr into non-blocking mode for that one write and puts the flags
  back before it leaves — `fcntl(STDERR_FILENO, F_GETFL, 0)` to save them,
  `fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)`, the write, then
  `fcntl(STDERR_FILENO, F_SETFL, flags)` with the saved value, and only then
  `_exit(128 + signal)` — and it emits the line with
  a **single `write(2)` call**, not the copied
  `write_all(STDERR_FILENO, …)` (`portable-profile-resolution-launcher.c:164`) the copied
  file uses for every stderr write of its own, because `write_all` loops until the whole
  buffer is out and on a non-blocking full pipe that loop is a spin rather than a write.
  A short write, an
  `EAGAIN` or an `EPIPE` is ignored — no check of the return value and no retry — so a
  truncated line, or no line at all, is an accepted outcome where a hung termination is
  not.

  **The restore is not optional, and the earlier round that said it was had the wrong model
  of what `F_SETFL` changes.** That round wrote "no restore afterwards because
  `_exit(128 + signal)` follows immediately", which would be sound if the flag belonged to
  the process. It does not. `O_NONBLOCK` is a *file status flag*, and file status flags
  live on the **open file description** — not on the descriptor, and not on the process —
  so the parent, the entry that started it and whatever started the entry are all looking
  at one flag through descriptors of their own. The parent exiting takes its descriptor
  away and leaves the flag exactly as it set it. That matters on this path and nowhere
  else, because stderr here is inherited rather than opened: after the parent exits, the
  entry writes on that same stderr and the caller goes on using it afterwards (R1).

  **Which of those two the argument rests on changed this round, and the weaker half is
  withdrawn rather than quietly kept.** The round that added this restore reached first
  for the entry's own `entry-signal:` line: a flag left set turns that write into a short
  write on a full pipe, so the entry's diagnostic contract is broken by the parent's
  convenience. That example is gone. R1 now has the entry **omit** that line entirely when
  stderr is a pipe, a FIFO or a socket, precisely so a bash `printf` cannot hang on one, so
  a flag the parent left behind cannot truncate a line the entry is no longer writing
  there. What survives is the half that was always the stronger of the two, and it is
  enough on its own: **the caller**. Stderr is the caller's descriptor, handed in and
  handed back; a flag the parent left set turns the caller's own later writes into
  `EAGAIN`s and short writes the moment the pipe is full, and nothing entitles a program
  the caller invoked to change the mode of a descriptor it owns and walk away. R10's pipe
  variant asserts the flag on the test's own `dup` rather than the entry's line for exactly
  this reason, which is why that case needs no rewriting now that the line it might have
  asserted is not written on a pipe at all. So the handler restores, and the restore is
  made **unconditionally, including when the write failed or wrote nothing**, because the
  flag was set whatever the write did; it is the same single `fcntl` either way. It costs
  the termination nothing measurable: `fcntl` on the process's own descriptor neither
  blocks nor forks, and it happens after the killing and the reaping like the write it
  follows. The `runtime-pgid:` write below already restores, and the reason recorded there
  was the narrow one — the parent keeps running on that descriptor. The shared open file
  description is the wider reason, it was the reason all along, and it covers both writes.

  `SIGPIPE` is **ignored**, not blocked: the parent sets it to `SIG_IGN` in the same
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
  parent is waiting for and the cleanup it exists to describe (R1). *Whether* it is written
  at all is the one rule the two halves do not share, and R1 states it: the parent can make
  its write non-blocking and so writes on every kind of stderr, the entry cannot and so
  writes only where a write is incapable of blocking, omitting the line on a pipe, a FIFO
  or a socket. Same guarantee, two languages, one difference in how it is reached.
  What this block adds is
  that a forward landing in the pre-fork
  window now ends cleanly rather than ambiguously: the parent kills at most its own one
  pre-resolver child, then writes `parent-signal: TERM no-runtime`, and exits
  `143`, so the entry's wait returns that status and the caller sees the entry's
  `entry-signal: TERM forwarded <pid>` line beside the parent's `no-runtime` line and an
  exit of `143`. Nothing is left running and no group anywhere was signalled.

  **The parent names the resolver's process group on stderr, so nothing downstream has to
  guess which child is which.** The parent runs children before the resolver — the
  platform's SHA-1 tool for each blob-id pin, its SHA-256 tool for the jq digest, and the
  bound jq for the `--version` probe, each `execve`d with the fixed environment R7
  specifies rather than with the one the parent was handed — so "the parent's child" does
  not identify the
  runtime, and anything picking a process by parentage could pick a digest tool instead.
  Rather than have a reader infer it, the parent reports it. After the `fork`
  (`portable-profile-resolution-launcher.c:432`), the `setpgid(child, child)` the copied
  supervisor already does from the parent side (`:450`), the `pgid` assignment, and the
  `sigprocmask(SIG_SETMASK, &saved, NULL)` that ends the blocked-signal region those three
  sit in — **outside** that region, deliberately, for the reason the region's own block
  gives above, and under a short block of its own, for the reason two blocks below — and
  before it enters the poll loop, the parent writes exactly one line to
  its own stderr:

  ```
  runtime-pgid: <n>
  ```

  `<n>` is the child's pid in decimal, which is also the process group id: the child makes
  itself a group leader with `setpgid(0, 0)` (`:440`) and the parent sets the same thing from
  its side (`:450`), so the group id equals the child pid whichever of those two calls won
  the race, and it is a number the parent already holds.

  **The write is made the same way the handler's `parent-signal:` line is made, and for the
  same reason — with one difference this round names, because it is the only place the two
  lines part company.** It is a `snprintf` into a small buffer and then a **single
  `write(2)`**
  with stderr in non-blocking mode for it: `fcntl(STDERR_FILENO, F_GETFL, 0)` to read the
  flags, `fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)` before the write, and the saved
  flags put back with a second `F_SETFL` after it — the same three calls in the same order
  as the handler's, and for the same two reasons: the parent goes on to supervise a whole
  resolution on that descriptor, and the descriptor is not its own to alter, the flag being
  shared with the entry and the caller through one open file description (above). A short write, an
  `EAGAIN` or an `EPIPE` is ignored: no check of the return value and no retry. `SIGPIPE` is
  already `SIG_IGN` from the first statements of `main` (above), so a closed stderr returns
  `EPIPE` to code that ignores it rather than killing the parent. It is neither the copied
  `write_all(STDERR_FILENO, …)` (`:164`) — which loops until the whole buffer is out, and on
  a non-blocking full pipe that loop is a spin rather than a write — nor a buffered
  `fprintf`, so the line is on the descriptor before the poll loop starts and a reader
  watching stderr sees it while the resolution is still running.

  The `snprintf` is the difference, and it is allowed here for one reason only: this write
  runs in `main`, not in a signal handler, so the async-signal-safe list the handler's line
  is held to (above) does not bind it. A plan must not read the "same way" of this block as
  permission to run the `snprintf` the other direction — the handler's line is assembled
  from a static signal-name table and a hand-written decimal routine precisely because
  `snprintf` is not on that list. Same three `fcntl`/`write` statements, same best-effort
  contract, two different ways of filling the buffer, and the boundary between them is
  which function the code is in.

  **Those calls run with `INT`, `TERM` and `HUP` blocked, and the block is part of the
  sequence rather than a precaution wrapped around it.** The whole write is six statements
  in this order and no other:

  ```
  sigprocmask(SIG_BLOCK, &three, &saved)
  fcntl(STDERR_FILENO, F_GETFL, 0)                    -> flags
  fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)
  write(STDERR_FILENO, buf, len)                      -> ignored
  fcntl(STDERR_FILENO, F_SETFL, flags)
  sigprocmask(SIG_SETMASK, &saved, NULL)
  ```

  The reason is the window between the third statement and the fifth. If one of the three
  signals arrives in there, the handler runs, and the handler's own first act on stderr is
  to read the flags so it can put them back before its `_exit` (above). What it reads is
  the toggled value — `flags | O_NONBLOCK` is what is on the open file description at that
  instant — so it takes the parent's half-finished edit for the original state, restores
  *that*, and exits. The parent's own fifth statement never runs, because the handler does
  not return. The flag the parent set for one line is then left set on a description the
  entry and the caller share, which is precisely the failure the handler's restore exists
  to prevent, arriving by the one route the restore cannot see: the restore is correct
  about what it saved, and what it saved was wrong. Blocking the three across the sequence
  closes it. No handler can run between the set and the restore, so the flags any handler
  saves are always flags the parent was not part-way through changing, and the parent's own
  restore always runs.

  **This does not reintroduce what round 19 fixed, and the difference is which write is
  inside the region.** Round 19 took this line *out* of the fork-publication block for a
  real reason, which that block still states: a `write_all` in there can wait forever on a
  full pipe, and a parent waiting inside a region where no handler can run is a parent that
  never terminates its group. Two things are different here. The write is not that write —
  it is one non-blocking `write(2)` that returns at once with a short count or `EAGAIN`,
  never waiting for a reader, so nothing in these six statements can wait for anything.
  And the region is not that region — the line still stands **outside** the fork block,
  after the `sigprocmask(SIG_SETMASK, …)` that ends it, exactly where round 19 put it;
  what it gains is a second, much shorter block that spans only its own three `fcntl`/
  `write` statements. The rule the two rounds share is worth stating once so a plan does
  not have to infer it from two decisions that look opposed: **no write that can block goes
  inside a blocked-signal region, and no toggle of a shared file status flag goes outside
  one.** Both lines of this component satisfy both halves.

  **The rule is general, and the enumeration behind that claim is written down rather than
  implied.** Every non-handler write the parent makes that toggles stderr's flags gets the
  same six statements. Reading this spec for the three markers — `O_NONBLOCK`, `F_SETFL`
  and a single unchecked `write(2)` — finds exactly two flag-toggling writes in the whole
  parent, and this is the only one of them outside a handler. The other is the handler's
  own `parent-signal:` line, which needs no `sigprocmask` of its own and is already
  covered: each of the three `sigaction` installations carries an `sa_mask` of all three
  signals (above), so the mask is held for the entire handler body, its `F_GETFL`, its
  write and its `F_SETFL` included, and a sibling signal cannot re-enter it mid-toggle.
  Every other stderr write the parent makes changes no flag at all — the `E_*` refusal
  lines, the usage text, and the child's relayed bytes through `sanitized_error`
  (`:118-165`) all go out through the copied `write_all` (`:164`) — so none of them is
  inside this rule, and none of them needs to be. What the rule is for is the next one: a
  plan that adds a flag-toggling diagnostic anywhere in the parent writes it the same six
  ways, and R10 reads for that rather than for this one line.

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
  through — and that holds for the parent's *other* children as well, not only for this
  array: the SHA-1 tool, the SHA-256 tool and the jq probe run before this array exists
  and are `execve`d with the fixed two-variable environment R7 specifies, `environ` being
  handed to nothing the parent starts. The parent closes every inherited descriptor above 0/1/2 twice over: once
  among the first statements of `main`, before it forks anything at all, so no SHA tool
  and no `jq --version` probe can inherit one either (R5), and again in the resolver child
  before `execve`, which is the line of defence this requirement has always named.
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
  named deviation; any file in the parent-pinned set — all eight of the loaded files below,
  which is every file the runtime executes or evaluates, and no others — does not match
  its pinned blob id; the jq at the bound path
  does not match the pinned SHA-256 for the platform or does not answer `jq-1.6`
  (`portable-profile-resolution.test.sh:96-105,112-129`, mirroring
  `shadow/v1/reproduce.sh:113-118`), or is not the run directory's own `jq`; the `awk`
  beside it in that directory is not a regular caller-owned mode-0500 file holding the
  bytes the entry put there — the bound-tool-root block below specifies those last two in
  full; the helper fails the run-directory checks below;
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
  helper, binary, run-directory, jq-identity and awk checks below, for the reason the
  block after this one gives.

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
  parent trusts anything *inside* the run directory: the helper, the compiled parent binary,
  the run-directory mode check, and — since this round — the jq identity comparison and the
  `awk` verification below all run after it, so every one of them is made against an
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
  anywhere after it. The entry sets the same umask (R1), so on the supported path the parent
  inherits 077 and sets it again; the call is there because the parent may not assume it
  was started by the entry, which is the assumption every other check in this requirement
  also declines to make — the boundary statement below says the entry is the only
  *supported* launch and says in the same breath that the parent detects nothing about
  which caller it has.

  **And immediately after that, still before the first `fork`, the parent closes every
  descriptor it inherited above 2.** R3 has always required the parent to close inherited
  descriptors in the resolver child before `execve`, and that requirement stays — but it is
  the last line of defence, not the first, and on its own it is too late. The parent forks
  well before it launches the resolver: a SHA-1 tool per pinned file, the SHA-256 tool for
  the jq, and the `jq --version` probe are all children of the parent, created while the
  pin checks run. Every one of them inherits whatever the caller left open, because
  inheritance across `fork` is the default and the caller's descriptors carry no
  `FD_CLOEXEC` unless the caller set it. The entry closes them on its side (R1), and that
  is not enough, for the reason the boundary statement below gives: the entry is the only
  launch this spec *supports*, and the parent has no way to tell that it was the caller —
  R10's whole group 2 drives the parent directly, no marker the parent could check would
  be out of a caller's reach, and R5 exists precisely because the
  parent must defend itself against a caller rather than trust one. A caller's credential
  file, socket, or write handle outside the output root, inherited by a SHA tool the parent
  forks, is a hole in the same two claims the child-side close protects: no caller state
  reaches a helper (R3), and there is one write root (R7).

  **Descriptors are one of the two things a `fork` hands on that the parent did not choose;
  the environment is the other, and it is closed in R7 rather than here.** The same three
  children, forked in the same window and for the same reasons, would otherwise be
  `execve`d with whatever environment the caller set, which on Darwin is enough to run
  code inside the digest tool that decides whether the pins hold. R7 requires a fixed
  `envp` on every one of those execs and forbids the parent from ever handing `environ` to
  a child. The two fixes are separate statements in separate requirements because they are
  separate mechanisms, and they are named together in both places because either one alone
  leaves "no caller state reaches the parent's children" false.

  So the close goes where it can be checked — among the first statements of `main`, after
  `umask(077)` and after the three `sigaction` installations, before the first pin, the
  first fork and the first creation. The C half has no version of the ordering problem R1
  fixes this round on the entry's side, and it is worth confirming rather than assuming:
  `umask` and `sigaction` are system calls that create no process, `main` is entered with
  nothing forked, and the loop is the parent's own third statement, so there is no
  equivalent of the shell's process substitutions or its re-exec sitting between the start
  of the process and the close (R1):

  1. Enumerate what is actually open. `opendir("/dev/fd")`, then for each entry whose name
     is all digits, `close` that number unless it is 0, 1, 2 or the number the directory
     stream itself holds (`dirfd`), and `closedir` at the end. Nothing else is skipped for
     any reason. If the `opendir` fails, the parent refuses with `E_RUNTIME` and launches
     nothing: this is the one step that knows what the caller left open, and a parent that
     cannot read it cannot make the claim this requirement makes, so it fails closed rather
     than proceeding on a list it does not have.
  2. Then close a range as well, as a belt:
     `for (int fd = 3; fd < ceiling; fd++) (void)close(fd);` — errors ignored, because
     `EBADF` on a descriptor that was never open is the expected answer for most of the
     range and the call has nothing else to report. The ceiling is
     `getrlimit(RLIMIT_NOFILE, &rl)`'s `rl.rlim_max` where that is not `RLIM_INFINITY`,
     and `sysconf(_SC_OPEN_MAX)` otherwise, capped at 65536 so a hostile or absurd limit
     cannot turn this into a long loop. The sweep exists for a `/dev/fd` that lists
     incompletely — a platform where it is absent under a chroot, a partial mount, an
     answer nobody predicted — where step 1 would otherwise come up silently short; the
     cost of having it anyway is a few instructions per descriptor.

  **Neither step is capped at the caller's current soft limit, and an earlier round of this
  spec capped the loop at exactly that.** That round took `sysconf(_SC_OPEN_MAX)` and used
  `rl.rlim_cur` "where it is smaller", reasoning that there is no point spinning over
  descriptors the process cannot hold. The reasoning is wrong about the one case that
  matters. `RLIMIT_NOFILE` bounds the numbers a process may *allocate*; it closes nothing
  that is already open. So a caller opens a descriptor at a high number, lowers `rlim_cur`
  below it, and `exec`s the parent: the descriptor is still open, its number is above the
  new soft limit, and a loop that stopped at `rlim_cur` walks straight past it and leaves
  it inherited by every SHA-1 tool, SHA-256 tool and `jq --version` probe the parent forks
  — this requirement's own claim, made false by two lines of caller setup. So the cap is
  withdrawn. `rlim_max` is the right bound where it is finite, because the hard limit is
  what the caller had to be under to open that descriptor at all and it does not fall when
  `rlim_cur` does; the 65536 on top of it bounds the loop and not the claim, for the same
  reason — a descriptor numbered above 65536 can only exist on a host whose hard limit
  allowed it, and on such a host `rlim_max` is the larger of the two and is the one used.
  And the arithmetic is the belt rather than the guarantee: step 1 closes what is open,
  whatever its number, which is why it is first and why its failure is a refusal. The
  entry's side of this needs no change at all — its loop already enumerates `/dev/fd/*`
  with a glob and never reads a limit, for the reason R1 gives (a shell has no loop cheap
  enough to do it the other way), so the finding reaches the C half only.

  **Why not `closefrom` or `close_range`.** Neither is portable across the two platforms
  this initiative pins. `closefrom(3)` is a BSD interface and is not in glibc on the Linux
  side; `close_range(2)` is Linux-only and needs a kernel and a libc newer than this
  initiative is willing to require. Either would have done both steps above in one call.
  The two portable shapes are what the parent uses instead: `/dev/fd`, which is what the
  entry uses for the same job, and a bounded `close` loop in C. An earlier round of this
  spec used the loop alone and argued the parent "does not need" the directory, because
  reading a path would be the shape R5 spends the rest of its length replacing. That
  argument does not survive the descriptor the loop cannot reach, and it overstated the
  cost: nothing in `/dev/fd` is opened, resolved for content or handed on — the parent
  reads a list of numbers out of it and closes them.

  **What the parent deliberately holds, and why none of it is affected.** Every descriptor
  this requirement keeps open from check to use is opened *after* startup, by the parent
  itself: the output-directory descriptor from the `O_DIRECTORY|O_NOFOLLOW` open, the
  run-directory descriptor from the `openat` on `.run`, and the two `child.stdout` and
  `child.stderr` descriptors the parent creates with `openat(..., O_CREAT | O_EXCL |
  O_NOFOLLOW)` and later reads back through (all in this requirement, above). Both steps
  run before any of them exists, so neither can take one away, and R7's read and write
  lists are unchanged by them. The one descriptor a step must not shut while it is using it
  is the directory stream's own, which is why `dirfd` is on step 1's skip list beside 0, 1
  and 2 — and it is gone before step 2 begins, because `closedir` closes it, so the skip
  costs the claim nothing. Stdin, stdout and stderr are untouched, which is what R6's
  byte-identical stdout and R2's `runtime-pgid:` and `parent-signal:` lines on stderr
  depend on.
  This is an extension of the second named deviation from the copied launcher rather than a
  new one: the launcher has no startup close at all — verified, every one of its
  `close` calls (`:91,102,109,127,424,427,434,441-442,448-449`) and both its `fclose`s
  (`:214,217`) is on a descriptor or stream it
  opened itself, and `closefrom`, `close_range`, `sysconf` and `getrlimit` do not appear in
  its 702 lines — so the deviation that already said the parent closes inherited
  descriptors rather than relying on `O_CLOEXEC` now says it does so at both ends. One
  name in the pair above does appear in the launcher and it is not a startup close:
  `opendir` is there once, on `/proc` in the Linux `process_group_count`
  (`portable-profile-resolution-launcher.c:178`, with its `readdir` at `:193` and its
  `closedir` at `:229`), which R7 already lists among the copied supervisor's
  process-table reads. The parent's `/dev/fd` enumeration is a second use of the same call
  for a different job, and the plan should not read the copied one as precedent for it.

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
  So the set has three owners — the entry, the parent and the library — and which one owns
  what is stated once here and used in
  those words everywhere else in this spec. **The entry pins the git blob id of every
  file in that set** — 1, 2, 3, the five modules of 8, and its own two C sources — as
  constants carrying the same `# pinned at <commit>` header, checked before any compile
  against a blob id the entry computes itself (R1), a mismatch being `E_RUNTIME` before the
  compile. Each of those ten checks is written the way R1 requires of every external
  command in the entry — the digest command's status captured, then `checkpoint`, then the
  refusal on that status, never a `|| refuse` beside the command — so a pin check that a
  terminal `Ctrl-C` killed exits `128 + signal` with an `entry-signal:` line rather than
  reporting a blob mismatch that did not happen. **The parent
  re-pins all eight of the loaded files — 1, 2, 3 and the five modules of 8 — and nothing
  else; call those eight the parent-pinned set.** Files 1, 2 and 3 are reachable from the
  runtime path the parent is handed, using the
  runtime's own `${dir%/resolver/v1}` repository-root rule
  (`resolver/v1/profile-resolve-runtime.sh:9-10`), and a mismatch on any of the eight is
  `E_RUNTIME` before `execve`.

  **The five modules are reachable too, and an earlier round of this spec said they were
  not.** That round's reason was that reaching them needs the generation id and the
  generation id lives in the library, so the parent would have to trust the library to
  find the files whose content it wanted to check. The id does live there and that is not
  an obstacle, because it lives there as a **constant**:
  `PROFILE_RESOLUTION_CORE_GENERATION` and `PROFILE_RESOLUTION_SCHEMA_MAJOR`
  (`scripts/lib/profile-resolution.sh:5,11`) are committed text that nothing computes at
  run time, and the library builds the generation root from them by plain concatenation
  (`:710`). So the parent carries its own copy of both as constants beside its blob pins
  and builds `<repo>/core/v<major>/generations/<generation>/modules/<name>.jq` for the
  five names `contracts.jq:1-5` imports — `schema.jq`, `profile_graph.jq`,
  `stage_request.jq`, `result_facts.jq`, `result_truth.jq` — from the same repository root
  it already derives. It reads nothing out of the library to do it.

  Two of the library's constants therefore appear in the parent as well, and they cannot
  silently disagree with the library's own, because the parent pins file 2's blob id: a
  library whose generation constant has moved is a library with a different blob id, and
  that refusal fires before any module path is built. The two copies are consistent or the
  run is refused, and which one is stale does not matter to the outcome. That is the same
  argument the library's own pins rest on, one level out.

  Every sentence in this spec about a parent blob refusal says "the parent-pinned set (the
  eight loaded files)" and means those eight — the parent now claims the whole set the
  runtime executes or evaluates, and nothing beyond it.

  **The helper is the one thing the parent cannot pin, and that is the whole of what is
  left.** File 9 is a compiled binary: its bytes are whatever this machine's compiler
  produced from the pinned source, they differ between machines of the same platform, and
  no constant in a committed C file can name them — the same reason `.run/awk` is checked
  by byte comparison rather than by a digest pin (below), except that there is no
  host-provided reference copy of the helper to compare against either. So the parent's
  claim on the helper is what it has always been: a regular, non-symlink, caller-owned
  mode-0500 file inside a run directory the parent has proved is the output root's own
  `.run`.

  **The cost of the widening, stated rather than waved at.** The parent runs the platform's
  SHA-1 tool once per pinned file, so it forks eight children where it forked three: five
  more short-lived `execve`s, each under the fixed `PATH=/usr/bin:/bin`, `LC_ALL=C` `envp`
  R7 requires of every child the parent runs, and each inside the block-fork-publish and
  block-reap-zero regions R2 requires — the same shape, five more instances of it. Nothing
  else about them is new: same tool, same `blob <size>\0` header and file bytes written to
  the tool's stdin, same hex comparison, same refusal. Five forks and five reaps on a path
  that already pays three, against a module edit the parent now refuses for itself instead
  of trusting a caller to have been the entry.

  **What a caller who drives the parent directly still loses.** Not a pin any more: files
  1, 2, 3 and the five modules are the parent's own, and files 4 through 7 are covered by
  the library's own blob checks at run time
  (`scripts/lib/profile-resolution.sh:711-714`), which the parent's pin of file 2 is what
  makes trustworthy. What such a caller loses is the helper's **provenance**, and it is
  not a gap the parent can close. Every check the parent makes on the helper is
  satisfiable by a caller who built `.run` themselves: a 0500 helper of their own,
  compiled from anything at all, sitting in a 0500 directory they created inside a 0700
  output root they own. Only the entry establishes where those bytes came from, because
  only the entry compiles the helper from a blob-pinned source into a directory it made a
  moment earlier and tightened before anything else could write there (R1). A binary
  cannot be pinned, so the provenance has to come from the process that made it.

  **So the only supported launch is the entry, and a direct `trusted-launch` invocation is
  a test harness.** The supported way to resolve a profile is
  `resolver/v1/resolve-profile.sh`, under the two invocation forms R1 names and no others.
  Invoking `trusted-launch` directly is the shape R10's group 2 drives to prove the
  parent's own refusals, and it is unsupported for every other purpose: it is not a
  documented interface, not how the operator runs step 7 or takes the Darwin measurement
  (R10 rewrites that recipe around the entry), and not a shortcut for a caller who would
  rather skip the compile. R9's documentation says so, Out of scope records it as a thing
  this initiative deliberately does not provide, and R10's group 2 carries a comment
  saying its cases are the only legitimate user of the shape they drive.

  **The parent does not try to detect direct invocation, and this boundary is documentary
  for that reason.** Anything the parent could test is something the caller controls: a
  variable the entry sets is a variable a caller can set, a marker argument is a word in a
  committed file, a parent-pid or process-group shape is a shape a caller can arrange, and
  a nonce would travel through the same argv the caller writes. This spec has already
  refused that kind of check once, in R1's marker-word paragraph, and refuses it here for
  the same reason: a check a caller can satisfy is theatre, and shipping one would make
  the parent look like it enforced something it does not. What the parent enforces is
  every check in this requirement, on every caller, with no supported-caller fast path
  anywhere in it — which is what keeps it a boundary rather than a second copy of the
  entry's checks that happens to agree with them. What makes the entry the only supported
  launch is the helper provenance the entry alone can give, stated in the shipped
  documentation and in this spec, and the test suite is the boundary statement's only
  legitimate exception.

  The focused test asserts every pinned constant equals the working
  tree's `git hash-object` output — the test may run git, the shipped files may not (R1) —
  so an edit that forgets a pin fails CI rather than
  shipping.

  What this buys, plainly: the trusted set is explicit, finite, and the same set on both
  sides of the boundary — whichever process is asked, the answer for the eight loaded
  files is the committed bytes or nothing. What it costs: any change to
  resolver code moves pins in two files in the same pull request rather than one, and a
  new core generation moves five module pins in each of them plus the generation-id
  constant the parent now carries. That cost is the repository's existing pattern, paid in
  the library today (`scripts/lib/profile-resolution.sh:7-10,711-714`), and it is now paid
  twice over.

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

  **The bound jq must live inside the checked run directory, and the `awk` beside it is
  verified before any fork.** The helper and the compiled parent binary are not the only
  executables in play, because the run directory holds two more and the runtime reaches
  one of them without ever being told its path. `YSTACK_RESOLVER_JQ` is the jq the parent
  hands over (R3), and the runtime derives its whole tool root from that one string:
  `profile_resolution_bound_tool_root=${YSTACK_RESOLVER_JQ%/*}`, then
  `profile_resolution_bound_core_awk="$profile_resolution_bound_tool_root/awk"`, checked
  with `[ -x ]` and `[ ! -L ]` and nothing else
  (`scripts/lib/profile-resolution.sh:673-676`, read and verified), and then executed —
  `"$profile_resolution_bound_core_awk"` is the command word at `:99`, in the function
  that decodes every byte string the resolver writes. The parent's own `PATH` for the
  child is built from the same string, `<dir of the bound jq>:/usr/bin:/bin`
  (`portable-profile-resolution-launcher.c:662-677`). So a caller who invokes
  `trusted-launch` directly can hand the parent a genuine pinned jq 1.6 that happens to
  sit in a directory of the caller's own, and the resolver will execute that directory's
  `awk` — the caller's program, inside the boundary, with every check above satisfied.
  All of those checks are aimed at `.run`; what the parent had not said is that the bound
  jq is in there too.

  Two refusals close it, both before any `fork`:

  - **The jq path argument must be the run directory's own `jq`.** The parent opens
    `openat(run_fd, "jq", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` — `run_fd` being the
    descriptor already proved to be the output root's own `.run` — opens the path it was
    handed with the same flags, `fstat`s both, and requires equal `st_dev` **and**
    `st_ino`. Same mechanism as the `.run` containment check above and for the same
    reason: nothing is resolved twice and no symlink is followed on either side, so an
    equal answer means one object rather than two names that agree at the moment of
    asking. A jq anywhere else is `E_RUNTIME`. The SHA-256 pin and the `jq-1.6` probe
    still run on it — descriptor identity is a further condition, not a replacement for
    either.
  - **`.run/awk` is verified the way the helper is.** Opened
    `openat(run_fd, "awk", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)`, it must be a regular
    file, owned by the current uid, at mode exactly 0500 — the same three facts the
    helper bullet above requires — and its bytes must be the bytes the entry put there.
    The parent needs no digest tool for that and starts no process: it reads both sides
    in full through descriptors it opened, compares the sizes first and then the bytes.
    On Linux the other side is `/usr/bin/awk` itself, opened `O_RDONLY|O_NOFOLLOW`,
    because that is what the entry copied in (`/bin/cp /usr/bin/awk <run>/awk`, R1, R7).
    On Darwin the entry writes a two-line shim instead — `#!/bin/bash` and
    `exec /usr/bin/awk "$@"`, 35 bytes — so the other side is that string, held in the
    parent as a constant, which is the stronger of the two comparisons. It is a byte
    comparison and not a pinned digest for one plain reason: awk's bytes are whatever the
    host's OS build shipped, they differ between machines of the same platform, and a
    constant in a committed C file cannot name them the way the jq digest pin names jq's.

  **Why that closes the hole, in the runtime's own terms.** Once the jq argument is
  proved to be `.run/jq`, the runtime's `${YSTACK_RESOLVER_JQ%/*}` is `.run`, so
  `$profile_resolution_bound_tool_root/awk` is `.run/awk` — the file the parent has just
  read end to end — and `PATH=<.run>:/usr/bin:/bin` names a 0500 directory whose whole
  content is the four files the parent has now checked. There is no fifth entry for a
  `PATH` search to reach, because the output-directory rule admits exactly `.run` and the
  run directory holds exactly those four files and no subdirectory at launch (R1). The
  caller's `awk` is then unreachable by either route, the derived one and the `PATH` one.

  **And the check is the parent's, not the entry's, even though the entry already copies
  both files.** The entry puts the jq and the awk into `.run` and tightens them to 0500
  before it launches anything (R1), so on the supported path neither refusal ever fires.
  They exist for the same reason every other check in this requirement exists: the parent
  does not know which caller started it and does not try to find out. The direct
  `trusted-launch` invocation is unsupported outside R10's group 2 (the boundary statement
  below), and "unsupported" is a statement about what this spec provides, not a refusal the
  parent performs — so every check here has to hold on a caller the documentation told not
  to exist. A contract the parent states has to hold without the
  entry, or the parent is not a boundary — it is a second copy of the entry's checks that
  happens to agree with them.

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
  to close this one — same shape as the `HOME`/`TMPDIR` residual stated just above it. The
  two refusals added just above are inside this residual rather than outside it, and the
  shape is worth saying exactly: they are check-time facts like every other one here, so a
  `.run` swapped out after them takes the jq and the awk with it as surely as it takes the
  helper. What they do buy, which nothing before them did, is that a caller cannot *name* a
  tool root outside the output structure at all — the swap needs write access to the
  caller's own output directory, where handing over a jq from somewhere else needed nothing.

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

  **One thing that claim used to depend on without saying so is the caller's descriptors,
  and this round removes the dependency.** A write root is a claim about where the
  processes in this tree can write, and an inherited descriptor is a place to write that no
  path check can see: a caller who starts the entry, or the parent, with a write handle
  open on descriptor 7 hands every child in the tree a second write root that nothing in
  the lists above mentions. Nothing in this spec reads or writes such a descriptor
  deliberately — but the claim is about what *can* be written, not about what the shipped
  code intends, and a compiler or a `cp` that inherits one is a plausible accident rather
  than a contrived one. Both shipped files now close every inherited descriptor above 2
  before they fork anything (R1 for the entry, R5 for the parent), so the write lists above
  are the whole of it whatever the caller held open, and R10 asserts the closes by
  observation on both files.

  **The entry's half of that claim is stated as "closed or refused" from this round on, and
  never as "silently skipped".** The wording matters because the exception it rules out is
  the one the round before this one actually had. The entry enumerates the descriptors with
  a `/dev/fd/*` glob, and a glob that matches nothing leaves its own word in the list rather
  than producing an empty one — which is what happens to a caller who has filled every
  descriptor number below the soft limit the precondition settles on, because reading a
  directory needs a descriptor too. The round-41 text ran its loop over that one literal
  word, closed nothing, and went on to the scrub, the re-exec, the compiles and the `cp`s
  with the caller's write handle still open and a status of `0` at the end: precisely a
  second write root that the lists above do not mention, preserved by the statement written
  to remove it. R1 now refuses that arrangement outright — one `E_RUNTIME` line and a
  non-zero exit, before the run directory exists and before anything at all is created — and
  R1's raised-first limit ladder narrows the set of callers who reach it. So the claim this
  paragraph makes has two exits and no hole: for the entry, every descriptor above 2 is
  closed, or the entry refuses to run and writes nothing anywhere. The parent's half is
  unaffected: its startup close is a C `/dev/fd` enumeration whose `opendir` failure is
  already an `E_RUNTIME` refusal rather than a fall-through (R5), which is the same
  fail-closed shape arrived at independently a few rounds earlier.

  **That last sentence is exactly true from this round on, and it was not when it was
  written.** The round that moved the entry's close to the top of the file paid for the
  descriptor-headroom precondition standing above it with `nofile=$(ulimit -n)`, and bash
  3.2 forks for a command substitution — so on a supported invocation where the caller held
  a credential, a socket or a write handle on descriptor 7, one short-lived bash child did
  inherit it, for the duration of one builtin, before the close loop ran. The claim was
  being carried with that one-child residual stated in Areas of concern rather than here,
  which is the wrong place for a qualification on a sentence this paragraph makes
  absolutely. This round replaces the precondition with a builtin-only form that *sets* the
  soft limit rather than reading it (R1), so no child of any kind exists between the entry's
  first statement and the last pass of the close loop, and the write-root claim needs no
  qualification at all: nothing in this tree has ever held a descriptor the close did not
  shut first.

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
     **the same eight read again by the parent to be hashed**, which is this round's one
     widening of who reads what rather than of what is read: the parent-pinned set is now
     the whole loaded set and not three of it, so the five module bodies are opened by the
     parent as well as by the entry, at paths the parent builds from its own copies of the
     library's generation-id and schema-major constants (R5)
     (and the runtime file among those eight also mode-checked), the
     remaining four hashed by the library itself at run time (`:711-714`), and all of them
     bar the registry then read by the resolver under the bound `/bin/bash`; the request
     file and the repository-map file named on the command line; the jq binary supplied as
     an argument; `/usr/bin/awk`, read on Linux by **both** shipped files and by neither on
     Darwin — the entry reads it to copy it into the run directory, and the parent reads it
     to compare it byte for byte against the `awk` it finds there (R5), while on Darwin the
     entry writes a two-line shim naming that path and the parent compares against that
     same two-line string held as a constant, so neither opens the host binary at all
     (below); the caller's output directory; and
     the entry's own run directory. `/usr/bin/awk` was the previous round's one widening of
     this list and it is
     a read of a fixed path in the same class as the ones already here, not a new kind of
     read: no content of it leaves the parent, and the only thing the parent does with the
     bytes is compare them. **This round widens nothing at all** — the list of files is the
     same list, and only the column saying which process reads which of them moves, because
     the five modules the entry alone used to hash are now hashed by the parent too. Same
     paths, same one-way use of the bytes, one more reader.

     **The executables, listed exactly.** The previous round's list was short enough to be
     wrong. It named seven — the compiler, `/bin/bash`, `/bin/mkdir`, `/bin/cp`,
     `/bin/chmod`, `/usr/bin/git` and the SHA-256 tool — and left out four the spec's steps
     needed then: `/usr/bin/uname` for the platform case, `/usr/bin/mktemp` for the run
     directory, `/bin/rm` for the cleanup, and `/usr/bin/printf`, which that round put on
     the list for the `E_*` lines — a reason this round withdraws, the refusal lines being
     the builtin's and the external one's job being the data writes named below. It
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
     `/usr/bin/printf`, **for data writes only, never for a refusal line**: the
     `blob %d\0` header bytes it feeds into the SHA-1 pipeline for each pin (R1) and, on
     Darwin, the two-line awk shim text it writes into the run directory. Those two uses
     and no others. Every `E_*` line the entry writes is written with bash's **builtin**
     `printf`, which starts no process — see the boundary note below this list;
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

     **"`/usr/bin/env` is the first external command" is true by construction, and this
     round is what makes it so rather than leaving it to a reading.** Everything above the
     re-exec is builtins and reserved words: the privileged-mode refusal is a `case` and a
     bare `exit 78` that prints nothing at all, the `ulimit` ladder is three builtins, and
     the close loop is a glob, a `case`, a parameter expansion and an `eval` (R1). The two
     refusals in that stretch that *do* write a line — the ladder's and the loop's
     unmatched-glob `case` — write it with the builtin `printf`, which is why the sentence
     holds: an `/usr/bin/printf 'E_RUNTIME\n'` there would be an external command standing
     in front of `env`, which is the boundary this whole ordering exists to give, and it
     would do it on the one path where nothing has been checked yet. So the split in the
     list above is the rule and not a note about it — external `printf` writes data,
     builtin `printf` writes refusals — and it holds below the re-exec too, where the
     external one is available and is still not used for a refusal, so a reader never has
     to work out which side of the boundary a given `E_*` line is on. R10 asserts the
     boundary as an ordering rather than trusting the reading (R1, R7, R10).

     *The parent, `resolver/v1/trusted-launch.c`* — `/bin/bash`, `execve`d with the fixed
     argv R2 gives (`portable-profile-resolution-launcher.c:652-657,701`); the same
     per-platform SHA-1 tool, run once for each of the eight files of the parent-pinned
     set — eight children this round where three ran before, the widening R5 states and
     costs — and
     it needs neither `stat` nor `cat` for that, having the size from its own `fstat` and
     writing the header and the bytes to the tool's stdin itself; the same per-platform
     SHA-256 tool,
     for the jq digest; and the bound jq, for its own `--version` probe. Nothing else. The
     sandbox `home` and `tmp` directories come from `mkdirat(2)` on the descriptor the
     parent checked (R5), not from `mkdir(2)` on a path (`:645-647`) and not from
     `/bin/mkdir`, at the mode they ask for because of the parent's own `umask(077)` (R5);
     and every mode and ownership check is an `fstat` on a descriptor the
     parent opened, not a call to `/usr/bin/stat`.

     **Every one of those three is `execve`d with a fixed environment the parent writes,
     never with the one it was handed.** They run *before* the resolver's clean
     environment exists — R3 builds that array for the resolver child and for nothing
     else — so on the direct-parent path, which R10's group 2 drives and which R5 states
     is supported for that and nothing else, the caller's environment would
     otherwise be standing in front of the eight SHA-1 runs, the SHA-256 tool and the jq
     probe
     at the exact moment the pins decide whether this run is trustworthy. The rule holds on
     the supported path too, and for a reason worth keeping: the entry launches the parent
     under exactly this environment, so the fixed array is what the parent was meant to
     have and not a defence against its own launcher. On Darwin that
     is not a hypothetical: `/usr/bin/shasum` is a perl script — `#!/usr/bin/perl` on its
     first line — so `PERL5LIB` naming a directory the caller controls, or a `PERL5OPT`
     with a `-M` in it, runs the caller's code inside the digest tool before the tool
     reaches its own first statement, and a tool that never digests anything can print
     whatever hex the caller likes. Measured on `Darwin 27.0.0` while this round was
     written: with `PERL5LIB` pointing at a directory holding a four-line `strict.pm` that
     writes a marker to stderr and exits 3, `/usr/bin/shasum -a 1 /dev/null` writes the
     marker and exits 3 where a clean run prints `da39a3ee…` and exits 0; `PERL5OPT=-Mstrict`
     does the same; and the same command under `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C`,
     with both variables still set in the caller's environment, prints the digest and
     exits 0. `LC_ALL` is the quiet half of the same problem — it is these tools' output
     formatting, and the parent compares their stdout as text.

     **The fixed environment is two variables: `PATH=/usr/bin:/bin` and `LC_ALL=C`,
     and nothing else.** That is not a new list; it is exactly the environment the entry
     launches the parent under (`/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C`, R1), so the
     parent hands its children the environment it was meant to have rather than the one it
     happens to have, and on the normal path the two are the same array written twice.
     `TMPDIR` and `HOME`, which R1's compile line carries beside those two, are
     deliberately **not** here, and the reason is worth stating so a plan does not add them
     back for symmetry. R1 already says the parent needs neither: they are on the compile
     line because a compiler writes intermediates and a toolchain reads a home, and these
     three children do neither — a digest written to stdout, of bytes the parent hands the
     tool on stdin or of a file it names, and a
     `--version` that prints one line. The two directories that line names,
     `<output>/.run/tmp` and `<output>/.run/home`, do not exist by the time the parent runs
     at all: the entry removes both before the mode pass (R1). And the parent's own sandbox
     `tmp` and `home` come last in R5's order, after the pin checks, which is load-bearing
     rather than incidental — a refused run leaves the caller's output directory exactly as
     it found it — so pointing `TMPDIR` at them would mean creating them ahead of the
     checks and paying for two variables nothing reads with a weakened refusal. Measured with the
     rest of the block above: the full blob-id pipeline under those two variables, with
     `PERL5LIB` and `PERL5OPT` set in the caller's environment, returns the same forty
     hex digits as `git hash-object`.

     **And the parent hands `environ` to nothing, ever.** Not to these three, not to the
     resolver child, whose array R3 builds from empty, and not to any child a later round
     adds. `execv`, `execvp` and `execlp` — the forms that take the caller's environment
     implicitly — appear nowhere in the file; every exec in it is an `execve` with an array
     the parent wrote, which is also what the copied launcher does at each of its own two
     exec sites (verified: `execve` at `:445` and `:622`, and neither `environ` nor any
     `execv`/`execvp`/`execlp` appears anywhere in its 702 lines). R10 reads the file for
     that and greps it for those four names. This is what makes the claim R3 states and
     R5 leans on true rather than nearly true: **no caller state reaches the parent's
     children.** Descriptors were the other half of it and were closed in R5; the
     environment is this half; together they are the whole of what a `fork` and an `exec`
     would otherwise carry across that the parent did not choose.

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
     either. **This round the parent's source names it too, in one place, and that place
     is not a command either.** It is the string literal the Linux arm of the `.run/awk`
     verification opens `O_RDONLY|O_NOFOLLOW` to read the expected bytes from (R5); the
     Darwin arm names it once more inside the two-line constant it compares against
     instead, which is text the parent reads out of `.run` and never runs, exactly as the
     entry's copy of that text is text the entry writes and never runs. R10's pass 1
     therefore lists the path with the data paths, and the assertion there pins the
     positions rather than only reclassifying the path, because a classification on its
     own would let an accidental `/usr/bin/awk '{print $1}'` in command position through
     the very grep that exists to catch it — and it now pins three positions across two
     files rather than two in one, the C file's occurrences being required to be the
     `open` argument and the constant and never an entry in any `execve` argv.

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
       list entirely and appears only as a file read and named — copied in for the
       runtime's benefit by the entry, and read once more by the parent as the bytes
       `.run/awk` has to match (R5). That comparison starts no process either: the
       parent reads both sides through descriptors it opened and compares sizes and then
       bytes, so this round widens what awk *is* in these two files without putting it
       back among the things either one runs. The paragraph above says where the path may
       stand, and R10's pass 1 and its position assertion are what hold it there.
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
       the scrub is first among the external-facing steps because an `env -i` prefix
       cannot protect the `env` that carries
       it, with only the entry's own three builtins-and-keywords statements ahead of it —
       the `-p` refusal, the `umask` and the descriptor close, none of which runs a
       command (R1). This is a named deviation from the test, and the scrub and re-exec are
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
  the resolver files correctly. **And the documentation says, in both files, that the entry
  is the only supported way to launch this component.** `docs/components.md` names
  `resolver/v1/resolve-profile.sh` as the launch and says that
  `resolver/v1/trusted-launch.c` is not an interface: running the compiled parent without
  the entry is a test harness for `scripts/test/resolver-trusted-launch.test.sh` and is
  unsupported for anything else. It says why in one sentence rather than asserting it — the
  parent can pin every file the runtime loads but cannot pin a compiled binary, so only
  the entry, which compiles the helper from a blob-pinned source into a directory it made
  itself, establishes where the helper's bytes came from (R5). And it says plainly that the
  parent does not detect direct invocation and performs every one of its checks on every
  caller, so a direct run that succeeds is not a supported configuration and is not
  evidence that one exists. The entry's documentation states the two supported
  invocation forms — both of which carry `-p` — says the marker word is not a public entry
  point and that any invocation without `-p`, marker word or not, exits 78 at the entry's
  first statement without doing anything, and
  names the Darwin
  prerequisite: the Command Line Tools must be installed, because the entry compiles with
  `/Library/Developer/CommandLineTools/usr/bin/clang` rather than the `xcrun` shim at
  `/usr/bin/cc`, and refuses `E_RUNTIME` when they are absent (R1). It also states that a
  successful launch prints one informational `runtime-pgid: <n>` line on stderr — best-effort,
  so a caller whose stderr is a pipe it is not draining may not see it (R2) — and that an
  interrupted one prints one `parent-signal: <NAME> group <pgid>` or
  `parent-signal: <NAME> no-runtime` line, and beside it the entry's own `entry-signal:`
  line **only when stderr is a regular file, and no such line at all otherwise — a
  terminal, `/dev/null`, a pipe, a FIFO and a socket all lose it** — the same condition R1
  states and in the same words, because the documentation was the one place that promised the
  line unconditionally and an implementation following R1 would have made it false for
  every piped caller, and now for every caller at a terminal too. It says the plain thing a
  caller needs to do about it — redirect stderr to a file if you want the line — and says
  that the exit status and the parent's own `parent-signal:` line are the record in every
  other case. So the documentation carries the condition rather than the promise, and
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
  id no longer matches its pin; an edited `resolver/v1/trusted-launch.c`, the parent's own
  source, the same way; an edited `scripts/lib/profile-resolution.sh` and an
  edited `resolver/v1/profile-resolution.jq`, same thing; an edited jq module under
  the generation's `modules/` directory, which the entry pins and which the parent pins
  too from this round — so this case proves the entry's copy of that pin, and group 2
  below proves the parent's, where the previous round had nothing to put in group 2 at all
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

  **The edited-`trusted-launch.c` case is this round's, and it carries two assertions the
  other pin cases do not, because it is the only pin whose subject is compiled into the
  thing the entry then trusts.** Every other pin in group 1 guards a file that is read at
  run time; this one guards the source of the parent itself, so a miswired or missing
  check here does not produce a wrong answer, it produces a *different parent*, compiled
  from whatever the caller's tree happened to contain and launched with the entry's
  blessing. The previous round's list left it out and proved only `nofollow-snapshot.c`,
  and the two are not interchangeable: a suite that exercises one of the two C pins says
  nothing about whether the other is wired up at all.

  So the case appends one byte to a copy of `resolver/v1/trusted-launch.c` in the copied
  tree — a newline, so the file would still compile and the refusal can only be the pin — and
  asserts four things. One: the entry exits non-zero with one `E_RUNTIME` line, and that
  line names the parent-source pin rather than some other check, so a case that refused
  for an unrelated reason fails instead of passing. Two: **no compiler ever ran.** From
  the moment `.run` appears until the entry exits, a background poll every few
  milliseconds — the same mechanism the two-umask case already uses to read inside `.run`
  while it exists, and the same `-o` target the group-signal case watches for — requires
  that neither `.run/trusted-launch` nor any object file beside it ever appears. Three:
  the output directory is completely empty afterwards, `.run` included, which is the
  trap's removal. Four: the copied tree's `nofollow-snapshot.c` is untouched by the test,
  so the refusal cannot be the neighbouring pin's.

  Say what the poll can and cannot do, in the same terms as the sampler further down: a
  compiled `trusted-launch` persists inside `.run` from the instant the compiler writes it
  until the trap removes the directory, so any sample in that span sees it, and the span
  on this path is at least the remaining pin checks and the refusal — many samples at a
  few milliseconds each. What it cannot do is prove the absence at instants it did not
  sample. The ordering guarantee itself is R1's — the pin checks all precede both compiles
  — and the reviewer reads it there; this assertion is what fails loudly if a plan
  compiles first and checks afterwards.

  **The parent cannot catch this for itself, which is why the entry has to.** The
  parent-pinned set R5 defines is the eight loaded files, and its own source is not among
  them and cannot be — the widening this round makes to that set does not reach this case
  and could not: the two C sources stay entry-owned however many loaded files the parent
  takes on. By the time the parent runs it *is* the compiled result of that
  source; a check it made would be a check the altered parent performs on itself, with the
  altered constant the same edit could carry. The entry is the last process in the chain
  that sees the source as an input rather than as itself, so this pin is the only place the
  substitution is visible, and this case is the only thing in the suite that proves the
  pin exists.

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
  each for the list below.

  **This group is the only legitimate user of the shape it drives, and the test says so in
  a comment beside the shared fixture builder.** R5 states that the entry is the only
  supported launch and that a direct `trusted-launch` invocation is a test harness and
  nothing else, so these cases are the reason that shape exists at all. The comment says
  the three things a reader needs: the cases exist to prove the parent's own refusals,
  which is the only way to prove them; a hand-built `.run` gives a helper no provenance,
  which is exactly why the shape is unsupported outside this file; and nothing in the
  shipped files detects the difference, so a passing group 2 is not permission for anyone
  else to launch the parent this way.

  - a runtime file whose blob id does not match the pin (one byte changed);
  - a runtime file at mode 0755 instead of 0644, the check the parent takes over from the
    test script (R5);
  - a `scripts/lib/profile-resolution.sh` whose blob id does not match the pin, and a
    `resolver/v1/profile-resolution.jq` whose blob id does not match the pin — the two
    sourced-and-evaluated files that, with the runtime file above, are the first three of
    the parent-pinned set (R5), reached by handing the parent a runtime path inside a copied
    repository tree whose library or jq program has been edited;
  - **an edited jq module under the generation's `modules/` directory** — one byte changed
    in a copy of `schema.jq`, in the same copied tree — which is this round's case and the
    other five names rotated across runs would prove nothing more, so one module is edited
    and the reading covers the loop that walks all five. It is the case the previous round
    could not write, because the modules were entry-owned then and the parent passed them
    without looking; it is here now because R5 widens the parent-pinned set to all eight
    loaded files. Its extra assertion is the one that says the parent found the file by
    itself: the parent is handed nothing but the runtime path, the library in the copied
    tree is *unedited*, and the refusal still names a blob mismatch — so the generation id
    and schema major the parent used to build the module path came from its own constants
    and not from anything it read out of the tree. A sibling case makes the same point from
    the other side: a copied tree whose library has had its `PROFILE_RESOLUTION_CORE_GENERATION`
    constant changed is refused on the *library's* blob pin, before any module path is
    built, which is what keeps the parent's two copies of that constant from drifting
    unnoticed (R5);
  - a jq whose SHA-256 does not match the platform pin;
  - a jq that does not answer `jq-1.6`;
  - **a valid pinned jq that is not the run directory's own.** The run directory is built
    correctly, with its real jq and awk inside it, and the parent is then handed a
    *second* copy of the same jq — the genuine binary, matching the platform's SHA-256 pin
    and answering `jq-1.6` — sitting in a directory of the test's own that also holds an
    executable `awk` the test wrote, a two-line script whose only job is to print a marker
    and exit non-zero. So every check the previous two cases exercise passes and only the
    identity check can refuse. Two assertions: the parent's `E_RUNTIME` line and a non-zero
    exit, before the `fork`, as every case in this group asserts; and the marker **nowhere**
    — not on stdout, not on stderr, not in either capture file — which is what says the
    caller's `awk` never ran rather than only that the run failed. The negative control
    that makes the second assertion mean something is the same fixture's `awk` invoked
    directly by the test before the parent run, which must print the marker, so a marker
    grep that could never match is not mistaken for a pass;
  - **a tampered `.run/awk`.** Everything else is as the entry would leave it, including a
    jq argument that is the run directory's own jq, and the only change is to the awk copy
    inside `.run`: one byte flipped in the Linux copy, and on Darwin a third line added to
    the two-line shim. Refused with the parent's `E_RUNTIME` line and a non-zero exit
    before the `fork`. The case has to relax the 0500 mode to write the file and set it
    back, which is a fixture detail worth naming so nobody reads the case as also testing
    the mode: the mode assertions are the bullets below, and this one is about bytes;
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

  What group 2 also shows, by omission, is the residual R5 states, and the shape of it
  changed this round. **The module gap is gone**: a caller who reaches the parent directly
  now gets all eight loaded files pinned by the parent itself, files 4 through 7 get the
  library's own blob checks at run time (`scripts/lib/profile-resolution.sh:711-714`),
  which the parent's pin of file 2 is what makes worth having, and the edited-module case
  above is the proof — the previous round could only put that case in group 1 and had to
  say why it could not sit here. **What is left by omission is the helper's provenance.**
  Every case in this group builds `.run` by hand, compiles the helper into it and tightens
  it, and the parent accepts that helper on owner, mode and containment alone: no case
  here proves, or could prove, that those bytes came from the pinned source, because
  nothing the parent checks distinguishes them from bytes the fixture chose. That is the
  residual R5 names, and it is also the whole reason the entry is the only supported
  launch — the group proves the parent's refusals and proves, by what it cannot assert,
  why driving the parent this way outside this file is unsupported.

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

  **A third direct-parent run pollutes the variables the parent's *own* helpers read,
  which the two above do not reach.** Everything in that pollution set is aimed at the
  resolver, and R3's array is built from empty before the resolver starts, so a run that
  passes proves the resolver was not reached. The SHA-1 tool, the SHA-256 tool and the jq
  probe are a different question: they are forked while the pins are being checked, long
  before that array exists, and what shields them is the fixed `envp` R7 requires. So the
  case sets `PERL5LIB` to a directory the test builds containing a `strict.pm` that writes
  `YSTACK-PERL-MARKER` to stderr and exits 3, sets `PERL5OPT=-Mstrict` beside it, runs the
  parent directly on the group-2 fixture, and asserts three things: the pin checks all
  passed and the run completed with the clean run's stdout byte for byte; no `E_*` line
  was written; and `YSTACK-PERL-MARKER` appears in nothing the run produced — not stdout,
  not stderr, not `child.stdout` or `child.stderr`. A parent that passed `environ` fails
  the first of those, because a `shasum` that exits 3 without printing a digest is a pin
  that cannot match.

  **That case carries its own negative control, and would be worthless without one.**
  A fixture that is simply inert passes it on every run: the assertion is that a marker
  does *not* appear, and a marker that could never appear satisfies it. So before the
  polluted run, the same function runs `/usr/bin/shasum -a 1 /dev/null` itself, in the
  same shell and under the same two variables, and **requires** the marker on stderr and
  an exit of 3 — if the pollution cannot reach a perl script the test invokes on purpose,
  it proves nothing about one the parent invokes, and the case fails there rather than
  passing later. This was measured before it was specified, on `Darwin 27.0.0`: the
  control fires exactly as described, and the same command under
  `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C` returns `da39a3ee…` with both variables
  still set. On Linux the fixture is a different pair for the same reason the control
  exists — `/usr/bin/sha1sum` is a coreutils binary and reads no perl variable, and
  `/usr/bin/shasum` may not be installed at all — so the Linux arm pollutes with
  `LD_PRELOAD` naming the marker library the loader-variable case already builds, and
  controls it the same way, by running `/usr/bin/sha1sum /dev/null` under that environment
  and requiring a line in the marker file. Its assertion is then the one the platform
  allows honestly: the marker file may hold the parent's own line, because the loader acts
  before `main` and R10 says elsewhere why no test can change that, and it must hold **no**
  line for a SHA tool, for jq, or for the resolver. Neither arm skips; each has a fixture
  that fires on its own platform.

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
  the marker word (R1), and R1 answers that with a refusal — the entry's first statement
  exits 78 unless `$-` carries a `p`, which this round moved from the marker branch to the
  top of the file and which the marker arrival therefore still meets — plus a re-run of
  the scrub behind it. The two halves
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
     equality, and it is written out here because the operator runs it by hand.

     **Every run in this recipe goes through the entry, and this round says so as a rule
     rather than leaving it to the word "resolution".** The operator's measurement is
     `resolver/v1/resolve-profile.sh` with a pinned jq and a fresh empty mode-0700 output
     directory, exactly as a real resolution is run, and nothing in it invokes
     `trusted-launch` directly — not this half, and not half 2 below, which runs the
     compile line alone and launches no parent at all. That matters beyond tidiness: a
     hand-built `.run` gives the helper no provenance (R5), so an operator who drove the
     parent directly would be measuring the Darwin cache behaviour of a launch this spec
     does not support, and the same applies to step 7 by hand, which is the entry with the
     operator's own arguments and not the parent. An earlier round of this spec described
     the direct invocation as something an operator does; R5 now states that the entry is
     the only supported launch, and this recipe is written the same way.

     - Before the entry run, record two things in the per-user temp directory — the
       directory
       `/usr/bin/getconf DARWIN_USER_TEMP_DIR` reports: the state of `xcrun_db` itself,
       which is either *absent* or *present with a size, an mtime and a SHA-1 of its bytes*
       (**absent is a state, not a reason to skip** — a skip there would throw away the
       strongest evidence available), and a listing of the whole directory with each entry's
       name, size and mtime.
     - Run the resolution through the entry. Then record both again.
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
     Nothing here launches the parent: the half compiles and hashes, which is why it can
     borrow group 2's fixture builder without borrowing group 2's unsupported invocation
     (R5).
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
  and that each signal trap body is the two statements R1 fixes — the assign-if-empty and
  `wait_interrupted=1` — and nothing besides: a body carrying only the assignment is the
  one form of this bug a test cannot catch, because the loop it breaks needs a signal
  inside a `wait` to break it. The wait loop's own statement order joins that list for the
  same reason and is read the same way, with the plan quoting the five steps in sequence —
  the flag cleared at the top of the body, the forward of an already-recorded signal above
  the `wait`, the `wait`, the clear-flag break, the `127` break — and the reviewer checking
  that no statement stands between the clear and the loop header and that no `kill` stands
  below the `wait`, since both of the windows those positions close need a signal delivered
  between two adjacent statements (R1). One more line joins that
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

  **A caller's inherited descriptor is closed at startup, and each shipped file gets its
  own case, because each has its own startup.** A descriptor is the other process
  attribute no environment scrub touches (R1, R5), and the failure it guards against is
  silent: a run that is correct in every observable way while a caller's credential,
  socket or write handle sits open inside every child the entry or the parent forks. There
  are eight runs — six on the entry and two on the parent, the entry's fifth and sixth added
  this round — and every one of them except the sixth is built on the same helper, the sixth
  being a refusal with no ordering to observe and saying so where it stands. The test
  makes a fifo in its own scratch, starts a reader
  on it in the background — `/bin/cat > /dev/null`, which returns when every writer has
  closed — opens the write end on descriptor 7, starts the process under test with that
  descriptor inherited, and then **closes its own copy of 7 immediately**, because while
  the test itself holds a writer open the reader can never see end-of-file and the case
  would assert nothing. From that moment the only writer is the process under test and
  whatever it forks, so the reader returning is exactly the event "nobody in that tree
  holds descriptor 7 any more".

  - *The entry half, first run: an unrelated object.* Start the shipped entry on an
    ordinary successful resolution with `7>` the fifo. The assertion is an **ordering**:
    the reader must return before `<output>/.run` appears. The test watches both — the
    reader in the background setting a flag, the output directory polled every few
    milliseconds the way the two-umask case above already polls it — and fails if `.run`
    exists while the reader is still blocked.
    The round-34 condition on the fixture — *the object on descriptor 7 must not be the
    entry's own script* — is **withdrawn with the exception that made it necessary**. The
    loop skips nothing above 2 now, so there is no object a correct implementation is
    required to keep open, and the fixture is free again.
  - *The entry half, second run: the caller's descriptor is the entry script itself,
    opened for writing.* This is the case the round-34 skip would have failed and the
    reason that skip is gone, so it is a run of its own rather than a note. The test
    copies the shipped entry into its own scratch, runs **that copy** so nothing touches
    the file in the repository, and starts it with two descriptors: `7>` the fifo, as
    above, and `8>>` the copy it is running. The append is deliberate and it is safe —
    opening a file for append does not modify it while nothing writes — and it is the
    shape a caller would have if it were, say, logging into the same file it launches.
    Three assertions. The ordering assertion is the one above and is unchanged:
    end-of-file on the fifo before `<output>/.run` appears, which is the observable this
    suite has and a regular file does not give it. The resolution assertion: the run
    completes normally and produces the same profile bytes as the ordinary case, so a
    loop that refused, hung or truncated on the same-file descriptor fails here. And the
    file assertion: the copy's size and SHA-256 are unchanged afterwards, which is what
    catches a close loop that manages to write through the descriptor it is shutting.
    Be exact about what this proves and what it does not. It does not prove descriptor 8
    was closed — no portable observable in this suite can say that about a regular file,
    which is the same limitation the paragraph below gives for looking at a child's open
    descriptors. It proves the entry behaves correctly in the presence of that
    descriptor, and it stands beside the *reading* on R10's proof-by-reading list that
    the loop's `case` has three patterns and no test behind it, which is what actually
    establishes that 8 is shut. Those two together are the whole coverage, and saying so
    is better than an assertion that looks stronger than it is (R1).
  - *The entry half, third and fourth runs: descriptor headroom.* **These two cases are
    rewritten this round, and the thing they set is the change: the fixture lowers the
    caller's *hard* limit, not its soft one.** R1's precondition now sets the soft limit
    to 1024, or to 256, or to 64, rather than reading it and refusing, so a fixture that only lowers
    the soft limit no longer produces scarcity — the entry simply takes the headroom back —
    and a case built that way would assert an ordinary success under a name that promised a
    refusal. Both runs therefore set both numbers, in one line and in this order, in the
    subshell the test launches from: `ulimit -S -n 63; ulimit -H -n 63` for the third run,
    because a bare `ulimit -H -n 63` with the soft limit above it is refused by bash itself
    — measured: `ulimit: open files: cannot modify limit: Invalid argument`, return 1, both
    limits unmoved — and `ulimit -S -n 64; ulimit -H -n 64` for the fourth. With the hard
    limit at 63 the assertions are the three the round-35 case already made: exactly one
    `E_RUNTIME` line on stderr, a non-zero exit, and **an output root that is still
    empty**, with no `<output>/.run` at any point, polled the same way the two-umask case
    polls it. The third of those is the one that matters and is unchanged in what it
    catches: the refusal has to happen before the close loop, which is before the first
    external command, so a plan that puts the precondition anywhere below the loop passes
    the first two assertions and fails this one. The fourth run takes the boundary from the
    other side: with the hard limit at 64 the precondition's first attempt fails, its second
    succeeds, the entry continues with a soft limit of 64 and the same resolution comes out
    byte-identical, so the floor is a floor and not a wall. Both numbers are measured in R1
    — at a hard limit of 63 the entry refuses and closes nothing, at 64 it closes every
    caller descriptor and runs to its end — while the fixture's own two-call shape is
    measured here rather than in R1, being a property of the test's setup (R1, R10).
  - *The entry half, fifth run: the caller has filled the low descriptor numbers.* This is
    the round-42 finding's own fixture and it is a **success** case, which is worth saying
    before the shape, because the decision that ordered this round costed it as a refusal.
    Before it `exec`s the entry the launching subshell opens 253 descriptors on the numbers
    3 through 255 — a `while` loop of `eval "exec $i</dev/null"` that **skips 7**, which the
    shared helper has already opened on the fifo, so the ordering observable still applies —
    with `ulimit -S -n 1024;
    ulimit -H -n 1024` set first so that both limits are 1024 and bash has a number left for
    the entry's own script. Three assertions, and they are the three the first run makes:
    end-of-file on the fifo before `<output>/.run` appears, a run that completes normally,
    and profile bytes identical to the ordinary case. Under R1's limit ladder the first rung
    holds the soft limit at 1024, the glob finds free numbers, and all 253 are shut; under
    the round-41 single cap of 256 the same fixture lowered the limit under a full low range,
    the glob expanded to its own literal, nothing was closed and the run still exited `0` —
    so this case fails on exactly the text the finding names and passes on the ladder. The
    smaller 3-through-200 shape is the same case with a smaller number and is measured in R1
    rather than run twice here (R1, R10).
  - *The entry half, sixth run: the caller has filled every number the entry can normalise
    to.* The refusal side of the same mechanism, and the case that holds the "closed or
    refused" half of R7's boundary. The launching subshell sets `ulimit -S -n 1023;
    ulimit -H -n 1023` and then opens 298 descriptors on 3 through 300. The ladder's first
    rung fails against the hard limit, its second succeeds and lowers the soft limit to 256,
    every number below 256 is occupied, and the glob's own `opendir` therefore fails and
    leaves the literal `/dev/fd/*` as the loop's single word. Three assertions, the same
    three the hard-limit-63 case makes and for the same reason: an `E_RUNTIME` line on
    stderr, a non-zero exit, and **an output root that is still empty**, with no
    `<output>/.run` at any point. Two notes on what the assertions may and may not say, both
    measured in R1 rather than guessed. The stderr assertion is *an* `E_RUNTIME` line and
    not *exactly one line*: on a table this full bash cannot save a descriptor to perform
    `>&2` and writes one `redirection error: cannot duplicate fd` line of its own beside the
    refusal, so the case greps for the `E_RUNTIME` line and requires no second `E_RUNTIME`,
    where the hard-limit-63 case can still demand exactly one. And the numbers are the
    fixture rather than the rule — 1023 and 300 are chosen because the second rung lowers
    only from above 256 and only when the hard limit is under 1024, which is the narrow
    window R1 names; a plan that changes the ladder's rungs changes these two numbers with
    it, and the comment beside the case says so. This is the one run in the group that does
    **not** use the fifo-and-reader helper, and the omission is deliberate rather than an
    oversight: there is no ordering to observe when the entry refuses before its first
    external command, so the helper would start a reader that only ever sees the entry exit.
    It sits in this group because it is the same mechanism from the other side (R1, R10).
  - *The parent half, one run.* Build a run directory by hand with the group-2 fixture
    builder and invoke the parent directly with `7>` the same kind of fifo, with its stderr in a file
    the test can read. The assertion is the same shape against the parent's own first
    observable: the reader must return before the `runtime-pgid:` line appears in that
    file.
  - *The parent half, second run: a high descriptor under a lowered soft limit.* The same
    fixture and the same fifo, with two changes the test makes in the subshell it launches
    from, **in this order**: the write end is opened on **descriptor 300** rather than 7,
    and only then `ulimit -S -n 64` lowers the soft limit under it. That order is the whole
    fixture — `RLIMIT_NOFILE` bounds new allocations and closes nothing already open, so
    300 stays open and its number is now above the limit the parent reads — and it is the
    caller shape the round-39 finding describes. The assertion is the one above, unchanged:
    end-of-file on the fifo before the `runtime-pgid:` line appears in the parent's stderr
    file. A parent that took `rlim_cur` as its ceiling walks past 300, and the reader stays
    blocked until the resolver exits, which is long after the line — so this case fails on
    exactly the implementation the finding names and passes on the two-step close R5
    specifies. Two fixture notes, both worth stating rather than rediscovering: `ulimit -S`
    and not plain `ulimit`, because the hard limit has to stay where it was — it is what
    made 300 openable, and it is the parent's own ceiling for the second sweep; and 64 is
    the same floor R4 already gives the resolver child, so nothing downstream is starved by
    it.

  **Why the ordering and not the descriptor itself is what gets asserted.** The obvious
  test — look at the child's open descriptors — is not portable between the two platforms
  (`/proc/<pid>/fd` on Linux, `lsof` on Darwin, and neither is on R7's allowlist for the
  suite to depend on), and it is a sample: it can only say the descriptor was shut by the
  time somebody looked. The EOF-before-marker observation needs no such tool, because the
  kernel does the reporting, and it answers the question the finding actually asks, which
  is *when*. Every implementation closes the descriptor eventually — process exit closes
  everything — so a case that only checks "EOF arrives" passes on the bug. What
  distinguishes a startup close from an exit close is that the EOF arrives while the
  process is demonstrably still working, and `.run` and the `runtime-pgid:` line are the
  two cheapest proofs of "still working" each file has: one is created by the entry's first
  external command, the other is written by the parent after it has forked the resolver.
  Be exact about what each half proves. The entry half is tight: `.run` comes from
  `/bin/mkdir`, so EOF before it means the close preceded the entry's first fork of
  anything, which is the requirement in R1 word for word. That sentence took two rounds to
  become true and the case is unchanged for either of them. With the loop where round 30
  put it, the scrub's two process substitutions forked before the close, and the reader
  would still have seen EOF before `.run` as soon as those short-lived children exited — a
  pass on the bug; round 35 moved the close above the scrub and fixed that, but paid for it
  with a precondition whose command substitution forked one child of its own above the
  close, so "the entry's first fork of anything" was still one fork short of what the case
  could see. Round 41 takes that fork out (R1). The close now precedes every fork and every
  `exec` the entry performs, with nothing above it that forks at all, so what the case
  observes and what R1 requires are finally the same statement. The parent
  half is looser, and
  says so: `runtime-pgid:` is written after the resolver fork, which is well after the SHA
  tools and the jq probe, so the case proves the close happened before the resolver
  inherited anything and leaves "before the *first* fork" to the read of `main`'s opening
  statements in the read-and-check sequence below. A tighter parent marker would need a
  new line on stderr written between the close and the first pin, and this spec does not
  add an observable to the shipped parent for a test's convenience.

  The negative control is what makes both halves meaningful and it was measured while this
  round was written, not assumed: with no startup close, a shell that forks a helper and
  exits leaves the reader blocked until the *helper* exits — the descriptor outlives the
  process that inherited it, which is the finding in one observation.

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
  rather than inferring it, and it does so **without sampling a pid**. From the first
  signal until the entry exits it polls, every few milliseconds, two facts together:
  whether `<output>/.run` exists, and whether the parent's own
  `parent-signal: TERM group <pgid>` line has yet appeared in the stderr file this case
  already redirects the entry's output to. A sample that finds `.run` gone with no
  `parent-signal:` line written is a failure, and the case fails on the first such sample
  rather than at the end.

  **The line is the right marker because the parent cannot write it early.** R2 fixes it
  after the group `SIGTERM`, the wait and the group `SIGKILL`, after the reap, and
  immediately before the handler's `_exit` — so its absence is proof the parent has not
  finished, and the bug this case exists for leaves it absent for as long as the `SIGKILL`
  sequence takes, which is hundreds of milliseconds here and so tens of samples wide at a
  few milliseconds each. Its presence does not prove the parent has exited, and the
  sampler does not need it to: the only combination it fails on is the removal happening
  with the line still unwritten. The line cannot be lost to a full pipe either, for the
  same reason the `runtime-pgid:` poll is safe in the mid-run case — this case's stderr is
  a plain file, where a write can neither block nor return `EAGAIN` (R2, R1).

  **An earlier round of this spec polled `kill -0 <parent pid>` instead, and that has to
  go for the same reason R1 takes it out of the entry's loop.** The pid the sampler would
  poll is a grandchild of the test and a child of the entry, so the entry's own bash reaps
  it, and from that instant the number can belong to any other process on the machine. The
  ordering the sampler watches for puts the removal *after* that reap — the wait returns,
  the loop breaks, the `EXIT` trap unlinks — so the one sample that matters is taken in
  exactly the window where the pid is no longer the parent's. A `kill -0` answering there
  is a stranger answering, and the case would report the ordering bug it is named for on
  an implementation that has it right. The pid cross-check that used to sit beside the
  poll — the polled pid against the pid in the `entry-signal: TERM forwarded <pid>` line —
  goes with it, because there is no longer a polled pid to check; the `entry-signal:` line
  is still asserted, by assertion five below. Say plainly what a sampler can and cannot
  do: it can catch an entry that exits on the second wait, and it cannot prove the
  ordering at instants it did not sample. The
  guarantee itself comes from R1's loop, which a reviewer reads; this assertion is what
  fails loudly if a plan writes two `wait` calls instead.

  **Five: exactly one `entry-signal:` line, and it names the first signal.** The entry's
  stderr, read from the plain file this case already redirects it to, holds one
  `entry-signal:` line and no more, and that line is `entry-signal: TERM forwarded <pid>`
  in both the repeated-`TERM` run and the `TERM`-then-`INT` variant — `TERM` in the
  variant too, because the traps keep the first name (R1). Nothing asserts what became of
  the second signal, because nothing observable should depend on it: the entry does not
  re-forward it and does not record it, and R1 says so in those words.

  **The job-table check R1 adds this round changes nothing this case asserts, and that is
  worth saying rather than leaving to be rediscovered.** The word `forwarded` in that line
  is now conditional on `$(jobs -l)` listing the parent as `Running` at the moment the
  loop asks — the pass after the wait a signal cut short, which is where this round's
  reordering puts the question — and in this case it always is: the parent is alive and inside its
  `SIGTERM`-then-`SIGKILL` sequence against a group that has been `SIGSTOP`ped, which is
  the slowest window this whole requirement has, and the case does not even signal until it
  has read the parent's `runtime-pgid:` line. So the line still reads
  `entry-signal: TERM forwarded <pid>`, and an implementation that gates the forward
  correctly passes this case exactly as one that does not. The case the gate exists for is
  the coincidence, where the parent exits on its own at the instant a signal lands, and no
  test is written for it for the reason R1's measurement gives: provoking it needs the
  signal to land inside a window a few instructions wide, so a case aimed at it would pass
  by missing. That one is proved by reading, alongside the fork and reap windows the
  read-and-check sequence below already covers.

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
  parent**.

  **That sharing is not automatic, and this case turns job control off to get it.** The
  sentinel only detects an accidental `kill(0, …)` or `kill(-0, …)` if the parent's own
  group is the group the sentinel is in; a sentinel somewhere else survives a handler that
  signals its group by mistake, and the assertion that earns this case would pass on the
  bug it exists to catch. Bash's default for a background job is the wrong one here:
  with monitor mode on, each `&` gets a **new** process group of its own, so the parent and
  the sentinel would sit in two different groups and neither would be the test's. That was
  measured on the same bash 3.2 as R1's loop — with `set -m`, two background `sleep`s
  reported pgids `58405` and `58406` against a shell pgid of `58393`; with `set +m`, both
  reported `58393`. So **this case runs with `set +m`, stated here rather than left to the
  plan**, and it states it because two of the entry-side signal cases above deliberately do
  the opposite. Monitor mode is left on for the repeated-signal case and the group-signal
  case, which need exactly the behaviour this case must not have: a group of the entry's
  own to aim `kill -TERM -<pgid>` at without hitting the test's shell. The stopped-parent
  case signals the parent by pid only, so it needs no group of its own and can afford to
  share one — and must.

  **The sharing is asserted, not assumed.** Before it sends the first signal, the test
  requires `ps -o pgid= -p <parent>` and `ps -o pgid= -p <sentinel>` to be equal, and to
  equal the test shell's own group; a mismatch fails the case immediately with a message
  saying the sentinel was in the wrong group, rather than letting the run reach assertion
  three and report a pass. That check is what keeps the case honest if a future edit adds a
  `set -m` above it, or if the plan starts the sentinel through some wrapper that changes
  its group. The sentinel is the only one in this test, and the two `set -m` cases above
  are the only other places job control is touched; all three were read against this same
  question this round, and the two that keep `set -m` have no sentinel to strand.

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
  block — the `runtime-pgid:` write above all — sits inside one with it (R2). **The count
  is part of that reading**: eleven forks, the resolver's and the ten pre-resolver
  children's — a SHA-1 tool for each of the eight files of the parent-pinned set, the
  SHA-256 tool and the jq probe — so a file with the five module-hash forks outside the
  pattern fails this reading by arithmetic rather than by judgement. **The reaps
  are checked the same way, and belong on the same list.** The reviewer reads that every
  `waitpid` on a tracked id — each pre-resolver child's, and the supervisor's `:457`,
  `:493-494` and `:451-452` — sits inside a
  `sigprocmask(SIG_BLOCK, …)`/`sigprocmask(SIG_SETMASK, …)` pair that also sets that id to
  `0` before the restore, and that no `kill` anywhere after that clear names the old
  `pgid`. On the resolver's two cleanup paths the same reading has one more thing to
  confirm, and it is the ordering rather than the pair: that the block opened before
  `:457` is still held across the survivor check at `:460-462` and across the
  `kill(-child, SIGKILL)`/`kill(child, SIGKILL)` at `:491-492` and the wait at `:493-494`
  that a positive scan reaches, with `pgid = 0` after all of it and the restore after
  that — and the same on the limit path, which enters at `:491` — so that no arrangement
  of those statements leaves a handler able to read `0` while the group is still there
  (R2). A
  test cannot do better here than it can on the fork window, and for a harder reason: the
  failure needs the kernel to hand the reaped pid to some other process on the machine at
  the instant a signal arrives, which nothing a test script can do makes happen, so a case
  aimed at it would pass by missing. Proof by reading, and no flaky case pretending
  otherwise (R2). The same
  reading covers the handler installations themselves, and for the same reason: the
  reviewer checks that all three `sigaction` calls set `sa_mask` to `SIGINT`, `SIGTERM` and
  `SIGHUP` and leave `SA_RESTART` unset, because a sibling signal re-entering a handler
  that is part-way through the kill and the reap is the other way this state can be raced,
  and no test can put one there on demand either (R2). The six
  signal cases above
  are unchanged by the mask and must still pass exactly as written, which is the other
  half of the check: the mask changes *when* a pending signal is delivered, never which
  branch the handler takes once it runs.

  **Three more lines join that list this round, two of them positions and one of them a
  guard.** The reviewer reads, in the parent, that the startup close — the `/dev/fd`
  enumeration and the range sweep behind it since round 39, a bare `close` loop when this
  line was written — sits among the opening statements of `main` — after `umask(077)` and the three
  `sigaction` calls, before the first pin check and therefore before the first `fork` —
  because the descriptor case above proves the close precedes the *resolver* fork and
  leaves the pre-resolver forks to this reading (R5). In the entry, the same reader checks
  that the `/dev/fd/*` close loop sits after the `case $-` refusal and `umask 077` and
  before the first external command, with the all-digits test ahead of its `eval` and 0, 1
  and 2 skipped (R1) — and, this round, that it also precedes the copied scrub's first
  process substitution and the `exec /usr/bin/env` of the re-exec, which is the position
  the round-30 wording allowed a plan to get wrong while still satisfying every word of
  it; the
  entry-side descriptor case does bound this one by observation, and the reading is what
  catches a plan that keeps the loop and moves it. **Two joined it there the round before this
  one and both are replaced this round, because the thing to read changed.** Those two
  were the reference open on descriptor 3 and the `-ef /dev/fd/3` skip; R1 withdraws both,
  so reading for them would now fail a correct implementation. What the reviewer reads
  instead is the absence: that the loop's `case` arm is exactly `''|*[!0-9]*|0|1|2` —
  three patterns for the caller's three descriptors and two for junk, **no fourth number
  and no test of any kind behind the arm** — because any skip at all is a descriptor that
  reaches the re-exec and every child below, and `-ef` in particular cannot tell a
  caller's read-only handle on the entry script from a write handle on it. This is the
  reading that covers descriptor 8 in the same-file case above, which no assertion there
  can reach. **One line joins this entry rather than contradicting it this round, and the
  distinction is the point of reading it.** The loop's body now opens with a *separate*
  `case` on the unstripped word — `case $fd in '/dev/fd/*') printf 'E_RUNTIME\n' >&2;
  exit 1 ;; esac` — and the reviewer checks three things about it: that it is its own
  statement above the `fd=${fd##*/}` and not a fourth pattern added to the all-digits arm,
  which would be the skip this list exists to forbid; that its body refuses and exits rather
  than `continue`-ing, since a `continue` on the unmatched glob is the round-41 behaviour
  under a different spelling; and that the `*` inside the pattern is **quoted**, because
  unquoted it is a wildcard that matches every real descriptor path and would refuse every
  run. That last one is a grep as much as a reading and it is the kind of quoting a later
  editor removes as noise. The sixth descriptor run above bounds this by observation for one
  fixture; the reading is what covers the shape, and the two together are why R1 can claim
  "closed or refused" with no third outcome (R1). And the reviewer reads that the headroom
  precondition stands between
  `umask 077` and the loop, and that it is the one-line builtin-only form R1 specifies —
  `ulimit -S -n 1024 2>/dev/null || ulimit -S -n 256 2>/dev/null || ulimit -S -n 64
  2>/dev/null` and then the refusal, three rungs in descending order with the largest first
  so the entry raises where it can rather than cutting itself down, and with
  **no command substitution, no process substitution and no external word anywhere above
  the loop** — because a loop that runs without the precondition shuts the descriptor bash
  reads the script from in an environment where bash cannot relocate, and the failure that
  follows is a *silent* truncation with exit status `0` that no assertion in this suite
  would catch: every case here reads output or a status, and the truncated entry produces
  neither an error nor a diagnostic. The absence of a substitution is on this list for a
  second reason and is this round's addition to it: a child forked above the loop inherits
  exactly the descriptors the loop exists to shut, which is a hole in R7's write-root claim
  rather than in R1's, and no case in this suite can see a child that runs one builtin and
  exits. The hard-limit-63 case above bounds the refusal by observation; what the reading
  adds is the *position*, which that case can only bound from one side, and the *shape*,
  which it cannot bound at all. And the same reader
  checks that the `2>/dev/null` is on the loop's `eval` and not inside the quoted `exec`
  — the same two characters on an `exec` with
  no command point the shell's own stderr at `/dev/null` for the rest of the run, taking
  every `E_*` line below with it. That one is a grep as much as a reading, and it is on
  the list because it is the kind of line a plan moves while tidying up a stray error
  message (R1). And in the entry's wait loop, the
  reviewer checks that the only `kill` is inside the
  `case " $(jobs -l) " in *" $parent_pid Running"*)` arm, that the not-interrupted branch
  breaks without forwarding, and that no `kill -0` on `parent_pid` has come back anywhere
  (R1). **Two more join the list this round, both in the parent, and both are things a
  grep settles in a line.** The reviewer reads that each of the three `sigaction` handlers
  ends `fcntl(F_GETFL)`, `fcntl(F_SETFL, flags | O_NONBLOCK)`, one `write(2)`,
  `fcntl(F_SETFL, flags)`, `_exit` — the restore unconditional, ahead of the `_exit`, and
  not inside any branch on what the write returned — because the pipe variant above proves
  the flag is clear after a `TERM` and this reading is what covers `INT` and `HUP`, which
  have no variant of their own and cannot earn one: a third and fourth copy of the same
  case would measure the same statement. And the reviewer greps the file for `environ`,
  `execv`, `execvp` and `execlp`, requiring no hit on any of the four, and reads that each
  `execve` in it is given an array the parent built — the two-variable one for the SHA
  tools and the jq probe, R3's for the resolver child (R7). That one is on the list rather
  than in a case because the polluted-helper case above can only prove the variables it
  thought to set, where the grep covers the ones nobody has thought of yet.
  **One more joins the list this round, and it is six consecutive statements in one
  function.** The reviewer reads that the parent's `runtime-pgid:` write is
  `sigprocmask(SIG_BLOCK, …)`, `fcntl(F_GETFL)`, `fcntl(F_SETFL, flags | O_NONBLOCK)`, one
  `write(2)`, `fcntl(F_SETFL, flags)`, `sigprocmask(SIG_SETMASK, …)` in that order, with
  nothing between the block and the restore that can wait on anything, and that the whole
  sequence still stands *after* the fork region's own `sigprocmask(SIG_SETMASK, …)` rather
  than back inside it (R2). It is a reading and not a case for the same reason the fork
  and reap windows are: the failure needs a signal delivered in the few instructions
  between two `fcntl`s, so a case aimed at it would pass by missing. The reviewer also
  checks the rule behind it holds for the file as a whole — that the handler's own toggle
  needs no `sigprocmask` because `sa_mask` already covers it, and that no other write in
  the parent touches `F_SETFL` at all.
  **One more joins the list this round, and it is a list of names rather than a sequence.**
  The reviewer takes every call appearing in the three handler bodies and checks each
  against the POSIX.1-2017 async-signal-safe list (R2), which today should find exactly
  `kill`, `waitpid`, `select`, `fcntl`, `write`, `_exit` and the `memcpy` of the
  `parent-signal:` assembly and nothing else; and greps the handler bodies for `snprintf`,
  `malloc`, `free`, `fprintf`, `printf`, `strerror`, `nanosleep` and `usleep`, requiring no
  hit on any of the eight. It is a reading rather than a case for a reason worth stating
  plainly: undefined behaviour in a handler is not an outcome a test can provoke on demand,
  and the two failures it produces — a deadlock in the middle of a termination, or a
  corrupted allocator in a process that is killing a process group — would show up in this
  suite as a flake, so a case aimed at them would pass almost every time on the bug. The
  grep for the eight names is what actually holds the property. Its one false-positive risk
  is named so the reviewer does not widen it: `snprintf` is legitimate in the parent's
  `runtime-pgid:` write and `nanosleep` is legitimate in the copied poll loop at `:488`, so
  the grep is scoped to the handler bodies and not to the file (R2).
  **One more joins the list this round, and it is four lines inside those same bodies.**
  The reviewer reads that the bounded wait sets a `reaped` flag when its `waitpid` returns
  the target, and then that the two branches spend the flag differently: on the single-pid
  branch the `kill(pre_child, SIGKILL)` and the blocking `waitpid` after the loop both sit
  inside an `if (!reaped)`, and on the group branch the `kill(-pgid, SIGKILL)` sits
  **outside** any such guard with only the blocking reap inside one. Both halves are the
  check, in opposite directions: a guard missing from the single-pid branch signals a pid
  the handler has already given back, and a guard wrongly added to the group branch leaves
  a surviving resolver group alive. Neither is a case, for the reason the reaps above are
  not — the failure needs the kernel to hand the reaped pid to another process in the few
  instructions between the loop's `waitpid` and the `kill`, which nothing a test script
  can arrange, so a case aimed at it would pass by missing (R2).
  **Two more join the list this round, both in the parent, and both are about order rather
  than content.** The reviewer reads that the startup close is the `/dev/fd` enumeration
  *first* and the range sweep second, that the enumeration's failure is an `E_RUNTIME`
  refusal and not a fall-through to the sweep, that its only skips are 0, 1, 2 and `dirfd`,
  and that `rlim_cur` appears nowhere in either ceiling — a grep for the name settling the
  last of those in a line. The fd-300 case above bounds this by observation for one
  descriptor number; the reading is what covers the enumeration being first and the refusal
  existing at all, neither of which any case in this suite reaches, since a `/dev/fd` that
  cannot be opened is not a state a test script can arrange on either platform. And the
  reviewer reads that the jq-identity and `.run/awk` checks stand before the first `fork` —
  in the same run of statements as the helper and run-directory checks, after the
  output-directory identity comparison and before the sandbox creation — and that the awk
  byte comparison is two `read` loops and a `memcmp` with no `fork`, no `posix_spawn` and
  no `system` in it. The group-2 cases above prove both refusals fire; what the reading adds
  is that they fire on the right side of the launch, which is the half a refusing case
  cannot distinguish from a refusal that happens to arrive later (R5).
  The `kill -0` reading is on this list for the same reason the reaps are: the failure needs
  a signal to land in the instant between a reaping `wait` and the next statement, and a
  case aimed at it would pass by missing — R1's sixty-attempt coincidence measurement is
  how the behaviour was established, and it is a measurement of the design rather than a
  case in the suite.

  **The same is true of the diagnostics moving after the cleanup, and each of the six
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
  why that last-position write cannot hang here at all, and why the
  line is written in this case rather than omitted, a regular file being the one kind
  R1's condition admits — the only kind, since this round narrowed it from three (R1).
  That is true of every case above that asserts
  the line, all of which redirect the entry's stderr into a plain file in the test's own
  scratch; the choice was made for readability and now carries a second load, which is
  stated here rather than left for someone to discover by moving one of them onto a pipe.
  The new full-pipe case below is the deliberate opposite and asserts the absence. The group-signal case added
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

  **The mid-run case gains one assertion this round, in a variant of its own, and it is
  about the flags rather than about the line.** The obvious test for the handler's restore
  is to put the run's stderr on a pipe and check that the entry's `entry-signal:` line
  arrives whole — and it is the wrong test twice over. On a pipe nobody has filled, a line
  that short leaves in one atomic write whether `O_NONBLOCK` is set or not, so the case
  would pass on the broken parent as readily as on the fixed one: it would pass by missing,
  which this section refuses everywhere else. Asserting the same thing on the case's
  existing plain file is worse, because regular files ignore `O_NONBLOCK` altogether — the
  flag can be left set all day and nothing observable changes, which is also the honest
  reason this bug survived the suite it already has. What *is* measurable is the flag, and
  the reason it is measurable is the reason the bug matters: the flag is not the parent's
  to leave, it lives on the open file description, and the test can be holding that same
  description itself.

  So the variant reruns the mid-run case's body with the run's stderr on a pipe the test
  made, keeps a `dup` of the write end for itself — the same open file description it
  handed the run, not a second `open` of the same object, which is the entire point — and
  leaves a background reader on the read end so nothing ever fills. After the run has
  exited `143` and the case's three existing assertions have passed, the test reads the
  flags back off its own `dup` with a small C probe it compiles beside the marker library
  (an `fcntl(3, F_GETFL, 0)`, a `nonblock`-or-`clear` line on stdout, exit 0) and requires
  `clear`. Nothing here is a race: a parent that leaves the flag set fails this on every
  run and on both platforms, because the flag outlives the process that set it. That was
  checked before it was written down — a stand-in child that sets `O_NONBLOCK` on an
  inherited pipe write end, writes one line and `_exit`s leaves the flag set on the
  surviving `dup`, measured on `Darwin 27.0.0`. The variant asserts nothing else: the
  `runtime-pgid:` read, the `SIGSTOP` freeze and the group assertions stay on the
  plain-file variant they already work on, where a non-blocking write can neither block
  nor fail. Its assertion is untouched by R1's omission rule this round, and that was
  checked rather than assumed: the variant asserts the *flag* on the test's own `dup`, not
  a line, so the entry writing no `entry-signal:` line into that pipe changes nothing it
  looks at.

  **A sixth signal case puts the entry's stderr on a full pipe, and it is the case that
  proves the omission rule rather than the line.** R1 has the entry omit its
  `entry-signal:` line when stderr is a pipe, a FIFO or a socket, because a bash `printf`
  into an undrained pipe never returns and the entry would then never reach the
  `128 + signal` exit that is the actual promise. A case is owed for that, and it has to
  be the hostile version: a pipe nobody reads *and that is already full*, because an empty
  pipe takes a short line without blocking and would pass on the broken entry as readily
  as on the fixed one — the same trap the pipe variant above avoids, in the other
  direction.

  **The filler has to be a blocking writer, and the `O_NONBLOCK` filler this spec used to
  name is withdrawn this round, because it broke the very case it was setting up.** That
  filler set `O_NONBLOCK` on its own copy of the write end and wrote until `EAGAIN`. A copy
  of a descriptor shares the open file description, and `O_NONBLOCK` lives on the
  description and not on the copy — so the filler handed the entry a *non-blocking* stderr,
  and an unconditional `printf` into a full non-blocking pipe fails fast with `EAGAIN`
  instead of hanging. The case would then have passed on an entry that never omitted the
  diagnostic at all: pass by missing, in the one place in this section that exists to catch
  the write. That was measured rather than reasoned about. On `Darwin 27.0.0` that filler
  reports `filled 65536 bytes, then EAGAIN` and leaves the `fcntl` probe reading
  `nonblock` on the write end the test still holds, and a `/bin/bash -c 'printf … >&2'` on
  that descriptor comes back with a failing `printf` status immediately and runs straight
  on to its `exit 143` — no wait at all.

  So the test fills the pipe with a writer that **blocks**, and sets no flag on anything.
  It makes the pipe, keeps the read end open and never reads it, and starts a background
  writer that pushes more than the pipe can hold in ordinary blocking mode —
  `dd if=/dev/zero bs=65536 count=2` with the write end as its stdout, at `/bin/dd` on
  Darwin and at whichever of `/bin` and `/usr/bin` the platform keeps it in, or a bash
  `printf` loop where the plan would rather not name a path at all — so that writer is
  sitting in `write` from the moment the pipe is full and stays there. Capacity is measured and not assumed — 65536 bytes on `Darwin 27.0.0` — and the
  plan measures Linux beside it, though nothing in the case depends on the number:
  `count=2` at that block size is twice whatever the buffer holds on either platform.

  **Waiting for "full" needs an observable, and the case uses the writer's own survival
  rather than a guess.** A blocking filler that has not exited is a filler with bytes still
  to place, which is the same statement as "the pipe is full" once it has written at least
  the capacity. So the test waits a fixed short time after starting it and then requires
  the writer to still be there — `kill -0` on its pid, with `ps -o state=` read for the
  failure message, the same tool the stopped-parent case above already uses — and **fails
  the case outright if the writer has exited**, because a filler that finished means the
  pipe was never full and every assertion below would be measuring nothing. Both platforms
  answer this the same way and neither answer needs a tool off R7's allowlist. Measured:
  the blocking `dd` above is still alive at one second and still alive at two, `ps -o
  state=` reports `S`, and it never exits at all while nobody drains the pipe.

  **And the case asserts the mode before it launches the entry**, with the round-32 `fcntl`
  probe the pipe variant already compiles: run against the write end, it must print
  `clear`. That is the assertion that stops this case quietly turning back into the
  withdrawn one — a filler that sets the flag, a plan that "optimises" the fill, a later
  reader adding an `O_NONBLOCK` for speed. Measured on `Darwin 27.0.0`: `clear` before the
  filler starts, and `clear` again with the pipe full and the filler blocked.

  Then it runs the entry with that write end as stderr, polls the output directory for
  `.run` the way the pre-parent case does, sends `SIGTERM`, and waits with the same bounded
  timeout. At the end it tears down in the other order — kill the filler first, then close
  the pipe — so no blocked writer is left behind in the test's own scratch.

  Three assertions after that. One: the entry exits `143`, inside the timeout — which is the whole
  case, because an entry that writes unconditionally is still sitting in `printf` when the
  timeout expires. Two: `.run` is gone and the output directory is completely empty, so
  the omission bought the exit without costing the cleanup. Three: nothing the entry wrote
  arrives in the pipe — the test drains the read end afterwards, past the filler bytes,
  and requires no `entry-signal:` line, which is the positive check that the rule omitted
  rather than that the write happened to fit. The behaviour under test was measured on a
  real `pipe(2)` behind a blocking filler before it was specified: on bash 3.2.57,
  `Darwin 27.0.0`, an unconditional `printf` into that pipe was still in its write when a
  `perl` `alarm 3` killed it three seconds later, exit `142`, while the same body guarded
  by `[ -f /dev/fd/2 ]` exited `143` at once having written
  nothing. (That measurement was made against the three-test condition the round before
  this one wrote; the pipe row answers `no` to all three, so narrowing the condition to
  the one test leaves the measured outcome and this case unchanged.) **The case is not
  widened to a terminal, and the reason is that it cannot be.** R1 drops terminals from
  the writing set because a tty's output can be flow-controlled and a pty master may go
  unread, and a case that stopped a pty from draining would be asserting the absence of a
  line on an object whose readiness this suite cannot pin down any more reliably than the
  interactive caller can. The pipe case proves the mechanism — the condition omits, and
  the exit still happens — and the terminal is covered by the reading, which is that the
  condition is exactly `[ -f /dev/fd/2 ]` with no `-t` and no `-c` beside it.

  The test also
  asserts every pinned blob constant equals the working tree's `git hash-object` output —
  the two C sources and all eight files of the runtime's loaded set that R5 enumerates as
  entry-pinned, and separately, in the parent, **the eight constants of the parent-pinned
  set**, where three used to stand. Two more constants join that assertion this round and
  are not blob ids: the generation id and the schema major the parent carries so it can
  build the five module paths for itself, each required to equal the library's own
  `PROFILE_RESOLUTION_CORE_GENERATION` and `PROFILE_RESOLUTION_SCHEMA_MAJOR`
  (`scripts/lib/profile-resolution.sh:5,11`) read out of the working tree — a one-line
  comparison each, and the thing that fails CI when a new core generation moves the
  library's copy and not the parent's. **And it asserts the computed id equals
  `git hash-object` for every one of those
  files** — eighteen pinned blob ids now rather than thirteen, ten in the entry and eight
  in the parent, with all eight loaded files pinned in both places and asserted on both
  sides rather than once and assumed. Neither shipped file runs git any more; each builds the blob id from a size and a
  SHA-1 (R1), and the only thing keeping that construction honest is checking it against
  the tool it replaces. So for each pinned file the test computes the id the way the entry
  does, and requires the computed id, `git hash-object`'s answer and the pinned constant to
  agree — three values, not two. The test may run git freely: it is not a shipped file, and
  the allowlist grep below covers the two shipped files only.

  **The read allowlist is a grep, not a promise, it covers external command words only, and
  the mechanism is settled here rather than left to the plan.** The list it checks against is
  R7's: `/bin/bash`,
  `/bin/mkdir`, `/bin/cp`, `/bin/chmod`, `/bin/rm`, `/bin/cat`, `/usr/bin/uname`,
  `/usr/bin/printf` (data writes only, R7), `/usr/bin/env`,
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
     text, and which the parent opens on Linux and names in its own copy of that shim
     text, neither of them ever executing it (R5, R7). Anything else fails, whatever
     prefix it carries. Matching
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
     answer. **This round the C parent may contain the token, so "not at all" is replaced
     by a position rule there too.** The previous round's assertion was that the C file
     must not hold it anywhere, and that is no longer a correct assertion: R5's `.run/awk`
     verification needs the path as the Linux arm's `open` argument and again inside the
     Darwin arm's two-line constant. So the test requires every occurrence in the C file
     to be one of those two literals and requires none of them to appear in any `execve`
     argument array — which is the same grep the `environ`/`execv` reading already scopes
     to the exec sites, asked about one more token. That is what makes an
     accidental host-awk invocation a CI failure rather than an allowlisted path in a new
     place. The test may still run awk freely for its own parsing, the way the existing
     test does at `scripts/test/portable-profile-resolution.test.sh:448-449`, for the
     same reason it may run git: the sweeps cover the two shipped files only.

     **And `/usr/bin/printf` gets an ordering assertion, for the mirror-image reason.**
     R7 splits the two printfs — the external one writes data, the builtin one writes
     refusals — and the half of that split a grep can lose is the first external command
     boundary: an implementer who wrote the `ulimit` ladder's refusal or the close loop's
     as `/usr/bin/printf 'E_RUNTIME\n' >&2` would pass pass 1 as a listed command word and
     pass 2 as no bare word, and would have run an external binary above the `env -i`
     re-exec. So the test asserts the order rather than the wording: it takes the line
     number of the entry's `env -i` re-exec and requires **every** occurrence of
     `/usr/bin/printf` in the file to sit below it. Line-number ordering inside the one
     file is the mechanism, chosen over a marker comment on purpose — a marker is a second
     thing to keep in step with the statement it marks, and the re-exec line is already
     unique in the file and already the thing R1 orders everything else around. The
     assertion is one `grep -n` for each and a numeric comparison, and it is what makes
     R7's "first external command is `/usr/bin/env`" a checked claim. **Pass 2 must not
     count the builtin `printf` as an external command**, and does not: `compgen -b` reports
     it and pass 2 drops every name that set holds, which is the same drop that lets `cd`,
     `umask` and `[` through. The two halves are deliberate and belong together — without
     the drop the refusals fail the grep, and without the ordering the drop would hide the
     one arrangement this pair exists to catch (R1, R7).
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
   (R5), and including the bound tool root: the jq path argument proved to be the run
   directory's own `jq` by the same `st_dev`/`st_ino` identity off an
   `openat(run_fd, "jq", O_RDONLY|O_NOFOLLOW)` and an `O_NOFOLLOW` open of the handed
   path, and `.run/awk` opened `openat(run_fd, "awk", O_RDONLY|O_NOFOLLOW)` and required
   to be a regular caller-owned mode-0500 file whose bytes equal `/usr/bin/awk`'s on Linux
   or the two-line shim constant on Darwin — read in full through both descriptors, sizes
   compared and then bytes, with no child process anywhere in it (R5) — and
   the check order R5 fixes (length guard, then the output directory with its identity
   comparison, then the helper, run-directory, jq-identity and awk checks, then the sandbox
   creation) — checks that the test script performs today or cannot perform at all.
   Every mode and ownership check is done with `fstat` on a descriptor
   the parent opened (`O_DIRECTORY|O_NOFOLLOW` for the run directory), never with `stat`
   on a path it will later hand on by name; `umask(077)` is called among the first
   statements of `main`, before any check and before any creation, where the copied
   launcher has no `umask` call at all and relies on the test harness setting one
   (`portable-profile-resolution.test.sh:5`), so the modes below are the modes that appear
   rather than the modes that were asked for (R5); every descriptor above 2 that the
   parent inherited is closed in the same opening run of statements, after that `umask`
   and after the handler installations but before the first pin check and therefore before
   the first `fork`, in two steps — an `opendir("/dev/fd")` enumeration that closes every
   all-digit entry except 0, 1, 2 and `dirfd`, refusing `E_RUNTIME` if the `opendir`
   itself fails, and then a `close` loop from 3 to `getrlimit(RLIMIT_NOFILE)`'s
   `rlim_max` where that is finite or `sysconf(_SC_OPEN_MAX)` otherwise, capped at 65536,
   with the caller's `rlim_cur` used as a ceiling nowhere, because a caller can open a
   high descriptor and lower the soft limit under it before the `exec` — not `closefrom`
   or
   `close_range`, neither of which is portable to both pinned platforms — so that no SHA
   tool, SHA-256 tool or `jq --version` probe the parent forks can inherit a caller's
   credential, socket or write handle, with the resolver child's own pre-`execve` close
   kept as the second line (R3, R5); every `execve` in the file is given an array the
   parent wrote and never `environ` — the fixed `PATH=/usr/bin:/bin`, `LC_ALL=C` pair for
   each SHA-1 tool, the SHA-256 tool and the `jq --version` probe, which run before R3's
   array exists, and R3's array for the resolver child — with `execv`, `execvp` and
   `execlp` absent from the file, so a caller's `PERL5LIB` cannot run code inside Darwin's
   perl-script `shasum` while the pins are being decided (R3, R7); and the sandbox's four entries —
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
   copied source and are written fresh: the blob-id pins for all eight loaded files the
   parent re-checks (the runtime, `scripts/lib/profile-resolution.sh`,
   `resolver/v1/profile-resolution.jq` and the five jq modules — the first three located
   from the runtime path with the
   runtime's own repository-root rule, `resolver/v1/profile-resolve-runtime.sh:9-10`, and
   the five from that same root plus the parent's own constant copies of the library's
   `PROFILE_RESOLUTION_CORE_GENERATION` and `PROFILE_RESOLUTION_SCHEMA_MAJOR`
   (`scripts/lib/profile-resolution.sh:5,11`), each asserted against the library's own in
   R10 and kept honest at run time by the parent's pin of the library itself, so the parent
   reads nothing out of the tree to find them — eight SHA-1 children where three ran, each
   under the fixed `envp` and inside the same block-fork-publish and block-reap-zero
   regions as the rest, R5), and
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
   pre-resolver child currently being waited on (one of the eight SHA-1 tool runs, the
   SHA-256 tool, the jq
   `--version` probe), set before its `waitpid` and cleared to `0` under the same
   three-signal block as that `waitpid`, before the mask is restored, because a pid the
   kernel has taken back can be handed to any process on the machine and not only to a
   child of this one — the same block-reap-zero-restore shape around each of the three
   `waitpid`s in the copied supervisor that can reap the resolver (`:457` in the poll loop,
   `:493-494` on the limit path, and `:451-452`, which is already inside the fork region and
   needs only the mask restored before it returns), except that on the resolver's two
   cleanup paths the region does not end at the reap: it carries on through the survivor
   check at `:460-462` and, when that finds survivors, through the `kill(-child, SIGKILL)`
   and `kill(child, SIGKILL)` at `:491-492` and the wait behind them, with `pgid = 0` last
   and the restore after it, so no handler can ever see `0` while part of that group is
   still alive — the rest of the poll loop (`:469-488`) staying outside the block as
   before — with three branches on
   them: the group sequence when `pgid != 0`, `SIGTERM`-then-`SIGKILL` on that one pid when
   only `pre_child != 0`, and nothing to kill otherwise, never `kill(0, …)` or
   `kill(-0, …)` in any of them — and the two killing branches part company after the
   wait: the group branch sends `kill(-pgid, SIGKILL)` whether or not the leader was
   reaped, because survivors are what a group kill is for and a handler cannot run the
   process-table scan that would tell it there are none, while the single-pid branch sends
   `kill(pre_child, SIGKILL)` **only** when the wait did not already reap the child,
   because a reaped pid is back in the kernel's pool and signalling it is the stranger-kill
   the rest of this design closes (R2). The wait between the `SIGTERM` and the `SIGKILL` is a
   bounded loop of at most twenty iterations, each a `waitpid(target, &st, WNOHANG)` that
   sets a local `reaped` and breaks out when it returns the target, and a
   `select(0, NULL, NULL, NULL, &tv)` with `tv` at
   50 ms — about a second in total, ending early — with `target` the child's own pid on
   both branches, `pgid` being the leader's pid so the group branch waits on the leader,
   and `reaped` the flag the two post-loop shapes above read; chosen because both calls are on the
   POSIX.1-2017 async-signal-safe list and `nanosleep` and `usleep` are not, which rules
   out copying the poll loop's own `nanosleep` (`:488`) into handler context; every call
   in the three handler bodies is checked against that list by name, and `snprintf`,
   `malloc`, `free`, `fprintf`, `printf`, `strerror`, `nanosleep` and `usleep` are
   forbidden there, so the `parent-signal:` line is assembled from a static signal-name
   table indexed by signal number and a hand-written decimal routine for the pgid rather
   than by `snprintf` — which the `runtime-pgid:` write below may still use, being in
   `main` (R2). Every `fork` the parent performs — eleven in a run: the resolver's
   (`:432`) and each of the ten pre-resolver children's, one SHA-1 tool per pinned file for
   all eight of the parent-pinned set, the SHA-256 tool and the jq probe — is wrapped in
   `sigprocmask(SIG_BLOCK, &three, &saved)` before it and
   `sigprocmask(SIG_SETMASK, &saved, NULL)` after the parent has done its `setpgid` and
   assigned `pgid` or `pre_child`, so no handler ever
   runs between a `fork` and the publication of what it returned — and nothing else goes
   inside that region, the `runtime-pgid:` line being written after the restore rather than
   in there, because a stderr write that blocks with the three signals blocked would stop
   the handler running at all (that line has a block of its own, which is a different
   thing: a bounded sequence in which nothing can wait, R2); on the child's side the
   three dispositions are reset to `SIG_DFL` **first, while the three are still blocked**,
   with `SIGPIPE` reset beside them, and the same mask is restored only after that — the
   resets because the child runs C code before `execve` and a pending signal unblocked
   ahead of them would run the parent's handler inside the child, the mask restore because
   the mask is inherited across `exec` (R2). Each branch ends by writing one line —
   `parent-signal: <NAME> group <pgid>` or `parent-signal: <NAME> no-runtime`, which is
   what R10's stopped-parent case asserts — **after** it has killed and reaped, not before,
   with stderr put into non-blocking mode by an `F_GETFL` and an `F_SETFL`, a single
   `write(2)` rather than the copied
   `write_all` (`:164`), a short write or `EAGAIN`/`EPIPE` ignored, and the saved flags put
   back by a third `fcntl` before the `_exit`, unconditionally and whatever the write
   returned, because a file status flag lives on the open file description the entry and
   the caller share and a flag left set would turn their later stderr writes into
   `EAGAIN`s; and `SIGPIPE` set to
   `SIG_IGN` among the same first statements of `main`, so a blocking or closed stderr can
   never hold up the termination this path exists to guarantee (R2). One further line has no counterpart either: the single `runtime-pgid: <n>` written
   straight to stderr after the `fork` (`:432`), the parent-side `setpgid` (`:450`), the
   `pgid` assignment and the mask restore — **outside** the blocked-signal region, and
   best-effort in the same way the handler's line is, with stderr made non-blocking for one
   `write(2)` and the saved flags put back by a second `fcntl` afterwards, and a short write
   or `EAGAIN`/`EPIPE` ignored, the whole `fcntl`/`write`/`fcntl` sequence run between a
   `sigprocmask(SIG_BLOCK, &three, &saved)` and its matching
   `sigprocmask(SIG_SETMASK, &saved, NULL)` so that no handler can fire mid-toggle, save
   the non-blocking flags as the original and restore them as such — the rule being that
   no blocking write goes inside a blocked region and no toggle of a shared file status
   flag goes outside one, which every flag-toggling diagnostic the parent writes follows
   (R2) — and before the poll loop, so a reader can
   identify the resolver's process group without guessing at the process table (R2).
2. **`resolver/v1/resolve-profile.sh`** — in this order, each step refusing with
   `E_RUNTIME` before the next. **The entry's own four statements, then the copied scrub
   and re-exec, and only then anything external.** First
   `case $- in *p*) ;; *) exit 78 ;; esac` as the first statement in the file, so an
   arrival that is not one of the two supported invocations is turned away before anything
   else is parsed, and so that everything below it runs in a shell that imported no
   function and read no `BASH_ENV`. Then `umask 077`, copied from
   `adapters/local-git-materializer/v1/materialize.sh:31` but set here rather than after
   the scrub, because the scrub resets variables and not the process umask (R1). Then the
   descriptor-headroom precondition, one line and builtins only:
   `ulimit -S -n 1024 2>/dev/null || ulimit -S -n 256 2>/dev/null || ulimit -S -n 64
   2>/dev/null`, and on the failure of
   all three one `E_RUNTIME` line and a non-zero exit. It *sets* the headroom rather than
   reading it, which is why it forks nothing, and the attempts are what make it a check
   as well as a fix: an unprivileged process may raise its soft limit to its hard limit, so
   the ladder fails throughout only when the hard limit is below 64. The rungs descend, the
   largest first, so a caller whose hard limit allows 1024 has the entry's room *raised* or
   held rather than cut to 256 — which is what stops the normalisation itself taking away
   the free numbers the loop below needs (R1). **The postcondition is exact and is stated
   here once: past this line the soft limit is one of 1024, 256 or 64 — the first rung the
   hard limit allows — and nothing else.** Every assertion in R10 that names the limit, and
   every fixture that sets one, reads those three values; an assertion still written against
   "256 or 64" is testing the two-rung form this ladder replaced (R1, R10). The loop below closes the
   descriptor bash reads the script from and bash needs free numbers at or above 10 to
   relocate its input onto — with no headroom it truncates the script and exits `0`, or
   crashes — and nothing above the loop may fork, because a child there would inherit the
   very descriptors the loop exists to shut (R1). Then
   every inherited descriptor above 2 closed, with **no exception of any kind** — the
   numbers enumerated by a `/dev/fd/*` glob, which forks nothing, each one checked to be
   all digits and not 0, 1 or 2 before `eval "exec ${fd}>&-"` shuts it, because bash 3.2
   has no `{fd}>&-` form — and **the one arrangement in which that glob yields no numbers
   refused rather than skipped**: with `nullglob` off an expansion that matches nothing
   leaves its own word behind, which is what a caller who has filled every descriptor below
   the normalised soft limit produces, because the glob's own directory read needs a
   descriptor too. So the loop's first statement is a `case` on the unstripped word against
   the quoted literal `'/dev/fd/*'`, and its body is one `E_RUNTIME` line and a non-zero
   exit — above the `${fd##*/}` strip, refusing rather than continuing, and reached before
   the run directory exists, so such a caller gets a refusal and never a run that closed
   nothing and reported success (R1). Bash's own script descriptor is closed with the rest and bash
   relocates it (`save_bash_input`), which is why the precondition comes first and why the
   round-34 reference-open-and-skip is gone: `-ef` cannot tell a caller's read-only handle
   on the entry script from a write handle on it, and the skip preserved both. The
   `2>/dev/null` stays on the `eval` and must not move onto the `exec` inside it, which on
   a command-less `exec` would redirect the shell's own stderr for the rest of the run —
   placed here, ahead of the scrub and the re-exec, because the
   scrub's two process substitutions fork bash children and the re-exec runs
   `/usr/bin/env` and a second bash, all of which would otherwise inherit whatever the
   caller left open, and so that none of the pin checks, compiles, copies or probes the
   entry forks below can inherit a caller's credential, socket or write handle outside the
   output root (R1). Only then the
   builtins-only scrub copied verbatim from
   `materialize.sh:4-13` under the same `#!/bin/bash -p`
   shebang (`:1`), then `exec /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p
   "$script_path" __resolve_profile_clean "$1" "$2" "$3" "$4"`, adapted from `:22-29` in the
   marker word, the arity, the `-p` that carries privileged mode across the re-exec where
   the materializer drops it, and the four statements above that the copied file does not
   have in that position — and then the marker branch, which re-runs the same builtin
   scrub plus `builtin unalias -a` and `builtin shopt -u expand_aliases` as defence in
   depth (R1). The four opening statements run again in the second process, where the
   close loop finds nothing above 2 but that second bash's script descriptor and shuts it,
   and that bash relocates in turn. Then, still
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
   `entry_signal` with an assign-if-empty and setting the wait loop's flag beside it,
   `: "${entry_signal:=TERM}"; wait_interrupted=1` and its `INT` and `HUP` siblings, which
   is two statements in each of the three bodies and the whole of each of them, so that a
   repeat or a second, different signal cannot overwrite a name the entry
   has already acted on and no signal arriving during a `wait` can leave the loop below
   reading an interrupted wait's return as the parent's own status (R1), and
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
   With a parent, the wait is a loop rather than a fixed pair of `wait` calls, and its five
   steps run in this order on every pass: clear the flag; forward an already-recorded
   signal; `wait`; leave on a clear flag; leave on a `127`. **Whether to leave the loop**
   is the `wait_interrupted` flag's:
   the three traps set it, the loop clears it at the top of every pass, and a `wait` that
   comes
   back with it clear was not cut short, so its status is the parent's own — the entry
   records it in `entry_status`, breaks and exits, forwarding nothing, because the parent
   has been reaped. **Whether to forward** is bash's job table's, and the question is asked
   *before* each `wait` rather than after an interrupted one: if `entry_signal` is set and
   differs from `last_forwarded`, the entry consults `$(jobs -l)` and sends
   `kill -"$entry_signal"` only if the
   parent's job is listed as `Running`, because the flag says a trap ran and not that the
   parent was alive when it ran — a signal landing after a `wait` has reaped the parent but
   before the loop reads the return sets it too, and forwarding there is a `kill` at a pid
   the shell
   has given back, which after pid reuse is a stranger's. Asking before the `wait` is what
   covers a signal recorded before the loop began — the first pass forwards it, where a
   loop that forwarded only after an interruption would block for the parent's whole
   natural life and report its ordinary status (R1, measured) — and clearing the flag at
   the top rather than immediately above the `wait` is what keeps a signal that lands
   during the forward from being erased. A job listed `Exit`/`Done`, or
   absent, is not forwarded to; a `last_forwarded` variable, assigned after the `case`
   whether or not the table let the `kill` through, keeps a later
   pass from re-sending; neither `jobs` nor `case` forks an external command, and no
   version of `kill -0` on the pid survives anywhere in the loop (R1). The
   one wrinkle is a parent that exits in the same instant a signal lands, where the flag is
   set on a wait that was not cut short: nothing is forwarded, the loop waits once more,
   bash 3.2 hands back the
   parent's saved status, and the `[ "$status" -ne 127 ]` guard covers a bash that would
   instead have discarded it, reporting `128 + signal` and saying so (R1). So
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
   cleanup or the forward; and it is written at all only when
   `[ -f /dev/fd/2 ]` — one test and nothing beside it, so the line is omitted on a
   terminal, on `/dev/null` and on a pipe, a FIFO or a socket alike, because last position
   stops the write delaying the cleanup and does not stop it
   hanging the entry short of the `128 + signal` exit and hanging the caller's wait with it,
   and a terminal's write can wait as surely as a pipe's when its output is flow-controlled
   or its pty master is not being read
   — bash cannot write non-blocking the way the parent's C can, so where the parent writes
   best-effort the entry writes nothing (R1). No child of the entry's own is alive to race that removal because
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
- **A supported way to launch the parent without the entry.** R5 states the boundary: the
  only supported launch is `resolver/v1/resolve-profile.sh` under its two invocation
  forms, and invoking `trusted-launch` directly is a test harness for R10's group 2 and
  nothing else. Making direct invocation supported would mean giving the parent a way to
  establish the helper's provenance for itself, and a compiled binary cannot be pinned by a
  constant, so it would mean either committing a binary (the bullet above) or moving the
  compile into the parent — a different component from the one this spec ships. Nothing
  here provides a documented direct-invocation interface, a test-only marker that would
  let the parent recognise the entry, or a mode in which the parent relaxes a check for a
  caller it trusts.
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
- **The boundary has one supported entrance, and the statement is documentary rather than
  enforced.** R5 settles this: the only supported launch is
  `resolver/v1/resolve-profile.sh` under its two invocation forms, a direct
  `trusted-launch` invocation is a test harness for R10's group 2 and unsupported
  otherwise, and R9's documentation and Out of scope both say so. The reason is one thing
  the parent cannot do for itself. It now pins every file the runtime executes or
  evaluates — all eight, not three (R5) — but the helper is a compiled binary, and no
  constant in a committed C file can name a binary's bytes, so a caller who builds `.run`
  themselves can put a 0500 helper of their own in it and pass every check the parent
  makes. Only the entry, compiling from a blob-pinned source into a directory it created
  and tightened, says where those bytes came from. **And the parent deliberately does not
  detect the difference**: every marker it could test is one the caller controls, the same
  reason R1 gives for refusing a nonce on the marker word, so a detection would be theatre
  and would make the parent look like it enforced a boundary it does not. The plan must
  carry this in these words and must not describe the direct path as "blocked", "refused"
  or "detected": what is true is that it is unsupported, that every check still runs on it,
  and that what it lacks is provenance rather than a refusal.
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
- **Pinning the whole loaded set is real maintenance, and it costs more this round than
  last.** Eighteen pinned blob ids across two
  files — ten in the entry, eight in the parent — each of which must move in the same pull
  request as the code it pins, and a new
  core generation moves ten of them at once plus the generation-id constant the parent now
  carries beside the library's own. What it buys is that the trusted set stops being
  implicit — today nothing pins `scripts/lib/profile-resolution.sh` or
  `resolver/v1/profile-resolution.jq`, so pinning the runtime alone proves only that a
  dozen lines of `source` chain are the committed ones. The defence against a forgotten
  pin is the CI assertion in R10, and it is worth saying that the defence is one test.
  Worth saying too, and it is the change: **all eight loaded files are now re-checked by
  the parent**, where three were, so no pin exists only on the path through the entry any
  more and an edited jq module is refused by either process. The entry keeps two pins of
  its own, the C sources, and those are what no widening of the parent's set can reach.
  The duplication is the cost and it is deliberate: all eight loaded files are pinned
  twice, so a change to any one of them moves a constant in two committed files, and the
  assertion that the two agree is a test rather than a mechanism.
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
  that ends only when the parent has actually been reaped, so the case samples the
  existence of `.run` against the appearance of the parent's own `parent-signal:` line and
  fails on the first sample that finds the run directory gone with that line still
  unwritten — it does not poll the parent's pid, which is the thing R1 has stopped
  trusting — and it asserts that the one
  `entry-signal:` line still names the first signal (R1, R10). This round adds the other
  half of that distrust, on the shipped side rather than the test's: the loop forwards the
  recorded signal only while bash's own job table still lists the parent's job as
  `Running`, so a signal that lands after the reap cannot send a `kill` at a pid the kernel
  may already have given to another process (R1). This round adds the two positions that
  make that loop see a signal at all, and both are read rather than tested because each
  needs an arrival between two adjacent statements: the traps set the loop's flag as part
  of recording, so a signal delivered inside `wait` cannot pass for the parent's own exit;
  and the loop forwards an already-recorded signal *before* each `wait`, so a signal that
  arrived before the loop began is not left unsent while the entry blocks for the parent's
  whole natural life — measured on bash 3.2 both ways, and the old order exits `0` on a run
  the caller sent a `TERM` to (R1). The third test drives the
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
  first one did, so R1 makes the wait a loop that forwards once per recorded name and
  takes the
  exit status only from the wait that actually reaped the parent — and unlike the two
  fixes above it does have a test behind it, the repeated-signal case in R10, because this
  window is hundreds of milliseconds wide rather than a few instructions.
  **This round replaces the thing that loop asked.** It told an interrupted wait from a
  reaping one with `kill -0` on the parent's pid, and a pid is the one question that stops
  being about the parent the moment bash reaps it — measured, not argued: an exited
  background child answers `kill -0` with `ESRCH` and shows no zombie at all, so on a busy
  same-uid host the number can already belong to a stranger when the loop asks. R1 now
  asks the traps instead, through a `wait_interrupted` flag the loop clears before every
  `wait`, and R10's sampler stops polling that pid too, watching the parent's own
  `parent-signal:` line against the existence of `.run`. What is left is a residual rather
  than a hole, and R1 states it: the single forward can, in the instant the parent exits by
  itself, go to a recycled pid, and nothing a shell can reach distinguishes that instant.
  Two more of this round's finds are the test's. Group 1 gains an edited-`trusted-launch.c`
  case, because the suite proved only the *other* C pin, and a missing parent-source pin
  would let the entry compile and launch an altered parent — which the parent, being that
  binary, cannot catch for itself. And the stopped-parent case now runs with job control
  off and asserts its sentinel shares the parent's process group, because with `set -m`
  each background job gets a group of its own and the sentinel would have survived the
  accidental `kill(0, …)` it exists to detect (R10).
  One more
  ordering belongs in this bullet, and it points the other way: the two diagnostic lines
  this path writes — the parent's `parent-signal:` and the entry's `entry-signal:` — are
  written **after** the killing and the cleanup rather than before, and best-effort, because
  stderr may be a pipe nobody is draining and a blocking write ahead of the kill would hang
  the very path that exists to guarantee cleanup (R1, R2). The plan should treat "the
  diagnostic never delays termination" as a rule of this component rather than a detail: the
  handler's line goes out with one non-blocking `write(2)` whose failure is ignored, and the
  entry's `printf` is the last statement of its `EXIT` trap, before that trap's own `exit`.

  This round takes both of those one step further, in the two places where "best-effort"
  had been read as a property of *when* a write happens rather than of the write itself.
  On the parent's side, the one flag-toggling diagnostic outside a handler — the
  `runtime-pgid:` line — now sets and restores `O_NONBLOCK` with the three signals
  blocked, because a handler firing between the set and the restore saves the toggled
  flags, restores them as though they were the original, and `_exit`s, leaving the flag
  set on a description the entry and the caller share; the handler's own line needed
  nothing, its `sa_mask` already covering its whole body (R2). On the entry's side, last
  position turns out not to be enough at all: bash has no way to write non-blocking, and a
  `printf` into a full undrained pipe never returns, so the entry reaches neither its
  `128 + signal` exit nor the caller's waiting `wait` — cleanup done, resolver dead,
  caller hung on a courtesy. The entry therefore writes its line only where a write cannot
  block, and this round that set is exactly one kind of object: a regular file behind
  `[ -f /dev/fd/2 ]`, with the line omitted everywhere else (R1). The three-kind condition
  an earlier round wrote admitted a terminal and a character device beside it, and the
  terminal half was wrong — a tty's output queue is finite, `IXON` flow control stops it
  draining, and an unread pty master fills exactly as a pipe does, so the interactive case
  was the one with a hang still in it. `/dev/null` is harmless and loses the line anyway,
  to keep the rule one test wide. What the caller keeps in every case is the exit status
  and, on the forwarded branch, the parent's own `parent-signal:` line.
  The plan should carry the sharper rule: **a
  diagnostic must be incapable of blocking, and where the language cannot make it so, it
  is not written.** That is the one place the two shipped files legitimately differ, and
  R10 covers each side its own way — a reading for the parent's six statements, a
  full-pipe case for the entry's omission.

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
  an untrusted one. The inherited descriptors the entry closes sit in exactly the same
  place and carry exactly the same residual: they are shut among the entry's first
  builtins, before any external command, so nothing the entry runs can inherit one — but
  the statements ahead of that loop run with them still open, as they do with the caller's
  variables still set, and the answer is the same answer. **The round-35 shape made one of
  those statements a fork and this bullet said so; this round takes the fork back out, and
  the residual returns to being about descriptors held rather than descriptors inherited.**
  What that round recorded was real: the headroom precondition's `nofile=$(ulimit -n)` is a
  command substitution, bash 3.2 forks for one, and so exactly one bash child existed above
  the close holding whatever the caller left open — brief, exec'ing nothing, running one
  builtin, with nothing of the caller's able to run inside it (the `-p` refusal above it
  means no imported function and no `BASH_ENV`), and gone before the loop's first pass, but
  a process that had briefly held a caller's credential or socket all the same. The
  precondition is now `ulimit -S -n 1024 2>/dev/null || ulimit -S -n 256 2>/dev/null ||
  ulimit -S -n 64 2>/dev/null ||
  refuse`, which sets the headroom instead of reading it and creates no process at all
  (R1), so the count above the close is zero children rather than one and the
  write-root claim in R7 carries no qualification. **A second thing this bullet used to
  leave unsaid is what happens when the loop is given nothing to close, and this round it
  is a refusal rather than a residual.** A caller who has filled every descriptor number
  below the soft limit the precondition settles on makes the `/dev/fd/*` glob match nothing
  — the directory read needs a descriptor of its own — and with `nullglob` off the loop then
  runs over the glob's own literal word and shuts nothing at all, which until this round
  meant the caller's credential, socket or write handle survived into every child and the
  run reported success. R1 now refuses that arrangement with one `E_RUNTIME` line before
  anything is created, and R1's ladder raises the soft limit where the hard limit allows it
  rather than always cutting to 256, which shrinks the set of callers who reach the refusal
  to those whose hard limit is under 1024 and whose low numbers are full. So this bullet
  carries the residual it always carried — the statements above the loop run with the
  caller's descriptors open — and it no longer carries a case where the loop ran and left
  them open. Nothing else about the residual changes:
  the entry's own first process still runs with the caller's descriptors open and with the
  caller's loader variables already consumed, and that is the same one answer as above. The
  parent closes its own at the top of `main`
  because it cannot know it was started by the entry (R5), which is the one case the
  entry's close cannot cover — the direct invocation is unsupported and the parent detects
  nothing about it, so the close has to be there anyway.
- **Copy versus adapt.** The test launcher is 702 lines, and far less of it is test
  scaffolding than a glance suggests: only the argv modes at `:547-631` and the two
  test-variable lines at `:686-689` are test-only, so the parent copies roughly 605 lines
  of it (see the size derivation above). Copying the supervisor verbatim keeps the proven
  behaviour but carries code written for a test harness; adapting risks a subtle
  divergence in exactly the code that enforces the limits. The plan should list every
  deviation line by line. Ten are already known in the parent: the mode-0644 check moves
  from the test
  into the parent; inherited descriptors above 2 are
  closed explicitly rather than relying on the launcher's `O_CLOEXEC` on its own opens —
  and that item grows this round rather than an eleventh being added, because it is the
  same deviation at a second point: the close now happens twice, once among the first
  statements of `main` before any fork — a `/dev/fd` enumeration that refuses `E_RUNTIME`
  if its `opendir` fails, then a range sweep whose ceiling is `rlim_max` where finite and
  `sysconf(_SC_OPEN_MAX)` otherwise, capped at 65536 and never at the caller's `rlim_cur`,
  with neither `closefrom` nor `close_range` used
  because neither is portable across both pinned platforms — and once in the resolver child
  before `execve` as before, where the launcher has no startup close anywhere in its 702
  lines (verified: every `close` and `fclose` in the file is on a descriptor or stream it
  opened itself, and `closefrom`, `close_range`, `sysconf` and `getrlimit` do not appear
  at all), so the pre-resolver children it forks inherit whatever its caller held (R3, R5);
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
  to copy and the whole check is written fresh (R5) — and it grows once more this round
  for the two executables the run directory holds besides those the item already names:
  the jq path argument is proved to be `.run/jq` by the same `st_dev`/`st_ino` identity,
  and `.run/awk` is opened relative to the run-directory descriptor and its bytes compared
  in full against `/usr/bin/awk` on Linux or against a two-line constant on Darwin, all of
  it new code for the same reason the rest of the item is — the launcher takes the jq path
  and the tool root it derives entirely on trust, doing nothing with `argv[4]` but the
  `strlen` guard at `:662-665`, the `strrchr` that cuts the directory off at `:667-672`
  and the `PATH` it builds from the result at `:673-677`, and it never looks at `awk` at
  all (verified: the token does not appear in its 702 lines); the blob pins
  for the eight loaded files — the runtime, `scripts/lib/profile-resolution.sh`,
  `resolver/v1/profile-resolution.jq` and the five jq modules — are new, and that item
  grows this round rather than an eleventh being added, because it is the same new block
  with five more entries in it: the modules join the three the item already named, and
  with them two non-blob constants the parent carries so it can build their paths, its own
  copies of the library's generation id and schema major, which R10 asserts against the
  library's own. There is nothing to copy for any of it — the launcher pins nothing at all
  (R5); the request and repository-map
  arguments get a regular-non-symlink check where the launcher checks only the leading
  slash (`portable-profile-resolution-launcher.c:636`); the `INT`/`TERM`/`HUP`
  handlers with process-group termination are new (R2) — and that item grows again this
  round rather than a tenth being added, because it is all the same deviation: the handlers
  are installed by `sigaction` with `sa_mask` set to all three of `SIGINT`, `SIGTERM` and
  `SIGHUP` and `SA_RESTART` unset, so none of them can re-enter another, and they
  carry two `volatile sig_atomic_t` variables, three branches on them, a prohibition on
  `kill(0, …)`/`kill(-0, …)`, one `parent-signal:` line each branch writes — written last,
  after the kill and the reap, with stderr made non-blocking for a single `write(2)` whose
  short write or `EAGAIN`/`EPIPE` is ignored and the saved flags put back by a third
  `fcntl` before the `_exit`, because the flag sits on an open file description the entry
  and the caller share, and `SIGPIPE` left at `SIG_IGN` from the
  first statements of `main`, so the diagnostic can never hold up the termination — and a
  `sigprocmask(SIG_BLOCK, …)` around every fork the parent performs with the matching
  `sigprocmask(SIG_SETMASK, …)` after the pid assignment and nothing else inside the region
  with them — the `runtime-pgid:` line is written after that restore, not in there, under a
  second and much shorter block of its own that spans only its `fcntl`/`write(2)`/`fcntl`,
  so a handler can never save the toggled flags as the original —
  and, this round, a bounded `waitpid(…, WNOHANG)`/`select` loop for the wait between the
  `SIGTERM` and the `SIGKILL` with every call in the three bodies held to the
  POSIX.1-2017 async-signal-safe list, which is why that line is a `select` and not the
  `nanosleep` the copied poll loop uses at `:488` and why the `parent-signal:` line is
  built from a static table and a hand-written decimal routine instead of the `snprintf`
  the `runtime-pgid:` line is allowed —
  and the same pair around every `waitpid` that can reap a tracked child, with the id set
  to `0` before the restore: each pre-resolver child's, and the copied supervisor's
  `:457`, `:493-494` and `:451-452`, the last of which is already inside the fork region —
  and on the resolver's two cleanup paths that region reaches past the reap, over the
  copied survivor check at `:460-462` and the copied `kill(-child, SIGKILL)` and
  `kill(child, SIGKILL)` at `:491-492`, with `pgid = 0` after them and the restore after
  that, so the copied statements are unchanged and only the mask around them is new, the
  rest of the poll loop at `:469-488` deliberately left outside the block —
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
  shortcut would have been `git hash-object` (R1, R7) — and that item grows this round
  rather than an eleventh being added, because it is the same new block seen from the
  side of what it runs: those digest tools, and the `jq --version` probe beside them, are
  pre-resolver children the launcher does not have at all, and each is `execve`d with the
  fixed `PATH=/usr/bin:/bin`, `LC_ALL=C` pair the parent writes rather than with
  `environ`. There is nothing to adapt here and it is worth recording as a clean result
  rather than as an omission: the launcher's only two exec sites are `execve` at `:445`
  and `:622`, both already handed an explicit array, and `environ`, `execv`, `execvp` and
  `execlp` appear nowhere in its 702 lines (verified). So the deviation is the new
  children, not a habit corrected — which is exactly why the rule had to be written down
  instead of inherited (R7). The ninth is this round's only change
  to the C file: the one `runtime-pgid: <n>` line the parent writes to its own stderr after
  the fork and after the mask restore, best-effort with the same non-blocking single
  `write(2)` the handler's line uses and with the three signals blocked across its two
  `fcntl`s, where the launcher writes nothing there and leaves the
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
  where the entry's three signal traps only record — the signal's name and the wait loop's
  `wait_interrupted` flag, two statements each — its `EXIT` trap does
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
  that is a copy rather than new code — just from a third file: the entry carries the
  builtins-only environment scrub, the empty-environment re-exec and the `umask 077` from
  `adapters/local-git-materializer/v1/materialize.sh:1,4-13,22-29,31`, deviating from *those*
  lines in the marker word, the arity, the `-p` added to the re-exec's `/bin/bash`, the
  marker branch's re-run of the scrub with two alias-reset lines the copied bytes do
  not have, and — this round, and this is a change of position rather than of text — the
  four statements the entry puts *above* the copied scrub: the
  `case $- in *p*) ;; *) exit 78 ;; esac` refusal, which was on the marker branch and is
  now the first statement in the file; the `umask 077`, copied unchanged from `:31` but
  set before the scrub instead of after it; the descriptor-headroom precondition, which
  is this round's and is a fourth statement rather than growth in a third, because it
  refuses on a condition of its own — a *hard* limit below 64, since round 41 rewrote the
  statement as `ulimit -S -n 256 2>/dev/null || ulimit -S -n 64 2>/dev/null || refuse`,
  which sets the headroom rather than reading it and so forks nothing where the round-35
  `nofile=$(ulimit -n)` forked once, and which this round gives a third rung at the top,
  `ulimit -S -n 1024` before the other two, so the statement raises a caller's room where
  the hard limit allows it instead of always cutting to 256 — and has to stand before the
  close rather than inside it; and the `/dev/fd/*` close loop, which has no
  counterpart in the copied file at all and has to precede the scrub, because the copied
  scrub's two process substitutions (`:5-10`) fork bash children and the copied re-exec
  (`:22-29`) execs `env` and a second bash, and each of those would otherwise inherit a
  caller's descriptor above 2. The loop's own text *shrinks* this round by three
  statements: the round-34 reference open, its `-ef` skip and its close are withdrawn,
  because `-ef` compares device and inode and so kept a caller's *writable* handle on the
  entry script alive across the re-exec and into every child — the loop now skips nothing
  above 2 and closes bash's own script descriptor with the rest, which bash survives by
  relocating its input. **This round it grows back by one statement, and the statement is a
  refusal rather than a skip**: a `case` on the unstripped glob word against the quoted
  literal `'/dev/fd/*'`, above the `${fd##*/}` strip, writing one `E_RUNTIME` line and
  exiting — because a glob that matched nothing leaves its own word in the list, and a
  caller who has filled every number below the normalised soft limit is exactly the caller
  who makes that happen. The materializer has nothing of the kind to deviate from — it
  closes no descriptors anywhere in its own opening statements and neither reads nor sets a
  resource limit — so this is new code in a new position rather than copied lines altered. The
  copied bytes are untouched by all four;
  what moved is what
  stands in front of them (R1) — where the
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
