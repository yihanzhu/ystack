---
intent-blob: f898d102e1d68cea35590da17931ae021c6376f5
risk: high
drafted: 2026-09-27
---

# Spec: fixed file-digest verifier

Tracks #437. Step-8 child concern 3 (`work/step8-bounded-write-readiness/spec.md:293`),
second child of the sandbox decision (`work/real-sandbox-boundary/spec.md:158-159`).
It subsumes #314, whose requirements carry over unchanged. It ships one inactive
executable source, its build script and its tests. Nothing runs it in a sandbox,
and the shadow driver keeps `tool.git-blob-digest` (`shadow/v1/reproduce.sh:486-512`).
All citations are to origin/main at `272ec0f`.

## Requirements

### R1. Placement and identity

1. The verifier is one C11 source file, `verifiers/file-digest/v1/verifier.c`, built
   by `verifiers/file-digest/v1/build.sh`. C is chosen because the repository
   already builds a C helper with the host compiler and no acquisition
   (`scripts/test/candidate-content-preparation.test.sh:61`, compiling
   `adapters/local-git-materializer/v1/object-closure.c`), and one compiled file fits
   the fixed `/sandbox/tools/verifier` tool. It uses only POSIX.1-2008
   interfaces (`_POSIX_C_SOURCE 200809L`) plus `openat`, `fstatat`, `O_NOFOLLOW`,
   `O_DIRECTORY` and `O_NONBLOCK`, and contains its own FIPS 180-4 SHA-256. It
   links no library beyond the C runtime and executes no program.
2. `build.sh build <out-dir>` compiles with exactly `cc -std=c11 -Wall -Wextra -Werror
   -O2`, where `cc` is `/usr/bin/cc`, into `<out-dir>/verifier`, and writes
   `<out-dir>/build-record.json` (canonical `jq -S -c`, kind
   `file_digest_verifier_build`, `schema_version: 1`) with exactly:
   `source_sha256`, `build_script_sha256`, `compiler_path`, `compiler_version_sha256`
   (SHA-256 of `cc --version` stdout), `flags` (the list above), `platform`
   (`uname -s`:`uname -m`), `sandbox_root` (R1.4) and `executable_sha256`. It
   refuses an output directory that already exists, writes nothing else, uses no
   network and installs nothing.
3. **Identity levels.** The source digest is the stable, reviewable identity. The
   executable digest is a build identity for one compiler, flag set and platform.
   Two builds of the same source with the same compiler and flags in two different
   fresh directories on one host must be byte-identical; if a platform cannot meet
   that, the plan stops rather than waiving it. No cross-host or cross-compiler
   identity is claimed. The executable for the guest is built by concern 4 with the
   guest toolchain, and its digest is the one a receipt would name.
4. **Sandbox root.** The source has one build-time string, `YSTACK_SANDBOX_ROOT`,
   default `/sandbox`. Every fixed path (`/sandbox/candidate`, `/sandbox/evidence`,
   `/sandbox/tools`, `/sandbox/scratch`) and the expected argv and environment
   values are derived from it and nothing else. The production build uses the
   default and `build.sh` accepts no override. Tests build a second executable with
   only that define changed (R8.1).
5. **No accepted digest.** The demonstration policy keeps the all-ones tool digest
   (`control/v1/sandbox.jq:179-182`); `control/v1/**` is unchanged. This concern
   records build identities but adds no digest to any accepted set, policy or
   registry. A real digest becomes accepted only through the qualification of
   concern 4, and replacing the policy's tool digest is a separate reviewed control
   change for the consumer-integration concerns (`work/real-sandbox-boundary/spec.md:162-165`).

### R2. Invocation and environment

1. The only accepted argv, after `argv[0]`, is exactly `verify`, `--candidate`,
   `<root>/candidate`, `--evidence`, `<root>/evidence`
   (`control/v1/sandbox.jq:179-180`). Any other count, order, spelling, extra or
   missing argument exits `64` with `E_USAGE` on stderr, touches no file and reads
   no input. `argv[0]` is not inspected.
2. The environment must be exactly the four entries `LANG=C`, `LC_ALL=C`,
   `PATH=<root>/tools` and `TMPDIR=<root>/scratch` in any order
   (`control/v1/sandbox.jq:161-163`): no other entry, no duplicate, no other value.
   Otherwise exit `64` with `E_ENVIRONMENT`, as for R2.1. The verifier does not use
   any variable's value and never touches `<root>/scratch` or `<root>/tools`.

### R3. Trusted instruction transport and framing

