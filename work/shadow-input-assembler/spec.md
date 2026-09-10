---
intent-blob: 61218c3c9b3554f4a86c58fd3a7311d9e818f3b6
risk: routine
drafted: 2026-09-09
---

# Spec: shadow-input-assembler

One shipped component builds the single materialization input the shadow driver
needs, for a real repository revision, from the real default profile. The driver
(`shadow/v1/reproduce.sh`) and the materializer are not touched.

The assembler does **not** resolve a profile. It takes an already-resolved
profile document as an input and checks it against the supplied profile and
manifests with the core v2 profile-graph rules — the operator's DR-1 decision on
issue #262 (option 2). Production resolution needs a trusted parent for
`resolver/v1/profile-resolve-runtime.sh`; that parent does not exist and is its
own high-risk initiative. The only launcher today is the one in `scripts/test/`,
so today the only resolved profiles that exist are test-produced. This spec says
so plainly rather than implying otherwise.

`review_size: accepted-exception`. One concern: one inactive component whose
focused test must drive the real `reproduce.sh` end to end with the existing
fixture environment (the shadow slice test itself is 622 lines for the same
reason). Range: 450-650 net lines — about 300 lines of component (shell plus
jq), about 250 lines of test, and the documentation rows. The evidence is the
nearest thing in the repository: `scripts/test/shadow-slice.test.sh` is 622
lines, because a test that runs the driver has to build a bare repository, a
profile set, and a claim before the driver can run once. This test builds that
same fixture ground and then runs the driver again on the assembled input, so
it lands in the same band, and the component itself is the ~300 lines above.

The exception waives only the soft line signal. It does not widen scope beyond
the one concern, and it does not relax readability, tests, CI, review, or
operator merge. The component and its focused test land together, which is the
repository convention; splitting them would ship a component with no proof and
a test with nothing to prove.

## Requirements

1. **Nine positional inputs, all absolute paths or exact values.** Invocation
   is `assemble <repository-id> <source-git-dir> <commit-id>
   <attempt-timestamp> <profile-dir> <resolved-profile-file> <jq-binary>
   <output-dir> <environment-claim-file>`. The claim is appended, so the first
   eight keep their positions. The repository id matches
   `\A[a-z0-9][a-z0-9._:-]{0,127}\z`; the source Git directory is a physical
   bare repository, and **its hash algorithm is read from the repository, not
   assumed** — `git rev-parse --show-object-format` under the same protective
   environment the driver and the materializer use (`--no-replace-objects`,
   `GIT_NO_REPLACE_OBJECTS=1`, `GIT_NO_LAZY_FETCH=1`, no system or global
   config, and the alternates, grafts, replace-refs, shallow, and worktree
   checks the materializer already makes at
   `adapters/local-git-materializer/v1/materialize.sh:265-275` and `:327-333`,
   the same read it makes at `:352`); the commit id is lowercase hex — 40
   characters when the repository reports `sha1`, 64 when it reports `sha256`
   — must match the format the repository actually reports, and must exist
   there as a commit; the timestamp is exactly `YYYY-MM-DDTHH:MM:SSZ`; the
   profile directory holds `profile.json`, `producer-config.json`, and
   `manifests/`, whose bytes must match the digests requirement 3 pins; the
   jq binary is the pinned jq 1.6
   the driver already pins by SHA-256 per platform; the output directory is an
   existing, empty, physical `0700` directory — the shape the driver requires
   of its own — disjoint from the source repository and profile directory; and
   the environment claim file is the same `execution_environment_claim`
   document the caller will hand to `shadow/v1/reproduce.sh` as its own claim
   argument, read here as data and never modified (requirement 7 says what is
   derived from it).
2. **The resolved profile is an input, never something this component makes.**
   The assembler never sets `YSTACK_RESOLVER_TRUSTED`, never invokes
   `resolver/v1/profile-resolve-runtime.sh`, and imports nothing from
   `scripts/test/`. It reads the supplied resolved-profile file as data.
