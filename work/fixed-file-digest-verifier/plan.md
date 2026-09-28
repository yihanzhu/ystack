---
spec-blob: 3d245b065336a275d797b7dde3ceaa07bf271039
intent-blob: f898d102e1d68cea35590da17931ae021c6376f5
risk: high
drafted: 2026-09-28
---
# Plan: fixed-file-digest-verifier

Tracks #437. Risk: high (`artifact-high`): independent review, green CI and operator
merge of this plan come before any code. One implementation PR on
`ystack/impl/fixed-file-digest-verifier`, in five ordered commits. The spec (blob
above) is the contract; this plan only fixes the readings it leaves open.

Checked on origin/main `7c8c6e9`: the spec's `272ec0f` citations still hold (no
diff since over the cited trees). On Darwin arm64, Apple clang 21, two R1.2 builds of
one C file in two fresh directories were byte-identical.

## Dependencies

- Merged artifacts only: this slug's intent and spec; the sibling spec
  `work/enforcement-evidence-binding/spec.md` (blob `e8403c6f…`), only to confirm
  R7.3 (Risks); `shadow/v1/incident-record.jq` (run by the test);
  `control/v1/sandbox.jq:161-163,179-182` (the argv and environment copied).
- **Merge order (R9.4).** The implementation PR may be built and reviewed now, but
  merges only after #436 closes with its implementation merged. It consumes no content
  of that concern; `enforcement/v1/` does not exist on main and nothing here reads it.

## Files that change

Implementation PR, nothing else:

| Path | Change | Est. lines |
| --- | --- | ---: |
| `verifiers/file-digest/v1/verifier.c` | new, mode 100644 | 550-750 |
| `verifiers/file-digest/v1/build.sh` | new, mode 100755 | 60-90 |
| `scripts/test/file-digest-verifier.test.sh` | new, mode 100755 | 600-800 |
| `docs/components.md` | new section (text below) | +18 |
| `RESTORE.md` | new subsection (text below) | +20 |
| `ci/required-files.txt` | new block (text below) | +8 |

No executable, fixture or helper source is committed; test helpers live in `mktemp -d`.

**Existing tests and pins, enumerated; none is edited.**

- Manifest prefix pins, all above line 317 where the new block goes:
  `portable-core-profile-graph.test.sh:1022` (100 lines), `-stage-request.test.sh:1016`
  (108), `-result-facts.test.sh:642` (112, block to 116), `-ingress.test.sh:1296-1305`
  (96) and `-schema.test.sh:537-542` (89).
- Whole-tree scans: `portable-core-schema.test.sh:880-899,921-928` flag tracked files
  that contain a v1/v2 generation id or a jq `import`/`include` of `"schema"`
  (pattern at `:766`). New files and text must contain neither; C `#include` lines do
  not match the pattern.
- `scripts/check-rename.sh` (no old name in new text); `run-all.sh:66-69` and
  `run-all-sharding.check.sh:57-59` (discovery by name, no count pinned); CI
  `shellcheck -x -S style` on every `*.sh` (`.github/workflows/ci.yml:86-92`).
- The five R8.3 suites (listed in Proof) pass unchanged.

## Order of work

