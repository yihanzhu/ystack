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

**Implementation PR size (the component and its test).**
`review_size: accepted-exception`. One concern: one inactive component whose
focused test must drive the real `reproduce.sh` end to end with the existing
fixture environment (the shadow slice test itself is 622 lines for the same
reason). Range: 595-825 net lines — about 425 lines of component (shell plus
jq), about 320 lines of test, and the documentation rows. The evidence is the
nearest thing in the repository: `scripts/test/shadow-slice.test.sh` is 622
lines, because a test that runs the driver has to build a bare repository, a
profile set, and a claim before the driver can run once. This test builds that
same fixture ground and then runs the driver again on the assembled input, so
it lands in the same band, and the component itself is the ~425 lines above.

The range moved up from 450-650, and then by about another 30 lines, for one
reason, and it is a reason that argues for the exception rather than against
it: requirement 15 copies the materializer's repository-level source-purity
predicates verbatim — about 90 lines of predicate, or about 105 counting the
header, the four name bindings and the subshell wrapper — and requirement 17
copies the materializer's clean entry, 18 lines more, plus the assertions and
the negative sources that prove both in the test. That is text this initiative
did not write and must not edit. Shortening it would mean re-implementing a
predicate the whole point of which is that it is not re-implemented.

The exception waives only the soft line signal. It does not widen scope beyond
the one concern, and it does not relax readability, tests, CI, review, or
operator merge. The component and its focused test land together, which is the
repository convention; splitting them would ship a component with no proof and
a test with nothing to prove. Requirement 17's clean entry is not a second
concern either: it is the first lines of the same script, and requirement 15's
predicates do not mean what they say without it, so the two cannot ship apart.

**This artifact PR's own size (the spec file).** The `AGENTS.md:102-106` soft
budget of ~300-400 net lines applies to this spec PR as well, not only to the
implementation it describes, and this file is far over that budget, so the
overrun is recorded here rather than left unexplained. One concern: one
component spec for a security-adjacent input assembler whose ten review rounds
each added a verified requirement (protocol-valid inertness, byte-pinned
default profile, hash algorithm, full repository-level source guards, clean
entry, working-tree proofs). Evidence-based range: 1041 lines measured — the
count is self-inclusive, the length of this file as committed — so 885-1197
net lines at that measurement +/-15%. This exception waives only the soft line
signal for this artifact PR. It does not widen scope beyond the one concern,
and it does not relax readability, review, CI, or operator merge. No content
is trimmed to fit: each of those lines carries a requirement or a rationale
that a review round verified, and deleting them to hit a line count would
lose the verified detail the rounds added.

## Requirements

