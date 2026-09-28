---
spec-blob: e8403c6f7361e85510f827aec512a398ad90060c
intent-blob: 260a66350c0fad4d8d9bda4c68811e95b9783c5d
risk: high
drafted: 2026-09-28
---
# Plan: enforcement-evidence-binding

Tracks #436. Risk: high, as the accepted spec records; gate mode `artifact-high`.
The spec is the contract: where a step names a requirement, its wording is the
detail to follow. Citations are to origin/main at `7c8c6e9`.

Four PRs, in order, from one branch `ystack/impl/enforcement-evidence-binding`.
PRs 1-3 use `Tracks #436`; PR 4 alone uses `Closes #436`. Each opens only after the
previous one merged and the branch took fetched main by an exact merge (no reset,
rebase or force). No shipped entry point exists until PR 3 adds the driver (R7.1),
and the shipped accepted set is empty from PR 2 on (R5.3), so a partly built
program is never a usable check.

## The program interface (fixed in PR 1, used unchanged by PRs 2-3)

`enforcement/v1/sandbox-receipt.jq` runs as
`jq -n -S -c -f sandbox-receipt.jq` with exactly these inputs:

- `--slurpfile receipt`, `expectation`, `evaluation` (the three caller inputs);
- `--slurpfile policy`, `decision`, `policy_set`, `registry`, `accepted` (the five
  fixed files of R7.1, in that order);
- `--slurpfile entry_digests`: an array, in registry order, of
  `{environment_id, sha256}`, where `sha256` is the SHA-256 of that registry entry as
  `jq -S -c` text with its newline (jq 1.6 has no hash builtin, so the caller hashes);
- `--arg receipt_sha`, `expectation_sha`, `evaluation_sha`, `policy_sha`,
  `decision_sha`, `policy_set_sha`, `accepted_set_sha`: SHA-256 of each file's bytes.