1. **Transport.** The instruction arrives on file descriptor 0, which the
   supervisor opens from the instruction bytes it binds as the
   verification-instruction identity (`work/real-sandbox-boundary/spec.md:45-47`).
   This adds no argument, variable or candidate path, and no new authority channel:
   the supervisor already owns launch. fd 0 must be a regular file (`fstat`);
   otherwise the result is `instruction.transport-rejected`.
2. **Bytes.** Read at most 4,209 bytes, the longest valid instruction plus one. A
   valid instruction is exactly three LF-terminated ASCII-keyed lines and then EOF:

   ```text
   ystack.file-digest-instruction.v1
   path <path>
   sha256 <64 lowercase hex>
   ```

   One space follows each key. No CR, BOM, NUL, blank line, leading or trailing
   space, other key, reordering, repetition or byte after the third LF.
3. **Refusals.** More than 4,208 bytes: `instruction.oversize`. Any byte after the
   third LF: `instruction.trailing`. Any other framing error, a digest not 64
   lowercase hex, or invalid UTF-8 in `<path>` (overlong forms, surrogates, above
   U+10FFFF, truncation): `instruction.malformed`. A well-framed path outside R4:
   `instruction.path-rejected`.
4. Candidate content never selects the command, the path, the expected digest, the
   instruction or any authority. The verifier opens nothing under the candidate
   except the one instruction path, and reads nothing else from anywhere but fd 0.

### R4. Path rules

The verifier accepts exactly the paths `shadow/v1/incident-record.jq:30-38`
(`repo_path_ok`) accepts, as pinned jq 1.6 evaluates it. Enumerated from that
predicate:

1. 1 to 4,096 bytes of valid UTF-8.
2. No control character: U+0000-U+001F and U+007F-U+009F. This is the set pinned
   jq 1.6 matches for `[[:cntrl:]]`; U+00A0, U+00AD, U+200B, U+2028, U+FEFF,
   U+E000 and U+FFFF are not in it and are accepted.
3. No backslash; does not start with `/`.
4. Split on `/` into at most 64 components, none empty, `.` or `..`; none equal to
   `.git` after ASCII-only lowercasing; none ending in `.` or U+0020.

A differential test (R8.2) holds the verifier and the jq predicate to identical
accept and reject results over one shared corpus.

### R5. Reading the candidate file

1. Open `<root>/candidate` with `O_RDONLY|O_DIRECTORY|O_NOFOLLOW`. Walk each
   intermediate component with `fstatat(AT_SYMLINK_NOFOLLOW)` then
   `openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`. For the final component, `fstatat` with
   `AT_SYMLINK_NOFOLLOW` classifies it before any open.
2. Classification, closed: absent at any component `file.missing`; a symlink at any
   component `file.symlink`; an intermediate that is not a directory, or a final that
   is a directory, FIFO, character or block device, or socket `file.not-regular`.
   FIFOs and devices are never opened, so nothing blocks.
3. A regular final entry whose `st_size` exceeds 1,048,576 is `file.oversize`
   without reading; 1,048,576 exactly is allowed; 0 is allowed.
4. Open it with `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_NOCTTY`; `fstat` must show the
   same device, inode, regular type and size as the classification, else
   `file.changed`. Read until EOF, at most `st_size + 1` bytes. A byte count other
   than `st_size` is `file.size-mismatch`. Re-`fstat` after the read; a changed
   device, inode, size or modification time is `file.changed`. Any open or read
   error not classified above (including `EACCES`) is `file.read-error`.
5. The digest is SHA-256 over the exact bytes read, with no newline, CRLF, encoding
   or Git-object transformation. It is not a Git object id.
6. Metadata checks cannot exclude a concurrent same-inode change between reads.
   Immutable input stays a preparation and runtime dependency (concern 4), and the
   verifier claims no more than the checks above.

### R6. Output

1. **One payload file,** `<root>/evidence/file-digest-result.json`, created with
   `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0400`, written fully, fsynced and
   closed. The verifier never reads, lists or reopens the evidence directory.
   stdout is always empty.
2. **Bytes.** Exactly the canonical `jq -S -c` text of the payload with one trailing
   newline, at most 16,384 bytes:
   `{"body":{"check":C,"instruction_sha256":I,"observed":O,"outcome":X,"reason_id":R},"id":"file-digest-payload","kind":"file_digest_verifier_payload","schema_version":1}`
   where `C` is `{"expected_sha256":…,"path":…}`, or `null` for every
   `instruction.*` reason; `I` is the SHA-256 of the bytes read from fd 0, or `null` for
   `instruction.oversize` and `instruction.transport-rejected`; `O` is
   `{"sha256":…,"size_bytes":…}` only after a complete read, else `null`. The path
   is emitted as raw UTF-8 with only `"` escaped as `\"`, which is what jq emits
   for any R4-valid path.
