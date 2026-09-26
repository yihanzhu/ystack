# First self-host shadow run: evidence

Issue #264. This directory holds the repository's first pair of real,
genuine self-host shadow runs against ystack's own history, plus the
durable verification for them. It is inactive, read-only evidence: it
registers, activates, or qualifies nothing, and it changes no registry
`proof_state`.

The operator confirmed the registered local environment on intake #264 with
“确认，环境登记准确” (comment `5766438552`), then confirmed the two historical
observations with “确认” after the manager stated their exact revisions,
digests and `2026-09-21T19:41:53Z` observation time (comment `5846767755`).
The delegated local Codex manager then captured this pair on Yihan Zhu's local
macOS account in session
`01a09ae7-9bd4-77f3-8c15-966143bebff4`. The outer capture ran from
`2026-09-26T14:20:13.131971Z` through `2026-09-26T14:23:50.167000Z` and
returned zero. That execution provenance does not change the six-field
operator identity retained in `requester.json`.

## What this is, and is not

- It is a read-only replay of one already-committed file-digest condition —
  `config/construction-mode.json` differs between two real revisions of this
  repository — using the shipped, unmodified shadow reproduction slice.
- It is **not** sandbox-enforced, qualified, or proposable. The retained
  sandbox evaluation for each case is declaration-only
  (`enforcement_proof: "declaration-only"`, `authority_effect: "none"`,
  `qualification_effect: "none"`); a `satisfied` verdict there records only
  that the claim matched the declared policy, never that anything was
  enforced. Real sandboxed execution remains a separate, step-8 prerequisite —
  see `work/real-sandbox-boundary/spec.md`. The retained policy and claim
  bytes keep the shipped verifier tool digest of 64 ones
  (`1111111111111111111111111111111111111111111111111111111111111111`);
  that is the **shipped demonstration value**, never a real tool identity
  (`work/real-sandbox-boundary/spec.md` requirement 5), and every other
  digest this evidence carries is recomputed from real committed bytes.
- The environment registry entry `env.local-macos-ystack-self`
  (`shadow/v1/shadow-environments.json`) stays `proof_state: unproven`. This
  task does not change that.

## Precondition: dependencies

- Frozen runtime: `8b3e3f55037de84c441cfe4ca5231c98814a7bbd`.
- `resolver-trusted-parent` implementation commit:
  `83d1efd0cf1aa1377ee95ceef0fa8ee338d56948`.
- `shadow-input-assembler` (including the requester-argument amendment)
  implementation commit: `84b6ba29c1e5257ce3839f279c4549df60979030`.
- The reviewed capture used the accepted dependencies already present in the
  clean frozen runtime. Their required proof was green before execution.
- Resolver entry SHA-256:
  `c3b7fd08e31bef3324b83062c2fb74e635aed89bd614555eda29e115d446fb14`.
  Trusted launcher SHA-256:
  `5e0ece1980484be37678d477b3abf683020664521cccaa3c58017238eb5072d2`.
- Assembler entry SHA-256:
  `82225709cd6841a322fd259135a991a40e6980c34b585116b2b00881c700ba4d`.
  Its jq program SHA-256:
  `3b1b29da5448d2bb7dabe513058c5d2f126b238660757498b88485c970924a3a`.

## Precondition: pinned dependency provisioning (operator, before the run; not an evidence document)

- jq 1.6 asset and URL: `jq-osx-amd64`,
  `https://github.com/jqlang/jq/releases/download/jq-1.6/jq-osx-amd64`.
- Verified SHA-256:
  `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`.
- Shared cache path:
  `${TMPDIR:-/tmp}/ystack-portable-core-jq16/jq-osx-amd64`.
- The asset was already provisioned outside the evidence boundary and was
  reverified on `2026-09-26` before the session. The retained record does not
  establish its original download time.
- The precompiled closure helper SHA-256 was
  `7c4b91afd746b346451ec3829354753c6f91b78d4ced61fed625a56f409c4810`;
  its frozen source SHA-256 was
  `f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27`.

## The two input tuples

