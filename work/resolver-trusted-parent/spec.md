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

`review_size: accepted-exception`. One concern: this is a single security-boundary
component whose only honest proof runs the real resolver twice and compares the
output. Evidence-based range: 600-900 changed lines (C ~250 copied/adapted, entry
shell ~180, focused test ~290, docs/manifest ~60). The entry shell and the test are
each larger than a first estimate because the entry now owns helper provenance — blob
pins, two compiles, a fresh private run directory — and the test proves each of those
separately.

## Requirements

- **R1 — two shipped files.** `resolver/v1/trusted-launch.c` is the parent.
  `resolver/v1/resolve-profile.sh` is a thin entry that checks the jq it was handed,
  compiles the parent and `resolver/v1/nofollow-snapshot.c` from the committed sources,
  then `exec`s the parent. Nothing shipped reads `scripts/test/`. The split follows the
  test today: the test script owns compilation, jq binding and platform choice
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
  under `TMPDIR`, mode 0700, owned by the current uid, removed on exit — compiles both C
  files from those pinned sources into it with the fixed flags
  (`portable-profile-resolution.test.sh:146-149`), and passes the helper path inside that
  directory to the parent along with the directory itself.
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
  `shadow/v1/reproduce.sh:113-118`); the helper fails the run-directory binding below;
  any allowlisted value is not an absolute
  regular path or is too long for the buffer (`:641-676`); the request or repository-map
  argument is not an absolute regular non-symlink file; or the caller's output directory
  is not an empty directory the caller owns at mode 0700, mirroring the sandbox rule the
  test uses (`portable-profile-resolution.test.sh:219-222`).

  **The helper's run-directory binding.** The parent cannot recompile the helper or
  recognise a binary by digest, so its check is a binding to the directory the entry
  built this run. The entry passes that directory as an argument alongside the helper
  path, and the parent refuses unless: the helper is a regular, non-symlink, executable
  file; the directory containing it is exactly the run directory it was given, compared
  after resolving both with `realpath`; that directory is itself a real directory, not a
  symlink, owned by the current uid, mode 0700, and not group- or world-writable; and
  the helper is owned by the current uid at mode 0700 or 0500 with no write bit for
  group or others. The parent checks the opened file, not the path, so the path cannot
  be swapped between check and use. There is no identity probe to add: the runtime's own
  helper check is only "executable and not a symlink"
  (`scripts/lib/profile-resolution.sh:664-667`) — jq gets a `--version` probe (`:668-671`)
  but the helper gets none — and the helper has exactly one subcommand,
  `snapshot-repository` with a fixed nine-argument shape
  (`resolver/v1/nofollow-snapshot.c:2678-2682`), so there is nothing safe to call for an
  identity answer. The binding is what the check rests on.

  What that proves: the helper the runtime will execute is the artifact this invocation
  compiled, from sources whose blob ids match the pins, in a directory this invocation
  created and no one else can write. What it does not prove: nothing here stops root on
  the host, who can write into any directory and replace any file. That is out of scope,
  and it is the boundary the accepted resolver spec already assumes — the security
  boundary begins in a parent process that was already running and trusted before any
  hostile input arrived (`work/portable-profile-resolution/spec.md:218-222`).
- **R6 — the output is the runtime's bytes.** Success writes exactly the canonical
  `resolved_profile` the runtime prints on stdout (`scripts/lib/profile-resolution.sh:973`),
  streamed unchanged (`portable-profile-resolution-launcher.c:504-511`). For the same
  request the shipped parent and the test launcher produce byte-identical output; the
  focused test runs both and `cmp`s them.