3. **The supplied profile set is validated, and a mismatch is refused.** The
   profile, the resolved profile, and the manifests must satisfy the core v2
   rules in `core/v2/generations/g-*/modules/profile_graph.jq` —
   `profile_set_ok`, and inside it `profile_set_graph_ok`, so the bindings'
   `manifest_ref` values equal the supplied manifests exactly, the resolved
   profile's `profile_source.value_sha256` equals the profile's own digest, and
   every binding matches its manifest. **The profile must be the shipped
   default profile, proven by bytes and not by name.** The id check comes
   first because it is cheap: the supplied `profile.json` must carry the
   top-level `id` `"profile.default.v1"` — the exact value
   `profiles/default/v1/profile.json` carries in its own `id` field — and any
   other id is `E_PROFILE`, not a warning. But the id proves nothing on its
   own. A caller can hand over a profile directory that is entirely
   self-consistent — its own manifests, its own resolved profile, its own
   `id` reused as `profile.default.v1` — and the id check, the six-manifest
   count, and `profile_set_ok` would all pass while the output claimed to
   have been built from the real default. So the component **pins the SHA-256
   digest of each of the eight shipped default profile documents** as
   constants in `shadow/v1/materialization-input.jq`, under a header
   `# pinned from profiles/default/v1 at <commit>`, and refuses `E_PROFILE`
   when any supplied document's digest differs from its pin, naming the file
   that differed. The digests below are of the bytes as committed on `main`
   at `4965175d0edeeec8ba746609e585b053be03e075`. All eight files are stored
   canonical — byte-identical to their `jq -S -c` form, including the single
   trailing newline — so the committed bytes and the canonical bytes have the
   same digest and there is no choice to get wrong:

   | file under `profiles/default/v1/` | sha256 of the bytes as committed |
   | --- | --- |
   | `profile.json` | `4562888df59cd52feb6e9c9d29e2345579815695ec3af0aec833891f7f608a74` |
   | `producer-config.json` | `ea076206d7f721aa4796c2a0830e95b3c7006703addc717240447c64ad589b61` |
   | `manifests/claude-code-producer.json` | `ada221fd7186544a53ceb2f10e0bbe863eb0ef6ef54b407c65f58d7f21881bb3` |
   | `manifests/codex-native-reviewer.json` | `2f1ceaacd455e6cadc09f2762c6735eab48b91890240b6031af3db744a1175c4` |
   | `manifests/deterministic-verifier.json` | `58f65eeac7dc8292e48adf6e1d0e8235d5a19c92521993c74b7b3368bb3f36fe` |
   | `manifests/dormant-publisher.json` | `e780e0ceb0a305928d6c1fec127cfc6db0140cf2e48b3921e23e59d942419029` |
   | `manifests/github-actions-ci.json` | `a5cf4b1b94e32d850e3d056024fa2d2c3977b977fb08323e99b89f8c159baff3` |
   | `manifests/local-git-materializer.json` | `47c5884ca83597a09f1122467c9c0dfd3ea5b4e0256d2d52ae648167349bffe5` |

   The implementer copies those values verbatim; they are not to be
   recomputed by hand. All eight are pinned, not just `profile.json`, even
   though the shipped profile's own `manifest_ref` digests already equal the
   six manifest files: pinning each one lets the refusal name the file that
   differs instead of failing somewhere inside the graph rules, and
   `producer-config.json` is in the profile directory but outside
   `profile_set_ok`, so nothing else would have checked it at all. A pin is
   a copy of a fact that lives elsewhere in the
   repository, so it can drift, and requirement 13's test asserts each pin
   equals the digest of the live file at the same commit. That makes a later
   change to the default profile move the pins in the same pull request or
   fail CI — the same keep-in-sync discipline
   `loop/v1/review-fix-planner.jq:1-3` states for source it copies verbatim.
   The default profile (`profiles/default/v1/`) has **six** manifests and six
   bindings — `ci`, `forge`, `producer`, `publisher`, `reviewer`, `verifier`
   — and anything but those six exact documents is a refusal, not a warning.
   The operation is
   always `binding.forge` with capability `core.forge.materialize-candidate.v2`
   and the four permissions the materializer offers; that binding already
   satisfies `materializer_relations_ok` in
   `adapters/local-git-materializer/v1/protocol.jq` (deterministic, no config,
   prompt, model request, skills, or tools).