| | Post-transition (`reproduced`) | Pre-transition control (`no-change`) |
| --- | --- | --- |
| Revision | `0427390224c25147650f1bd3b6e43ed6911b97a7` | `d3f6d525328838b9c2de819699e53d8909ab7a3f` |
| Checked path | `config/construction-mode.json` | `config/construction-mode.json` |
| Expected SHA-256 | `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` | `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` |
| Observed SHA-256 | `5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda` | `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` |
| Outcome / reason | `reproduced` / `check.failed-at-revision` | `no-change` / `check.passed-at-revision` |
| `observed_at` (frozen input timestamp, real UTC time the digest was checked) | `2026-09-21T19:41:53Z` | `2026-09-21T19:41:53Z` |

Both incidents share the same repository (`repo.ystack`), the same failing
check kind (`file-digest`), and `deploy_authority: none`. The pre-transition
run is a control observation, not a second reported outage.

## Shared documents (produced once, referenced by both cases)

- `resolved-profile.json` — the resolver's output. Request/map digests,
  `0728be374426f09039280e422ccd46a64beec6d6cfeb26650ecba85845658c7a` /
  `2eb42412323ece8f5dbe03f08ce1f92a79964d58f1fa45b45a6f51ba6b91b353`;
  output digest
  `dcb134c6da9c240572100323317e974ef345b8e37cf40d2eaf72418c2b5f5f96`.
  The request locators name the real default profile and six manifests in the
  frozen runtime. Its selection scope names the historical runtime plan blob
  `2f627aadcb22a68eec05d7a187f2fa08d82ce99b`; that is resolver provenance,
  not the governing amended plan blob
  `09fe9becce436873f70ce683a81567718e3ea04b`. The selected producer settings
  are Anthropic `claude.sonnet`, effort `high`, and `routines/coder.md`;
  these are recorded configuration and no model ran.
- `environment-claim.json` — the real claim for `env.local-macos-ystack-self`.
  Digest: `0503d8bc6e79454f62f040c2867628d3f50d7fceac83fb308398b6786805c025`.
- `control-policy-set.json` — `control/v1/control-policy-set.json` copied byte
  for byte. Digest: `3fff018a4a7cbd9d8c69339ce1cd20c7f940b7af8080b12afe36e57961757eb8`.
- `requester.json` — the DR-5 operator identity approved on intake #262,
  naming implementation `ystack-operator-cli` at frozen runtime
  `8b3e3f55037de84c441cfe4ca5231c98814a7bbd`. Digest:
  `26206e640e708c7e7b8c47b0c7d780dcbc9b8b9e5ffc05296f39d1108774c386`.
- `core-package-closure.json` — the core v2 `core.contracts.v2` package
  closure descriptor at the pre-transition revision's pinned generation
  (id begins `g-c83c940a`), stored with no trailing newline. Digest:
  `eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963`
  (the same-bytes-plus-newline form hashes to the different
  `06dbd5ec60040dd0d913ca011fd296d7cce78d604bb887a3be0656698f535cf1`, which is
  how a re-serialized copy would be caught).
- `duty-evaluation.json` — the duty evaluation over the prerequisite stage
  run. Digest: `b1a9e6d0c30fa8748a3501907bf1fd57e4db176c9c0db491e5f1aeaf6560cfa5`.
  Verdict: `satisfied` / `duty.satisfied`.