0. After operator merge of this plan: fetch main, confirm the intent, spec and plan
   blobs and both hash links, record the accepted plan blob and the merged default OID
   as `plan-base`, and create `ystack/impl/fixed-file-digest-verifier` from it. If main
   moves before the first code commit, follow the `work/README.md` base-move rule
   (fresh non-author `Plan-verdict`, operator reaffirmation on #437) before any edit.

Commits 1-4 grow the verifier and its test together; only the final head is claimed
to meet the spec.

### Commit 1: build and invocation (R1, R2)

- `verifier.c` opens with `#define _POSIX_C_SOURCE 200809L`, then, under
  `#if defined(__APPLE__)`, `#define _DARWIN_C_SOURCE`: Darwin hides `O_NOFOLLOW`
  under a strict POSIX level (checked while drafting). This only exposes
  declarations; the interface set stays R1.1's. Then
  `#ifndef YSTACK_SANDBOX_ROOT` / `#define YSTACK_SANDBOX_ROOT "/sandbox"`. Every
  fixed string is a literal concatenation of that macro: `/candidate`, `/evidence`,
  `/evidence/file-digest-result.json`, `/tools`, `/scratch`, and the expected
  `PATH=` and `TMPDIR=` values. `extern char **environ;`. No other macro may change
  behaviour.
- R2.1 first: `argc == 6` and `argv[1..5]` equal the five fixed strings byte for byte,
  else `E_USAGE`. Then R2.2: walk `environ`; exactly four entries, each equal to one of
  the four fixed `NAME=value` strings, each seen once, else `E_ENVIRONMENT`. Both write
  `<code>\n` to stderr and exit 64 before any read, open or write.
- `build.sh`: `set -euo pipefail`, absolute utilities, accepts only `build <out-dir>`
  (anything else: usage message, exit 2). `/bin/mkdir -- "$out"` is the existence
  check; an existing path refuses. It makes `$out` absolute, `cd`s into its own
  directory and runs exactly `/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2
  verifier.c -o "$out/verifier"`, then `/bin/chmod 0555`. The relative source name
  keeps the checkout path out of the object (gcc records it). `build-record.json` is
  written with `/usr/bin/printf` in sorted key order (jq is not available without
  network). It is flat: exactly `build_script_sha256`, `compiler_path`
  (`"/usr/bin/cc"`), `compiler_version_sha256`, `executable_sha256`, `flags`
  (`["-std=c11","-Wall","-Wextra","-Werror","-O2"]`), `kind`
  (`"file_digest_verifier_build"`), `platform`, `sandbox_root` (`"/sandbox"`),
  `schema_version` (`1`), `source_sha256`, plus one newline. Digests use
  `/usr/bin/shasum -a 256`. On failure it exits non-zero and deletes nothing.

### Commit 2: instruction and payload (R3, R6)

Processing order, which fixes R6.3 precedence:

1. `fstat(0)`: not a regular file, or a read error on fd 0, gives
   `instruction.transport-rejected` (`I` null).
2. Read until EOF or 4,209 bytes. 4,209 bytes gives `instruction.oversize` (`I`
   null). The longest valid instruction is 34 + 4,102 + 72 = 4,208 bytes.
3. `I` = SHA-256 of the bytes read.
4. Fewer than three LF bytes gives `instruction.malformed`; any byte after the third
   LF gives `instruction.trailing`.
5. `instruction.malformed` if: line 1 is not exactly the header; line 2 does not start
   `path ` or line 3 does not start `sha256 `; any CR or NUL; any line whose last byte
   before its LF is a space; the digest is not exactly 64 of `[0-9a-f]`; or the path is
   not valid UTF-8 (overlong, surrogate D800-DFFF, above U+10FFFF, truncated, stray
   continuation). The path is everything after `path ` up to the LF. "Leading space"
   means before a key (the key check refuses it); a path may begin with U+0020, as R4
   accepts ` a`. "BOM" means before the header; U+FEFF inside the path is valid.
6. R4 rules (commit 3) give `instruction.path-rejected`.

Payload writer (R6): builds the exact R6.2 bytes with fixed key order. `C` is null
for every `instruction.*` reason, otherwise `{"expected_sha256":…,"path":…}`. `O` is
non-null only for `match` and `mismatch`. A read that ends in `file.size-mismatch`
or `file.changed` has no digest of a stable file. The path is emitted as raw bytes
with only `"` escaped; R4 excludes every other byte jq would escape. Output: `open` of
the fixed result path with `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, mode `0400`, loop
`write` until done, `fsync`, `close`. `EEXIST` gives `E_OUTPUT_COLLISION`; any other
failure gives `E_OUTPUT`. Exit 73 in both cases. A partial file is not removed, since
the verifier never touches the evidence directory otherwise. stdout is never written.
Until commit 4, a well-formed instruction ends at a stub that commit 4 replaces.

SHA-256 is the FIPS 180-4 algorithm in the same file, streaming over a context.

### Commit 3: path rules (R4)

Over the decoded code points of a valid UTF-8 path: byte length 1-4,096; no code
point in U+0000-001F or U+007F-009F; no `\`; no leading `/`; split on `/` into 1-64
components, none empty, `.` or `..`, none equal to `.git` after lowercasing only
A-Z, none ending in `.` or U+0020. Nothing else is rejected.

### Commit 4: reading the candidate (R5)

- Open the candidate root with `O_RDONLY|O_DIRECTORY|O_NOFOLLOW`; failure gives
  `file.read-error` (the root is not a path component).
- For each intermediate component, `fstatat(AT_SYMLINK_NOFOLLOW)`: `ENOENT` gives
  `file.missing`, any other error gives `file.read-error`, a symlink gives
  `file.symlink`, and a non-directory gives `file.not-regular`. Then `openat` with
  `O_RDONLY|O_DIRECTORY|O_NOFOLLOW`: `ENOENT` gives `file.missing`, any other failure
  `file.read-error`.
- Final component: the same `fstatat` mapping; only `S_ISREG` continues; a size over
  1,048,576 gives `file.oversize`. `openat` with `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_NOCTTY`
  (any failure gives `file.read-error`), then `fstat` against the classification for
  device, inode, `S_ISREG` and size (`file.changed`). Read into a static
  1,048,577-byte buffer until EOF or `st_size + 1` bytes (a read error gives
  `file.read-error`). A count other than `st_size` gives `file.size-mismatch`.
  Re-`fstat`: device, inode, size, `st_mtime` and its nanoseconds
  (`st_mtimespec.tv_nsec` on Darwin, `st_mtim.tv_nsec` elsewhere, one macro) must
  match, else `file.changed`.
- Hash, compare with the expected digest (`match`/`mismatch`), write the payload.

### Commit 5: docs and manifest (R9.1)

`docs/components.md`: a new section after the last paragraph of `## Inactive
deterministic verifier normalizer payload` (ends at line 715) and before `## Inactive
eval and trace framework`, wrapping adjustable:

> ## Inactive fixed file-digest verifier
>
> `verifiers/file-digest/v1/verifier.c` is the fixed file-digest verifier of the
> [sandbox boundary decision](../work/real-sandbox-boundary/spec.md), specified in
> [its spec](../work/fixed-file-digest-verifier/spec.md). It accepts only the sandbox
> policy's fixed invocation and four-variable environment. It reads one trusted
> instruction from standard input and one bounded regular file under the candidate
> root, following no link. It writes one canonical payload: `match`, `mismatch` or one
> closed refusal reason. The digest is SHA-256 over the raw file bytes, not a Git
> object id. `verifiers/file-digest/v1/build.sh` builds it with the host compiler and
> records the source, build-script, compiler and executable digests.
>
> The payload is untrusted verifier output and never a receipt; only the host
> supervisor binds it, by digest. Nothing runs the verifier outside its test. The
> shadow slice still records `tool.git-blob-digest`, the sandbox policy keeps its
> all-ones demonstration tool digest, and no build digest is accepted anywhere. The
> test proves component behaviour on a build whose sandbox root is a temporary
> directory. The production build at `/sandbox`, mounts, limits, containment and
> guest-toolchain identity stay unproven until the launcher and supervisor concern
> qualifies them.

`RESTORE.md`: a new subsection after `### Restore the inactive maintenance loop` (its
last paragraph ends at line 327) and before the `---` preceding `## 1.`:

> ### Restore the inactive fixed file-digest verifier
>
> Restore the paths listed under “Inactive fixed file-digest verifier” in
> [`ci/required-files.txt`](ci/required-files.txt) from one commit, then run:
>
> ```sh
> bash scripts/test/file-digest-verifier.test.sh
> ```
>
> The proof builds the production executable with
> `bash verifiers/file-digest/v1/build.sh build <new-directory>` and a test build
> whose only difference is its sandbox root. It shows match, mismatch and every
> closed refusal against real files, digests checked independently, byte-identical
> rebuilds and payloads, and an unchanged candidate. The build uses no network; the
> test fetches only the pinned jq 1.6 release, as the other suites do. Restoring
> these records installs nothing, runs no verifier in a sandbox, accepts no digest,
> and performs no model, credential, publish or target operation.

`ci/required-files.txt`: after line 317
(`scripts/test/default-deterministic-verifier-adapter.test.sh`) and its blank line,
before `# Inactive default profile assembly`, followed by one blank line:

```text
# Inactive fixed file-digest verifier
verifiers/file-digest/v1/verifier.c
verifiers/file-digest/v1/build.sh
scripts/test/file-digest-verifier.test.sh
work/fixed-file-digest-verifier/intent.md
work/fixed-file-digest-verifier/spec.md
work/fixed-file-digest-verifier/plan.md
```

