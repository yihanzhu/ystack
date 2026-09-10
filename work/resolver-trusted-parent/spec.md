---
intent-blob: 0fd28feb8f1de6ce71ccb90e2fce69056ec2ab32
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

**Evidence-based range: 1580-2130 changed lines** (implementation). The derivation,
measured rather than guessed:

- **C parent ~970 lines** = ~605 copied verbatim + ~365 new. The test launcher is 702
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
  output-directory check (~25), the regular-non-symlink check on the request and map
  arguments (~15), the `INT`/`TERM`/`HUP` handlers and process-group termination in R2
  (~45), closing inherited descriptors above 2 (~15), and the usage
  text and `E_*` exit paths those new checks need (~15). The biggest unknown in that ~365
  is how the parent computes digests: delegating to the platform's SHA-256 tool and
  `git hash-object` at fixed paths sits at the low end, while a SHA-256 implementation
  carried in the C file would add roughly 150 more lines. The
  plan decides that, and it is the one thing that could push the C file past ~1100.
- **Entry shell ~255 lines.** `shadow/v1/reproduce.sh:94-142` does the closest existing
  subset — self and repository-root resolution, platform case, jq digest pin, `mktemp -d`,
  the `EXIT`/`HUP`/`INT`/`TERM` traps, the bounded copy and the `--version` probe — in
  about 50 lines. The entry adds ten `git hash-object` blob pins — two C sources plus the
  eight loaded files R5 lists (~25 more than two pins would be, since the constants and
  the loop over them are the whole cost) — two compiles, the awk
  copy, the `tmp` subdirectory, the `chmod 0500` pass, the
  `LD_*`/`DYLD_*`/`BASH_ENV`/`ENV` clearing, and run-as-child plus wait plus signal
  forwarding plus `128 + signal`, each step with its own `E_RUNTIME` exit.
- **Focused test ~570 lines.** For scale, the existing resolution test is 746 lines and
  `scripts/test/shadow-slice.test.sh` is 622. R10 is now close to both:
  jq provisioning the `shadow-slice` way (~30), request and map fixtures (~40), the two
  resolutions plus `cmp` (~30), five entry-level refusals in group 1 (~60), a shared
  hand-built run-directory helper for the direct-parent cases (~15) and the sixteen
  group-2 cases on top of it (~130, the overlong-value case now building a near-`PATH_MAX`
  directory tree rather than naming a long path), the group-3 runtime refusal (~10),
  the R3 polluted
  environment run plus the Linux `/proc/<pid>/environ` allowlist assertion (~25), the
  signal test with its bounded poll for the resolver's child, its pgid bookkeeping and its
  `SIGSTOP` freeze (~35), the cleanup assertions
  (~50), the pin-constant assertions over ten pins (~25), the command-word allowlist grep
  plus the downloader and `git`-subcommand grep (~30),
  exit-status assertions (~15), harness
  boilerplate (~30), and the per-case temporary directory setup and teardown (~45).
- **Docs and manifest ~60 lines.** `docs/components.md:33-39`, the `README.md:252` row,
  `RESTORE.md:43-46`, and three lines appended to `ci/required-files.txt`.

Those sum to about 1855 lines; the range above is that sum with ~15% headroom at both
ends. It grew from 1350-1800 two rounds ago, then 1560-2120, and the growth is itemised
above rather than absorbed: ~90 more in the parent (the two extra blob pins, the request
and map check, the signal handlers), ~25 more in the entry (eight more pins), and ~155
more in the test (thirteen more direct-parent cases, the R3 environment proof, the signal
test). This round moves ~15 net lines, all of them in the test and all of them from the
three findings: the unsupported-platform case leaves the runtime list for code review
(−10), the overlong-value case grows a near-`PATH_MAX` directory fixture (+10), and the
downloader grep becomes a full command-word allowlist grep plus a `git`-subcommand
assertion (+15). No implementation code changed size, because none of the three findings
changed what the shipped files do. Nothing was made cheaper to compensate.

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
requests too, and this one exceeds it by more than double: `wc -l
work/resolver-trusted-parent/spec.md` is 1012 lines. Accepted as one concern: one
high-risk security-boundary spec whose review
rounds each added a verified requirement (offline jq, attestable provenance, cleanup,
compiler temporaries, narrowed read claims, the full pinned load set, process-group
termination on signals, per-check direct-parent coverage, and this round an exact
executable allowlist and two claims moved from untestable runtime cases to code review).
**Evidence-based range: 860-1164 lines** — the measured 1012 lines plus or minus 15%. It was
553 lines and 470-636 three rounds ago, then 783, then 847; where each block of growth
went is worth naming so it can be checked rather than taken on trust. The 230 lines of
the round before last were its three findings: about 65 enumerating the runtime's loaded
set with its
evidence and deciding the pins (R5), about 40 restructuring R10's refusals into
owner-labelled groups with one line per case, about 25 on the signal decision in R2 and
its test, and the rest spread over R1, R7, the Design steps, three Areas-of-concern
bullets and the re-derived size figures. The 64 lines of the previous round were its two
findings: about 27 stating pin ownership once and naming the parent-pinned subset with
its residual (R5, echoed in R1, R7 and R10), about 28 replacing the signal test's
fallback with the `SIGSTOP` freeze and its failure case (R10, echoed in R2 and Areas of
concern), and the remaining handful in re-derived size figures.
The 165 lines of this round are its three findings, and this one is mostly one of them:
about 55 replacing R7's seven-tool read list with the exact twelve-command enumeration per
shipped file and the four path-policy choices behind it, about 30 explaining why the
overlong-value case now aims at the output path (R10, echoed in R5), about 25 on the
unsupported-platform refusal becoming code-review coverage (R10, echoed in R8, Design
step 2 and Areas of concern), about 11 turning the read list into R10's command-word
grep, and the rest in the Copy-versus-adapt deviation list and these re-derived figures.
Two of the three findings shrink what the spec claims rather than adding requirements; the
lines are the cost of saying precisely what is no longer claimed.
This waives only the soft line signal for this artifact pull request. It waives nothing
else: one concern per PR, readability, the review itself, CI, and operator merge all
still apply, and an unexplained overrun beyond
the range above still blocks review.

