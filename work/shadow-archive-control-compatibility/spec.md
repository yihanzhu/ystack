---
intent-blob: a6119e33fe63408eb6842e63f1291311a8b53316
risk: high
drafted: 2026-10-25
---
# Spec: historical shadow archive control compatibility

Tracks #727. Separate these two offline results within the existing evidence
suite. Neither result grants runtime authority or qualification.

| Result | Control source | Required meaning |
| --- | --- | --- |
| Historical authenticity | Fixed original data below | The archive resolves to its recorded source bytes and passes every original archive check. |
| Current control compatibility | Actual current repository files | Every control reference matches current bytes. Any mismatch refuses current compatibility, even when historical authenticity passes. |

## Requirements

1. Preserve all 45 leaves of each archive under
   `shadow/evidence/self-host-transition/v1/` and
   `shadow/evidence/external-dummy-target/v1/`, including READMEs, digests,
   declaration-only markers and demonstration identities, byte for byte and mode
   for mode. Do not recapture, normalize or update their checksums.
2. Resolve historical control references against independently verified original
   Git objects. An archive's own digest is not independent source proof. Keep
   inventory, reference closure, positives, negatives and restoration complete.
   Missing evidence fails; it is never a skip.
3. Keep current mismatch as a separate hard refusal. Historical success cannot
   substitute old files into current evaluation or change a failed current result.
   Current control consistency alone also gives no qualification.
4. Change no production policy, decision, reader, evaluator or gate. Invoke the
   current shipped sandbox evaluator on the three retained inputs and require its
   exact retained output bytes. Keep current scope and maintenance refusal checks.
   Never execute historical source code.
5. The two fixed test bindings below are exhaustive. Archive content, environment
   variables and command arguments cannot select another source, path or commit.
   Add no downloader, Git-read protocol, generic archive reader or public selector.

## Design

### Original source and fixed inventory

Use one shared, non-executable fixture set. Both commits in `yihanzhu/ystack`
contain the same 12 original files.

| Archive directory | Original runtime commit | Original tree |
| --- | --- | --- |
| `shadow/evidence/self-host-transition/v1/` | `8b3e3f55037de84c441cfe4ca5231c98814a7bbd` | `71dda3114cac146c465e5de3b62fa8d792d6b0e9` |
| `shadow/evidence/external-dummy-target/v1/` | `2ced5b37d1c0b405f281d980761f619c584d353e` | `cecf4c487a3bc93dde08fc655930a12e7be48018` |

Each filename has source path `control/v1/<filename>` in both trees. Its only
fixture destination is `scripts/test/fixtures/shadow-archive-control/v1/<filename>`.
Copy raw bytes, including line endings. All source and fixture Git modes are
`100644`. These files total 18,115 bytes. Do not reserialize their JSON.

| Filename | Git blob | SHA-256 | Bytes |
| --- | --- | --- | ---: |
| `credential-policy.json` | `5ef82544d1e5f6a3271a3bc69e99fddafa48a3ac` | `2ba0ec54d11ab4e9d02993e9283c5f820c662a20cf33d2bff25b1393a5ee403d` | 1444 |
| `credential-policy-decision.json` | `b4affcd1b821660097fad90845569f600ff8a1f0` | `73877276c868eae2da9dcedf8eb465b0526ce26a66506691b9cedbba15f00615` | 1583 |
| `duty-separation-policy.json` | `6bd404d333286155e7be89ab1b61cffeab4a3284` | `b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9` | 2104 |
| `duty-separation-decision.json` | `59fedc2053153d69e91f8c63f8e53a5224295791` | `4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99` | 1409 |
| `evidence-integrity-policy.json` | `2a80dd1c2c703c443f5d01d2b15190bbdf052012` | `8e630c4aaee1cf1d97b3c04e96da6bb8408a0a46a2ce42bca2583767ee42f604` | 914 |
| `evidence-integrity-decision.json` | `bc39f5998a6b9fdb20292ce9c597c8e53cf90d20` | `03e9225face347f1a4990beb6812f0e839d777cfbc6b95997d8031c4ad85e879` | 1859 |
| `kill-switch-policy.json` | `7fa389c5170d117e706bf562bc737e6e107cd349` | `b46eebfeb9de37eb0ebdb8fb297e0e200b537d0ca08dcf28eab7f91ef603e799` | 503 |
| `kill-switch-decision.json` | `005bd5b1d10ec06d73258600db773082f215510d` | `f0e88e03633c28d4916fa3480c4a4d27bc815da05891dc3efd8bc9c08b544941` | 1604 |
| `risk-gates-policy.json` | `b8b0086215f10bbe267caeb82fbd46afc45976f2` | `3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e` | 1844 |
| `risk-gates-decision.json` | `0860ae875d09388bf3adb4a8db947f77a076cca9` | `8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5` | 1563 |
| `sandbox-policy.json` | `0c244e00c3220eb52e876c0e8caea445a4b70551` | `4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e` | 1829 |
| `sandbox-decision.json` | `f53d8b02dc815f03225e2aafab1c85415a0ef381` | `c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd` | 1459 |