1. **Nine positional inputs, all absolute paths or exact values.** Invocation
   is `assemble <repository-id> <source-git-dir> <commit-id>
   <attempt-timestamp> <profile-dir> <resolved-profile-file> <jq-binary>
   <output-dir> <environment-claim-file>`. The claim is appended, so the first
   eight keep their positions. The repository id matches
   `\A[a-z0-9][a-z0-9._:-]{0,127}\z`; the source Git directory is a physical
   bare repository that passes **every repository-level source guard the
   materializer applies, copied verbatim** — requirement 15, which also says
   plainly which materializer check is *not* mirrored here and why — and
   **its hash algorithm is read from the repository, not
   assumed**: `git rev-parse --show-object-format` under the same protective
   environment the driver and the materializer use (`--no-replace-objects`,
   `GIT_NO_REPLACE_OBJECTS=1`, `GIT_NO_LAZY_FETCH=1`, no system or global
   config, and the hook pin at
   `adapters/local-git-materializer/v1/materialize.sh:265-269`) — which is the
   same read the copied span makes at `:352`; the commit id is lowercase
   hex — 40 characters when the repository reports `sha1`, 64 when it
   reports `sha256`
   — must match the format the repository actually reports, and must exist
   there as a commit whose object is at most 1 MiB; existence, object type and
   that size bound are all decided by requirement 15's copied lines `:355-360`
   rather than by anything written here; the timestamp is exactly
   `YYYY-MM-DDTHH:MM:SSZ`; the
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
   `profile_set_ok`, so nothing else would have checked it at all — and
   requirement 16 carries that same pin through into the resolved profile's
   producer binding, which `profile_set_ok` also leaves unchecked. A pin is
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
    `packaging/v1/install.sh`. `E_USAGE`: wrong argument count or verb —
    both decided by requirement 17's copied entry, before anything else runs
    — relative path, bad repository id, bad timestamp, or a commit id that is
    not lowercase hex of one of the two accepted widths, 40 or 64 — a width
    the repository has not been asked about yet. `E_TARGET`: the source Git
    directory is not a physical bare repository, it fails any of the
    materializer source guards requirement 15 copies — including the two an
    earlier draft left out, a config key outside the seven-name allow-list and
    a hook that is not a `*.sample`, the `packed-refs` span, a file that
    carries a `refs/replace/` line or is over 1 MiB, and the commit-object
    bound this revision adds, a commit whose object is over 1 MiB
    (`materialize.sh:359-360`) — it does not report a hash
    algorithm of `sha1` or `sha256`, the commit id's width does not match the
    algorithm it does report, or the commit is not in it. The materializer's
    own `E_SOURCE_*` ids stay in the materializer: a copied predicate that
    fails is reported with the id this component already has, so the copy adds
    no error id even though it adds checks. That is why an oversized commit
    object is `E_TARGET` and not `E_LIMIT` even though the copied line says
    `E_SOURCE_LIMIT`: `E_LIMIT` is for the caller's own files and the finished
    output, and everything the copy refuses about the source repository is
    `E_TARGET`. `E_WORKSPACE`: the
    output directory is not an empty physical
    `0700` directory, or it overlaps another argument. `E_RUNTIME`: wrong jq
    digest or version, missing or symlinked required file — including the
    script's own path once requirement 17 has normalized it — failed command,
    or the `0700` scratch directory requirement 15's copy writes into cannot
    be made inside the output directory.
    `E_LIMIT`: an input file or the finished output exceeds its bound, the
    claim's bound being the driver's own 1 MiB. `E_PARSE`: an input is not
    exactly one JSON value, or carries a BOM. `E_CANONICAL`: it parses but is
    not byte-identical to its `jq -S -c` form. `E_SHAPE`: the profile, resolved
    profile, or a manifest fails its own core v2 document shape, or the claim
    is not kind `execution_environment_claim` with an id in the id charset.
    `E_PROFILE`: the profile directory layout is wrong, it does not hold
    exactly six manifests, `profile.json` is not the default profile
    `profile.default.v1`, a supplied document's SHA-256 differs from its
    pin in requirement 3 — a look-alike default, refused by bytes — or a
    present `config_source` in the supplied resolved profile does not carry
    the pinned digest of the document it names (requirement 16).
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

    The fixture builder needs one change the existing ones do not have.
    `scripts/test/local-git-materializer-fixtures.sh:114` writes
    `config_source={state:"absent"}` for every binding, and the shipped
    default profile's producer binding carries a `config_ref`, so an absent
    config source there would not even satisfy the core rules. The test's
    builder therefore writes a present producer `config_source` whose
    `value.source` is that `config_ref` and whose `value.value_sha256` is the
    real SHA-256 of `profiles/default/v1/producer-config.json` — not the
    stand-in digest `scripts/test/default-profile-assembly.test.sh:310-311`
    reuses for every source, which requirement 16 now refuses.

    Two further assertions carry the two findings the previous revision
    answered.
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

    The assertions below carry this revision's three findings — how the copy
    is proven, the commit-size guard, and the clean entry — plus the guards an
    earlier draft missed and the producer config digest.

    **The copy is a copy, and
    it is compared against the working tree.** The test extracts the copied
    spans from `shadow/v1/assemble-materialization-input.sh`, between the copy
    header and its end marker, and compares them byte for byte with
    `adapters/local-git-materializer/v1/materialize.sh` **in the working
    tree** — the same checkout the test itself is running in — at lines
    271-332, 333-347, and 348-360.

    An earlier revision read those bytes with `git show
    <commit>:adapters/local-git-materializer/v1/materialize.sh` at the commit
    the copy header names. That does not work in CI and would have made the
    assertion useless there: `.github/workflows/ci.yml:15` checks out with
    `actions/checkout` at its default depth of one commit, so no ancestor
    object is present and `git show <an older commit>:<path>` fails outright.
    A test that cannot read its own reference either errors or, worse, is
    written to skip.

    So the proof is "equal to the producer as it stands right now". The copy
    header still records the commit the copy was taken at, because that is the
    provenance a reader needs — where this text came from — but it is not what
    the test reads. If `materialize.sh` changes later, this test goes red and
    the copy must move in the same pull request. That is exactly the
    keep-in-sync discipline requirement 15 wants, and it is stronger than the
    pinned-commit read, which would have kept passing while the producer
    drifted underneath it.

    **The line ranges are anchored to content, not trusted as numbers.** For
    each span the test greps `materialize.sh` for that span's own **first**
    line, as a fixed whole-line string that must match exactly once, and
    asserts the line number it matched at equals the start this spec states —
    271, 333 and 348, and 4 and 22 for requirement 17's two blocks. Each of
    those five first lines is unique in the file today, which is what makes
    them usable as anchors. The **end** is fixed by length instead: the test
    counts the lines of the block it extracted from the assembler, reads that
    many lines from the anchor, and requires the resulting last line number to
    equal the end this spec states. The last lines are deliberately not used
    as anchors, because they are not unique — the three purity spans end on
    `emit_error E_SOURCE_GIT`, `fi` and `emit_error E_SOURCE_LIMIT`, each of
    which appears several times in `materialize.sh` — and an anchor that
    matches in several places proves nothing.

    So a line shift in `materialize.sh` fails as a shift, naming the number
    that moved, rather than silently comparing the wrong 62 lines; a span that
    grew or shrank fails on the length; and a reflow or an edit inside the
    span fails on the bytes. A first line that has come to appear twice, or
    not at all, also fails, which is the right answer — the anchor has stopped
    being an anchor and a person needs to look. There is no other
    `git show <commit>` proof left in this spec: every span assertion reads
    the working tree.

    **Requirement 17's entry is proven as an adaptation, not a copy.** Because
    it carries three named deviations, byte equality is the wrong test. The
    test instead diffs the assembler's entry against the working tree's
    `materialize.sh:4-13` and `:22-29` and asserts every hunk in that diff is
    one of the three deviations requirement 17 names — the marker word and
    verb, the argument count, and the script-path normalization — and nothing
    else.

    **The guards an earlier draft missed actually fire.** Four negative source
    repositories, each otherwise a clean copy of the `sha1` fixture: one with a
    disallowed config key set (`remote.origin.url`), one with a non-`*.sample`
    file in `hooks/`, one whose `packed-refs` file carries a
    `refs/replace/<commit>` line, and one whose head commit carries a commit
    message over 1 MiB, so its commit object exceeds the bound at
    `materialize.sh:359-360`. All four must come back `E_TARGET`; the second,
    third and fourth prove the parts of the copy that no earlier draft ran at
    all. The oversized-commit case also pins the id: `E_TARGET`, not
    `E_LIMIT`.

    **An exported function cannot silence the copy.** The test invokes the
    assembler twice more with a shell function planted in the environment —
    `find() { :; }; export -f find`, and the same for `grep` — once against
    the `hooks/` negative repository, which must still come back `E_TARGET`
    rather than passing, and once against the good `sha1` fixture, which must
    still assemble bytes identical to the clean run. The first shows
    requirement 17's scrub closes the bypass; the second shows it takes
    nothing the assembler needs. Both are run as `/bin/bash
    <path-to-assembler> assemble …` as well as directly, because the
    `#!/bin/bash -p` shebang does not apply to the first form and only the
    scrub and re-exec cover it.

    **The producer config digest is bound.** A
    resolved profile identical to the good one except that the producer
    binding's `config_source.value.value_sha256` is changed — its
    `value.source` left alone, so the core rules still pass it — must come
    back `E_PROFILE`.

    **Shellcheck.** `shellcheck -x -S style` at the pinned 0.11.0 passes on
    both new shell files, with no new `shellcheck disable` directive in
    either.

    It then feeds the assembled `sha1` input to `shadow/v1/reproduce.sh` with
    the existing fixture environment, policy set, and duty, and the same
    claim file it handed the assembler — so the request's `environment_ref`
    names the very environment the driver evaluates — and asserts an outcome
    that is not `inconclusive`.
