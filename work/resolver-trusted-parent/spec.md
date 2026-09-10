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

**Evidence-based range: 1350-1800 changed lines** (implementation). The derivation,
measured rather than guessed:

- **C parent ~880 lines** = ~605 copied verbatim + ~275 new. The test launcher is 702
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
  the runtime mode-0644 and blob checks (~45), the parent's own jq digest and `jq-1.6`
  checks (~40), the three `fstat` run-directory checks in R5 (~90), the caller
  output-directory check (~25), closing inherited descriptors above 2 (~15), and the usage
  text and `E_*` exit paths those new checks need (~15). The biggest unknown in that ~275
  is how the parent computes digests: delegating to the platform's SHA-256 tool and
  `git hash-object` at fixed paths sits at the low end, while a SHA-256 implementation
  carried in the C file would add roughly 150 more lines. The
  plan decides that, and it is the one thing that could push the C file past ~1000.
- **Entry shell ~230 lines.** `shadow/v1/reproduce.sh:94-142` does the closest existing
  subset — self and repository-root resolution, platform case, jq digest pin, `mktemp -d`,
  the `EXIT`/`HUP`/`INT`/`TERM` traps, the bounded copy and the `--version` probe — in
  about 50 lines. The entry adds two `git hash-object` blob pins, two compiles, the awk
  copy, the `tmp` subdirectory, the `chmod 0500` pass, the
  `LD_*`/`DYLD_*`/`BASH_ENV`/`ENV` clearing, and run-as-child plus wait plus
  `128 + signal`, each step with its own `E_RUNTIME` exit.
- **Focused test ~400 lines.** For scale, the existing resolution test is 746 lines and
  `scripts/test/shadow-slice.test.sh` is 622. R10 is smaller than either, but not by much:
  jq provisioning the `shadow-slice` way (~30), request and map fixtures (~40), the two
  resolutions plus `cmp` (~30), five entry-level refusals (~60), three direct-parent cases
  that hand-build a run directory (~70), the cleanup assertions (~50), the pin-constant
  assertions (~20), the downloader grep (~15), exit-status assertions (~15), harness
  boilerplate (~30), and the per-case temporary directory setup and teardown (~40).
- **Docs and manifest ~60 lines.** `docs/components.md:33-39`, the `README.md:252` row,
  `RESTORE.md:43-46`, and three lines appended to `ci/required-files.txt`.

Those sum to about 1570 lines; the range above is that sum with ~15% headroom at both
ends.

**That is over ~1200 lines, and the recommendation is still one pull request.** The seam
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
requests too, and this one exceeds it: `wc -l work/resolver-trusted-parent/spec.md` is
553 lines. Accepted as one concern: one high-risk security-boundary spec whose review
rounds each added a verified requirement (offline jq, attestable provenance, cleanup,
compiler temporaries, narrowed read claims). **Evidence-based range: 470-636 lines** —
the measured 553 lines plus or minus 15%. This waives only the soft line signal for this
artifact pull request. It waives nothing else: one concern per PR, readability, the
review itself, CI, and operator merge all still apply, and an unexplained overrun beyond
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
  `HUP`, and on those it kills the child, removes the run directory, and re-raises the
  signal so the caller sees the normal signal death. Because the trap runs against a run
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
  (`scripts/lib/profile-resolution.sh:7-10,711-717`). The pinned constants carry a
  `# pinned at <commit>` header naming the commit they were read from, and the focused
  test asserts they equal the working tree's blob ids, so a source edit that forgets the
  pin fails CI rather than shipping. A mismatch is `E_RUNTIME` before any compile. The
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
  named in a comment and in the plan; R4 and R5 are the known ones.
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
  named deviation; the runtime file's blob is not the committed
  `resolver/v1/profile-resolve-runtime.sh` blob; the jq at the bound path does not match
  the pinned SHA-256 for the platform or does not answer `jq-1.6`
  (`portable-profile-resolution.test.sh:96-105,112-129`, mirroring
  `shadow/v1/reproduce.sh:113-118`); the helper fails the run-directory checks below;
  any allowlisted value is not an absolute
  regular path or is too long for the buffer (`:641-676`); the request or repository-map
  argument is not an absolute regular non-symlink file; or the caller's output directory
  is not an empty directory the caller owns at mode 0700, mirroring the sandbox rule the
  test uses (`portable-profile-resolution.test.sh:219-222`).

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
     compiled by the entry); the runtime file
     `resolver/v1/profile-resolve-runtime.sh` (blob- and mode-checked by the parent,
     then read by the bound `/bin/bash`); the jq binary supplied as an argument and its
     awk sibling under `/usr/bin` (both digest- or existence-checked, then copied into
     the run directory); the C compiler and the system tools the two files invoke by
     fixed path under `/usr/bin:/bin` — `/bin/bash`, `/bin/mkdir`, `/bin/cp`,
     `/bin/chmod`, `/usr/bin/git` for `hash-object`, and the platform's SHA-256 tool;
     the request file and the repository-map file named on the command line; and the
     entry's own run directory. That is the whole list. Neither file reads a
     configuration file, a dotfile, a cache, a credential store, or any path derived
     from caller environment.

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
  pinned jq digests. Anything else refuses with `E_RUNTIME` before doing work.
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
  and `cmp`s the two outputs. It proves each R5 refusal separately: a runtime file at mode
  0755 instead of 0644, a wrong-digest jq, a leaked caller variable, a non-empty output
  directory, and a malformed request document. The swapped-helper case is now two cases,
  one per owner: the entry refuses when `resolver/v1/nofollow-snapshot.c` is edited so its
  blob id no longer
  matches the pin, and the parent refuses when it is handed a helper that lives outside
  the run directory it was given, or one whose mode is not 0500, or one whose directory
  is not 0500.

  **Both levels are exercised, not just the entry.** The entry refuses a bad jq before the
  parent ever runs, so an entry-level case alone proves nothing about the parent's own
  copy of that check. The test therefore keeps the entry-level cases and adds direct-parent
  cases that bypass the entry: it builds a run directory by hand the way the entry would,
  compiles the parent and helper into it, and invokes `trusted-launch` directly with
  (a) a jq whose SHA-256 does not match the platform pin, (b) a jq whose bytes match
  nothing that answers `jq-1.6`, and (c) a runtime file copied to mode 0755 instead of
  0644 — since the parent, not the entry, owns the runtime-mode check (R5). Each case
  asserts the parent's own `E_*` line on stderr and a non-zero exit, so the assertion
  fails if the check is ever quietly left to the entry.

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
     hands the entry a runtime file copied to mode 0755 instead of 0644, so the entry pins
     both blobs, compiles both binaries, removes `tmp`, tightens everything to 0500 and
     launches, and the parent refuses on the runtime-mode check it owns (R5). The trap
     therefore fires against a fully built, fully tightened run directory.
  3. *A refusal by the runtime, deeper still.* A malformed request document, which the
     parent accepts as a canonical regular file and passes through and the runtime refuses.
     The child exits non-zero only after the resolver has run and created its own scratch
     under the sandbox, and the entry's trap still leaves `TMPDIR` empty.

  No entry output is needed for any of this and the entry is not asked to print its run
  directory path. The test also asserts the entry's exit status is 0 in case 1 and equals
  the child's own non-zero status in cases 2 and 3.

  The test also
  asserts the pinned blob constants equal the working tree's `git hash-object` output for
  both C sources, and greps both shipped files for any downloader — `curl`, `wget`,
  `nc`, `git fetch`, `git clone` — and fails if one appears. It is shellcheck-clean,
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
   on a path it will later hand on by name.