4. **Read-only by construction, in the two places the driver looks.** The
   `input.producer-patch` payload data is the empty string in both `.payloads`
   and `.trust_context.verified_payloads`, and the empty-content digest
   `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` is recorded
   wherever the fixture builder records the patch digest — the verified payload's
   `sha256` and the stage request's `input.producer-patch` content ref.
   `network_mode` is `deny`. Those are exactly the facts the driver's
   `E_READ_ONLY` check reads (`shadow/v1/reproduce.sh` lines 241-246).
5. **`allowed_paths` is not empty, and that is not a hole.** The protocol
   requires at least one allowed path and `max_changed_paths` between 1 and the
   number of allowed paths, so the contract carries the single path
   `.ystack/never-written`, `max_patch_bytes: 1`, and `max_changed_paths: 1` —
   the smallest values it accepts. Inertness comes from the empty patch, not the
   path list: with no patch bytes there is nothing to apply to any path.
6. **Every digest is the digest of bytes that exist.** No placeholder constants.
   Profile, resolved-profile, and manifest digests are of their canonical file
   bytes; contract and patch digests are of the payload bytes the input carries.
   Requirement 3's eight pins are not an exception to this: they too are
   digests of bytes that exist, in the repository rather than in the caller's
   arguments, and the test proves they still are.
   The core also requires caller-owned scope refs — `finish-condition`,
   `verification-instructions`, `output-contract`, and `policy` — so the
   assembler writes each of those fixed decision-record texts into the output
   directory and records its real SHA-256, with `scope_sha256` equal to
   `decision_record_ref.sha256` (the convention `evals/v1/framework.jq:36`
   already uses). `selection_ref` and `repository_context_ref` are copied
   unchanged from the resolved profile, because
   `stage_request_resolved_relation_ok` requires it, and `requested_by` is
   projected from the resolved forge binding, so the requester is exactly the
   binding the operation selects.
7. **`environment_ref` is derived from the supplied claim, never invented.**
   The request carries the two-field object core v2 requires, `{environment_id,
   fingerprint_sha256}` (`core/v2/generations/g-*/modules/schema.jq:345-348`,
   `environment_ref_ok`; the fixture form is
   `scripts/test/portable-core-stage-request-fixtures.jq:218`). The assembler
   fills both from the claim file the caller supplies: `environment_id` is the
   claim's `.id`, and `fingerprint_sha256` is the SHA-256 of the claim's
   canonical bytes — the same digest `shadow/v1/reproduce.sh` line 168 takes of
   that same file as `claim_sha`. So the request's environment is exactly the
   claim the driver evaluates: the proof is bound to the execution environment
   it was produced in, which is what the ROADMAP asks for (`ROADMAP.md:94-96` —
   the record identifies the execution environment, and each execution
   environment qualifies separately). The claim is held to the same shape the
   driver holds it to: exactly one JSON value, byte-identical to its `jq -S -c`
   form, at most 1 MiB (the driver's own bound, `shadow/v1/reproduce.sh` line
   156), `kind` exactly `execution_environment_claim`, and `id` in the core id
   charset `\A[a-z0-9][a-z0-9._:-]{0,127}\z` (the driver's own test, lines
   222-228). Otherwise `E_SHAPE` for the wrong kind or an id outside the
   charset, `E_CANONICAL` for bytes that parse but are not canonical, `E_LIMIT`
   for a claim over 1 MiB, and `E_PARSE` for one that is not a single JSON
   value, as for every other input. No fixed inert id, and no fingerprint over
   a file the assembler wrote itself.
8. **One canonical output the materializer protocol accepts.** Exactly one
   `local_git_materialization_input`, written as `jq -S -c` canonical JSON, that
   passes `protocol.jq` `validate-input` under the pinned jq.
   `target_repository_id` and `target_revision` are the caller's repository
   id, the hash algorithm the source repository reported, and the commit;
   `target_revision.hash_algorithm` is that reported value — `sha1` or
   `sha256`, never a fixed string — which is what `git_revision_ref_ok`
   allows (`core/v2/generations/g-*/modules/schema.jq:266-273`) and what the
   protocol's `oid_ok` widths follow
   (`adapters/local-git-materializer/v1/protocol.jq:289-294`). The
   source-tree input is that commit's root tree, read from the bare
   repository, and its object id is in the same format. Because the algorithm
   is carried rather than assumed, the driver's `E_STALE` binding —
   `target_repository_id`, `target_revision.value.repository_id`,
   `.hash_algorithm`, and `.commit_id` all equal to the incident's own
   `git_revision_ref` (`shadow/v1/reproduce.sh:233-240`) — holds for a
   `sha256` target as it does for a `sha1` one, instead of failing on the
   algorithm field alone. `stage_request.sha256` is re-digested after the
   request is finished, so it is the digest of the bytes actually embedded.