Add exactly one adjacent `provenance.json`. Use readable UTF-8 JSON with a final
LF. Its closed root keys are `schema_version`, `kind`, `source_repository`,
`runtime_bindings` and `files`. The fixed scalar values are `1`,
`shadow_archive_control_provenance` and `yihanzhu/ystack` respectively.
`runtime_bindings` contains exactly the two rows above, ordered by archive path,
with keys `archive_path`, `commit` and `tree`. `files` contains exactly the 12
rows above, ordered by source path, with keys `source_path`, `fixture_path`,
`git_mode`, `git_blob`, `sha256` and `size_bytes`. Paths use the exact prefixes
above; `git_mode` is the string `100644`. Duplicate/unknown fields, duplicate rows
and extra entries fail.

Implementation preparation and independent source review read only these existing
local Git objects. Verify each commit's tree, each path/mode/blob entry, and each
blob's complete bytes, length and SHA-256 against this specification and both
archived policy sets. Compare fixtures byte for byte with both original objects.
Retain that evidence in the source review record. Missing local objects stop
preparation; this work grants no fetch.

Pin the independently reviewed provenance file's raw SHA-256 as a literal in the
existing test. Never derive the expected pin from the file under test. Before
either archive check, verify that pin, the closed schema/inventory and each
fixture's complete length and digest. Require regular, non-symlink, non-executable
files. Reject extra leaves, symlinks, special files and directories outside the
fixed layout. Git review verifies `100644`; ordinary tests reject executable bits.
The fixed reviewed pin prevents a fixture plus rewritten manifest from becoming
trusted. CI reads the tracked data without Git history or network access.

### Two checks in the existing test

Keep one private control-reference comparison in
`scripts/test/shadow-self-host-evidence.test.sh`. It checks exactly six section
IDs and all policy/decision references against complete bytes from its fixed
caller. Reject missing, extra or duplicate sections, wrong references and
placeholder digests. This is test-local, not a runtime admission API. Only its
fixed historical/current callers and bounded private mutation copies supply data.

The historical caller uses the validated fixture set for the 12 policy-set
references and the two duty policy/decision references. All other references
retain their original inputs or current immutable members. Preserve duty verdict,
claim/stage references, exact sandbox recomputation, registry, core closure,
requester and repository-ID checks. The current sandbox evaluator still reads its
own current policy and decision; never redirect it to the fixture directory. If
later source changes prevent exact recomputation, fail and return through the
artifact gates. This data set never authorizes copying or running an old evaluator.