14. **Component conventions.** A `docs/components.md` section, one README index
    row pointing at it, a `RESTORE.md` restore block naming the test, and the new
    paths appended at the **end** of `ci/required-files.txt`.
15. **Every repository-level source guard the materializer applies runs here,
    copied verbatim.** Here is the exact guarantee, and its exact boundary.
    **The assembler refuses every *repository-level* condition the
    materializer refuses** — the filesystem inventory, the config allow-list,
    bareness, the structural absences, hooks, the object format, the
    `packed-refs` scan for replace refs, and the size of the commit object
    itself — **plus commit existence and commit
    format.** **It does not re-check *tree content*** — symlinks, submodules,
    invalid path names, and the closure size caps the materializer's tree scan
    enforces (`scan_tree` at `materialize.sh:386-452`, used at `:456-465`,
    `E_SOURCE_TREE`, and the closure walk at `:463-465`). Those stay the
    materializer's job. When one of them trips, the driver reports
    `materialization.refused`, which is a documented, honest outcome rather
    than a surprise.

    The line is drawn there because of cost against the goal. The tree scan is
    not a predicate that can be lifted out: it needs the full object-closure
    walk the materializer performs — enumerating every tree and blob reachable
    from the root tree, under the same byte, entry and tree caps — so
    duplicating it would mean copying most of the materializer into this
    component, and then carrying that copy for the life of both. What the
    copying buys is smaller than it looks: none of the tree-content conditions
    can make the run write anything. The input carries an empty patch and
    `network_mode: deny`, and the materializer refuses the source before it
    materializes it, so a symlink or an oversized closure costs a refused run,
    not a side effect. The repository-level guards are different in kind —
    they are short, self-contained predicates that decide whether the source
    directory is a plain bare repository at all — so they are cheap to carry
    and they are carried.

    An earlier draft mirrored only part of even the repository-level set: the
    protective environment, and the alternates, grafts, replace-refs, shallow,
    and worktree checks. The materializer demands four more things. The source
    repository's config file may contain nothing beyond seven names —
    `core.repositoryformatversion`, `core.filemode`, `core.bare`,
    `core.logallrefupdates`, `core.ignorecase`, `core.precomposeunicode`,
    `extensions.objectformat` (`materialize.sh:301-323`, `E_SOURCE_CONFIG`);
    its `hooks/` directory may hold no file that is not a `*.sample`
    (`:348-351`, `E_SOURCE_HOOK`); and its `packed-refs` file, if it exists,
    must be a regular file, at most 1 MiB, and free of any `refs/replace/`
    line (`:333-347`, `E_SOURCE_GIT` and `E_SOURCE_LIMIT`) — the packed
    counterpart of the `refs/replace` directory check the earlier draft did
    mirror. And the commit the caller names must be a commit object of at most
    1 MiB: the materializer reads its type with `cat-file -t` and its size
    with `cat-file -s` and refuses `E_SOURCE_LIMIT` unless the type is
    `commit` and the size is `<= 1048576` (`:355-360`) — a check it makes
    *before* the tree scan, so it is a repository-level refusal like the other
    three and not part of the tree-content boundary below. A source that trips
    any of the four passes everything the earlier
    draft listed, gets an input built for it, and then comes back
    `materialization.refused` from the driver: a wasted run, and a confusing
    one, because nothing the assembler said would explain it.

    So the assembler runs the materializer's **complete** repository-level
    source-purity predicates, not a subset and not a paraphrase. They are
    three contiguous spans of
    `adapters/local-git-materializer/v1/materialize.sh`:

    - **271-332** — the `git_dir` helper (271-275); the bounded filesystem
      inventory (277-299), which requires every entry under the directory to
      be inside it, not a symlink, and either a regular file or a directory,
      at most 8388608 bytes of paths and 65536 entries; the bounded config
      snapshot and its name-only allow-list (301-323); `rev-parse
      --is-bare-repository` equal to `true` (324-325); and the structural
      absences (326-332) — no `commondir`, no `shallow`, no entry under
      `worktrees`, no `info/grafts`, no `objects/info/alternates`, no
      `refs/replace` directory, and no `*.promisor` pack.
    - **333-347** — the `packed-refs` scan: if `packed-refs` exists it must be
      a regular file and not a symlink (335), it is snapshotted into
      `run_root` under a 1 MiB bound (336-342), and the snapshot must contain
      no `^<40 or 64 hex> refs/replace/` line (343-346). See below for why the
      driver does not carry this span.
    - **348-360** — no hook that is not a `*.sample` (348-351); `rev-parse
      --show-object-format` equal to `$source_algorithm` (352-354); and the
      commit object itself (355-360) — `cat-file -t` and `cat-file -s` on
      `$source_commit`, which fail `E_SOURCE_IDENTITY` if the object is not
      there at all, and then the pair of conditions that the type is `commit`
      and the size is at most 1048576 bytes (`E_SOURCE_LIMIT`). The span used
      to stop at 354; extending it to 360 is what this revision adds. Because
      355-358 *is* the commit lookup, the assembler no longer writes its own:
      requirement 1's "must exist there as a commit" is decided by these
      copied lines. The span stops at 360 and does not reach 361-363, the
      materializer's root-tree read, because that compares the tree against a
      `$source_tree` the materializer was given and the assembler has none —
      the assembler reads the root tree afterwards, as its own step.

    They are **copied verbatim** into
    `shadow/v1/assemble-materialization-input.sh` — byte for byte, not
    re-implemented and not approximated — under the header this repository
    already uses for a copied predicate (`shadow/v1/qualified-identity.jq:8-13`
    is the pattern): `# Copied verbatim from
    adapters/local-git-materializer/v1/materialize.sh at
    a637451d4b3fbef6b516a9c08f68c0dde46a7059 (origin/main) — keep in sync.`,
    followed by one sentence saying why it is a copy — the assembler must
    refuse exactly what the materializer refuses *about the repository
    itself*, so the two can never disagree about what a plain source
    repository is. All three spans sit under the one header, and requirement
    17's clean entry is copied under the same one. That commit is
    the one
    `materialize.sh` last changed at; if it moves before this lands, the
    header names the new one and the copy is retaken from it.

    **What the commit in that header is for.** It records where the text came
    from — provenance a reader can follow — and nothing more. It is not what
    proves the copy is a copy. That proof is requirement 13's byte comparison
    against `materialize.sh` **as it stands in the working tree**, at the line
    ranges above, located by their own first and last lines. So the header
    answers "where did this come from" and the test answers "is it still equal
    to the producer", and the second question is the one that can fail. If
    `materialize.sh` moves, CI goes red and the copy moves in the same pull
    request.

    The copy runs **before the assembler reads anything else out of the
    repository**. The commit lookup is now inside the copy itself, so the only
    reads left after it are the algorithm read the copy already agreed on and
    the root tree — nothing that could decide a refusal. An impure source is
    therefore refused on its own terms rather than on some later symptom.
    Four names are bound just above the copy so its body needs no editing:

    - `run_root` — a `0700` scratch directory the assembler creates **inside
      the caller's output directory**, and removes before it finishes, so the
      output directory ends up holding only the documents requirements 6, 8
      and 9 name. It is inside the output directory rather than under
      `mktemp`'s `${TMPDIR:-/tmp}` for a plain reason: requirement 17's clean
      entry passes through `PATH` and `LC_ALL` only, so there is no inherited
      `TMPDIR` to read, and the output directory is the one writable place the
      assembler already owns — requirement 1 requires it empty, `0700`,
      physical, and disjoint from the source repository and the profile
      directory, which is exactly what `run_root` needs to be. The copied
      lines write only `source-filesystem`, `source-config.snapshot`,
      `source-config` and — from the second span — `packed-refs` there, and
      delete the first themselves.
    - `git_env` and `git_dir` — the assembler's own protective environment,
      which also carries the materializer's hook pin
      (`materialize.sh:265-269`: `GIT_CONFIG_COUNT=1`,
      `GIT_CONFIG_KEY_0=core.hooksPath`,
      `GIT_CONFIG_VALUE_0="$run_root/no-hooks"`). Those same lines set
      `HOME="$run_root"` and `TMPDIR="$run_root"` explicitly, which is how git
      gets a home and a temporary directory without the assembler inheriting
      either — see requirement 17.
    - `source_algorithm` — the algorithm the caller's commit-id width implies,
      `sha1` for 40 hex and `sha256` for 64. Binding it from the argument
      rather than from the repository is what keeps the copied 352-354 a real
      check instead of a tautology: it is the line that refuses a 40-hex
      commit id offered to a `sha256` repository. Requirement 1 still stands —
      the algorithm written into the output is the one the repository
      reported, and the copied line is what proves the two agree.
    - `source_commit` — the caller's commit id, bound because the extended
      third span reads it at 355-358. This is the binding that turns the
      assembler's own commit-existence check into a copied one.

    The copy runs inside a subshell function that shadows `emit_error` with an
    immediate non-zero exit — `source_pure() ( emit_error() { exit 1; };
    <verbatim span 271-332>; <verbatim span 333-347>; <verbatim span
    348-360>; exit 0 )` — so the predicates keep their exact text while a
    failure comes back as a return code the assembler can name. The three
    spans are placed in their materializer order, which is also the order
    they depend on: 333-347 reads `$source_git_dir` and writes into
    `$run_root`, both already bound, and 355-360 reads `$source_commit` only
    after 352-354 has agreed on the algorithm. Any failure is `E_TARGET`,
    whichever `E_SOURCE_*` id the copied line would have emitted in the
    materializer. The subshell is also why the copy cannot leak a value out:
    the assembler re-reads the algorithm and the root tree itself, in the
    parent shell, after `source_pure` returns clean.

    **The driver's copy is two spans; this one is three, and one of the three
    is longer.** The sibling spec
    `work/shadow-env-self-host/spec.md` (PR #268) requires the driver to carry
    271-332 and 348-354, and deliberately excludes 333-347: the driver's own
    reads cannot be moved by a replace ref, because the root-commit binding it
    checks runs under `--no-replace-objects` and `GIT_NO_REPLACE_OBJECTS=1`,
    so for the driver that span guards nothing. The assembler is in a
    different position. It is the component whose whole job is to refuse a
    source the materializer would refuse, and the materializer does run
    333-347 — so leaving it out here would put back exactly the gap
    requirement 15 exists to close. The assembler therefore carries all three
    spans. Its copy of 333-347 is copied from the materializer, verbatim,
    under the same header as the other two, and a failure inside it is
    `E_TARGET` like the rest.

    The third span differs from the driver's for a related reason. The driver
    stops at 354 because it is *handed* a commit and never looks one up, so
    355-360 has nothing to run against there. The assembler is handed a commit
    id it must check, so 355-360 is precisely the check it would otherwise
    have written by hand — and writing it by hand is what left the commit-size
    bound out of an earlier draft.

    So **the byte-identity requirement between the two components covers
    271-332 and the 348-354 prefix of this spec's third span** — the driver
    carries 348-354 and stops there, while the assembler's span runs on to
    360. Those shared lines must be byte-identical in the driver and in the
    assembler, and both must carry the header. They are copies of one text, so
    any difference between them is a defect in one of them. Two parts have one
    home rather than two and are checked only against the materializer: the
    `packed-refs` span 333-347, and the 355-360 tail the driver has no use for
    — the driver is handed a commit and does not look one up.
    Requirement 13's test asserts all three copied spans equal the
    materializer's **in the working tree**. Whichever pull request lands
    second inherits the other's bytes for the shared lines rather than
    retaking the copy. Requirement 17's clean entry is shared the same way:
    both components copy `materialize.sh:4-13` and `:22-29`, each with its own
    named deviations, so the scrub block is byte-identical between them and
    the arity, marker and script-path lines are not.
16. **The resolved profile's config bindings are bound to the pins too.**
    Requirement 3 pins the bytes of the eight shipped documents, but that only
    fixes what the caller's **profile directory** holds. The resolved profile
    is a separate input, and the core rules do not tie its source claims to
    those bytes. `resolved_binding_projection_ok` checks only that
    `config_source.value.source` equals the binding's `config_ref` — the Git
    object ref — and says nothing at all about
    `config_source.value.value_sha256`
    (`core/v2/generations/g-*/modules/profile_graph.jq:206-212`, through
    `present_source_matches_optional_ref` at `:185-190`). `source_claims_agree`
    (`:178-183`) only requires claims that share a source key to agree with
    each other, and in the shipped default exactly one claim names the
    producer config, so it agrees with itself and nothing else. A resolved
    profile that keeps the right `source` and swaps `value_sha256` for any
    other 64-hex string therefore passed every check this spec had.

    So the assembler adds one of its own. In the supplied resolved profile,
    the producer binding's `.body.bindings[] | select(.binding.role ==
    "producer") | .config_source.value.value_sha256` must equal
    `ea076206d7f721aa4796c2a0830e95b3c7006703addc717240447c64ad589b61`, the
    pin requirement 3 gives `producer-config.json`. The digest sits two levels
    down because `config_source` is a present-or-absent wrapper
    (`core/v2/generations/g-*/modules/schema.jq:155-159`) whose `value` is a
    `source_value_ref` (`:368-373`). It is the same digest whichever
    `value_format` the claim carries: `raw-bytes` is what
    `resolver/v1/profile-resolution.jq:167` and `:133-137` produce, and
    requirement 3's files are stored canonical, so the raw bytes and the
    canonical bytes are the same bytes.

    The rule is general rather than one hard-coded field. **Every**
    `config_source` in the resolved profile that is `state: "present"` — the
    six bindings' own and every `tool_sources[].config_source` — must name a
    document requirement 3 pins and carry that document's pinned digest. In
    the shipped default there is exactly one: the producer's, pointing at
    `profiles/default/v1/producer-config.json`, and no binding requests any
    tools, so the general rule and the single field coincide today. Writing it
    as a rule means a later default profile that adds a config source cannot
    slip through unchecked. A mismatch, or a present `config_source` naming a
    document that has no pin, is `E_PROFILE`.
17. **The first thing the script does is a clean entry, copied from the
    materializer.** A fixed `PATH` is not enough to make requirement 15's
    copied predicates mean what they say. Bash looks for a shell *function* of
    a name before it ever looks at `PATH`, and a function can be handed to a
    child bash through the environment (`find() { :; }; export -f find`). So a
    caller who cannot touch `PATH` can still make the three bare `find` calls
    inside the copy (`materialize.sh:327`, `331`, `348`) run its own silent
    code — at which point the worktrees, promisor-pack and hook predicates all
    report "nothing found" and an impure source walks through with an input
    built for it. The same door is open to `head`, `wc`, `tr`, `rm` and `grep`
    — every other command in the copied spans is called by absolute path — and
    an exported `IFS`, `BASH_ENV` or `SHELLOPTS` reaches the same code by
    another route. This is the finding the sibling spec (PR #268) answers for
    the driver, and it is answered the same way here, because the two
    components run the same copied text.

    The materializer already closes this at its own entry, and the assembler
    adopts that entry rather than inventing one. It is two blocks:
    `materialize.sh:4-13`, the scrub — unset every inherited function and
    every exported name but `PATH`, then fix `PATH=/usr/bin:/bin` and
    `LC_ALL=C` and export both — and `materialize.sh:22-29`, the arity check,
    the absolute-script-path check, the `exec /usr/bin/env -i PATH=…
    LC_ALL=C /bin/bash "$script_path" __materialize_clean …` that restarts the
    script in an environment built from nothing, and the marker check that
    every path into the real work has to pass. Both are **copied** into
    `shadow/v1/assemble-materialization-input.sh`, under the same copy header
    requirement 15 uses, naming `materialize.sh:4-13` and `:22-29`. The
    shebang is `#!/bin/bash -p` (`materialize.sh:1`), which is part of this
    entry: started through its shebang, a privileged bash imports no function
    from the environment and ignores `BASH_ENV`, `ENV`, `SHELLOPTS`,
    `BASHOPTS` and `CDPATH`. `-p` alone is not the fix — it is bypassed
    entirely when the file is run as `bash assemble-materialization-input.sh`
    — which is why the scrub and the re-exec are copied too, and why
    requirement 13 tests both invocations.

    Three deviations from the materializer's bytes, and nothing beyond these:

    - **the marker word and verb** — `assemble` where it says `materialize`,
      and `__assemble_clean` where it says `__materialize_clean`;
    - **the argument count** — `[ "$#" -eq 10 ]`, this component's nine
      arguments plus the verb, and the exec forwards `"$2"` … `"${10}"`, nine
      words after the marker. Requirement 1's contract is unchanged from the
      caller's side, and the arity check still runs before the dispatch,
      because the marker form is also ten words;
    - **the script path** — the materializer refuses a relative
      `${BASH_SOURCE[0]}` with `E_USAGE`; the assembler normalizes it against
      `$(pwd -P)` and then requires the result to be an existing non-symlink
      regular file or `E_RUNTIME`, the way `shadow/v1/reproduce.sh:94-96`
      already does, so a bad script path is reported in this component's error
      vocabulary instead of by bash's own failed-`exec` message.

    `set -euo pipefail`, `emit_error` and `umask 077` are the assembler's own
    lines, not deviations. They sit between and after the two copied blocks in
    the same places `materialize.sh:15`, `:17-20` and `:31` put them, and
    `emit_error` has to be defined before the arity check so `E_USAGE` can be
    said at all.

    **It really is the first thing.** The scrub is the top of the file, and the
    re-exec is the first thing after the arity check — before any external
    command, before the pinned-jq check, before any input file is opened, and
    before requirement 15's copy. The scrub runs in both entries, the public
    one and the marker one, so calling the marker form directly gains a caller
    nothing.

    **Environment pass-through is `PATH` and `LC_ALL`, and nothing else** —
    exactly what the materializer passes. The assembler needs no `TMPDIR`:
    every directory it touches is one of its nine arguments or is derived from
    one. Its scratch `run_root` is a `0700` directory inside the caller's
    output directory (requirement 15 says so and says why), not a `mktemp`
    under `${TMPDIR:-/tmp}`. Git's own temporary files and home go to the
    `TMPDIR="$run_root"` and `HOME="$run_root"` that the copied `git_env` sets
    explicitly (`materialize.sh:265-269`). Nothing else in the component reads
    an environment variable; requirement 10 already forbids it. So dropping
    everything is free here, unlike in the driver, where the same decision
    cost a `TMPDIR` fallback.

    Shellcheck 0.11.0 at `-x -S style` must pass on the file with **no new
    `shellcheck disable` directive**. `materialize.sh` passes that same lint
    today carrying only one file-level `disable=SC2016` (`:2`), and that one is
    for its embedded jq program text, not for this entry, so it is not copied
    and nothing replaces it.

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
   check that each supplied document's digest equals its pin. Requirement
   16's check sits beside them, because it compares against the same
   `producer-config.json` pin and the resolved profile is already parsed
   here: it walks every present `config_source` in the resolved profile,
   including each `tool_sources[].config_source`, and refuses unless the
   document it names has a pin and its `value.value_sha256` equals that pin.
   The claim's id and digest, the
   hash algorithm, and the commit and tree ids all arrive as arguments and
   are placed in the request; the jq program never reads a file and never
   spells `sha1` as a literal in the revision it builds. Anything copied from
   a producer sits verbatim under a `copied from <path> at <commit>` header,
   as `loop/v1/review-fix-planner.jq` already does.