3. **Outcomes,** closed: `match` with `file.match`; `mismatch` with `file.mismatch`;
   `refused` with exactly one of `instruction.transport-rejected`,
   `instruction.oversize`, `instruction.trailing`, `instruction.malformed`,
   `instruction.path-rejected`, `file.missing`, `file.symlink`, `file.not-regular`,
   `file.oversize`, `file.size-mismatch`, `file.changed`, `file.read-error`: the
   first one met in R3 then R5 processing order. A mismatch is a completed comparison, not an
   enforcement failure.
4. **Exit statuses,** closed: `0` payload written (any outcome); `64` R2 refusal,
   nothing written; `73` output failure, with exactly one of `E_OUTPUT_COLLISION`
   (the file already exists; it is not modified) or `E_OUTPUT` (any other create,
   write, fsync or close failure) on stderr. stderr is otherwise empty and at most
   one line of at most 64 bytes. A consumer uses a payload only with exit `0`.

### R7. Boundaries with the preparation bundle and the receipt

1. The verifier reads the #396 bundle's `candidate/` tree as mounted at
   `<root>/candidate`. It does not read `manifest.json`, `record.json` or any other
   bundle file; they are outside the candidate root. The preparation component
   already re-measures `candidate/` against its manifest on completion
   (`preparation/v1/prepare-candidate.py:2167-2183`), and checking the frozen tree
   against the manifest before launch is the launcher's job (concern 4). A
   consumer may compare the payload's observed digest with the manifest entry for
   the path (concern 5).
2. A planted `manifest.json`, expected-digest file or instruction-like file inside
   the candidate has no effect, because nothing but the instruction path is opened.
3. The payload is untrusted. It is never a receipt and cannot satisfy one
   (`work/real-sandbox-boundary/spec.md:54-61`). The supervisor, not the verifier,
   supplies every identity: verifier executable, instruction digest, candidate,
   environment, attempt, limits and teardown. It binds the payload only by digest
   and records exit status. The receipt kind is concern 2's (#436, proposed in
   PR #445, not yet merged); this spec relies only on the merged sandbox decision's
   rule that the host supervisor owns the receipt and binds output bytes.
4. The verifier gets no source history, checkout, filter, text conversion,
   submodule, Git execution, network, credential or model call.

### R8. Tests

1. `scripts/test/file-digest-verifier.test.sh` builds the production executable with
   `build.sh` and a test executable with `-DYSTACK_SANDBOX_ROOT` set to a fresh
   temporary directory, and proves the sources and flags are otherwise identical.
   Behaviour cases run the test executable against real files under that root; no
   privilege, chroot, namespace or mount is used. The suite refuses to run as uid 0,
   because `file.read-error` relies on permission denial.
2. It proves, each with a paired positive control that differs in one input:
   - match and mismatch; empty, binary (all 256 byte values), CRLF, no-final-newline
     and trailing-newline files, each digest checked against `shasum -a 256` and
     the FIPS 180-4 vectors for the empty string, `abc`, the 448-bit message and one
     million `a` bytes;
   - sizes 1,048,576 (accepted) and 1,048,577 (`file.oversize`);
   - the R4 differential corpus, including every rule of R4.1-R4.4, the listed
     accepted non-control characters, `.GIT`, and invalid UTF-8, run through both
     the verifier and `repo_path_ok` under pinned jq 1.6;
   - `file.missing`, a directory, a FIFO (the run finishes with no writer), a Unix
     socket, and intermediate and final symlinks (including one pointing at
     `/dev/null`, which is `file.symlink`);
   - every R3.3 instruction refusal, including CRLF framing, a BOM, uppercase hex,
     a fourth line, one trailing byte, 4,208 and 4,209 bytes, and fd 0 as a pipe;
   - `file.read-error` with a mode `0000` file;
   - output collision (existing result left byte-identical, exit 73) and an
     unwritable evidence directory (exit 73, `E_OUTPUT`);
   - every R2 refusal: each argv deviation and each environment deviation, both
     builds, with nothing written;
   - payload bytes equal their own `jq -S -c` canonical form, and two runs give
     byte-identical payloads;
   - candidate bytes, modes and tree digest are unchanged after every case, and a
     planted fake expected answer (R7.2) changes nothing;
   - two production builds in different fresh directories are byte-identical, and
     the build record matches recomputed digests.