9. **Sibling agreement.** Beside the input, the assembler writes the two
   `pair_ref` documents `{schema_version, kind, id, sha256}` for `stage_request`
   and `resolved_profile`, so the qualified-identity builder (initiative #264)
   binds exactly what `shadow/v1/reproduce.sh` lines 250-256 compares.
10. **Deterministic.** Identical inputs produce byte-identical outputs. The
    caller's timestamp argument fills `requested_at`, `started_at`,
    `finished_at`, and `recorded_at`; the component reads no clock, no
    environment, and no random source. Attempt and request ids are fixed strings.
11. **Bounded size.** The finished input must be under the driver's 8 MiB cap
    (`snapshot_bounded ... 8388608`), and the assembler refuses rather than emit
    something the driver would reject. Evidence: the five-manifest fixture input
    measures 40,210 bytes and the default profile's own documents total about
    13 KB, so the real six-manifest input lands near 50 KB — under one percent of
    the cap.
12. **Refusals use ids that already exist**, from `shadow/v1/reproduce.sh` and
    `packaging/v1/install.sh`. `E_USAGE`: wrong argument count or verb,
    relative path, bad repository id, bad timestamp, or a commit id that is
    not lowercase hex of one of the two accepted widths, 40 or 64 — a width
    the repository has not been asked about yet. `E_TARGET`: the source Git
    directory is not a physical bare repository, it does not report a hash
    algorithm of `sha1` or `sha256`, the commit id's width does not match the
    algorithm it does report, or the commit is not in it. `E_WORKSPACE`: the
    output directory is not an empty physical
    `0700` directory, or it overlaps another argument. `E_RUNTIME`: wrong jq
    digest or version, missing or symlinked required file, failed command.
    `E_LIMIT`: an input file or the finished output exceeds its bound, the
    claim's bound being the driver's own 1 MiB. `E_PARSE`: an input is not
    exactly one JSON value, or carries a BOM. `E_CANONICAL`: it parses but is
    not byte-identical to its `jq -S -c` form. `E_SHAPE`: the profile, resolved
    profile, or a manifest fails its own core v2 document shape, or the claim
    is not kind `execution_environment_claim` with an id in the id charset.
    `E_PROFILE`: the profile directory layout is wrong, it does not hold
    exactly six manifests, `profile.json` is not the default profile
    `profile.default.v1`, or a supplied document's SHA-256 differs from its
    pin in requirement 3 — a look-alike default, refused by bytes.
    `E_RELATION`: the profile set does not hold together,
    or the finished input fails `validate-input`. No new error id.
13. **Proof runs in CI.** `scripts/test/shadow-assembler.test.sh` bootstraps
    the pinned jq 1.6 the way the existing slice test does, builds a fixture
    bare repository, and produces a resolved profile the way
    `scripts/test/local-git-materializer-fixtures.sh` produces one — but over
    the **shipped** `profiles/default/v1/` documents, not the five synthetic
    manifests that builder invents for itself, because the pins in
    requirement 3 admit nothing else. It passes the existing fixture claim as
    the ninth argument, and asserts: the output validates against the
    materializer protocol; a second run is byte-identical; the read-only
    shape holds in both payload places; the request's
    `environment_ref.environment_id` equals the supplied claim's `.id` and
    its `fingerprint_sha256` equals the SHA-256 of that claim file's bytes;
    the two `pair_ref` documents match what the driver compares; and each
    refusal above fires for its own bad input, including a claim of the wrong
    kind, a claim with an out-of-charset id, a non-canonical claim, a profile
    whose id is not `profile.default.v1`, and — the case the id check cannot
    catch — a self-consistent profile set that reuses the id
    `profile.default.v1` but whose bytes differ, which must come back
    `E_PROFILE`.

    Two further assertions carry the two findings this revision answers.
    **The pins are live.** The test recomputes the SHA-256 of each of the
    eight files under `profiles/default/v1/` in the working tree and asserts
    it equals the pin the jq program carries, so the pins and the profile can
    only move together. **Both hash algorithms are covered.** The test runs
    the assembler against a `sha1` bare repository (the existing fixture
    shape) and against a `sha256` bare repository, and asserts that
    `target_revision.hash_algorithm` and the widths of the commit and tree
    ids follow the repository in each case, and that a 40-hex commit id
    offered to the `sha256` repository is refused `E_TARGET`. A `sha256`
    fixture is available: `scripts/test/local-git-materializer-fixtures.sh`
    takes the algorithm as its fourth argument and accepts `sha1` or `sha256`
    (lines 10 and 16-20), and
    `scripts/test/local-git-materializer-adapter.test.sh:973-981` already
    builds a `sha256` bare source and runs the adapter end to end on it. The
    second algorithm reuses the same fixture ground, so it adds a repository
    and an assertion block, not a second test.

    It then feeds the assembled `sha1` input to `shadow/v1/reproduce.sh` with
    the existing fixture environment, policy set, and duty, and the same
    claim file it handed the assembler — so the request's `environment_ref`
    names the very environment the driver evaluates — and asserts an outcome
    that is not `inconclusive`.
14. **Component conventions.** A `docs/components.md` section, one README index
    row pointing at it, a `RESTORE.md` restore block naming the test, and the new
    paths appended at the **end** of `ci/required-files.txt`.

## Design

Files, in the order they are written:

1. `shadow/v1/materialization-input.jq` — document construction and the
   self-check, as jq. Its structure mirrors
   `scripts/test/local-git-materializer-fixtures.sh`: contract, manifests,
   profile pair, resolved-profile pair, stage request, then the input that
   wraps them with `payloads` and `trust_context`. At the top it carries the
   eight default profile digests from requirement 3, under the header
   `# pinned from profiles/default/v1 at <commit>` — `<commit>` being the
   commit the digests were taken at, `4965175d0edeeec8ba746609e585b053be03e075`
   unless the profile has moved by the time the component lands — and the
   check that each supplied document's digest equals its pin. The claim's id and digest, the
   hash algorithm, and the commit and tree ids all arrive as arguments and
   are placed in the request; the jq program never reads a file and never
   spells `sha1` as a literal in the revision it builds. Anything copied from
   a producer sits verbatim under a `copied from <path> at <commit>` header,
   as `loop/v1/review-fix-planner.jq` already does.
2. `shadow/v1/assemble-materialization-input.sh` — argument and workspace
   checks, the pinned-jq check, reading and canonicalizing each input, the
   profile-id check and the eight digest comparisons against the pins, the
   claim checks and the two values derived from it (its `id` and the SHA-256
   of its bytes), the Git reads under the protective environment
   (`rev-parse --show-object-format` first, then the commit-id width check
   against what it reported, that the commit exists, and its root tree id),
   the call into the jq program with the algorithm passed through, the size
   check, then the writes: `input.json`, `stage-request-ref.json`,
   `resolved-profile-ref.json`, and the decision-record texts.
3. `scripts/test/shadow-assembler.test.sh` — the proof in requirement 13.
4. `docs/components.md` — an "Inactive shadow materialization input assembler"
   section that states plainly where resolved profiles come from today, next to
   the existing resolver trusted-parent note.
5. `README.md` one index row, `RESTORE.md` one restore block, and the three new
   paths appended at the end of `ci/required-files.txt`.

Nothing runs at build or install time. The component stays inactive: it is a
program an operator can run, and running it writes files into a directory the
operator supplies. It reads no network, no credential, and no model.

## Out of scope

- Resolving a profile, and the trusted parent that would make production
  resolution possible. That is a separate high-risk initiative.
- Registering the self-host execution environment
  (`work/shadow-env-self-host/`), and any judgment about whether the supplied
  claim's environment is listed or satisfied; the driver already decides that.
- Any profile other than the default. The assembler accepts only the shipped
  `profile.default.v1` documents, by digest; making a non-default profile
  work is carried forward from the intent's open question.
- The qualified-identity document (initiative #264); this spec only makes the two
  references it must bind available.
- Any change to `shadow/v1/reproduce.sh`, the materializer, the core modules, or
  the default profile; and running an actual self-host shadow run. This spec
  reads the default profile's bytes and pins their digests, and it does not
  touch the profile itself — but from here on a change to that profile also
  moves the pins, in that change's own pull request.

## Areas of concern

- **Intake criterion 2 is deliberately not met.** The intake issue asked for the
  input to be built "through the shipped resolver". It is not: the resolved
  profile is an input. The operator decided this as DR-1 option 2 on issue #262
  on 2026-09-09. The issue is a message bus; the merged intent says only "from
  the real default profile" and left the resolution question open, so the intent
  meaning is unchanged and this does not return through G1.
- **Risk stays `routine`.** No security control, workflow, identity or auth path,
  migration, deployment, or architecture changes. The driver, the materializer,
  the core modules, and the profile are untouched; this adds one producer of an
  existing input plus a test and documentation, and nothing it writes is
  activated by anything.
- **The input is only as trustworthy as the resolved profile handed to it.** The
  assembler proves the supplied resolved profile is internally consistent with
  the profile and manifests; it cannot prove a trusted resolver produced it.
  The pins do not close this. They fix the profile and the six manifests to
  the shipped bytes, so the resolved profile can only be consistent with the
  real default and no look-alike — but a resolved profile is produced per
  run, so there is nothing to pin it to. Until the trusted parent exists,
  that document can only have come from the test launcher, so a run built
  this way is a rehearsal, and the first self-host run should wait for the
  parent rather than treat it as production evidence.
- **`environment_ref` binds the request to the supplied claim, and no
  further.** The assembler proves the ref names the claim document the caller
  handed it: the id is that claim's `id`, and the fingerprint is the digest of
  that claim's bytes, so a request cannot quietly describe some other
  environment than the one the driver is given. That is the limit of what it
  proves. Whether that environment is listed in
  `shadow/v1/shadow-environments.json` and whether its sandbox claim is
  satisfied is the driver's job, and the driver already does it — an unlisted
  or unsatisfied environment comes back `inconclusive`. Registering the
  self-host environment stays with `work/shadow-env-self-host/`.
- **Only the default profile is accepted, and "the default profile" means the
  bytes.** Requirement 3 refuses any `profile.json` whose id is not
  `profile.default.v1`, but the id is only the cheap first check. What the
  component actually proves is that all eight supplied documents are
  byte-identical to the shipped `profiles/default/v1/` documents at the
  pinned commit `4965175d0edeeec8ba746609e585b053be03e075`. Without that, a
  caller could hand over a profile set that is entirely self-consistent —
  its own manifests, its own resolved profile — and reuse the id, and the
  output would claim real-default provenance for a profile nobody shipped.
  With the pins, what is accepted is exactly what is proven, and the claim
  the output makes about where it came from is a claim about bytes.
  The cost is that the pins are a copy: change the default profile and the
  pins must move in the same pull request, which the test enforces rather
  than trusts. Support for another profile is carried forward from the
  intent's open question.
- **The hash algorithm follows the repository, not this spec.** An earlier
  draft wrote `sha1` as a fixed value. That was wrong twice over: the
  materializer protocol accepts both formats
  (`adapters/local-git-materializer/v1/protocol.jq:289-294` and `:238-246`),
  the fixture builder takes the algorithm as an argument
  (`scripts/test/local-git-materializer-fixtures.sh:10,16-20`), and the
  adapter is already tested end to end on a `sha256` source
  (`scripts/test/local-git-materializer-adapter.test.sh:973-981`) — so a
  hard-coded `sha1` would have refused a legitimate target, and would have
  quietly mislabelled one if the label had been written without the width
  check. Reading the format from the repository keeps the assembler honest
  for either, and keeps the driver's `E_STALE` comparison meaningful. What
  it does not do is make the assembler tolerant: a commit id whose width
  disagrees with the format the repository reports is `E_TARGET`, not a
  coercion.
- **Timestamp, and resolve-fresh-or-pinned.** The intent's first open question is
  decided: the timestamp is a caller-supplied argument, because a clock read
  would break determinism. Its third is answered by DR-1 — neither fresh nor
  pinned; the resolved profile is an input, and producing one in production is
  the trusted-parent initiative.