2. `shadow/v1/assemble-materialization-input.sh` — in order:

   - **Step 0, the clean entry of requirement 17**, and nothing before it.
     `#!/bin/bash -p`, then the copied scrub (`materialize.sh:4-13`) at the
     very top of the file, then `set -euo pipefail`, `emit_error` and `umask
     077`, then the copied arity check, script-path handling and re-exec
     (`:22-29`) with the three named deviations. Everything below runs in a
     process with no imported functions, no inherited exported variables, and
     `PATH` and `LC_ALL` fixed.
   - Argument and workspace checks, the pinned-jq check, reading and
     canonicalizing each input, the profile-id check and the eight digest
     comparisons against the pins, requirement 16's producer config digest
     check against the same pin, and the claim checks with the two values
     derived from the claim (its `id` and the SHA-256 of its bytes).
   - The Git work under the protective environment: `run_root` created `0700`
     inside the output directory, the `git_env` array and `git_dir` helper,
     and the verbatim `source_pure` copy of requirement 15 — spans 271-332,
     333-347 and 348-360, in materializer order — under its
     header. The commit's existence, type and size are decided inside that
     copy, so there is no separate commit lookup here.
   - Only after `source_pure` returns clean: `rev-parse
     --show-object-format` and the root tree id, read in the parent shell.
     Re-reading the algorithm is deliberate — `source_pure` is a subshell, so
     no value escapes it — and it is safe, because the copied lines 352-354
     have already proved that what the repository reports equals the algorithm
     the caller's commit-id width implies. That reported value is what goes
     to the jq program. Nothing here re-reads the commit's tree to inspect
     its content: that check is the materializer's, by the boundary
     requirement 15 states.
   - The size check, then the writes: `input.json`, `stage-request-ref.json`,
     `resolved-profile-ref.json`, and the decision-record texts. Then
     `run_root` is removed, so the output directory holds only those
     documents.

   The copied text is the largest single block in the file — about 90 lines of
   predicate plus its header, the four name bindings and the subshell wrapper,
   and 18 more for the clean entry, so roughly 130 lines that were not written
   here and are not to be edited here.
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
- Strengthening or relaxing the source-purity predicates requirement 15
  copies, or the clean entry requirement 17 copies. They are copied, not
  authored here, and they are taken as they stand rather than improved on. If
  one of them is wrong it is wrong in `materialize.sh` and is fixed there, and
  the copies then move with it.