2. **`resolver/v1/resolve-profile.sh`** — in this order, each step refusing with
   `E_RUNTIME` before the next: resolve the repository root from its own `BASH_SOURCE`
   the way the runtime does (`resolver/v1/profile-resolve-runtime.sh:4-16`); refuse an
   unsupported platform; **pin check** — verify the jq passed as an argument against this
   platform's SHA-256 and `jq-1.6` (`shadow/v1/reproduce.sh:113-118`), and verify both C
   sources' blob ids against the pinned constants with `git hash-object`, the way the
   runtime pins its own dependencies (`scripts/lib/profile-resolution.sh:711-717`);
   create a fresh 0700 run directory with `mktemp -d`, plus a 0700 `tmp` subdirectory
   inside it for compiler scratch, and install the `EXIT`/`INT`/`TERM`/`HUP` trap that
   removes the whole run directory (the trap chmods the directory back to 0700 first,
   because by launch time it is 0500 and a 0500 directory will not let its entries be
   unlinked);
   **compile** — both C files from those pinned sources into the run directory with the
   exact flags the test uses, `-std=c11 -O2 -Wall -Wextra -Werror -pedantic`
   (`portable-profile-resolution.test.sh:146-149`), each compile carrying
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
  the test launcher's output for the default profile request, and each named refusal
  fires. That is all. There is no third-party audit, no fuzzing, no formal argument that
  the allowlist is complete, and no launch-evidence record — nothing this produces is
  live-qualified (`work/portable-profile-resolution/spec.md:264-271`).
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
- **Cleanup is best-effort, and the extra process is the price.** Waiting instead of
  `exec`ing is what makes cleanup possible at all, but a trap is not a guarantee: `SIGKILL`
  on the entry, or a power loss, leaves the run directory behind, and its 0500 mode makes
  the leftovers slightly annoying to delete by hand. The leftovers are inert — compiled
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
  deviation line by line. Three are already known: the mode-0644 check moves from the test
  into the parent; inherited descriptors above 2 are
  closed explicitly rather than relying on the launcher's `O_CLOEXEC` on its own opens;
  and the helper's run-directory and mode-0500 checks are new code with no counterpart in
  the test launcher, which simply trusts the path the test script hands it. A fourth,
  smaller one is in the entry rather than the parent: the run directory's files are 0500,
  where the test uses 0555 for the copied jq and awk
  (`portable-profile-resolution.test.sh:130-143`).
- **Platform matrix.** Three tuples, but CI runs one. The other two are proved only when
  someone runs the test there, and the parent's Darwin memory bound is polled rather than
  enforced by the kernel (`portable-profile-resolution-launcher.c:381-386,390-392`).
- **Test-only variables.** The runtime accepts `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS` and
  `YSTACK_RESOLVER_TEST_GIT_STOP` when both are `1`
  (`scripts/lib/profile-resolution.sh:656-659`). The shipped parent cannot set them, and
  the test must prove it cannot — otherwise a production path inherits a test escape.