## Requirements

- **R1 — two shipped files.** `resolver/v1/trusted-launch.c` is the parent.
  `resolver/v1/resolve-profile.sh` is a thin entry that checks the jq it was handed,
  compiles the parent and `resolver/v1/nofollow-snapshot.c` from the committed sources,
  then runs the parent as a child and waits for it. The entry does **not** `exec` the
  parent: it needs to outlive it so it can delete the run directory, which an `exec`
  would make impossible because the entry's `EXIT` trap would never run and the
  compiled parent, the compiled helper, the compiler's own intermediates, and the copied
  jq and awk would be left behind on every invocation. The entry passes the child's
  stdout and stderr through unchanged (it does not capture, buffer or rewrite them), and
  exits with the child's own exit status, or `128 + signal` when the child died on a
  signal. Its `EXIT` trap removes the run directory; it also traps `INT`, `TERM` and
  `HUP`, and on those it **forwards the same signal to the parent, waits for the parent to
  exit, and only then** removes the run directory and re-raises the signal so the caller
  sees the normal signal death. That order is the whole point: the parent, not the entry,
  terminates the resolver's process group (R2), so the entry must never remove the run
  directory while a resolver could still be running out of it. A bash `wait` returns as
  soon as the trap fires, so the trap forwards the signal and then waits for the parent a
  second time; the removal happens after that second wait returns. Because the trap runs
  against a run
  directory the entry has by then set to mode 0500 (below), the trap restores mode 0700
  on the directory before removing it — harmlessly a no-op when the trap fires earlier
  than that, while the directory is still 0700. Nothing shipped reads `scripts/test/`.
  The split follows the test today: the test
  script owns compilation, jq binding and platform choice
  (`scripts/test/portable-profile-resolution.test.sh:90-151`), and the C file owns only
  the launch.

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
  checks `git hash-object resolver/v1/nofollow-snapshot.c` and
  `git hash-object resolver/v1/trusted-launch.c` against blob ids pinned as constants in
  the entry, the way the runtime pins its own dependencies
  (`scripts/lib/profile-resolution.sh:7-10,711-717`). In the same pass it pins the whole
  set of files the runtime itself loads, which R5 enumerates: the runtime script, the
  library it sources, the resolver jq program, and the five jq modules the core contract
  imports. Pinning the whole set is the entry's job alone; the parent later re-checks only
  the first three of them (the parent-pinned subset, R5). The pinned constants carry a
  `# pinned at <commit>` header naming the commit they were read from, and the focused
  test asserts they equal the working tree's blob ids, so a source edit that forgets the
  pin fails CI rather than shipping. A mismatch on any of them is `E_RUNTIME` before any
  compile. The
  entry then creates a fresh private run directory for this invocation — `mktemp -d`
  under `TMPDIR`, mode 0700, owned by the current uid, removed on exit — and inside it a
  `tmp` subdirectory at mode 0700 for the compiler's scratch files. It compiles both C
  files from those pinned sources into the run directory with the fixed flags
  (`portable-profile-resolution.test.sh:146-149`), each compile run with
  `TMPDIR=<run dir>/tmp` in its environment and with `-o` naming a path inside the run
  directory, so that the compiler's intermediates — preprocessor output, assembler input,
  temporary object files — land inside the run directory and are removed by the same
  cleanup that removes everything else, rather than being left in the caller's `TMPDIR`
  where nothing tracks them. Passing `-pipe` as well is preferred wherever the compiler
  accepts it, because it keeps most intermediates off disk altogether; it is not required
  and the entry must work without it.

  The entry then copies in the bound jq and the platform's awk, and then — only after both
  compiles have finished — empties and removes the `tmp` subdirectory and tightens modes
  before anything is launched: every file in the run directory (the compiled parent, the
  compiled helper, the jq copy, the awk copy) is
  set to mode 0500, and the run directory itself is set to mode 0500. The order is
  load-bearing: compilation happens while the run directory is still 0700 and writable,
  and the 0500 tightening happens strictly afterwards, so the compiler is never asked to
  write into a directory that admits no new entries. Removing `tmp` before the tightening
  is what keeps the R5 checks simple — at launch the run directory holds only those four
  files and no subdirectory. A 0500 directory admits no new entries and no renames, and
  0500 files admit no writes, so from that
  moment nothing in the run directory can be added, replaced or overwritten without a
  `chmod` first. This is a deliberate deviation from the test, which uses 0555 for the
  copied jq and awk (`portable-profile-resolution.test.sh:130-143`); 0500 is the same
  minus the group and other bits, which nothing in the shipped path needs. Only after
  the mode pass does the entry launch the parent, handing it the helper path inside that
  directory along with the directory itself.
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
  `sigaction` and no `signal()` call anywhere in the file; the only group kill is on the
  limit paths (`kill(-child, SIGKILL)` at `:491`, then `kill(child, SIGKILL)` at `:492`,
  reaped at `:493-494`). So a `TERM` to the launcher kills the launcher on the default
  disposition and leaves the resolver's whole process group running, orphaned. That is
  harmless in a test that runs to completion; in the shipped path it means an entry trap
  that kills only its direct child would delete the run directory — the compiled helper,
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
- **R3 — the environment is built from empty, with exactly this allowlist.** From
  `portable-profile-resolution-launcher.c:645-690`, and nothing else:
  `HOME=<sandbox>/home` and `TMPDIR=<sandbox>/tmp` (both created by the parent, mode
  0700, `:645-647`), `LC_ALL=C`, `PATH=<dir of the bound jq>:/usr/bin:/bin` (`:662-677`),
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
  is not an empty directory the caller owns at mode 0700, mirroring the sandbox rule the
  test uses (`portable-profile-resolution.test.sh:219-222`).

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
  constants carrying the same `# pinned at <commit>` header, checked with
  `/usr/bin/git hash-object` before any compile, a mismatch being `E_RUNTIME` before the
  compile. **The parent
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
  tree's `git hash-object` output, so an edit that forgets a pin fails CI rather than
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
    exactly the run directory the entry named, compared after resolving both with
    `realpath`.

  There is no identity probe to add. The runtime gives jq a `--version` probe (`:668-671`)
  but gives the helper none, and the helper has exactly one subcommand,
  `snapshot-repository`, with a fixed nine-argument shape
  (`resolver/v1/nofollow-snapshot.c:2678-2682`), so there is nothing safe to call for an
  identity answer.

  **Stated residual — a same-uid attacker who can `chmod` can still race this.** Modes
  0500 stop a write and stop a rename; they do not stop the owner from running `chmod
  0700` on the directory or the file and then replacing the helper in the window between
  the parent's check and the moment the runtime execs that path. Every mode and ownership
  check above is against the current uid, so a process already running as that uid is
  inside all of them. This is not closed here, and the spec does not claim it is. It is
  unchanged from the boundary the accepted resolver spec already assumes: the security
  boundary begins in a trusted parent process that was already running before any hostile
  input arrived, and a helper newly started from a hostile environment is not that parent
  (`work/portable-profile-resolution/spec.md:219-222`). Root is likewise outside: root can
  write into any directory and replace any file regardless of mode.

  What the checks do buy: the entry compiled both binaries this invocation from sources
  whose blob ids match the pins, into a directory it created; the parent refuses to launch
  if, at check time, anything about those files or that directory has been loosened or
  moved. After that, the runtime's own `[ -x ] && [ ! -L ]` is the last line, and the spec
  says so rather than pretending otherwise.

  Closing the residual properly needs the runtime to accept an already-opened executable
  descriptor from the parent instead of a path — then check and exec are the same object
  and no `chmod` race exists. That is a change to
  `scripts/lib/profile-resolution.sh` and to the resolver's launch contract, both of which
  this initiative explicitly does not touch, so it is a separate initiative and is recorded
  under Out of scope as the recommended follow-up. It is not promised here.