Then read the full diff, run the proof, and open the PR with `Closes #437`,
`review_size` as below. Do not claim a sandbox run, an accepted digest, a receipt,
qualification or a shadow-driver change.

## The test

`scripts/test/file-digest-verifier.test.sh`, in the style of `shadow-slice.test.sh`
(`ok N - …` lines, `fail` exits 1, `mktemp -d` root removed by trap). Its closing
comment names the R8.4 unproven items, which no case fakes.

- **Preconditions.** Refuse uid 0 (R8.1), and refuse if `/sandbox` exists so the
  production positive control below never writes into a real root. Provision pinned
  jq 1.6 as `shadow-slice.test.sh:24-51`; use `/usr/bin/python3`; resolve the temp
  root with `pwd -P`.
- **Exact exec.** Compile, into the temp directory, an inline heredoc C helper that
  `execve`s its first argument with an exact envp (arguments up to `--`) and an exact
  argv (the rest, including `argv[0]`). Every verifier run goes through it, which is
  the only way to test duplicate entries and a chosen `argv[0]`. Run with stdin from a
  file, and bound every run (background plus kill after 20 s gives a failure), so a
  FIFO block fails instead of hanging.
- **Builds (R1.2, R1.3, R8.1).** Build production twice into two fresh directories;
  require byte-identical `verifier` files (a difference stops the plan per R1.3, never
  waived). Recompute every build-record field and require the record to equal its own
  pinned `jq -S -c` form. Compile `verifier.c` directly, from its directory, with the
  record's `flags`: it must equal the production executable, so `build.sh` adds nothing.
  The test build is that same command plus exactly
  `-DYSTACK_SANDBOX_ROOT="\"$root\""`. Also: `build.sh` refuses an existing directory
  and a wrong argument list, and leaves only `verifier` and `build-record.json`.
- **R2.** Paired against the exact vectors on both builds: each argv deviation
  (count 5 and 7, each position misspelled, swapped order, test-root paths given to
  production) and each environment deviation (missing, extra, duplicate, wrong value
  per variable, empty environment). Each exits 64 with the exact stderr line, and the
  evidence directory stays empty. `argv[0]` of `x` still passes. Production positive
  control: exact `/sandbox` vectors with stdin `/dev/null` exit 73 `E_OUTPUT`, not 64.
- **R3.** Each refusal against a valid instruction differing in one input: a fourth
  line and one trailing byte (`trailing`); CRLF, BOM, uppercase hex, 63/65 hex digits,
  wrong or reordered keys, a missing final LF, NUL, a trailing space (`malformed`);
  4,208 bytes (4,096-byte path; outcome not `instruction.*`) and 4,209 bytes
  (`oversize`, `I` null); stdin as a pipe (`transport-rejected`, `I` null); each
  invalid UTF-8 class (lone `0xff`, overlong `c0 af`, surrogate `ed a0 80`,
  `f4 90 80 80`, truncated `e2 82`), each `instruction.malformed`.
- **R4 differential.** One corpus of JSON string literals, valid UTF-8 only. Each
  entry is decoded to bytes with pinned jq, placed in an instruction and run through
  the test build. It is also placed as `.body.failing_check.path` of an otherwise-valid
  `shadow_incident_record`, then run through the unchanged
  `jq -r --arg operation shape --arg record_sha <64 zeros> -f shadow/v1/incident-record.jq`
  (empty output accepts; `E_SHAPE` rejects). The verifier accepts a path only when it
  reaches candidate-file processing (`match`, `mismatch` or any `file.*` reason); every
  `instruction.*` reason is a rejection. Rejections this way include 4,097 bytes
  (`oversize`), LF (`trailing`), and CR, NUL and a trailing U+0020 (`malformed`); a
  leading U+0020 and the 4,096-byte path are accepted. The results must agree entry
  for entry. The corpus covers every R4.1-R4.4 rule at and past its bound (4,096
  and 4,097 bytes including a multibyte case; 64 and 65 components), `.GIT` and `.Git`
  (rejected), `.GİT` (accepted), ` a`, `a b`, `x.git`, `.gitignore`, U+0001, U+001F, U+007F,
  U+0080, U+0085, U+009F, tab, LF, CR, NUL, and the accepted U+00A0, U+00AD, U+200B,
  U+2028, U+FEFF, U+E000, U+FFFF, U+1F600 and U+10FFFF.