3. Existing suites must pass unchanged, not edited:
   `scripts/test/shadow-slice.test.sh`, `scripts/test/control-sandbox-policy.test.sh`,
   `scripts/test/candidate-content-preparation.test.sh`,
   `scripts/test/default-deterministic-verifier-adapter.test.sh` and
   `scripts/test/portable-core-schema.test.sh`.
   `scripts/test/run-all.sh` discovers the new suite by name
   (`scripts/test/run-all.sh:66-69`) and is not edited.
4. **Honestly unproven here:** the production executable at the real `/sandbox`
   paths, read-only and write-only mounts, the fixed limits, containment,
   guest-toolchain identity, a device node at the final component (not creatable
   without privilege), and `file.size-mismatch` and `file.changed` (no
   deterministic trigger without a timing race; their code is reviewed, not faked
   by a test). These belong to concern 4. Docs keep component proof,
   containment and qualification separate.

### R9. Files, inactivity and order

1. The plan may create exactly `verifiers/file-digest/v1/verifier.c`,
   `verifiers/file-digest/v1/build.sh` (mode 100755) and
   `scripts/test/file-digest-verifier.test.sh` (mode 100755), and change exactly
   `docs/components.md` (a section after `## Inactive deterministic verifier
   normalizer payload`), `RESTORE.md` (one restore subsection with the build and
   test commands), `ci/required-files.txt` (one block listing the three new files and
   this slug's intent, spec and plan) and `work/fixed-file-digest-verifier/plan.md`.
   No executable is committed.
2. Byte-identical: `control/v1/**`, `config/**`, `shadow/v1/**`, `scope/v1/**`,
   `preparation/v1/**`, `adapters/**`, `evals/v1/**`, `ROADMAP.md`, `AGENTS.md`,
   `REVIEW.md`, `NORTH_STAR.md`, `.github/**`, `scripts/merge-pr.sh`,
   `scripts/codex-review.sh`, `scripts/test/run-all.sh`, `scripts/lib/*.sh` and
   every existing test script.
3. Nothing runs the verifier outside tests: no VM, launcher, supervisor,
   installation, native qualification, denied-access probe, credential, network,
   model call, target execution, activation or write. Nothing enables before step 7
   (#426) closes. Reserved decisions: none beyond review
   (`work/step8-bounded-write-readiness/spec.md:293`).
4. Order: this concern lands after concern 2 (#436) lands, as step-8 R8 orders it.
   Drafting and review may run in parallel. If concern 2's accepted spec contradicts
   R7.3, this spec returns to G2 before its plan.
5. `review_size: standard` for this spec and for the implementation.

## Design

The verifier is a straight line: check argv and environment, read and frame the
instruction from fd 0, validate the path, walk the candidate without following
links, classify before opening, read bounded bytes, hash, compare, and write one
canonical payload exclusively. Every branch ends in exactly one of the closed
outcomes or exit statuses, so the payload is a pure function of the instruction
bytes and the candidate tree.

Instruction on fd 0 keeps the accepted argv and environment unchanged and makes the
supervisor, which already binds the instruction identity, its only source. A line
format instead of JSON keeps the parser small enough to review whole in C.

## Out of scope

The receipt contract (#436); the launcher, supervisor, guest build and native
qualification (concern 4); replacing `tool.git-blob-digest` in the shadow driver
(concern 5); any change to the preparation component, its bundle format, the
sandbox policy or the demonstration digest.

## Areas of concern

- **Test build differs by one string.** Behaviour is proven on the test-root build;
  the production build's own behaviour at `/sandbox` waits for concern 4. R8.1
  proves nothing else differs.
- **jq-equivalent path rules in C.** R4 enumerates jq 1.6's actual control set;
  the differential test catches drift in either direction.
- **Reproducible builds.** Byte-identical rebuilds are required per host; a
  compiler that embeds paths or times fails the plan instead of being waived.
- **Devices and races.** A device node and a same-inode concurrent change cannot be
  created or timed deterministically without privilege; R8.4 names them unproven
  rather than claiming them.

Intent open questions, answered: instruction transport and framing (R3); payload
location, bytes and collision (R6); language and identity (R1); tests without
privilege and what stays unproven (R1.4, R8.1, R8.4); mapping onto the receipt
(R7.3); who checks the manifest (R7.1); the real digest versus the all-ones digest
(R1.5).