- **R6 — the output is the runtime's bytes.** Success writes exactly the canonical
  `resolved_profile` the runtime prints on stdout (`scripts/lib/profile-resolution.sh:973`),
  streamed unchanged (`portable-profile-resolution-launcher.c:504-511`). For the same
  request the shipped parent and the test launcher produce byte-identical output; the
  focused test runs both and `cmp`s them.
- **R7 — the shipped path never touches the network, and widens nothing.** No network, no
  credential, and exactly two write locations, named exactly:

  1. *The run directory the entry created for this invocation*, including its `tmp`
     subdirectory: the two compiled binaries, the jq and awk copies, and the compiler
     intermediates that `TMPDIR=<run dir>/tmp` keeps inside it. The `tmp` subdirectory is
     emptied and removed once compilation is done, before the 0500 tightening; the rest
     goes when the entry's trap removes the run directory.
  2. *The output path the caller named*, which the parent also uses as the sandbox root:
     the `home` and `tmp` directories the parent creates there at mode 0700 (R3), the
     supervisor's captured `child.stdout` and `child.stderr`
     (`portable-profile-resolution-launcher.c:413-414`), and the runtime's own `mktemp -d`
     scratch under that sandbox `TMPDIR`. The resolved profile itself is not written to a
     file; it goes to the parent's stdout, which the entry passes through (R6).

  Nothing outside those two is written. Not the caller's own `TMPDIR` — the run directory
  is created there and is itself location 1, but no sibling file is ever left beside it,
  which is exactly why the compile step redirects `TMPDIR` inward. Not the repository
  working tree, not a cache, not a dotfile, not a temporary file anywhere else on the
  filesystem.

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
     an argument; the caller's output directory; and the entry's own run directory.

     **The executables, listed exactly.** The previous round's list was short enough to be
     wrong. It named seven — the compiler, `/bin/bash`, `/bin/mkdir`, `/bin/cp`,
     `/bin/chmod`, `/usr/bin/git` and the SHA-256 tool — and left out four the spec's own
     steps need: `/usr/bin/uname` for the platform case, `/usr/bin/mktemp` for the run
     directory, `/bin/rm` for the cleanup, and `/usr/bin/printf` for the `E_*` lines. It
     also left `/usr/bin/awk` ambiguous, mentioning it as a file to copy without saying
     whether anything runs it. Twelve command words is the true count. Every external
     command either file runs, with the fixed absolute path it runs it by:

     *The entry, `resolver/v1/resolve-profile.sh`* — `/usr/bin/uname` (`-s` and `-m`, for
     the platform case); the platform's SHA-256 tool, `/usr/bin/shasum -a 256` on Darwin
     and `/usr/bin/sha256sum` on Linux, chosen in the same `case` that chooses the jq
     digest pin; `/usr/bin/git`, for `hash-object` on the ten pinned files;
     `/usr/bin/mktemp`, for the run directory; `/bin/mkdir`, for the `tmp` subdirectory;
     the compiler `/usr/bin/cc`; `/bin/cp`, for the jq and awk copies; `/usr/bin/awk`,
     read only in order to be copied in, because the runtime needs awk on its `PATH`;
     `/usr/bin/printf`, for the `E_*` lines and, on Darwin, for writing the awk shim;
     `/bin/chmod`, for the 0500 pass and the trap's 0700 restore; `/bin/rm`, for the `tmp`
     subdirectory and the run directory; `/bin/bash`, which is its own interpreter and the
     Darwin awk shim's; the bound jq, for the `--version` probe; and the compiled parent
     inside the run directory, which it runs as its child.

     *The parent, `resolver/v1/trusted-launch.c`* — `/bin/bash`, `execve`d with the fixed
     argv R2 gives (`portable-profile-resolution-launcher.c:652-657,701`); `/usr/bin/git`,
     for `hash-object` on the parent-pinned subset; the same per-platform SHA-256 tool,
     for the jq digest; and the bound jq, for its own `--version` probe. Nothing else. The
     sandbox `home` and `tmp` directories come from `mkdir(2)` (`:645-647`), not from
     `/bin/mkdir`, and every mode and ownership check is an `fstat` on a descriptor the
     parent opened, not a call to `/usr/bin/stat`.

     Four choices inside that list are named because each is a place the shipped path
     deliberately differs from the code it copies:

     - **The compiler is `/usr/bin/cc`, a fixed path on both platforms, and `$CC` is not
       honoured.** The test script uses `${CC:-/usr/bin/cc}` on Linux and
       `${CC:-/usr/bin/clang}` on Darwin
       (`scripts/test/portable-profile-resolution.test.sh:95,102`, invoked at `:146-149`).
       A caller-chosen compiler is a caller-chosen trust base, so the entry drops the
       override. `/usr/bin/cc` exists on both platforms, and on Darwin it is the same
       Xcode shim as `/usr/bin/clang`. This is a named deviation from the test.
     - **The SHA-256 tool is chosen per platform, at a fixed path, and never searched
       for.** The test script's `sha256_file` searches `PATH` with `command -v sha256sum`
       (`:31-37`), which the shipped path must not do, and
       `shadow/v1/reproduce.sh:18` uses `/usr/bin/shasum -a 256` on both platforms, which
       is right on Darwin but not guaranteed on Linux, where `/usr/bin/sha256sum` is the
       native tool and `/usr/bin/shasum` ships only with perl. Hence the pair above.
     - **No `awk` process is spawned to read a digest.** `reproduce.sh:18` pipes the
       SHA-256 tool through `/usr/bin/awk '{print $1}'`; the entry takes the first field
       with a bash parameter expansion and the parent parses it in C, so awk is on this
       list only as the file copied in for the runtime's benefit.
     - **No `find` and no `stat`.** The 0500 pass names the four files it tightens — the
       compiled parent, the compiled helper, the jq copy, the awk copy — instead of
       discovering them, which is the same fact as the run directory holding exactly those
       four and no subdirectory at launch (R1). So neither tool is on the list.

     That is the whole list, and R10 turns it into a checked invariant rather than prose:
     the focused test greps both shipped files for every command word and fails if any
     absolute executable path outside this list appears. Neither file reads a
     configuration file, a dotfile, a cache, a credential store, or any path derived from
     caller environment. What the compiler reads from its own installation — headers, the
     assembler, the linker — is outside this list and outside the claim; the compiler is
     trusted unverified, as Areas of concern says.

  No network is true by construction, not by
  policy: neither shipped file contains a downloader, and every input the shipped path
  needs — the jq binary, the C sources, the runtime — is either handed in as an argument
  or already committed in this repository. The runtime's own guarantees are restated, not
  extended: git runs with system and global config disabled,
  `protocol.file.allow=never` and `GIT_NO_LAZY_FETCH=1`
  (`scripts/lib/profile-resolution.sh:313-322`); every working file goes into the
  runtime's own `mktemp -d` scratch under `TMPDIR` at umask 077
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
  the resolver files correctly. Both new files plus the new test are appended at the END
  of `ci/required-files.txt`. The accepted resolver spec itself is not edited.
