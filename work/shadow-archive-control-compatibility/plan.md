---
spec-blob: 9985b7e85c1f4735047621232e2abd6d0bc295bd
risk: high
drafted: 2026-10-25
---
# Plan: shadow archive control compatibility

Tracks #727. Implement the accepted spec's historical/current separation inside
the existing offline suite. The spec's source table is the exact data contract;
do not duplicate or expand it here.

## Files that change

This plan stage changes only `work/shadow-archive-control-compatibility/plan.md`.
Implementation changes only these 16 paths:

- `scripts/test/shadow-self-host-evidence.test.sh`
- `scripts/test/fixtures/shadow-archive-control/v1/credential-policy.json`
- `scripts/test/fixtures/shadow-archive-control/v1/credential-policy-decision.json`
- `scripts/test/fixtures/shadow-archive-control/v1/duty-separation-policy.json`
- `scripts/test/fixtures/shadow-archive-control/v1/duty-separation-decision.json`
- `scripts/test/fixtures/shadow-archive-control/v1/evidence-integrity-policy.json`
- `scripts/test/fixtures/shadow-archive-control/v1/evidence-integrity-decision.json`
- `scripts/test/fixtures/shadow-archive-control/v1/kill-switch-policy.json`
- `scripts/test/fixtures/shadow-archive-control/v1/kill-switch-decision.json`
- `scripts/test/fixtures/shadow-archive-control/v1/risk-gates-policy.json`
- `scripts/test/fixtures/shadow-archive-control/v1/risk-gates-decision.json`
- `scripts/test/fixtures/shadow-archive-control/v1/sandbox-policy.json`
- `scripts/test/fixtures/shadow-archive-control/v1/sandbox-decision.json`
- `scripts/test/fixtures/shadow-archive-control/v1/provenance.json`
- `ci/required-files.txt`
- `RESTORE.md`

Implementation PR review_size: accepted-exception, 350–700 gross changed lines.
Preserve the raw JSON, readable provenance and all tests within this one concern.

## Order of work

1. Land this plan through separate independent review, required CI and protected
   merge. Every non-merge plan commit changes only the plan path. The manager
   records actual plan-base, accepted intent/spec/plan blobs and the fresh claim
   before source work. A moved base needs the normal exact-base review; changed
   meaning returns through its artifact gate. Preserve all other attempts/rounds.
2. From the spec's two existing local commits, read the exact tree entries and
   12 blobs. Verify both trees, `100644` modes, byte equality, lengths and SHA-256s
   against the spec and archived policy sets. Copy those raw bytes to the fixed
   destinations. Missing objects stop preparation; do not fetch or execute them.
   Write the exact closed, sorted provenance object defined by the spec as readable
   JSON with final LF. Retain raw-object comparison evidence for independent review.
3. Add the private fixture checks below within the existing test. Use Bash 3.2,
   its existing `sha_file`, pinned jq and temporary root. Add no file helper or
   public arguments. Add mutation cases with the change, then route the historical
   references through the validated data. Keep both real `load_bundle` entries.
4. Add the separate current calls and independent expected results below. Run them
   for both bundles. Preserve every remaining `check_evidence`, `run_bundle_checks`,
   `fresh_mutant_copy`, `refresh_checksums`, scope and maintenance assertion.
5. Add the 13 restore entries without removing any existing entry. Update RESTORE
   with fixed data provenance and the two result meanings. Keep its existing suite
   command and qualification limits. Freeze source for independent review and the
   complete proof below; only the manager may publish through protected gates.

### Private fixture checks

Place the helpers near `sha_file`/`canonical_ok`; invoke them after jq setup.
Use one fixed fixture directory rooted at the repository, never an archive field.
Keep the expected provenance SHA as a literal in the test. It comes from the
reviewed original-object comparison, not a runtime hash of candidate data.

Use a small wrapper, `check_control_fixture`, which checks root/provenance file
shape, the fixed raw provenance pin, then calls `check_control_fixture_data`.
The latter checks exactly one JSON value, the closed typed schema and sorted rows,
exact runtime/source bindings, exactly 13 directory entries, and each regular,
non-symlink, non-executable file's length and complete SHA-256. No extra directory
or special file is allowed. Compare semantic provenance values against the fixed
trusted provenance already authenticated by the literal pin, not a mutable test
argument's own claims. Check the selected row against `b_rel` and `b_run_commit`.
Read no old executable or history during a suite run.

The wrapper must pass before historical validation for either bundle. Keep the
trusted expected object separate from mutation copies. Tests may directly call
the lower helper on private copies to reach its checks. This is not a bypass flag
or a second production entry point. Lower-level tests never replace the pin or
change which data a normal historical call trusts.

| Layer | Private cases and proof |
| --- | --- |
| Raw pin | Wrong commit/tree/blob/path/digest/size, duplicate/unknown fields or rows, extra row, crossed runtime bindings, and a fixture plus rewritten manifest all fail the wrapper. Duplicate JSON keys and byte-only changes are rejected by this exact-byte pin; do not claim jq preserves duplicate keys. |
| Schema and fixed values | Directly call the lower helper with one otherwise valid copied manifest for each wrong field/binding, missing/extra field, type, ordering, duplicate/extra row or multiple JSON values. Keep its trusted expected object unchanged. Assert the schema/value failure, not a preceding pin failure. |
| Inventory and bytes | With the original valid manifest, remove or change each fixture in turn; add an extra file/directory, symlink, executable bit or special entry. Assert the inventory/type/size/hash failure. Use an existing ordinary temporary-file mechanism; do not add a system probe. |