- **R7 — the shipped path never touches the network, and widens nothing.** No network,
  no credential, no write outside the caller's output path and the run directory, no read
  outside the repositories named in the map. No network is true by construction, not by
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
  and `cmp`s the two outputs. It proves each R5 refusal separately: an executable runtime
  file, a wrong-digest jq, a leaked caller variable, a non-empty output directory, and a
  malformed request. The swapped-helper case is now two cases, one per owner: the entry
  refuses when `resolver/v1/nofollow-snapshot.c` is edited so its blob id no longer
  matches the pin, and the parent refuses when it is handed a helper that lives outside
  the run directory it was given, or one whose directory is group-writable. The test also
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
   run-directory binding, that the test script performs today or cannot perform at all.
2. **`resolver/v1/resolve-profile.sh`** — in this order, each step refusing with
   `E_RUNTIME` before the next: resolve the repository root from its own `BASH_SOURCE`
   the way the runtime does (`resolver/v1/profile-resolve-runtime.sh:4-16`); refuse an
   unsupported platform; **pin check** — verify the jq passed as an argument against this
   platform's SHA-256 and `jq-1.6` (`shadow/v1/reproduce.sh:113-118`), and verify both C
   sources' blob ids against the pinned constants with `git hash-object`, the way the
   runtime pins its own dependencies (`scripts/lib/profile-resolution.sh:711-717`);
   create a fresh 0700 run directory with `mktemp -d` and remove it on exit; **compile** —
   both C files from those pinned sources into the run directory with the exact flags the
   test uses, `-std=c11 -O2 -Wall -Wextra -Werror -pedantic`
   (`portable-profile-resolution.test.sh:146-149`), `chmod 0500` both so they satisfy the
   binding in R5, and copy jq and the platform's awk in at the same mode the way the test
   does (`:130-143`); clear `LD_*`, `DYLD_*`, `BASH_ENV` and
   `ENV` from its own environment; **then `exec` the parent**, handing it the helper path
   and the run directory so it can bind one to the other. No step reaches the network.
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
  blobs, compiles in a fresh private directory, and hands the parent both the helper and
  that directory; the parent binds one to the other. Together that means the helper the
  runtime executes is the artifact this invocation built from pinned sources. It stops
  at root: a root user on the host can write into the run directory, or replace the
  binary between compile and `execve`, and nothing here detects it. The same is true of
  the compiler itself, which is trusted unverified. Both sit outside the boundary the
  accepted resolver spec draws — it assumes the starting process is already trusted
  (`work/portable-profile-resolution/spec.md:218-222`) — and the plan should say so
  rather than imply the check is stronger than it is.
- **The entry script is a convenience, not part of the boundary.** The accepted spec says
  a helper newly started from a hostile environment is not the trusted parent. The C
  parent's own dynamic loader still runs before it can clean anything, so a caller who
  controls `LD_*`/`DYLD_*` at that moment is inside the boundary already. Step 2 clears
  those variables, and the plan must say plainly that the strong claim holds only when the
  process starting the parent is itself trusted — the operator's own shell for the step-7
  run.
- **Copy versus adapt.** The test launcher is 702 lines and much of it is test scaffolding.
  Copying the supervisor verbatim keeps the proven behaviour but carries code written for
  a test harness; adapting risks a subtle divergence in exactly the code that enforces the
  limits. The plan should list every deviation line by line. Three are already known: the
  mode-0644 check moves from the test into the parent; inherited descriptors above 2 are
  closed explicitly rather than relying on the launcher's `O_CLOEXEC` on its own opens;
  and the helper's run-directory binding is new code with no counterpart in the test
  launcher, which simply trusts the path the test script hands it.
- **Platform matrix.** Three tuples, but CI runs one. The other two are proved only when
  someone runs the test there, and the parent's Darwin memory bound is polled rather than
  enforced by the kernel (`portable-profile-resolution-launcher.c:381-386,390-392`).
- **Test-only variables.** The runtime accepts `YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS` and
  `YSTACK_RESOLVER_TEST_GIT_STOP` when both are `1`
  (`scripts/lib/profile-resolution.sh:656-659`). The shipped parent cannot set them, and
  the test must prove it cannot — otherwise a production path inherits a test escape.