- `prerequisite/*` — the six documents from the prerequisite stage run that
  break the claim → request → duty → claim cycle (see
  `work/shadow-self-host-run/plan.md`, "Construct the duty evaluation and the
  claim"). The real prerequisite request time was
  `2026-09-26T14:20:36Z`. In construction order their digests are:
  `environment-declaration.json` `d292c381…`, `input.json` `c2375fff…`,
  `stage-request.json` `e223defa…`, `resolved-profile-document.json`
  `dcb134c6…`, `stage-result.json` `5a6cee8a…`, and
  `materialization-receipt.json` `a910e8e1…`. `checksums.json` carries every
  full digest.

## Per-case documents

For each of `pre/` and `post/`: `incident.json`, `qualified-identity.json`,
`sandbox-evaluation.json`, `materialization-receipt.json`, the assembler's
seven outputs under `assembled/`, and the driver's four state outputs under
`state/`. `checksums.json` gives every exact digest. The main references are:

| | Post-transition | Pre-transition control |
| --- | --- | --- |
| Incident | `e53c173076172b01b2210d4e13bd1f7815c80e68c810739746f5a2ad80b6fd93` | `1380eb494e330abd0ae02bac4c507549fd1b34ab33ce7f9bd4bcd3736a3537ed` |
| Qualified identity | `6c7281d48a6ae9b74e9476d7e6b785cc03289691ededabfa4f02eef73c33b89f` | `e4bea63378b779fd5f39a77c1cee297f0ab3873022b9b364655bcde26e293eb3` |
| Shadow record | `b68551db80bc5158325ebf050ef1ea2dc5f791d9944041bd8675f0148ce9f93a` | `95d0cdd280c0a65959723166e94c54182df8d634299452df00dc88f86bd3fcea` |
| Stage result | `4ee1b37a9cb72635242e6c05fc2195c788ce0ba2ffafe473f05b6c6b1b57b3ac` | `50b16d4930003bb34d22bbd84b3f0792456032ec15d7f19a04294a759a68c3d3` |
| Materialization receipt | `a47751c72693b86416534daff3e06adc725371d6673a2efef741e2130d74af68` | `a7bbdf3f3e409c746daa4cc80b8f300064ee9caec508775397a204f06e310884` |
| Sandbox evaluation | `02f76ee617b5545317c8f3cef545af775739c901067a60638b463c4645e6fda0` | same bytes |

Both stage results are completed `no-change` materializations with empty
outputs. The different shadow outcomes above concern the historical digest
check, not a changed materialization.

## Source integrity

- `show-ref` digest before the first run / after the last run:
  `1d26c07f627cda1caf5b8a765ebf5b68846784273adac1a7f4df5547f8df3379` /
  the same digest.
- `cat-file --batch-all-objects --batch-check` digest before / after:
  `dcc394f8ea6b6270b110d66ef408d6634c17cc7e032ca6b1b573d788935215d1` /
  the same digest.
- Frozen runtime index SHA-256 before and after:
  `e05d5c5f880f0fad0c7581f316d952d164e59e088bed5fe87ecd1968b44c83ac`.
  Its inode, size, modification time and mode also stayed
  `1291192813 43982 1790034825 644`.

## Repeatability

Each fixed tuple was run twice, in fresh disposable directories, under the
same pinned tools, source, and environment. Both recursive assembler-output
diffs and both state-output diffs were empty. The repeated state hashes equal
the four retained state hashes for their case, and the repeated identities,
sandbox evaluations and receipts are byte-identical too. This proves
repeatability for these inputs and this environment, not portability to
another OS or future dependency versions.

## Unsuccessful attempts (if any)

There was no refused or inconclusive attempt in the accepted capture session.
Earlier preparation attempts remain outside this bundle and none is
relabeled as either accepted case.

## Capture limits

The capture retained all 43 planned producer and input files. It deliberately
discarded the prerequisite materializer response envelope after extracting
and checking its exact stage result and receipt. The command event retains
the envelope stdout digest
`013394847e9640b6f52546d1d7d0e41bff7da354e9f6d191d7473cfec1b7b971`;
the retained receipt and stage-result reference chain verifies consistently,
but the deleted envelope cannot now be independently rehashed. This follows
the reviewed capture procedure and is not replaced with reconstructed bytes.

The capture used no network, credentials, model, installation, activation or
external target. The successful declaration-only sandbox evaluations do not
prove operating-system enforcement. All four driver calls used the same
confirmed historical timestamp; their command start and end times are the
separate `2026-09-26` capture times described above.

## Replay recipe

See `work/shadow-self-host-run/plan.md` in full for the exact commands. In
outline, with caller-supplied scratch paths (`$SRC`, `$CANDIDATE`, `$SCRATCH`,
`$STATE`, and so on — never a path from this run):

1. Provision the pinned jq 1.6 and compile the closure helper (once, outside
   the no-network boundary).
2. Clone a disposable, scrubbed bare copy of local ystack history into `$SRC`
   under an isolated Git configuration; record the before source
   integrity comparison.
3. Resolve the real default profile through `resolver/v1/resolve-profile.sh`.
4. Construct the prerequisite stage run, the control policy set copy, the
   core package closure, the duty evaluation, and the environment claim, in
   that fixed acyclic order.
5. For each case: assemble the materialization input with
   `shadow/v1/assemble-materialization-input.sh`, validate the incident, run
   `shadow/v1/reproduce.sh`, then capture that case's materialization receipt
   and sandbox evaluation through the materializer's and evaluator's own
   public interfaces, with the driver's exact inputs.
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
proof over the committed bytes (no self-host reproduction, no credentials,
no model call).
