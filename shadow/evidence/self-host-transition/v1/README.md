# First self-host shadow run: evidence

Issue #264. This directory holds the repository's first pair of real,
genuine self-host shadow runs against ystack's own history, plus the
durable verification for them. It is inactive, read-only evidence: it
registers, activates, or qualifies nothing, and it changes no registry
`proof_state`.

**Status of this document: skeleton.** The focused test, this layout, and the
consumers' wiring are complete. The approved requester recipe is fixed below;
the current `requester.json` is still a placeholder. The operator or delegated
manager replaces it and fills the value slots below once the two runs described
in `work/shadow-self-host-run/plan.md` ("Operator steps") have produced the
remaining evidence documents, in the same commit that adds those documents.
Until then, `scripts/test/shadow-self-host-evidence.test.sh` fails with an
explicit "evidence not yet captured" message rather than silently passing.

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

## Precondition: dependencies (TBD by operator/reviewer at merge time)

- `resolver-trusted-parent` implementation commit: `TBD`
- `shadow-input-assembler` (including the requester-argument amendment)
  commit already on `main`: `TBD`
- Both dependencies' own required proof green at those commits: `TBD`

## Precondition: pinned dependency provisioning (operator, before the run; not an evidence document)

- jq 1.6 asset name and URL: `TBD`
- Verified SHA-256: `TBD`
- Cache path: `TBD`
- Date provisioned: `TBD`

## The two input tuples

| | Post-transition (`reproduced`) | Pre-transition control (`no-change`) |
| --- | --- | --- |
| Revision | `0427390224c25147650f1bd3b6e43ed6911b97a7` | `d3f6d525328838b9c2de819699e53d8909ab7a3f` |
| Checked path | `config/construction-mode.json` | `config/construction-mode.json` |
| Expected SHA-256 | `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` | `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` |
| Observed SHA-256 | `5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda` | `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` |
| Outcome / reason | `reproduced` / `check.failed-at-revision` | `no-change` / `check.passed-at-revision` |
| `observed_at` (frozen input timestamp, real UTC time the digest was checked) | `TBD` | `TBD` |

Both incidents share the same repository (`repo.ystack`), the same failing
check kind (`file-digest`), and `deploy_authority: none`. The pre-transition
run is a control observation, not a second reported outage.

## Shared documents (produced once, referenced by both cases)

- `resolved-profile.json` — the resolver's output. Request/map digests,
  resolver source revisions, runtime and helper identities: `TBD`.
- `environment-claim.json` — the real claim for `env.local-macos-ystack-self`.
  Digest: `TBD`.
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
  run. Digest: `TBD`. Verdict: `TBD` (must be `satisfied` /
  `duty.satisfied`).
- `prerequisite/*` — the six documents from the prerequisite stage run that
  break the claim → request → duty → claim cycle (see
  `work/shadow-self-host-run/plan.md`, "Construct the duty evaluation and the
  claim"). Digests: `TBD`.

## Per-case documents

For each of `pre/` and `post/`: `incident.json`, `qualified-identity.json`,
`sandbox-evaluation.json`, `materialization-receipt.json`, the assembler's
seven outputs under `assembled/`, and the driver's four state outputs under
`state/`. Digests and identities: `TBD`.

## Source integrity

- `show-ref` digest before the first run / after the last run: `TBD` / `TBD`
  (must be equal).
- `cat-file --batch-all-objects --batch-check` digest before / after: `TBD` /
  `TBD` (must be equal).

## Repeatability

Each fixed tuple was run twice, in fresh disposable directories, under the
same pinned tools, source, and environment. `diff -r` over both assembler
output directories and `shasum -a 256` over both state directories: `TBD`
(must show byte-identical results). This proves repeatability for these
inputs and this environment, not portability to another OS or future
dependency versions.

## Unsuccessful attempts (if any)

`TBD` — list any refused or inconclusive attempt used only for diagnosis.
None is ever relabelled as the accepted pair.

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