- **R10 — the focused test.** `scripts/test/resolver-trusted-launch.test.sh` provisions
  the pinned jq the way `scripts/test/shadow-slice.test.sh:24-51` does, runs the shipped
  entry with that binary as its argument, builds a resolution request naming the real
  committed `profiles/default/v1` profile and manifest objects with this repository as
  the mapped root, resolves it through the shipped parent and through the test launcher,
  and `cmp`s the two outputs. The refusals fall into three groups, and the test labels
  which owner each one belongs to, because the groups prove different things.

  **Group 1 — entry-owned refusals**, driven through the shipped entry: a jq whose SHA-256
  does not match the platform pin; an edited `resolver/v1/nofollow-snapshot.c` whose blob
  id no longer matches its pin; an edited `scripts/lib/profile-resolution.sh` and an
  edited `resolver/v1/profile-resolution.jq`, same thing; and an edited jq module under
  the generation's `modules/` directory, which the entry pins and the parent does not
  (R5). Every case here and in group 2 that needs an edited
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
  `E_RUNTIME` before any pin check, any compile and any `mktemp -d`. Second the negative
  fact that makes the refusal total: those same three tuples, and no others, are the whole
  of every per-platform table in the entry — the jq digest pin (two digests, three
  tuples), the SHA-256 tool choice, the awk branch — so an unrecognised platform has no
  digest, no hashing tool and no awk branch to fall through to even if the `*)` arm were
  deleted. Anyone reviewing the `case` should read those tables in the same pass; all four
  must agree on the same three tuples. R8 says the same, and neither the test nor this
  spec claims a runtime case for it.

  **Group 2 — parent-owned refusals, each proved by invoking `trusted-launch` directly**,
  bypassing the entry. This group carries the weight: the entry refuses a bad jq before
  the parent ever runs, so an entry-level case alone proves nothing about the parent's own
  copy of that check. The test builds a run directory by hand the way the entry would,
  compiles the parent and the helper into it, tightens the modes, and then invokes the
  parent directly — one case each for:

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
  - an output directory that is not empty, and one whose mode is not 0700.

  Each case asserts the parent's own `E_*` line on stderr and a non-zero exit, so it fails
  if a check is ever quietly left to the entry. Those cases, and no others, are what "the
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
  is repeated with a deliberately polluted caller environment — `FOO=bar`, `LD_PRELOAD`,
  `DYLD_INSERT_LIBRARIES`, `BASH_ENV`, `ENV`, and both
  `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS=1` and `YSTACK_RESOLVER_TEST_GIT_STOP=1` — and
  the test asserts its stdout is byte-identical to the clean run's. Third, on Linux CI
  only, the test reads `/proc/<child pid>/environ` of the launched runtime while it runs
  and asserts the environment is exactly R3's allowlist — no extra entry and no missing
  one. Darwin has no unprivileged equivalent, so there the claim rests on the verbatim
  copy plus the byte-identical output, with the exact-allowlist assertion coming from
  Linux CI. That third assertion is also what proves the test-only variables cannot be
  inherited: they are absent from the child's environ even when both are set in the
  caller's.

  **Cleanup is asserted, using refusals that happen after the run directory exists.** The
  entry runs the parent as a child and removes the run directory in its `EXIT` trap (R1),
  so the test gives the entry a fresh empty `TMPDIR` of its own and asserts that directory
  is empty again after the entry returns. Which refusal is used matters. The wrong-digest
  jq refusal fires during the pin check, before `mktemp -d` has run at all, so it proves
  only that the entry never created a run directory — not that the trap removes one. It
  stays in the test as a pin-check case and is not cited as cleanup evidence anywhere.
  Three cases carry the cleanup claim, each asserting the entry's `TMPDIR` is empty
  afterwards; two of them are refusal cases the list above already includes, and the
  cleanup claim adds the `TMPDIR`-empty assertion to them:

  1. *A successful resolution.* The run directory existed, was tightened to 0500, and is
     gone afterwards — which also proves the trap's `chmod 0700` is there, because without
     it the entries of a 0500 directory cannot be unlinked.
  2. *A refusal by the parent, after the run directory and the trap both exist.* The test
     hands the entry a runtime file copied to mode 0755 instead of 0644, so the entry
     checks every pin, compiles both binaries, removes `tmp`, tightens everything to 0500 and
     launches, and the parent refuses on the runtime-mode check it owns (R5). The trap
     therefore fires against a fully built, fully tightened run directory.
  3. *A refusal by the runtime, deeper still.* A malformed request document, which the
     parent accepts as a canonical regular file and passes through and the runtime refuses.
     The child exits non-zero only after the resolver has run and created its own scratch
     under the sandbox, and the entry's trap still leaves `TMPDIR` empty.

  No entry output is needed for any of this and the entry is not asked to print its run
  directory path. The test also asserts the entry's exit status is 0 in case 1 and equals
  the child's own non-zero status in cases 2 and 3.

  **A signal mid-run is tested, and the test is deterministic because it freezes the
  resolver before signalling.** R2's group termination has no other proof, so the signal
  path has to run every time rather than whenever the timing happens to work out. The test
  starts the entry in the background on a real resolution — the default profile request
  with this repository as the mapped root — and then, before it signals anything, waits for
  the resolver to actually be running: it polls `pgrep -P <entry pid>` for the entry's only
  child, the parent, and then polls for the parent's own child, the launched runtime, up to
  a bounded number of short waits. Once that child exists the test records the resolver's
  process group id — from the parent's own bookkeeping where the parent reports it,
  otherwise `ps -o pgid= -p <child pid>` — and sends `SIGSTOP` to that whole group. A
  stopped group cannot make progress and cannot finish, so from that moment the run will
  not end on its own and there is no race left to lose. Only then does the test send
  `SIGTERM` to the entry.

  What must follow, in order: the entry forwards `SIGTERM` to the parent and waits; the
  parent's handler sends `kill(-pgid, SIGTERM)`, waits briefly, then sends
  `kill(-pgid, SIGKILL)`, which is what actually kills the frozen group, reaps the child
  and exits `128 + 15`; the entry's second wait returns, its trap chmods the run directory
  back to 0700 and removes it, and the entry exits `143`. The test asserts the three
  observable ends of that: `pgrep -g <pgid>` finds no process and `kill -0` on the group
  fails, the entry's own `TMPDIR` is empty so the run directory is gone, and the entry's
  exit status is `143`, which is `128 + SIGTERM`.

  **If the resolver's child never appears, the test fails.** There is no fallback in which
  a completed run counts as signal coverage, because a run that finished before the child
  could be seen proves nothing about group termination. The bounded poll expiring is a test
  failure, with a message saying the fixture was too short on this machine. The fix is one
  of two, decided in the plan rather than papered over at run time: enlarge the fixture so
  the resolution takes long enough for the child to be observed, or drive the parent
  directly in the group-2 style with a deterministic pause in the launched runtime so the
  child is guaranteed to exist before the test signals. Either way the `SIGSTOP` freeze
  runs, and the mid-run path is exercised on every platform the test runs on.

  The test also
  asserts every pinned blob constant equals the working tree's `git hash-object` output —
  the two C sources and all eight files of the runtime's loaded set that R5 enumerates as
  entry-pinned, and separately, in the parent, the three constants of the parent-pinned
  subset.

  **The read allowlist is a grep, not a promise.** The test greps both shipped files for
  every command word — every absolute path under `/usr/bin` or `/bin` and every bare
  command name — and fails unless each one appears in R7's list: `/bin/bash`,
  `/bin/mkdir`, `/bin/cp`, `/bin/chmod`, `/bin/rm`, `/usr/bin/uname`, `/usr/bin/mktemp`,
  `/usr/bin/git`, `/usr/bin/awk`, `/usr/bin/printf`, `/usr/bin/cc`, and the platform pair
  `/usr/bin/shasum` and `/usr/bin/sha256sum`. Anything else — a new tool, a bare name that
  would be resolved through `PATH`, a `${CC:-…}` style override — fails CI, which is what
  makes R7's list an invariant rather than a paragraph someone has to keep true by hand.
  The downloader grep that was already here stays alongside it, because the allowlist
  cannot replace all of it: `curl`, `wget` and `nc` would fail the allowlist as
  unlisted commands, but `/usr/bin/git` is on the list, so `git fetch` and `git clone`
  need their own assertion that no subcommand other than `hash-object` appears. The test
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
   run-directory and mode-0500 checks, that the test script performs today or cannot
   perform at all. Every mode and ownership check is done with `fstat` on a descriptor
   the parent opened (`O_DIRECTORY|O_NOFOLLOW` for the run directory), never with `stat`
   on a path it will later hand on by name. Two blocks here have no counterpart in the
   copied source and are written fresh: the blob-id pins for the three loaded files the
   parent re-checks (the runtime, `scripts/lib/profile-resolution.sh` and
   `resolver/v1/profile-resolution.jq`, all located from the runtime path with the
   runtime's own repository-root rule, `resolver/v1/profile-resolve-runtime.sh:9-10`), and
   the `INT`/`TERM`/`HUP` handlers that terminate the child's process group with
   `kill(-pgid, SIGTERM)` then `kill(-pgid, SIGKILL)`, reap, and exit `128 + signal` (R2).
2. **`resolver/v1/resolve-profile.sh`** — in this order, each step refusing with
   `E_RUNTIME` before the next: resolve the repository root from its own `BASH_SOURCE`
   the way the runtime does (`resolver/v1/profile-resolve-runtime.sh:4-16`); refuse an
   unsupported platform, from a `case` over `/usr/bin/uname -s` and `-m` with one arm per
   supported tuple and a refusing `*)` arm, which is the branch R10 covers by review
   rather than by a test case; **pin check** — verify the jq passed as an argument
   against this
   platform's SHA-256 and `jq-1.6` (`shadow/v1/reproduce.sh:113-118`), and verify with
   `git hash-object` the blob ids of both C sources and of the eight loaded files R5 lists
   as entry-pinned, against the pinned constants, the way the
   runtime pins its own dependencies (`scripts/lib/profile-resolution.sh:711-717`);
   create a fresh 0700 run directory with `mktemp -d`, plus a 0700 `tmp` subdirectory
   inside it for compiler scratch, and install the `EXIT`/`INT`/`TERM`/`HUP` trap that
   removes the whole run directory (the trap chmods the directory back to 0700 first,
   because by launch time it is 0500 and a 0500 directory will not let its entries be
   unlinked; on the three signals it first forwards the signal to the parent and waits for
   the parent to exit, and removes nothing until that wait returns, because the parent is
   what terminates the resolver's process group — R2);
   **compile** — both C files from those pinned sources into the run directory with the
   exact flags the test uses, `-std=c11 -O2 -Wall -Wextra -Werror -pedantic`
   (`portable-profile-resolution.test.sh:146-149`), invoking the fixed `/usr/bin/cc` on
   both platforms rather than the test's `${CC:-…}` (`:95,102`; R7), each compile carrying
   `TMPDIR=<run dir>/tmp` and an `-o` path inside the run directory, plus `-pipe` where
   the compiler accepts it, so no compiler intermediate is written outside the run
   directory; then copy in jq and the platform's awk the way the test does (`:130-143`);
   **tighten** — remove the `tmp` subdirectory and its contents, then `chmod 0500` every
   remaining file in the run directory and then `chmod 0500` the run directory itself, so
   the R5 checks pass and nothing further can be added or replaced there without a
   `chmod`; this step comes after both compiles for exactly that reason; clear `LD_*`,
   `DYLD_*`, `BASH_ENV` and `ENV` from its own environment; **then run the parent as a
   child** — not `exec`, so the trap survives to clean up — handing it the helper path and
   the run directory; **then wait**, pass the child's stdout and stderr through unchanged,
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
- **Closing the same-uid `chmod` race on the helper — the recommended follow-up, not done
  here.** The residual stated in R5 exists because the runtime takes the helper as a path
  and re-resolves it at exec time
  (`scripts/lib/profile-resolution.sh:209,664-667`). Closing it means changing the runtime
  to accept an executable descriptor from the parent — a `fexecve`-style handoff, or an
  `/dev/fd` path the parent opened — so the object checked and the object executed are the
  same. That is a change to the runtime and to the resolver's launch contract, both listed
  above as untouched, so it belongs to a separate initiative. This spec records it as the
  recommended next step and promises nothing about it.

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
  unreachable. That is all. There is no third-party audit, no fuzzing, no formal argument
  that the allowlist is complete, and no launch-evidence record — nothing this produces is
  live-qualified (`work/portable-profile-resolution/spec.md:264-271`). The read allowlist
  is the one claim here with a mechanical check behind it: R10's command-word grep fails
  CI on any executable path outside R7's list.
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
  (`:664-667`), so a same-uid process that can `chmod` the run directory or the helper back
  to writable can still swap the file in the window between the check and that exec. That
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
  have been. Its one test is at least deterministic: R10 stops the resolver's process group
  with `SIGSTOP` before signalling the entry, so the path is exercised on every run, and a
  run that finishes before the resolver's child appears fails the test rather than passing
  on a weaker claim. The plan
  should treat this as the highest-risk new code here and say what it does on `EINTR` in
  `waitpid`, on a second signal during termination, on an already-reaped child, and on a
  group whose members are stopped when the handler fires.
- **Cleanup is best-effort, and the extra process is the price.** Waiting instead of
  `exec`ing is what makes cleanup possible at all, but a trap is not a guarantee: `SIGKILL`
  on the entry, or a power loss, leaves the run directory behind, and its 0500 mode makes
  the leftovers slightly annoying to delete by hand. `SIGKILL` on the entry cannot be
  forwarded either, so in that case the parent keeps running and its own handlers never
  fire — the resolver group is reaped by the parent's normal exit rather than by a signal,
  which is the right outcome, but nothing removes the run directory afterwards.
  The leftovers are inert — compiled
  binaries, copies of jq and awk, and, if the kill landed mid-compile, whatever the
  compiler had written into the `tmp` subdirectory, all inside one private directory under
  `TMPDIR`, owned by the caller — but they are leftovers, and the honest statement is
  "removed on every exit the entry can observe", not "never leaks". Not `exec`ing also
  leaves one extra shell in the process tree for the life of the resolution; it holds no
  state and does nothing but wait, and it is outside the sandbox and the parent's
  limits, so it does not widen what the resolution can do.
- **The entry script is a convenience, not part of the boundary.** The accepted spec says
  a helper newly started from a hostile environment is not the trusted parent. The C
  parent's own dynamic loader still runs before it can clean anything, so a caller who
  controls `LD_*`/`DYLD_*` at that moment is inside the boundary already. Step 2 clears
  those variables, and the plan must say plainly that the strong claim holds only when the
  process starting the parent is itself trusted — the operator's own shell for the step-7
  run.
- **Copy versus adapt.** The test launcher is 702 lines, and far less of it is test
  scaffolding than a glance suggests: only the argv modes at `:547-631` and the two
  test-variable lines at `:686-689` are test-only, so the parent copies roughly 605 lines
  of it (see the size derivation above). Copying the supervisor verbatim keeps the proven
  behaviour but carries code written for a test harness; adapting risks a subtle
  divergence in exactly the code that enforces the limits. The plan should list every
  deviation line by line. Six are already known: the mode-0644 check moves from the test
  into the parent; inherited descriptors above 2 are
  closed explicitly rather than relying on the launcher's `O_CLOEXEC` on its own opens;
  the helper's run-directory and mode-0500 checks are new code with no counterpart in
  the test launcher, which simply trusts the path the test script hands it; the blob pins
  for the runtime, `scripts/lib/profile-resolution.sh` and
  `resolver/v1/profile-resolution.jq` are new (R5); the request and repository-map
  arguments get a regular-non-symlink check where the launcher checks only the leading
  slash (`portable-profile-resolution-launcher.c:636`); and the `INT`/`TERM`/`HUP`
  handlers with process-group termination are new (R2). Two more, smaller,
  are in the entry rather than the parent: the run directory's files are 0500,
  where the test uses 0555 for the copied jq and awk
  (`portable-profile-resolution.test.sh:130-143`); and the compiler is the fixed
  `/usr/bin/cc` on both platforms with no `$CC` override, where the test honours
  `${CC:-/usr/bin/cc}` and `${CC:-/usr/bin/clang}` (`:95,102`) — a caller-chosen compiler
  would be a caller-chosen trust base (R7).
- **Platform matrix.** Three tuples, but CI runs one. The other two are proved only when
  someone runs the test there, and the parent's Darwin memory bound is polled rather than
  enforced by the kernel (`portable-profile-resolution-launcher.c:381-386,390-392`). The
  fourth case — a platform that is none of the three — has no runtime coverage on any
  machine, because the entry reads `/usr/bin/uname` at a fixed path and nothing a test can
  set changes the answer. R10 makes that a code-review item rather than adding a test-only
  platform override to the security wrapper, and the plan should treat the `case` and the
  per-platform tables (jq digests, SHA-256 tool, awk branch) as one thing to read
  together: all four must agree on the same three tuples.
- **Test-only variables.** The runtime accepts `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS` and
  `YSTACK_RESOLVER_TEST_GIT_STOP` when both are `1`
  (`scripts/lib/profile-resolution.sh:656-659`). The shipped parent cannot set them, and
  the test must prove it cannot — otherwise a production path inherits a test escape. The
  proof is the R3 block in R10: both variables are set in the polluted caller environment,
  and the Linux `/proc/<child pid>/environ` read asserts the child's environment is exactly
  the allowlist, so their absence is asserted rather than assumed. On Darwin that
  assertion is unavailable and the claim rests on the copied environment block plus the
  byte-identical output — worth knowing, since Darwin is two of the three platforms.
