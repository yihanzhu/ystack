# First external-target shadow run: evidence

Issue #426. This directory holds the first pair of real, genuine shadow runs
against an external repository's history — `yihanzhu/ystack-dummy-target`
(repository id `repo.ystack-dummy-target`), which shares nothing with
ystack — plus the durable verification for them. It is inactive, read-only
evidence: it registers, activates, or qualifies nothing, and it changes no
registry `proof_state`.

The operator confirmed the registered `env.local-macos-dummy-target` entry on
intake #426 with "确认，环境登记准确", then confirmed the two frozen
incident inputs with "确认，冻结输入采用" after the manager stated their
exact revisions, digests and `2026-09-27T18:59:20Z` observation time (both
confirmations: chat, session `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`,
`2026-09-28T19:09:49Z`; the observed values were posted on `#426` comment
`issuecomment-5858795268`, the confirmations on comment
`issuecomment-5876686554`). The delegated manager session then captured this
pair on Yihan Zhu's local macOS account (arm64), in session
`dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, under the #375 delegation rule
extended to this intake by DR-6 (both on #426). The outer capture ran from
`2026-09-28T19:10:16Z` through `2026-09-28T19:14:05Z`. That execution
provenance does not change the six-field operator identity retained in
`requester.json`.

## What this is, and is not

- It is a read-only replay of one already-committed file-digest condition —
  `src/greet.sh` differs between two real revisions of the external dummy
  target repository — using the shipped, unmodified shadow reproduction
  slice, exercised for the first time against a repository that is not
  ystack itself.
- It is **not** sandbox-enforced, qualified, or proposable. The retained
  sandbox evaluation for each case is declaration-only
  (`enforcement_proof: "declaration-only"`, `authority_effect: "none"`,
  `qualification_effect: "none"`); a `satisfied` verdict there records only
  that the claim matched the declared policy, never that anything was
  enforced. Real sandboxed execution remains a separate, step-8 prerequisite
  — see `work/real-sandbox-boundary/spec.md`. The retained policy and claim
  bytes keep the shipped verifier tool digest of 64 ones
  (`1111111111111111111111111111111111111111111111111111111111111111`);
  that is the **shipped demonstration value**, never a real tool identity
  (`work/real-sandbox-boundary/spec.md` requirement 5), and every other
  digest this evidence carries is recomputed from real committed bytes.
- The environment registry entry `env.local-macos-dummy-target`
  (`shadow/v1/shadow-environments.json`) stays `proof_state: unproven`. This
  task does not change that.
- No shipped component was changed, patched, or special-cased for this
  target. See "Portability result" below.

## Precondition: dependencies

- Frozen runtime (`RUN_COMMIT`): `2ced5b37d1c0b405f281d980761f619c584d353e`
  (PR 1's merge commit, registering `env.local-macos-dummy-target` and
  carrying this slug's operator-merged plan).
- Plan blob: `82b5a8b5661fd1253e7bb0cb06b5b795bafc9c9c` (SHA-256
  `da56b6784c98a60e92f363192a72a6e4c80c8609c890ce3d149f18fcdf075d6d`). Spec
  blob: `f55ca9023b66b52fefed8571a2c8806656018578`. Intent blob:
  `7659bfdbf0175d5f6a0ab363038ac21f7b4e0568`.
- The #373 components (driver, resolver entry and trusted launcher,
  assembler, local-git materializer, declaration-only sandbox evaluator, and
  the scope and maintenance consumers) were unchanged since `a73bd8c` at
  `RUN_COMMIT`; checked before the boundary (precondition gate, step 2).
- Resolver entry SHA-256:
  `c3b7fd08e31bef3324b83062c2fb74e635aed89bd614555eda29e115d446fb14`.
  Assembler entry SHA-256:
  `808ae022f5c1a3f29986de36921b2f625d224a971ec6e93f2406e28f8524a5ff`; its jq
  program SHA-256:
  `6725bdb69527741c9af3be81b0d138e6d4a9cde3391d2b45488f75cdc711299c`. Driver
  entry SHA-256:
  `5255978be9703f3f00657b34d921ddc726dfcdd2dd2a7f34e5e611abb9e962a2`.
  Materializer entry SHA-256:
  `9b806bb5e202f98166aae60d391107c29aa0d19176765bf48fef47155f9fd358`.
- Frozen runtime index SHA-256 before and after the session:
  `0238705de30c38b0719aa62b8fac6eb63f85303dc150e03a1a37c1d26078df5b`. Its
  inode, size, modification time and mode also stayed
  `1295456386 53628 1790535384 644`.
- The reviewed capture used the accepted dependencies already present in the
  clean frozen runtime. Their required proof was green before execution.

## Precondition: pinned dependency provisioning (operator, before the run; not an evidence document)

- jq 1.6 asset and URL: `jq-osx-amd64`,
  `https://github.com/jqlang/jq/releases/download/jq-1.6/jq-osx-amd64`.