- **R5, R6.** Match and mismatch; empty, all-256-byte, CRLF, no-final-newline and
  trailing-newline files, each observed digest equal to `shasum -a 256`; the FIPS
  vectors for the empty string, `abc`, the 448-bit message and one million `a` against
  their published digests; sizes 1,048,576 and 1,048,577; missing (final and
  intermediate); directory; FIFO (`/usr/bin/mkfifo`, no writer); Unix socket (python3
  binds a relative name after `chdir`, which avoids the socket path limit); an
  intermediate symlink, a final symlink and a final symlink to `/dev/null`; an
  intermediate regular file (`not-regular`); a mode `0000` file (`read-error`); an
  existing result (exit 73 `E_OUTPUT_COLLISION`, bytes unchanged); a mode `0500`
  evidence directory (exit 73 `E_OUTPUT`). Every payload equals its own pinned
  `jq -S -c` text and the exact expected bytes, stdout is empty, the result mode is
  `0400`, and repeat runs in fresh evidence directories are byte-identical.
- **Preservation (R7.2, R8.2).** A python3 `lstat`-based tree digest (type, mode,
  size, content SHA-256 of regular files, link targets) of the candidate is the same
  before and after every case. Planting a `manifest.json` and a file holding the
  target's true digest, plus an instruction-like file, leaves a mismatch payload
  byte-identical to the same case without them.

## What does not change