- Mirroring the materializer's tree-content scan (`scan_tree`,
  `materialize.sh:386-452`) or the object-closure walk it rides on. Symlinks,
  submodules, invalid path names and closure size caps stay the
  materializer's checks; requirement 15 states that boundary, and a source
  that trips one of them comes back `materialization.refused` from the
  driver.

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
  pinned commit `4965175d0edeeec8ba746609e585b053be03e075`, and — through
  requirement 16 — that the resolved profile's one config claim carries that
  same `producer-config.json` digest rather than merely naming the file.
  Without that, a
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
  coercion — and that refusal is not written here either. It is
  `materialize.sh:352-354`, inside requirement 15's copy, running against a
  `source_algorithm` bound from the caller's commit-id width.
- **The source guards are a copy, and part of that copy is shared with
  another initiative.** Requirement 15 puts about 90 lines of `materialize.sh`
  inside this component and requirement 17 puts 18 more, and the sibling spec
  puts most of the same text inside the driver: the 271-332 span, the 348-354
  prefix of this spec's third span, and the same clean entry. What lives here
  only is the `packed-refs` span, the 355-360 commit-object tail, and each
  component's own named deviations in the entry. Three things can drift
  instead of one: the
  materializer, the driver's copy, and this copy. That is the price of the
  alternative being worse — a
  paraphrase drifts silently, while a copy drifts loudly, because
  requirement 13's test compares the bytes against the materializer as it
  stands in the working tree and fails CI the moment they differ. It is the
  same
  keep-in-sync discipline the profile pins use, and the same one
  `loop/v1/review-fix-planner.jq:1-3` states. The residual risk is that the
  two copies land in different pull requests and someone edits one of them
  in place; whichever lands second should take the other's bytes for the
  shared lines rather than retaking the copy from the materializer, so there
  is one text with two homes and not two texts.