- Verified SHA-256:
  `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`.
- Shared cache path:
  `${TMPDIR:-/tmp}/ystack-portable-core-jq16/jq-osx-amd64`.
- The asset was already provisioned outside the evidence boundary and was
  reverified on `2026-09-27` before the session (`jq_precondition cache
  verified, no fetch performed`, `2026-09-27T18:56:24Z`); provisioning
  completed `2026-09-27T18:59:00Z`. This was the only network action in this
  initiative; nothing inside the boundary fetched. The retained record does
  not establish the asset's original download time.
- The precompiled closure helper SHA-256 was
  `7c4b91afd746b346451ec3829354753c6f91b78d4ced61fed625a56f409c4810`;
  its frozen source SHA-256 was
  `f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27`.

## The two input tuples

| | Post-change (`reproduced`) | Pre-change control (`no-change`) |
| --- | --- | --- |
| Revision | `e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e` | `413a2f02a46ababa987039be65089e95c1916765` |
| Checked path | `src/greet.sh` | `src/greet.sh` |
| Expected SHA-256 | `c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c` | `c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c` |
| Observed SHA-256 | `9a3eecedc5f314cbc921ac8768b7651c3324afa355d42c90686ee8efb803dd90` | `c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c` |
| Outcome / reason | `reproduced` / `check.failed-at-revision` | `no-change` / `check.passed-at-revision` |
| `observed_at` (frozen input timestamp, real UTC time the digest was checked) | `2026-09-27T18:59:20Z` | `2026-09-27T18:59:20Z` |

Both incidents share the same target repository (`repo.ystack-dummy-target`),
the same failing check kind (`file-digest`), and `deploy_authority: none`.
The pre-change run is a control observation, not a second reported incident.
The post revision's single parent is the pre revision; both share the root
tree `1c173494765089b1cce2dac6e061135e7fee5c77` and use SHA-1 object ids. The
pre blob (`bbea64b735dfc55fff76ce32c477cb0ccc5e21ef`) is 121 bytes; the post
blob (`2abe3e52f6c35685cc4e0adc9cd68695072bff8f`) is 330 bytes.

## Shared documents (produced once, referenced by both cases)

- `resolved-profile.json` — the resolver's output. Request/map digests,
  `0aa16836bd09ee01dd725a3e0dcbfb7b6b4ec91c8b326a9869f5a0697d145c98` /
  `cb307551337ee2f20d33940539154aa8de64b605ff5e51fa3cbc66721b3f7fda`; output
  digest `b1d9cca552f205d2b390eca3e7f5cea44696611d98f8991cdc3342aaf088a1b7`.
  The map names exactly two repositories, `repo.ystack` (the frozen runtime)
  and `repo.ystack-dummy-target` (the disposable bare copy), by repository
  id only — not their local roots. The request locators name the real
  default profile and six manifests in the frozen runtime. Its selection
  scope names this slug's operator-merged `plan.md` blob
  `82b5a8b5661fd1253e7bb0cb06b5b795bafc9c9c` at `RUN_COMMIT`, in
  `repo.ystack`. Its `repository_context_ref` names the dummy target's root
  tree `1c173494765089b1cce2dac6e061135e7fee5c77` at the post revision, in
  `repo.ystack-dummy-target`, with the frozen runtime's registry bytes
  (`37c9776205decf8aa37404ca1ddff941d13401f8b515a6e03e0e3f8e4102dd12`) as its
  decision record. The selected producer settings are Anthropic
  `claude.sonnet`, effort `high`, and `routines/coder.md`; these are
  recorded configuration and no model ran.
