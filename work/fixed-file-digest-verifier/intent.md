# Intent: fixed file-digest verifier
Author: Claude (yshifu, intent author at the operator's direction). Status: draft.

## Problem

No shipped fixed verifier reads a file from a frozen candidate filesystem. The
shadow slice checks an incident by hashing Git blob bytes straight out of the
candidate `repository.git` with `git cat-file` (`shadow/v1/reproduce.sh:486-512`),
and records the tool as `tool.git-blob-digest` (`reproduce.sh:511`). That is the
preparation side reading Git, not a verifier reading candidate content.

The pieces that look like a verifier are not one:

- The sandbox policy names `/sandbox/tools/verifier` with the all-ones
  demonstration digest (`control/v1/sandbox.jq:179-182`,
  `control/v1/sandbox-policy.json` tool `sha256`). No real executable has that
  identity.
- `adapters/deterministic-verifier/v1/normalize.jq` only normalizes an existing
  snapshot into a stage result (`normalize.jq:24-31`, `:65-76`). It reads no file
  and computes no digest.

The real sandbox boundary decision names this as its second child concern: "fixed
file-digest verifier: bounded deterministic data processing and trusted
instructions with real tool identity and mismatch/no-change tests"
(`work/real-sandbox-boundary/spec.md:158-159`), with the fixed invocation and
ceiling at `spec.md:19-43`. Parked issue #314 specified it in detail but was
blocked on preparation. That dependency is now delivered: PR #396 (merged
`6fab6da5`) ships `preparation/v1/prepare-candidate.py`, which exports raw Git
object bytes into a `candidate/` tree with a `manifest.json` listing each file's
size and SHA-256 (`prepare-candidate.py:1610-1612`, `:2099`). Its record still says
`immutable: false`, `authenticated_receipt: false` and
`supervisor_handoff: "required"` (`prepare-candidate.py:1928-1929`), so the bundle
alone is not a frozen, supervised input.

Step-8 R8 lists this as child concern 3, depending on child concern 2 for the
receipt kind (`work/step8-bounded-write-readiness/spec.md:293`). The launcher,
shadow integration and scope-gate hardening (child concerns 4, 5, 6) all need a
real verifier identity to bind.

## Proposed outcome

One inactive, bounded file-digest verifier, exactly as #314 defines it:

- It reads a trusted instruction supplied outside candidate control. Candidate
  content never selects a command, expected digest, instruction or authority.
- It keeps the fixed invocation
  `/sandbox/tools/verifier verify --candidate /sandbox/candidate --evidence /sandbox/evidence`
  and the four exact variables LANG=C, LC_ALL=C, PATH=/sandbox/tools and
  TMPDIR=/sandbox/scratch.
- It reads one bounded regular file under the current incident path rules
  (`shadow/v1/incident-record.jq:30`) and the inclusive 1 MiB limit. It checks both
  the declared size and the bytes actually read. It refuses non-regular files and
  symlink traversal without blocking on a FIFO or device. Empty and binary files
  are valid; CRLF and final newlines are not normalized.
- It computes SHA-256 over the raw file bytes, not a Git object identity.
- It emits a bounded payload that tells apart match, mismatch, and unreadable or
  refused. A mismatch is a completed comparison, not an enforcement failure.
- It has a real executable and build identity, and restore instructions.

The candidate it reads is the #396 bundle's `candidate/` output. Its output is
untrusted payload. It maps onto the child-2 receipt kind only through the
supervisor, never as its own receipt and never through a new authority channel.

Success means #314's full synthetic proof list passes against the real parser,
reader, comparison and output code: match and mismatch; empty, binary, CRLF and
trailing-newline bytes; exact size limit and overflow; allowed and rejected paths;
missing, directory and non-regular inputs; intermediate and final symlinks;
malformed or trailing instructions; read and output failures; output collision;
exact argument refusal; and repeatable results. Digest vectors are checked
independently, candidate bytes are preserved, and a fake expected answer planted
in the candidate cannot change the result. Tests keep component proof separate
from containment and qualification.

## Affected users and systems

The operator, who reviews each gate. The shadow slice's file-digest check, which
keeps its current behaviour until child concern 5 wires the verifier in. The #396
preparation bundle, read as input. The sandbox policy and decision, read and not
changed. The later receipt contract (#436), launcher and supervisor, shadow
integration and scope gates. CI, which runs the new tests.

## Constraints

- Risk: high. G1 intent, then G2 spec, then an operator-merged high-risk plan come
  before any code, each with independent review and required CI. Tracks #437.
- Lands after #436 (child concern 2), because it needs that receipt kind.
  Drafting may run in parallel now.
- Nothing enables before step 7 (#426) closes.
- Reserved decisions per step-8 R8 row 3: none beyond review.
- Ships nothing enabling: no VM, launcher or supervisor, installation, native
  qualification, denied-access probe, credential, network, model call, target
  execution, activation or write.
- The verifier grants no authority and cannot satisfy its own receipt. No sandbox
  limit, root, environment or separation rule is weakened.
- The verifier gets no source history, checkout, filters, text conversion,
  submodules, Git execution or source access. No generic verifier framework and no
  arbitrary command interface.
- `control/v1` policy and evaluator behaviour and `config/**` stay byte-identical
  unless the G2 spec names one exact, reviewed change.
- File metadata checks cannot rule out a concurrent same-inode change. Immutable
  input stays a preparation and runtime dependency, stated as such.
- #314 is subsumed by this intake; its requirements carry over unchanged.
- Non-goals: the receipt contract (#436); the launcher and supervisor (child
  concern 4); replacing `tool.git-blob-digest` in the shadow driver (child
  concern 5); any change to the preparation component or its bundle format.

## Open questions

- How does the trusted instruction reach the verifier without a new argument,
  variable or candidate-controlled path? What framing and rejection rules apply?
- Where in `/sandbox/evidence` does the payload go, what are its exact bytes, and
  what happens on an output collision?
- Which language and existing toolchain give a real, reproducible executable
  identity without installation or acquisition, within `/sandbox/tools` only?
- How do tests exercise the fixed `/sandbox/...` paths without privileged setup,
  and what stays honestly unproven until child concern 4?
- How does the verifier's untrusted payload map onto the #436 receipt kind, and
  which fields does the supervisor, not the verifier, supply?
- Who checks the #396 `manifest.json` against the candidate before verification,
  and does the verifier read it at all?
- How does the real verifier digest reach the accepted identity set while the
  demonstration policy keeps the all-ones digest?