- **A fixed `PATH` was not enough, because Bash resolves functions first.**
  This is the one finding in this revision that changes what the component
  actually refuses rather than what it says. The copied predicates call
  `find`, `head`, `wc`, `tr`, `rm` and `grep`; most of those calls are
  absolute, but three `find` calls are bare (`materialize.sh:327`, `331`,
  `348`), and Bash looks for a shell function of that name before it consults
  `PATH` at all. A function crosses into a child bash through the environment
  (`export -f find`), so a caller with no ability to change `PATH` could still
  make the worktrees, promisor-pack and hook predicates answer "nothing
  found". Requirement 17 closes it by adopting the materializer's own entry —
  scrub every inherited function and exported name, then re-exec through
  `env -i` — and requirement 13 proves it in the direction that matters: an
  impure fixture is still refused with a planted `find` in the environment,
  and a good fixture still assembles identical bytes. The residual is the one
  the copy always has: if the materializer's entry is ever weakened, this
  entry is weakened with it, which is why the test compares them.
- **The copy header records provenance; the test proves currency.** These are
  two different jobs and an earlier revision conflated them, which is how it
  ended up asserting the copy against a commit CI cannot read (a
  default-depth checkout has no ancestors, so `git show <old commit>:<path>`
  fails). The header now answers only "where did this text come from", and
  the assertion compares against the producer in the working tree. The trade
  is honest but worth naming: the test can no longer tell a reviewer that the
  copy matches the specific reviewed commit — if someone changes
  `materialize.sh` and the copy in one pull request, byte equality still
  holds and the reviewer, not the test, is what catches a bad change to the
  original. That is the right division. The test's job is to stop the two
  from drifting apart silently, and comparing against the current producer
  does that strictly better than comparing against a frozen one, which would
  keep passing while the producer moved. The line numbers are the other half
  of it: each span is anchored to its own first line and bounded by its own
  length rather than trusted as a number, so a shift in `materialize.sh` is
  reported as a shift instead of quietly comparing the wrong lines.