- `environment-claim.json` — the real claim for
  `env.local-macos-dummy-target`. Digest:
  `f939c319913ec1f71357a65d910c13fc875dbca888beea0e3c0c0be9cbfb2284`.
- `control-policy-set.json` — `control/v1/control-policy-set.json` copied
  byte for byte, the same shared control-plane document the self-host bundle
  carries. Digest:
  `3fff018a4a7cbd9d8c69339ce1cd20c7f940b7af8080b12afe36e57961757eb8`.
- `requester.json` — the DR-5 operator identity, naming implementation
  `ystack-operator-cli` at frozen runtime
  `2ced5b37d1c0b405f281d980761f619c584d353e`. Digest:
  `a7d930d5a2f7b84452489fc29a6b3fa857af717f5e0f39f4c2165c0e994a8f3f`.
- `core-package-closure.json` — the core v2 `core.contracts.v2` package
  closure descriptor at the pinned generation (id begins `g-c83c940a`),
  stored with no trailing newline. Digest:
  `eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963`
  (the same-bytes-plus-newline form hashes to the different
  `06dbd5ec60040dd0d913ca011fd296d7cce78d604bb887a3be0656698f535cf1`, which is
  how a re-serialized copy would be caught). This is the same generation and
  the same nine members the self-host bundle names; only the generation's
  short prefix is ever quoted here, never the full id.
- `duty-evaluation.json` — the duty evaluation over the prerequisite stage
  run. Digest: `5750caa80792f2285f724f75c4d89546f343fe19ef00bdebfe50d32e0da2f41c`.
  Verdict: `satisfied` / `duty.satisfied`.
- `prerequisite/*` — the six documents from the prerequisite stage run that
  break the claim -> request -> duty -> claim cycle (see
  `work/external-target-shadow-run/plan.md`, "Construction order"). The real
  prerequisite request time was `2026-09-28T19:11:09Z`. In construction
  order their digests are: `environment-declaration.json`
  `9f0994c066279571143a0e10bde65eb002f38ce5ca8d0751dead7cb1be09e818`,
  `input.json` `90f40ae1c893fc65fb1ab8eca2ed23e2d0ce7e1384b6ac90cc9eb66e824e9377`,
  `stage-request.json` `a1155fbc1e59b90d5338a3dbfb2c3447c76e0151b07c0c6ea35978d29b23d785`,
  `resolved-profile-document.json`
  `b1d9cca552f205d2b390eca3e7f5cea44696611d98f8991cdc3342aaf088a1b7`,
  `stage-result.json` `94e91bc4237050c5e31b142d38c50f355aee3250646bdd4a47162846eba19a55`,
  and `materialization-receipt.json`
  `b1755fa2f56f1ee7c766cb14241dec064641ac4623c7d8f84eece06c53a1707f`. The
  materializer response envelope was discarded after extraction; its stdout
  digest was
  `795691f6d2f96361bd536e8dfa48174537c388f1df680c6b1aacdd85714e9ba5`.
  `checksums.json` carries every full digest.

## Per-case documents

For each of `pre/` and `post/`: `incident.json`, `qualified-identity.json`,
`sandbox-evaluation.json`, `materialization-receipt.json`, the assembler's
seven outputs under `assembled/`, and the driver's four state outputs under
`state/`. `checksums.json` gives every exact digest. The main references are:

| | Post-change | Pre-change control |
| --- | --- | --- |
| Incident | `fcdd531b6f2e055455099adf37af497ceef1eec04b4518bc891c212abf8d9736` | `36414d896bf90020af267dd08499234025060e77b60f86701f7164e33721f532` |
| Qualified identity | `d8ca07cb90689cc533c494651dae48a05c48f12599937fc95f561aeb043b4a03` | `1b4561314a61d252ae554ede1252338ffa898da88526a0fe3663bb960578588f` |
| Shadow record | `13c880dad38adbb15883e3b979443dfe88db39f2ec323ce5f7d45dafd7f4a4c2` | `94bf350a0a76f854b699f7f8f92c2682cbb7b5ef7cbbd568c5ccd0a186693fbf` |
| Stage result | `b775fa0da9ee0cdaead4b170e853598a2fdda0c32c0ca2f24d2a42aa84ace730` | `392acb0212a3e74f6b7a38e21ce96c160e7fee06ac630b4764fb70c5449e6db2` |
| Materialization receipt | `6bd6a572f27a45b078fd99db7eb921aa056d09dc97ad4bbe6b46304c3d128d05` | `a64d26285d4c2a727a880045a23632d5079196806201a29b14e1ab019478ef56` |
| Sandbox evaluation | `977229cf118add86fe2fb22244be0d45eeec6a4b0f54b67a3adfb082b66b46f7` | same bytes |

Both stage results are completed `no-change` materializations with empty
outputs. The different shadow outcomes above concern the historical digest
check, not a changed materialization.

## Source integrity

- `show-ref` digest before the first run / after the last run:
  `2d63aea208a301eb02f4f411f2ae8e0ae4e454d8a49a81953f23ff9b9dd2ad9e` /
  the same digest.
- `cat-file --batch-all-objects --batch-check` digest before / after:
  `8f8d1ac8b42c0ca6f7fd344d3a86287f57205a7c780d93ff987f7200ef446fea` /
  the same digest.
- Frozen runtime index SHA-256 before and after: see "Precondition:
  dependencies" above; unchanged across the session.
- The operator's own local clone of `yihanzhu/ystack-dummy-target` was never
  scrubbed or written; only the disposable bare copy made from it was used
  and scrubbed.

## Repeatability

Each fixed tuple was run twice, in fresh disposable directories, under the
same pinned tools, source, and environment. Both recursive assembler-output
diffs and both state-output diffs were empty. The repeated state hashes equal
the four retained state hashes for their case, and the repeated identities,
sandbox evaluations and receipts are byte-identical too. The before/after
source inventory digests were also equal on both readings. This proves
repeatability for these inputs and this environment, not portability to
another OS or future dependency versions.

## Unsuccessful attempts (if any)

There was no refused or inconclusive attempt in the accepted capture session
(0 entries under `attempts/`).

## Capture limits

The capture retained all 43 planned producer and input files. It deliberately
discarded the prerequisite materializer response envelope after extracting
and checking its exact stage result and receipt; its stdout digest is
recorded above. This follows the reviewed capture procedure and is not
replaced with reconstructed bytes.

The capture used no network beyond the one-time pinned jq provisioning
(outside the boundary), no credentials, no model, no installation, no
activation, and no write to the external target. The successful
declaration-only sandbox evaluations do not prove operating-system
enforcement.

## Portability result