Use the existing first-failure diagnostic style to identify these layers. Each
case starts with a positive copied baseline, changes one condition, asserts the
intended refusal, restores and proves a positive again. All copies live under
`$tmp` and the existing cleanup trap. Never mutate tracked fixtures or archives.

### Historical and current callers

Extract the existing six-section loop at `declaration-only-and-references` into
one private `control_references_match` helper. Keep the credential-policy filename
special case. Check the exact six section IDs with no missing/duplicate/extra ID,
all 12 references and placeholder refusal. Hash actual complete control files.
Caller arguments are fixed test paths or bounded mutation copies, not user input.

In `check_evidence`, call it on the retained policy set and fixed historical
controls. Change only the two duty policy/decision source reads to that same fixed
set. Keep the duty's other references/verdict, claim/stage closure and all other
checks. The `sandbox-evaluation-inputs` call still invokes the current
`control/v1/evaluate-sandbox.sh` with the original three retained documents and
requires byte-identical output. No path override reaches that evaluator.

In `run_bundle_checks`, after the original historical positive, check current
`control/v1/control-policy-set.json` against current `control/v1/` and require a
positive. Separately call the same helper on each archive policy set against those
current files. Before that call, hash the actual current files and compare the
12-value vector with the trusted original vector. All equal means expected match;
any difference means expected refusal. Do not use helper status or an archive's
self-described digest to calculate that expectation. Record each result separately.
The current helper is test evidence only; no result grants qualification.

For each of the 12 current files, start a fresh private copy of current controls
and its current policy set, prove current consistency, change one referenced byte,
require refusal, restore and prove consistency. Add policy-ref and decision-ref
mutants in valid JSON and missing/duplicate/extra section cases. With a current
mismatch still present, explicitly prove the unchanged historical archive passes.
With damaged historical data, prove a valid current tuple does not rescue the
historical wrapper. No fallback or short circuit connects the two results.

At a real changed integration tree, run the same archive/current comparison on
actual current bytes. Do not insert a later decision into the old fixture set.
If future current evaluator changes prevent exact historical recomputation, keep
that failure and return through the artifact gates; do not run an old evaluator.

## Risks

The main risk is turning historical source data into current authority. Fixed
callers, an independently pinned provenance object, separate current expectations
and unchanged runtime consumers prevent that substitution. Keep current scope's
not-proposable/unavailable/no-authority checks and maintenance's no-live-seed and
cross-pair refusals intact. Historical results remain declaration-only.

A pin-only negative could hide a broken lower validator. The layered tests above
reach schema, inventory and byte checks separately without changing the pin.
A stale mutation could hide a different failure; fresh positives and restoration
remain mandatory. A generic loader or copied historical evaluator adds authority
and maintenance burden without solving this bounded data problem; do not add one.

## Proof

- Source review compares all 12 fixtures with both original objects, verifies the
  provenance and its literal pin, and checks the exact 16-path diff. Compare both
  archive path/mode/blob inventories with the implementation base: 45 leaves each,
  unchanged READMEs/checksums/classification. Preserve all original assertion families
  and the full two-bundle loop. No code-then-revert or archive rewriting is allowed.
- Run `git diff --check` and `bash -n scripts/test/shadow-self-host-evidence.test.sh`.
  Use ShellCheck 0.11.0 with `-x -S style` when that pinned tool is already available;
  otherwise retain the check as pending for existing CI. Static checks are not
  functional proof.
- Run `bash scripts/test/shadow-self-host-evidence.test.sh` in the existing ordinary
  CI environment. It must reach both historical positives, every old archive
  negative and restoration, every new layer/current case, and all original scope
  and maintenance cases. Keep complete stdout/stderr, exit status and exact head.
  The suite currently provisions pinned jq and compiles its existing closure helper.
  Do not invoke it locally if doing so would download/install missing dependencies
  or exceed the existing environment authorization. Do not alter that provisioning,
  add a new download path, or treat a missing local jq as a pass.
- Require automatic required CI and an exact-head dispatched full matrix through
  the existing workflow. Freeze `bash scripts/test/run-all.sh --list` output there;
  all six `--shard <index>/6` jobs must cover that inventory exactly once, with the
  existing checks and aggregate job. Preserve full raw receipts and real skips.
  A failure stops acceptance; do not retry automatically or replace the suite.
- Require fresh independent exact-head/base review before protected merge. Later
  dependent integration uses normal merges, fresh bindings/review and its own full
  proof, including actual current drift. Do not borrow a pass from another head.
  Preserve earlier P2/FAIL/UNKNOWN/NOTRUN evidence, review caps and final debts.

No production source, other #701 fixture, workflow, native boundary or permission
changes. No real capture, historical execution, new network/credential scope,
install, activation or target action. This work does not complete genuine/native,
I1, final integration or G3 obligations. Independent authorized work remains separate.