Every R9.2 path stays byte-identical (the Proof's `git diff --quiet` covers them),
and no existing test script is edited. No README row. Nothing enables before step 7
(#426) closes. Reserved for the operator and excluded: activation, installation,
native qualification, credentials, network scope, a real publisher, accepting a
verifier digest, and any change to `config/**`,
`ROADMAP.md`, `AGENTS.md`, `REVIEW.md`, `NORTH_STAR.md`, `.github/**`,
`scripts/merge-pr.sh`, `scripts/codex-review.sh`, `scripts/test/run-all.sh` or
`scripts/lib/*.sh`. Reserved decisions for this concern (R9.3): none beyond review.

## Follow-up intakes

None new. Step-8 concern 4 builds and qualifies the guest executable; concern 5
replaces `tool.git-blob-digest` (`shadow/v1/reproduce.sh:511`); the tool-digest
change is theirs (R1.5).

## Review size

Implementation PR: `review_size: accepted-exception`, 1,250-1,700 net added lines
(the per-file estimate above), one concern: one C verifier, its build script and its
test. Splitting it would leave main with a verifier outside R6.3/R6.4's closed sets,
or with reviewed code lacking its test. Precedents: `work/shadow-input-assembler/plan.md`
(1,199 measured), `work/external-target-shadow-run/plan.md` evidence PR (1,000-1,400),
`work/credential-control-identity-handoff/plan.md` (900-1,400). Only the soft line
signal changes, never scope, tests, CI, review or human merge (`work/README.md:71-73`).

## Risks

- **Sibling citation (checked, no conflict).** R7.3 calls the receipt kind "proposed
  in PR #445, not yet merged". It is now merged and matches R7.3 field for field:
  `identities.verifier` and `.verification_instructions`, `subject.candidate` and
  `.environment_*`, `attempt`, `limits`, `teardown`; `payload` binds output only by
  digest (`stdout_sha256`, `stderr_sha256`, `evidence_manifest_sha256`) plus
  `exit_state`/`exit_code`, and treats it as untrusted (sibling R2.1, R3.9). The
  verifier's writes (at most 16,448 bytes, no child, no scratch) fit sibling R6. The
  wording is stale, not contradictory, so R9.4's return-to-G2 clause does not fire.
  Docs do not repeat "not yet merged"; the spec is not edited here.
- **R9.5 size forecast.** The spec says `standard` for the implementation. A C
  verifier with its own SHA-256 plus the R8.2 proof list cannot fit the soft budget,
  so this plan records the exception above, as `work/README.md` allows in an accepted
  plan. If the operator holds R9.5 binding, R9.5 needs a G2 amendment first; scope
  is unchanged either way.
- **Readings the spec leaves open**, fixed above and open to review: the flat build
  record; `O` only for `match`/`mismatch`; read errors on fd 0 as transport-rejected;
  root-open and post-classification open failures as `file.read-error`;
  line-level leading/trailing space; BOM only before the header; a partial result not
  removed on `E_OUTPUT`. A reviewer who reads any of these differently should say
  so in review, before code exists.
- **Reproducibility on Linux CI.** It was checked on Darwin only. If CI's gcc gives
  different bytes across the two directories, stop and report (R1.3); never waive or
  special-case it.
- **Differential drift.** jq 1.6 `[[:cntrl:]]` is taken from R4.2; if the
  differential disagrees on any entry, stop and report rather than adjusting the C
  rules or the corpus.

## Proof

BASE is the recorded `plan-base` (full OID); report it and the final head.

```sh
git rev-parse HEAD:work/fixed-file-digest-verifier/intent.md   # f898d102…
git rev-parse HEAD:work/fixed-file-digest-verifier/spec.md     # 3d245b06…
git rev-parse HEAD:work/fixed-file-digest-verifier/plan.md     # accepted plan blob
git show HEAD:work/fixed-file-digest-verifier/spec.md | sed -n '1,5p'
git show HEAD:work/fixed-file-digest-verifier/plan.md | sed -n '1,6p'
git diff --name-only BASE HEAD
git diff --check BASE HEAD
git ls-files -s verifiers scripts/test/file-digest-verifier.test.sh
git diff --quiet BASE HEAD -- control config shadow scope preparation adapters evals \
  ROADMAP.md AGENTS.md REVIEW.md NORTH_STAR.md .github scripts/merge-pr.sh \
  scripts/codex-review.sh scripts/lib && echo unchanged
git diff --name-only --diff-filter=MDR BASE HEAD -- scripts
```

Require: both hash links and `risk: high`; exactly the six paths of "Files that
change"; `--check` silent; `verifier.c` 100644, `build.sh` and the test 100755, and
nothing else under `verifiers/`; `unchanged`; the last command prints nothing.

```sh
grep -v -e '^$' -e '^#' ci/required-files.txt | while IFS= read -r f; do
  [ -f "$f" ] || echo "missing required file: $f"; done
for f in verifiers/file-digest/v1/verifier.c verifiers/file-digest/v1/build.sh \
  scripts/test/file-digest-verifier.test.sh work/fixed-file-digest-verifier/intent.md \
  work/fixed-file-digest-verifier/spec.md work/fixed-file-digest-verifier/plan.md; do
  grep -Fxc "$f" ci/required-files.txt; done
(cd docs && test -f ../work/real-sandbox-boundary/spec.md &&
  test -f ../work/fixed-file-digest-verifier/spec.md)
shellcheck -x -S style verifiers/file-digest/v1/build.sh \
  scripts/test/file-digest-verifier.test.sh
bash scripts/check-rename.sh
bash scripts/test/file-digest-verifier.test.sh
bash scripts/test/shadow-slice.test.sh
bash scripts/test/control-sandbox-policy.test.sh
bash scripts/test/candidate-content-preparation.test.sh
bash scripts/test/default-deterministic-verifier-adapter.test.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/portable-core-profile-graph.test.sh
bash scripts/test/portable-core-stage-request.test.sh
bash scripts/test/portable-core-result-facts.test.sh
bash scripts/test/portable-core-ingress.test.sh
bash scripts/test/run-all-sharding.check.sh
```

The first loop prints nothing, each count is `1`, every command exits 0; record
command, head, platform and full output. Do not run `scripts/test/run-all.sh`
locally. On the exact final head and base, require every CI job, including a
dispatched six-shard run so the new suite also passes on Linux x86_64. A fresh
non-author reviewer applies the Bugs, Security and Compliance passes to the full diff,
the hash links and this evidence. The manager reads the complete raw review and
resolves every Important finding before the operator-gated merge, which happens only
after #436 closes.