No component generalisation was needed: every #373 component (the incident
validator, the driver's registry lookup, the assembler, the materializer's
source repository argument, the qualified-identity shape, the scope gates
and the maintenance consumer) took `repo.ystack-dummy-target` from its input
and compared it, with no ystack special case. Target-facing fields — the
registry entry, both incidents, the prerequisite and per-case stage
requests, both resolved-profile documents' `repository_context_ref`, the
materialization receipts, the qualified identities, and the shadow
records — all name `repo.ystack-dummy-target`. Control-plane fields keep
naming `repo.ystack`, because they point at the ystack default profile, its
six manifests, the producer prompt, and this slug's plan: the resolved
profile's `profile_source` and `selection_ref`, every binding's
`package_ref`/`config_ref`/`prompt_ref` and their sources, and the qualified
identities' `prompt_refs` (inherited from the producer binding). Enumerating
every `repository_id` and `target_repository_id` path in the 45 files gives
114 pairs: 68 naming `repo.ystack` and 46 naming `repo.ystack-dummy-target`,
matching the two lists `work/external-target-shadow-run/spec.md`
requirement 15 names exactly.

## Requester provenance

Executor: the manager session (Claude Code, model Claude Fable 5.1), session
`dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, on the operator's Mac (macOS, arm64),
macOS account `yihanzhu`. Delegation basis: the #375 rule
(`work/shadow-self-host-run/plan.md`, "Operator steps") extended to this
intake by DR-6, both recorded on #426. `requester.json` stays the operator
identity (`principal.operator.yihanzhu`); this provenance section, not
`requester.json`, is where the executing session is named.

## Confirmations (verbatim)

- (a) The registry entry, after PR 1 merged and before source preparation:
  "确认，环境登记准确" — chat, session
  `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, `2026-09-28T19:09:49Z`; the
  observed registry values were posted on #426 comment
  `issuecomment-5858795268`.
- (b) The frozen incident inputs, with the `observed_at` time, before
  assembly: "确认，冻结输入采用" — chat, session
  `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, `2026-09-28T19:09:49Z`. Both
  confirmations are also recorded on #426 comment
  `issuecomment-5876686554`.

## Registry

The frozen runtime's registry digest is
`37c9776205decf8aa37404ca1ddff941d13401f8b515a6e03e0e3f8e4102dd12`; the new
entry's own `jq -S -c` bytes hash to
`2cad2eb4ed2381bcfa528fb3bf9d7314650cb5e5411b7f08f02825c1254c141a`. The
self-host bundle keeps the older registry digest `721e19bb…`, recoverable as
the Git object at its own frozen runtime commit, which its own README names;
a later registry edit does not change either bundle's pinned bytes.

## Replay recipe

See `work/external-target-shadow-run/plan.md` in full for the exact commands.
In outline, with caller-supplied scratch paths (`$SRC`, `$CANDIDATE`,
`$SCRATCH`, `$STATE`, and so on — never a path from this run):

1. Provision the pinned jq 1.6 and compile the closure helper (once, outside
   the no-network boundary).
2. Clone a disposable, scrubbed bare copy of the operator's local
   `yihanzhu/ystack-dummy-target` checkout into `$SRC`, under an isolated
   Git configuration; record the before source integrity comparison.
3. Resolve the real default profile through
   `resolver/v1/resolve-profile.sh`, with `repository_context_ref` naming
   the dummy target's root tree in `repo.ystack-dummy-target`.
4. Construct the prerequisite stage run, the control policy set copy, the
   core package closure, the duty evaluation, and the environment claim, in
   that fixed acyclic order.
5. For each case: assemble the materialization input with
   `shadow/v1/assemble-materialization-input.sh`, validate the incident, run
   `shadow/v1/reproduce.sh`, then capture that case's materialization
   receipt and sandbox evaluation through the materializer's and
   evaluator's own public interfaces, with the driver's exact inputs.
6. Repeat each case's assembly and run once more, in fresh directories, and
   compare for byte-identical results.
7. Record the after source integrity comparison; it must equal the before
   one.
8. Copy the retained files into this directory, unchanged, and build
   `checksums.json`.

## Verification

See `verification-instructions.md` in this directory for the minimal,
tool-free procedure to check the one file-digest condition by hand, and
`scripts/test/shadow-self-host-evidence.test.sh` for the complete offline
proof over the committed bytes (no external-target reproduction, no
credentials, no model call).