- **Tree content is not checked here, and that is a deliberate residual.**
  The guarantee requirement 15 makes stops at the repository level. A source
  repository can pass every guard the assembler copies and still be refused
  by the materializer's tree scan — a symlink or submodule entry in the
  commit's tree, a path name `safe_repo_path` rejects, or a closure past the
  16 MiB / 65536-entry / 1024-tree caps (`materialize.sh:386-452`, used at
  `:456-465`) or the 256 MiB import bound (`:461-465`). When that happens the
  operator gets `materialization.refused` from the driver rather than a
  refusal from the assembler, so the wasted-run cost requirement 15 removes
  for repository-level impurity is not removed for these. The trade is
  deliberate: mirroring the tree scan means mirroring the object-closure walk
  it rides on, which is most of the materializer, and none of these
  conditions can make a run write anything — the patch is empty and the
  network is denied, so the worst outcome is a refused run that names its own
  reason. If the wasted runs ever become a real cost, the fix is not a second
  copy of the scan here but a cheap pre-flight in the materializer itself,
  which both components already call the same way. This narrows the intent's
  own words — "bad inputs are refused with a clear reason rather than
  producing something the driver rejects" — to what this component can
  honestly promise: bad *repositories* are refused here with a clear reason;
  bad *tree content* is refused by the materializer, and the driver's
  `materialization.refused` is that clear reason, one step later.