The output is one `sandbox_receipt_check` document: `schema_version: 1`,
`kind: "sandbox_receipt_check"`, `id: ("receipt-check." + $receipt_sha)` (the
receipt's own `id` may be malformed, so it is not reused), and the R7.3 body. A
fixed-file shape or relation failure (policy, decision, policy set, registry,
accepted set, or `entry_digests` not matching the registry one-to-one) is a jq
`error`, which the driver maps to `E_RELATION`. The program uses only helpers in
the style of `control/v1/sandbox.jq:1-17` and no `import`/`include` directive
(`scripts/test/portable-core-schema.test.sh:827-837` allowlists module users).

Reason precedence (R7.4): `receipt.declaration-only` when the receipt's `kind` is
`sandbox_policy_evaluation`; else `receipt.kind-unsupported` when `kind` is not
`sandbox_enforcement_receipt`, `schema_version` is not `1`, or `body` is an object
whose `contract_version` is not `"v1"`; else `receipt.malformed` when receipt or
expectation fails R3/R4 shape. Otherwise every applicable non-exclusive reason is
collected, sorted and made unique. `receipt.placeholder-identity` scans every
`*_sha256` field and observed `sha256` in both receipt and expectation.
`timing` values are checked by pattern only
(`\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z\z`)
and ordered by string comparison; no date library is used, so both pinned
platforms agree.

## Files that change

Only these paths change, across all four PRs (R10.1). Nothing else, including every
existing test script.

| Path | PR | Mode |
| --- | --- | --- |
| `enforcement/v1/sandbox-receipt.jq` | 1 (created), 2 (extended) | 100644 |
| `scripts/test/sandbox-receipt.test.sh` | 1 (created), 2, 3 (extended) | 100755 |
| `enforcement/v1/accepted-identities.json` | 2 | 100644 |
| `enforcement/v1/check-sandbox-receipt.sh` | 3 | 100755 |
| `ci/required-files.txt` | 1, 2, 3 | |
| `docs/components.md` | 4 | |
| `RESTORE.md` | 4 | |

The plan changes only in this plan-only PR; intent, spec and plan stay
byte-identical in every implementation PR.

Existing pins the new files must not trip (checked while drafting):
`scripts/test/portable-core-schema.test.sh:899-955` allowlists every tracked file
holding a generation id, so no new file may hold one (tests read
`control/v1/control-policy-set.json` at run time, never copy it);
`scripts/test/run-all.sh:66-69` and `scripts/test/run-all-sharding.check.sh` find
suites by name; the CI structure check (`.github/workflows/ci.yml:18-46`) needs
listed `scripts/*.sh` executable; `scripts/test/construction-publisher-gate.test.sh:360`
copies the live manifest and only removes named lines; ShellCheck 0.11.0 lints every
`*.sh` (`AGENTS.md:152-158`). None needs an edit.

### The manifest block (final form)

After the `# Sandbox boundary decision records` block (`ci/required-files.txt:219-222`),
before `# Inactive credential policy and evaluator`, one blank line each side:

```text
# Inactive sandbox receipt check
enforcement/v1/accepted-identities.json
enforcement/v1/sandbox-receipt.jq
enforcement/v1/check-sandbox-receipt.sh
scripts/test/sandbox-receipt.test.sh
work/enforcement-evidence-binding/intent.md
work/enforcement-evidence-binding/spec.md
work/enforcement-evidence-binding/plan.md
```

PR 1 adds the header, the `.jq`, the test and the three `work/` lines. PR 2 adds
`accepted-identities.json` and PR 3 adds `check-sandbox-receipt.sh`, each at its
place above. Every path appears once.

## Order of work

1. This plan merges; record the accepted plan blob and the merged main OID as
   `plan-base`. If main moves before PR 1's first commit, follow `work/README.md`
   (fresh non-author `Plan-verdict:` plus operator reaffirmation on #436).
2. PR 1 from `plan-base`, then PRs 2, 3 and 4, each after merging fetched main.
   Each needs independent review, green CI and operator merge, and is one commit.

Before every PR, recheck the intent, spec and plan blobs against main; a mismatch
stops work (`stale`).

## PR 1: receipt shape, kind separation and outcome

Discharges R1.1, R1.2 (receipt, expectation and check kinds), R1.3, R3, R4.1, R5.4,
R7.3, the five R7.4 reasons `declaration-only`, `kind-unsupported`, `malformed`,
`placeholder-identity` and `outcome-inconsistent`, and R8.

**`enforcement/v1/sandbox-receipt.jq`** (created): the full interface above; shape
predicates for the receipt (R3.1-R3.12, including the R3.7 row rules and the R3.8
teardown and lifecycle rules) and the expectation (R4.1); the precedence rules above;
the R8 failure set, `failed`, `violated` and `satisfied` derivation with the exact
reason ids; `receipt.outcome-inconsistent` when the recorded `outcome` differs; and
the R7.3 output with `origin_check: "not-performed"`, `activation_state:
"inactive"`, `authority_effect: "none"`, `qualification_effect: "none"`, and
`enforcement_verdict: "none"` when refused. The five fixed documents and
`entry_digests` are accepted but not yet read.

**`scripts/test/sandbox-receipt.test.sh`** (created), header as
`scripts/test/control-sandbox-policy.test.sh:1-18` and pinned jq as
`scripts/test/shadow-slice.test.sh:24-51`:

- `syn <label>`: the SHA-256 of the label text, a synthetic non-placeholder digest.
- Inline `jq -n -S -c` fixture builders (one trailing newline): a
  `sandbox_policy_evaluation` with `verdict: "satisfied"` whose `policy_ref`,
  `decision_ref` and `policy_set` digests are the real fixed files' digests; an
  expectation; and three receipts (`satisfied`, `violated` on `cpu_time_ms`,
  `failed` with `failure.teardown`). They name `env.local-macos-fixture`, its
  `target_repository_id` and its entry digest computed from the live registry; the
  real policy, decision, policy-set and evaluator digests (the evaluator refs read
  from `control/v1/sandbox-decision.json`); the R6 bounds from
  `control/v1/sandbox-policy.json` and a test scratch bound; and a test-only
  accepted set (id `sandbox.accepted-identities.v1`, one entry listing every
  fixture identity and mechanism). Every fixture is bound correctly from the start,
  so PR 2's checks leave the controls `valid` without edits.
- `mutate <file> <name> <jq-filter>` and `recompute`, which re-hashes the
  evaluation and rewrites `sandbox_evaluation_sha256` in receipt and expectation.
- `run_program`: pinned jq with the interface above, computing every digest and
  `entry_digests` itself; `expect <out> <check_verdict> <enforcement_verdict>
  <reasons-json>` compares the output body exactly.

Cases: the three positive controls; the evaluation passed as the receipt
(`declaration-only` alone); `kind-unsupported` alone for another kind, for
`schema_version: 2` and for `contract_version: "v2"`; `malformed` alone for a
missing receipt body key and for a broken expectation; each of the five
consistency rules (`observed` null with `complete`, `observed` at or above `bound`
with `reached: false`, `not-started` with `admitted` and `completed`, `refused`
without `not-started`, `confirmed` teardown with `storage_destroyed: false`) broken
alone giving `malformed` alone; `placeholder-identity` alone for an all-ones
identity slot and for an all-zeros `payload.stdout_sha256`; each of the six
`failure.*` rules set alone on the satisfied control with a correctly derived
outcome, giving `valid`, `failed` and that reason; a recorded outcome that
disagrees with the fields (`outcome-inconsistent` alone); and two runs byte-identical.
Final line `sandbox receipt: N focused checks passed`.

**`ci/required-files.txt`**: the PR 1 lines of the block above.

## PR 2: fixed-file bindings, accepted identities and accounting

Discharges R1.2 (accepted set), R4.2, R5.1-R5.3, R5.5, R6, the nine remaining R7.4
reasons, and R8's row-driven cases.

**`enforcement/v1/accepted-identities.json`** (created), one canonical line:

```json
{"body":{"activation_state":"inactive","environments":[],"set_version":"v1"},"id":"sandbox.accepted-identities.v1","kind":"sandbox_accepted_identity_set","schema_version":1}
```

**`enforcement/v1/sandbox-receipt.jq`** (extended): shape checks of the five fixed
documents and `entry_digests` (failure is `error`); and the reasons
`origin-mismatch`, `replayed`, `subject-mismatch`, `control-mismatch` (receipt vs
expectation, `policy_sha`, `decision_sha`, `policy_set_sha`, the decision's
`evaluator.driver_ref.sha256` and `program_ref.sha256`, and `evaluation_sha`),
`evaluation-not-satisfied` (kind, `schema_version: 1`, `verdict: "satisfied"`, and
`policy_set.sha256`, `policy_ref.sha256`, `decision_ref.sha256` equal to the
receipt's), `environment-unlisted`, `stale`, `identity-unaccepted` (observed
non-placeholder identities and every `mechanism_id`) and `limit-mismatch` (first
five bounds from the fixed policy's `limits`, the scratch bound from the accepted
entry only when one exists, observers from the R6 table). The program never reads
`proof_state` (R5.5).

**Test** (extended), all through `run_program`:

- each of the nine reasons alone, mutating one field of a positive control:
  receipt `origin.store_id`; receipt `attempt_number`; receipt
  `subject.incident_sha256`; `control.evaluator_driver_sha256` in receipt and
  expectation; the evaluation's `verdict` to `violated` with `recompute`; a
  different `target_repository_id` in receipt and expectation; receipt
  `origin.accepted_set_sha256`; one observed identity digest; one row's `observer`
  and, separately, the memory `bound`;
- the companion case: the evaluation verdict changed without `recompute` gives
  exactly `receipt.control-mismatch` and `receipt.evaluation-not-satisfied`;
- replay: the satisfied control against a second expectation differing only in
  `launch_request_sha256`, then only in `attempt_id`, each `replayed` alone;
- integrity: a byte-identical copy of the satisfied control gives the same output,
  still `origin_check: "not-performed"`;
- the row matrix: for each of the six R6 rows, `partial` and `unavailable` give
  `failed` with `failure.observation-unavailable`; `none` and `unknown` give
  `failed` with `failure.enforcement-unavailable`; `reached` gives `violated` with
  that row's `limit.*` reason. Each case records the correctly derived outcome, and
  none is `satisfied`.

All PR 1 cases keep passing unchanged against the extended program.

**`ci/required-files.txt`**: the `accepted-identities.json` line.

## PR 3: the driver

Discharges R7.1, R7.2 and the driver-side cases of R10.2.

**`enforcement/v1/check-sandbox-receipt.sh`** (created), following
`control/v1/evaluate-sandbox.sh` step for step:

1. Usage `check <receipt> <expectation> <sandbox-evaluation>` (`:17` pattern,
   `E_USAGE`). Resolve its own physical path (`:19-25`); the repository root is two
   directories up; the five fixed paths come from R7.1 under that root.
2. `physical_regular` on itself, the program, the five fixed files and the three
   inputs (`:32-45`). Pinned jq by platform digest and snapshot (`:46-57`,
   `:75-89`). Private `mktemp` scratch with cleanup traps (`:59-66`).
3. Snapshot every file at the 1,048,576-byte bound (`:68-74`) and run
   `canonical_json` on all eight documents (`:91-117`).
4. Hash every snapshot. Build `entry_digests`: for each index of
   `.body.environments`, write `jq -S -c '.body.environments[i]'` to scratch, hash
   it, and assemble the array with jq.
5. Run the program with the interface above (`:189-197` pattern), bound output size
   (`:198-200`), then postflight: the driver, program, fixed files, inputs and jq
   snapshot unchanged (`:202-217`), else `E_RELATION`. Print the output.

Error codes are `E_USAGE`, `E_RUNTIME`, `E_LIMIT`, `E_PARSE`, `E_CANONICAL` and
`E_RELATION`, one on stderr with nothing on stdout. It invokes only the pinned jq
snapshot and R7.2's allowlist by absolute path; no `/usr/bin/env`, nested bash,
network, credential or model call.

**Test** (extended):

- `run_driver`: the driver with `PATH` of the pinned jq's directory plus
  `/usr/bin:/bin`. Temporary repository copy: `enforcement/v1/{sandbox-receipt.jq,
  check-sandbox-receipt.sh}`, the three control files and the registry copied, and
  the test-only set as `enforcement/v1/accepted-identities.json`. Each positive
  control and each single-reason fixture gives output byte-identical to
  `run_program`, and the positive controls are `valid` end to end.
- Shipped driver against the shipped files: each positive control, each
  `failure.*` fixture and each row-matrix fixture is refused with exactly
  `receipt.environment-unlisted`, `receipt.identity-unaccepted` and
  `receipt.stale`; each exclusive-reason fixture still gets its reason alone.
- Error paths, each with no stdout and the one code: wrong argument count
  (`E_USAGE`), non-canonical (`E_CANONICAL`), BOM and two JSON roots (`E_PARSE`),
  oversize and depth 33 (`E_LIMIT`), a symlinked input (`E_RUNTIME`), and an input
  changed during evaluation (`E_RELATION`). For the last, as
  `scripts/test/control-sandbox-policy.test.sh:418-468`: a race copy whose program
  first spins on a bounded `range`, run with `TMPDIR` set to a watched directory;
  once `output.json` appears in the driver's scratch (all snapshots are taken by
  then), the receipt is replaced; the run is bounded by a 10-second `perl` alarm.
- A byte-identical receipt copy, and two repeat runs, give identical output.

**`ci/required-files.txt`**: the driver line.

## PR 4: docs and restore

Discharges R1.4, R2 and R7.5 as reader-facing text, and closes #436.

**`docs/components.md`**: a new section after the last paragraph of
`## Inactive sandbox-policy evaluator` (`docs/components.md:296-315`) and before
`## Inactive credential-policy evaluator`, adjusting wrapping only:

> ## Inactive sandbox receipt check
>
> `enforcement/v1/check-sandbox-receipt.sh` checks one sandbox enforcement receipt
> against the consumer's expectation for that attempt and the declaration-only
> sandbox evaluation that admitted the launch. It reads the sandbox policy,
> decision and policy set, the environment registry and
> `enforcement/v1/accepted-identities.json` from the repository, never from
> arguments. It returns `valid` or `refused` with a closed list of reasons and, for
> a valid receipt, an enforcement verdict of `satisfied`, `violated` or `failed`,
> as the [accepted receipt contract](../work/enforcement-evidence-binding/spec.md)
> defines.
>
> The check proves shape, binding to one attempt, the accepted identities and
> internal consistency. It never proves origin, and its output always says
> `origin_check: "not-performed"`: a receipt is authentic only when the consumer
> reads it itself from the host supervisor's store, which does not exist yet. The
> shipped accepted identity set is empty, so no receipt can be `valid` today. The
> check is inactive, grants no authority or qualification, changes no gate, and
> runs no candidate, supervisor or network action. Declaration-only sandbox
> evaluations keep their meaning.

**`RESTORE.md`**: one paragraph and command after the sandbox decision paragraph
(`RESTORE.md:683-689`) and before the credential-policy paragraph:

> Restore the seven paths in the manifest's inactive sandbox receipt check block,
> then run:
>
> ```sh
> bash scripts/test/sandbox-receipt.test.sh
> ```
>
> This checks kind separation, receipt and expectation shape, placeholder digests,
> attempt, subject and control binding, the accepted identity set, accounting
> rows, outcome derivation, driver input limits and postflight mutation detection.
> The check is inactive and never authenticates origin. Restoring it installs no
> supervisor or receipt store, selects no runtime or credential, and makes no
> receipt count as enforcement.

Describe PR 4 as completing an inactive contract and check. Do not claim a real
receipt, supervisor, store, qualification, enforcement or step 8 progress beyond
child concern 2.

## What does not change

Every R9.2 path stays byte-identical (the scope proof below lists them), as does
every existing test script. No `README.md` row: R10.1 closes the file list. No
runtime, VM, supervisor, store or account, native probe, credential, network, model
call, activation or write (R9.1); nothing enables before step 7 (#426) closes (R9.3).

## Reserved for the operator (excluded here)

Every plan, PR and merge gate above. R2.5's question (the supervisor host account
and host administrator as origin trust root, or a signing credential first) is asked
inside concern 4's reserved installation decision, not here. Any entry in
`accepted-identities.json` is concern 4's, with native qualification. Any change to
a constitution path, `config/**`, the demonstration policy, the ceiling or the
listed scripts is excluded.

## Dependencies and follow-up intakes

No dependency (R11.1): only merged files on main are used, never the unmerged
plans of concern 3 (#437) or durable telemetry. Concern 3 consumes R3; concerns 4
(supervisor, store, first accepted entry), 5 (R2.3 origin section, shadow wiring)
and 6 (scope gates, `scope.sandbox-receipt-missing`) consume R2, R5 and R7. Each
keeps its own intake and gates; none is implemented here.

## Review size

Every implementation PR: `review_size: standard`. Estimated net lines:

| PR | Estimate | Main content |
| --- | ---: | --- |
| 1 | 350-400 | program core 200-230, test scaffolding and cases 150-170 |
| 2 | 260-330 | program bindings 80-110, accepted set 1, tests 170-220 |
| 3 | 330-400 | driver 200-230, tests 130-170 |
| 4 | 35-50 | two docs paragraphs, one restore paragraph |

Evidence: `control/v1/evaluate-sandbox.sh` is 220 lines, `control/v1/sandbox.jq`
276 and `scripts/test/control-sandbox-policy.test.sh` 476. A PR that would pass 400
lines stops and returns to this plan gate; it is never split ad hoc or given an
unrecorded exception.

## Risks

- **Overclaiming origin.** Text or output that reads as if `valid` or a matching
  digest proves a real sandbox or supervisor (R2.2). Output and docs always say
  `origin_check: "not-performed"`, and the shipped set makes `valid` impossible.
- **Precedence bugs.** A missed exclusive guard lets later checks read malformed
  input. Every exclusive case is tested alone, again through the driver in PR 3.
- **Weak fixtures.** Fixtures carry real fixed-file digests from PR 1 and mutations
  recompute bound digests (R10.2), so no reason passes because a check is skipped.
- **Staged program.** PRs 1-2 ship a program with no entry point; no text may
  present it as usable before PR 3.
- **Race flakiness.** The mutation test is timed by the `output.json` marker and a
  bounded spin, and the alarm fails closed.

## Proof

For every PR record BASE (the full main OID it is based on, its merge base with
main) and the head. Identity checks, before edits and on the final commit:

```sh
for f in intent spec plan; do git rev-parse "HEAD:work/enforcement-evidence-binding/$f.md"; done
git show HEAD:work/enforcement-evidence-binding/spec.md | sed -n '1,5p'
git show HEAD:work/enforcement-evidence-binding/plan.md | sed -n '1,6p'
```

Require both blobs above, the accepted plan blob, `risk: high` and both hash links.
Scope and modes:

```sh
git diff --name-only BASE HEAD
git diff --check BASE HEAD
git diff --quiet BASE HEAD -- control/v1 config shadow/v1 scope/v1 preparation/v1 \
  evals/v1 adapters ROADMAP.md AGENTS.md REVIEW.md NORTH_STAR.md .github \
  scripts/merge-pr.sh scripts/codex-review.sh scripts/test/run-all.sh scripts/lib work
git diff --name-only BASE HEAD -- scripts/test | grep -vx scripts/test/sandbox-receipt.test.sh
git ls-files -s enforcement/v1 scripts/test/sandbox-receipt.test.sh
```

Only that PR's paths from the table differ; `--check` and the `grep` print nothing,
the `--quiet` diff exits 0 and modes match the table. Guards:

```sh
grep -c 'proof_state' enforcement/v1/sandbox-receipt.jq
grep -cE '^[[:space:]]*(import|include)[[:space:]]' enforcement/v1/sandbox-receipt.jq
tail -n +2 enforcement/v1/check-sandbox-receipt.sh | grep -oE '/(usr/)?bin/[a-z]+' | sort -u
```

Both counts are `0`; from PR 3 the list is a subset of R7.2's allowlist. Required
files (the CI structure step):

```sh
grep -v -e '^$' -e '^#' ci/required-files.txt | while IFS= read -r f; do
  [ -f "$f" ] || echo "missing required file: $f"
done
```

It prints nothing, and `grep -Fxc <path> ci/required-files.txt` is `1` for each
added path. Lint, gates and tests, none of them edited:

```sh
shellcheck -x -S style scripts/test/sandbox-receipt.test.sh
shellcheck -x -S style enforcement/v1/check-sandbox-receipt.sh   # from PR 3
bash scripts/check-rename.sh
bash scripts/test/sandbox-receipt.test.sh
bash scripts/test/control-sandbox-policy.test.sh
bash scripts/test/shadow-slice.test.sh
bash scripts/test/shadow-assembler.test.sh
bash scripts/test/shadow-self-host-evidence.test.sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/candidate-content-preparation.test.sh
bash scripts/test/portable-core-schema.test.sh
```

ShellCheck must be 0.11.0. Record the command, head, platform and full output.
PR 4 also resolves the new link
(`(cd docs && test -f ../work/enforcement-evidence-binding/spec.md)`) and reads both
changed sections whole.

On each exact final head and base, require every CI job (checks, test shards, `ci`
aggregate); never rerun a failed suite until it passes. A separate read-only
reviewer applies Bugs, Security and Compliance passes to the full diff, the hash
links and this evidence; every Important finding is resolved before operator merge.