The current caller checks current `control/v1/control-policy-set.json` against
the actual 12 current `control/v1/` files and requires consistency. It also checks
each archive's control references against those actual files and reports that
result separately. Require match when the bytes still match and refusal for every
changed referenced byte. Derive the expected result independently from actual
current-file hashes and the fixed original vector, not the comparison's return
value. Expected refusal is a successful negative test, never a current-compatible
archive. Do not skip this caller on historical success. Keep all original current
scope/maintenance calls and unavailable, not-proposable and no-authority assertions.
No historical data path is offered to those consumers.

In private temporary copies, mutate each current control file with its policy set
unchanged. Require refusal, restore, and require the current positive again. Also
change a policy or decision reference in otherwise valid JSON and require refusal.
While that current mismatch exists, unchanged archives and fixed original controls
must still pass historical validation. A valid current tuple must not rescue a
damaged historical fixture. On an integration tree containing a real control
change, prove refusal against that tree's actual bytes too. Do not copy a later
production decision into this fixed fixture set to simulate integration.

### Allowed paths and restoration

G2 changes only `work/shadow-archive-control-compatibility/spec.md`. The separate
high-risk plan stage changes only the corresponding `plan.md`. Implementation
may change only these 16 paths:

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

Add all 13 fixture/provenance files to the restore manifest. Keep every existing
entry. RESTORE documents the fixed provenance, the historical/current distinction
and the existing offline suite. Add no separate test command or helper. A restored
checkout must run the whole suite with exact tracked data and without historical
commits, credentials, downloads or historical execution.

Implementation PR review_size: accepted-exception, 350–700 gross changed lines.
This covers 12 unchanged single-line JSON files, readable provenance for 12 files
and two runtimes, both checks with full negatives, and restore entries/docs.
Do not compress original bytes or tests to meet this range.

## Acceptance proof

- Independently compare both original trees, all 12 fixture bytes and provenance.
  Prove unchanged archive path/mode/blob inventories, 45 leaves each. Recompute
  original checksums without rewriting any archive file.
- Run both historical positives and every original negative. Keep changed bytes,
  missing leaves, each-leaf mutation followed by successful restoration, bad
  checksums, noncanonical JSON, changed outcomes, swapped records, incorrect target
  identities, extra/nested repository IDs, null IDs, removed array entries, empty
  arrays and missing parents. Keep fresh positives before each mutation and all
  original scope and maintenance conversion cases.
- Reach current positive and mismatch cases independently, including each file's
  mutation and restoration. Use the same control comparison for both callers.
  A renamed check or unconditional success cannot satisfy this requirement.
- Reject missing/modified fixture files, extra paths, symlinks, executable files,
  and provenance with a wrong commit, tree, blob, path, digest, size, duplicate or
  extra row. Include fixture-plus-manifest tampering and crossed archive/runtime
  bindings. Prove rejection at the fixed manifest pin and at the closed schema,
  inventory and data checks themselves, using bounded private function inputs for
  the latter. Never modify the checked-in pin. Restore each private case and prove
  the positive again. Tracked inputs remain untouched.
- Run the complete existing evidence suite on the exact implementation head.
  Require independent source review, automatic required CI and the Roadmap's
  applicable full matrix. Keep raw failures/skips and exact head/base bindings.
  Quick green is not full proof. Dependent integration needs its own fresh review
  and complete required suite; it cannot borrow this head's pass or erase failure.

## Out of scope

No production source, policy, decision, registry, runtime reader, native boundary,
qualification gate, workflow, historical archive or other #701 fixture changes.
No stale-guard or shadow-write repair. No reset of #681, #701 or core review-round
limits. No real collection, historical execution, native/SDK probe, credentials,
network, install, activation, target action, deployment or new authority.
Historical data remains declaration-only, unqualified and inactive. Existing
genuine/native, final integration, I1 and G3 obligations remain separate.

## Areas of concern

Risk is high because this changes how security-related historical references are
trusted by tests. Fixture substitution could hide current drift. Closed original
source inventory, independent byte review, separate current refusal and unchanged
runtime callers are mandatory. This settles the intent's source, path, restore,
proof and risk questions. G2 is not implementation authorization. A separately
accepted high-risk plan must land before code.