- **Requirement 16 binds the config claim, not every claim.** The resolved
  profile makes a source claim for each binding's manifest, package, prompt,
  skills and tools as well as its config. Only the config claim can be tied
  to a pin, because `producer-config.json` is one of the eight documents
  requirement 3 pins; the manifest claims are already tied to the pinned
  manifests through `manifest_source.value_sha256 ==
  binding.manifest_ref.sha256`, but the package, prompt and skill claims name
  bytes that live elsewhere in the repository — adapter normalizers,
  `routines/coder.md`, `reviewer/codex-review.md` — which this spec does not
  pin and should not, because pinning them would make this component a second
  copy of the whole repository's state. So a supplied resolved profile can
  still carry a wrong digest for the producer's prompt. That matters less
  than the config hole did: the materializer binding is the only one this
  input actually drives, and it has no config, no prompt, no skills and no
  tools (`materializer_relations_ok`). It is still a real limit, and it is
  another form of the limit the bullet above about the resolved profile
  already names — the resolved profile is trusted for what no pin covers,
  until the trusted parent exists.
- **Timestamp, and resolve-fresh-or-pinned.** The intent's first open question is
  decided: the timestamp is a caller-supplied argument, because a clock read
  would break determinism. Its third is answered by DR-1 — neither fresh nor
  pinned; the resolved profile is an input, and producing one in production is
  the trusted-parent initiative.
