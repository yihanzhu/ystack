---
intent-blob: 4a7f1573eb5c47947e2dc360d39f12e12847b7c6
risk: high
drafted: 2026-10-24
allowed-paths:
  - work/fixed-evidence-publication/spec.md
---
# Spec: implement fixed evidence publication

Tracks #701. G1 is PR #702. This G2 permits planning, not code.
A separately accepted high-risk plan must land before implementation.

## Requirements

| ID | Required outcome |
| --- | --- |
| R1 | Implement the complete fixed publisher concern, preserving the accepted contract and both real caller routes. |
| R2 | The first source checkpoint is a complete private core-v3 package for all five document kinds, with every rule owner, ingress, root, finite proof and restore entries. |
| R3 | Preserve all v1/v2 generations, their meaning, the selected wrapper, default profiles and live configuration. |
| R4 | Prepare shared offline admission and the real shadow route only after exact source reconciliation and an accepted scope/plan amendment. |
| R5 | Stop before runtime code depends on undefined transport, identity, credential, durable dispatch or authenticated readback bindings. |
| R6 | Partial source stays on the same implementation attempt. No incomplete implementation PR, G3 or issue closure substitutes for complete final acceptance. |

The binding design is `work/fixed-publisher-write-contract/spec.md`, immutable blob
`68ff3f7e673752b624710bebf540822164239234`, with intent blob
`a6ea35b514ec9150aa3695a01c7d81ec5e9bd8ca`. Its sections 1–7 remain normative in full.
#173 remains design-only. This initiative adds its own implementation gates; it
changes none of that contract's operation, arguments, permission or result meaning.

## Design

### 1. One complete concern, bounded source phase

The first accepted plan covers only the complete private pure core-v3 package.
Its source and proof are useful output before transport facts exist. It contains
all five document kinds, unchanged operation behavior, and the fixed publisher
increment. A schema fixture or disconnected checker cannot satisfy this checkpoint.

Keep one preserved implementation branch. Here, unpublished means no implementation
PR; the same branch may be pushed for the explicit existing-CI proof below. No
checkpoint closes #701 or claims G3, runtime readiness, qualification or delivery.
Artifact and high-risk plan PRs keep their normal independent gates.

The second source checkpoint and final runtime integration require the later gates
in section 6. They are part of this concern's final outcome, but outside the first
source phase's write allowance. Preserve the attempt while those gates are pending.

### 2. Fixed generation and exact files

Use semantic identity `core.contracts.v3`, with envelope and document-reference
major 3. Preserve the five kinds, canonical bytes, limits, error order and all
unchanged operation IDs and meanings. Do not accept mixed versions or relabel input.

The comparison package is selected by `scripts/core-contract.sh` and equals
`core/v2/generation-registry.json` entry `[1].generation_id`. That registry's SHA-256
is `3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94`.
The accepted parent `portable-core-contracts/spec.md` R5 and dormant-role rule
require a new major for the publisher capability, permission and fields.

Propose this one unused generation for the high-risk plan to select:
`g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee`.
It is `g-` plus SHA-256 of the following exact UTF-8 text, without a final LF:

```text
fixed-evidence-publication|issue=701|intent-blob=4a7f1573eb5c47947e2dc360d39f12e12847b7c6|semantic=core.contracts.v3
```

This ID is a package identity, not authority. It is absent from the G1 merge base
`05f4d269add087b27aa94f141026eb2fe8005cdc`; that base has no `core/v3` subtree.
The plan rechecks every generation registry and subtree before selecting this ID.
Reuse, collision or a different ID returns through G2 before code.

In the following closed table, `G` means exactly
`core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee`.
Concatenation with the seven listed suffixes denotes seven exact paths, not a glob.
Only these thirteen paths may change in the first source phase:

| Exact path | Allowed purpose |
| --- | --- |
| `G/modules/schema.jq` | Closed registry and shared shapes |
| `G/modules/profile_graph.jq` | Manifest/profile/resolved-profile rules |
| `G/modules/stage_request.jq` | Request and resolved-binding rules |
| `G/modules/result_facts.jq` | Actual execution facts |
| `G/modules/result_truth.jq` | Result states, evidence and truth |
| `G/core-ingress.sh` | Fixed private ingress |
| `G/contracts.jq` | Fixed five-module composition |
| `core/v3/generation-registry.json` | One canonical append-only generation record |
| `scripts/test/portable-core-v3-publisher.test.sh` | Fixed private drivers and finite proof |
| `scripts/test/portable-core-v3-publisher-fixtures.jq` | Owned literal fixtures and mutations |
| `scripts/test/portable-core-v3-publisher-rules.tsv` | Closed rule/case/route inventory |
| `scripts/test/portable-core-schema.test.sh` | Exact new private paths and inactive-generation proof |
| `ci/required-files.txt` | Append exact new restore-critical entries |

Follow parent R16–R24's immutable-generation and assembly rules. The registry uses
its normal exact record shape: `generation_id`, `parent_spec_blob`, and
`parent_plan_merge_commit`. Its first array entry binds this generation, this G2's
accepted blob and the actual accepted high-risk plan merge commit. The plan freezes
the record template; the manager records that merge OID after the plan lands and
before the first code commit. A claimed or predicted merge OID is invalid. Later
entries must preserve the prior ordered prefix and unique, never-reused IDs.

The plan pins the current wrapper blob and every old generation export's mode,
type and blob. Those bytes remain unchanged. Add the seven new package members,
registry and three proof files to the restore manifest immediately. Preserve every
existing manifest entry. No public docs, wrapper, profile, config or installer
changes belong to this phase.

### 3. Rule ownership and complete implementation

Reuse the current five owners and dependency direction. Copying a complete old
package into a new immutable generation is the normal upgrade path; it does not
permit editing the old package or copying rules into competing owners.

| Owner | Required increment |
| --- | --- |
| `schema.jq` | Major/semantic identity 3; protected deterministic publisher; `core.publisher.publish-evidence.v3`, argument selector `publish-evidence`, change family, deterministic evidence; `core.perm.evidence-publication.create.v3` for `exact-evidence-publication` with create-branch/open-change-request actions; existing evidence-write and target-read permissions; shared publisher argument/result value shapes. |
| `profile_graph.jq` | V3 reference construction; exact publisher offer/request; deterministic-only binding with empty tools/skills and no model/prompt; preserve all protected identity and authority separation, source projections and graph checks. |
| `stage_request.jq` | Dispatch publisher argument shape once through schema; add its delivered publication-contract scope and input/request relations; require exact selected resolved publisher binding and permission set. |
| `result_facts.jq` | Consume the v3 registry/references while preserving actual binding, performer, environment, capability and metadata checks, unavailable facts and the nonpassing incident path. |
| `result_truth.jq` | Compose the new publication value shape; own publication self-relations, request/profile relations, attempt/state/status/outcome/evidence rules and resolved verifier projection. |
| `core-ingress.sh` | Bind only this literal generation, v3 physical paths and v3 semantic identity; retain canonical-byte, snapshot, digest, runtime, size, cleanup and accounting behavior. |
| `contracts.jq` | Route the same three forms through all five owners, preserving ordered limits/shape/ref/relation checks; own no publisher rule. |

The new shared value predicates live once in schema. Existing operation shape
dispatch remains in stage_request; result-body composition remains in result_truth.
Do not move or duplicate unrelated operation rules. All unchanged capabilities,
including forge materialization, remain usable in v3 with v3 document references.

The nine publisher arguments stay exactly: `incident_id`, `scope_id`, `branch`,
`candidate_input_id`, `body_input_id`, `shadow_input_id`, `title`, `write_set`, and
`publication_contract`. Implement every type and relation from the binding contract
section 3: the incident restrictions, derived branch/title, fixed workflow/task/stage,
present equal base/target revision, different candidate commit, root-tree source,
same repository/hash algorithm, distinct resolved data and instruction inputs,
media types, sorted unique write rows, mode/add-only/digest/path constraints, and
required grant/qualification reference shapes. Core checks declarations only.
Actual held bytes, 32/33-file inventories, Git diffs and grant authenticity belong
to the later shared admission/runtime boundaries.

`publication` is optional at stage-result shape level. When present, document mode
must check its exact union fields and all relations available within that document:
branch/PR ordering, post-write ordering, no-execution/no-dispatch consistency,
status/outcome restrictions, empty outputs and absent delta. Stage-run requires it
exactly for the publisher capability and forbids it for all others. It adds candidate
head equality, attempt number 1 and the separate protected verifier projection.

Implement every row of the binding contract's section 6. Completed changed requires
both effects created, matched post-write, complete actual metadata and passing
deterministic evidence. The allowed completed fact-gap case remains inconclusive
with reason and nonpassing evidence. Partial/unknown/mismatched effects never pass.
Failed/cancelled execution retains actual facts and nonpassing evidence. Preserve
the corrected v2 rule that any passing evidence requires matching actual execution;
an incident mismatch cannot use inconclusive status to retain passing evidence.
No declared verifier, proof digest or matched state authenticates an observation.

### 4. Private composition, guard and restoration

Use fixed private test drivers to invoke the real ingress sequence: open, begin,
snapshot every input, finish driver, validate and close. Exercise document,
profile-set and stage-run. The root receives every complete document self-check
before adding the route's cross-document relations. It imports exactly schema,
profile_graph, stage_request, result_facts and result_truth by their fixed names.
Keep one fixed module directory, physical non-symlink package paths, jq 1.6 and
sanitized errors. No arguments, input data, environment or current directory selects
code. No new public validator, adapter, runtime interface or generic loader is added.

The existing schema test's import guard must recognize only the exact new seven
member paths and the named private proof paths above. Its v3 generation guard has
a closed hit list: the new registry, new ingress, named proof files, restore manifest
and this initiative's normative artifact records as needed for identity binding.
Artifact records may state the ID but may not load code. Enumerate exact paths in
the plan and test; no `core/v3/**` or blanket work/test allowlist is allowed.
Root/owner imports retain the existing five-name grammar. Reject extra module files,
foreign generation paths, public/non-test callers, symlink escapes and any wrapper
selection of v3. Keep all existing v1/v2 hit lists and meanings unchanged. New
tracked files read current v2 identity from its registry/wrapper; they must not
repeat the old corrective-generation literal. Do not encode it to evade the guard.

The complete private root is the normal pre-switch assembly phase. The selected
public wrapper remains byte-identical. The later public assembly/consumer change
needs an accepted amendment, a separate exact pre-switch proof and independent
review, then the normal bounded switch and fresh post-switch proof. This phase
allows no switch. Published generation exports remain immutable. Restoration proof
for this checkpoint reconstructs the private package and unchanged selected package
from the manifest without installation or activation.

### 5. Finite source proof

Freeze the following rule groups as rows in the named rules file. Each row names
one owner predicate, literal positive/negative case IDs and every applicable route.
The high-risk plan expands the finite cases and commands before code; implementation
cannot shrink them to fit a size target. Expected verdicts never call product policy.
For inherited rules, retain existing owner IDs and frozen legacy ledgers rather
than inventing replacement coverage. New group IDs use the `publisher-v3.` prefix.

| New rule group | Minimum finite cases |
| --- | --- |
| `registry` | Exact new registry/capability/permission/role; unknown IDs, extra permissions, wrong execution kind, dormant offer and mixed-major rejection. |
| `value-shapes` | Every new argument/result field, required/extra fields, wrong type, each closed enum arm and malformed proof/reference. |
| `profile` | Exact manifest/profile/resolved graph; wrong offer/request, tools/model/prompt, package projection and shared protected identity/authority rejection. |
| `request` | Every section-3 relation above: missing/duplicate/wrong input, scope/media mismatch, bad incident/branch/title/path/write row, stale-looking unequal base/source, absent grant/qualification and wrong binding. |
| `publication-self` | Every branch/PR/post-write state combination that is permitted, plus each forbidden transition; no execution with claimed dispatch; invalid status/output/delta/outcome combinations. |
| `publication-cross` | Capability-specific presence, attempt count, wrong candidate head, wrong verifier projection, shared verifier/publisher identity, mismatched refs and times. |
| `outcome` | Each section-6 result row, all six terminal statuses, missing actual metadata, incident identity mismatch, nonpassing evidence, false changed/no-change and partial/unknown effects. |
| `routes` | All five kinds in document mode; complete profile-set; all existing operations plus publisher in stage-run; every owner-to-command cell and a forced failing rule on each applicable route. |
| `private-package` | Exact registry, seven exports and manifest; unchanged old bytes; fixed imports and generation; false HOME/cwd/search path, missing/nonregular/symlink members/ancestors, outside paths and public caller rejection. |

The private suite exercises the full byte-to-result pipeline, raw/canonical limits,
error precedence and silent success. Direct jq predicate tests alone do not pass.
Retain the full existing regression commands:

```text
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/portable-core-ingress.test.sh
bash scripts/test/portable-core-profile-graph.test.sh
bash scripts/test/portable-core-stage-request.test.sh
bash scripts/test/portable-core-result-facts.test.sh
bash scripts/test/portable-core-result-truth.test.sh
bash scripts/test/portable-core-assembly.test.sh
bash scripts/test/portable-core-accounted-validation.test.sh
bash scripts/test/portable-core-v2-fake-forge.test.sh
bash scripts/test/portable-core-v2-evidence-identity.test.sh
bash scripts/test/portable-core-v3-publisher.test.sh
```

Preserve all 34 review-finding and 279 legacy-assertion rows and their coverage.
Report separate counters for owned rules, direct cases, route cells, forced routes,
legacy rows, loader/guard cases and restoration. Bind the exact head, package blobs,
registry, wrapper and current shared test/manifest files; partial counts fail.

Use the existing accepted jq 1.6 runtime. If it is unavailable locally, stop local
execution without downloads, substitute tools or claimed passes. The plan may use
the existing workflow_dispatch on the same unfinished implementation branch for
source proof. Push only that preserved branch; no implementation PR or workflow edit
is needed. Existing six-shard `scripts/test/run-all.sh` discovery runs the named new
suite and old regressions. Record exact commit, run, all shards and full counters.
This CI use is a test checkpoint only, does not consume a #558 real-run window,
and grants no G3, delivery, runtime execution or first-write permission. Automatic
quick CI is not the full matrix. Relevant complete proof remains mandatory.

### 6. Deferred source and runtime gates

Before the second checkpoint, reconcile source
`22d25c96f28ed42da0a5722b6b5ea0e65946274c`, including
`shadow/v1/write-shadow.py` blob `fc596350cab560a138c2059e8096542aa75554b8`:
exact repository, branch/local and remote heads, PR state, revision/blob, old/current
base and clean/dirty worktree. Obtain explicit adoption scope and source preflight
through an accepted G2 amendment and separate high-risk plan or plan amendment.
Preserve all outstanding source proof. Do not alter, duplicate or copy that attempt
before those gates. Without them, stop at the complete private core checkpoint.

That amendment must bind the shared admission and actual shadow path, exact six-field
mapping, held body/title bytes, 32/33-file inventories, full Git diff/base/parent/root
checks, path-policy owners, withholding and post-write plan. It must name exact files
and finite integration proof. Do not manufacture a publisher stage/profile/grant for
shadow, copy schema or create a test-only second caller. This G2 permits none of those
future paths to be edited yet.

Child 11's transport actions/failures, real identity and narrow credential enforcement,
durable incident reservation/dispatch mechanism and independent authenticated readback
need primary facts under the proper separate access authorization. Accept their exact
design and plan before writing dependent runtime code. An empty adapter, arbitrary
callable or public transport framework cannot fill a missing binding.

Final #701 acceptance retains the binding contract section 7 in full: both actual
source caller routes through the same admission, real concrete publisher binding,
finite fake branch-then-PR success, foreign/replaced branch and existing-PR refusal,
partial effects, crash/cancellation/lost response, durable at-most-once dispatch,
no retry or renewed incident budget, separate authenticated read-only post-write
verification, normal package/consumer assembly, full integration and restoration.
Runtime qualification, credential/sandbox/identity enforcement and first real write
remain separate reserved gates. Fixtures establish no such real-world evidence.

## Out of scope

This G2 writes only its frontmatter path. No plan, code or tests are written here.
The first later source phase excludes admission/runtime paths, public assembly,
provider/API/SDK access, credential acquisition, new network scope, target execution,
install, activation, live selection, config/bootstrap, production and real writes.
No default/protected-branch push, merge, approval, labels or comments beyond the one
PR body become publisher operations. Publisher has no model or candidate execution.
Support, request, external grant and actual result remain separate.

Keep #558, #544, #681 and step-7 debts. CPU wall is `NONE`, native qualification
`BLOCKED`, production `EMPTY`, automation `PAUSED`. PR #183 remains frozen, #412
parked, and all old refs/worktrees/attempts preserved.

## Areas of concern

Risk is high: this implements a new security-sensitive contract major and its
validation boundaries. Independent G2 and a separately accepted high-risk plan
must precede source preparation. No author accepts their own artifact.

Sections 2–5 answer the intent's package/path/proof question. Section 6 carries the
source-adoption and runtime-fact questions forward with exact stop conditions.
The complete seven-member baseline is about 3,405 lines before new rules/tests.
The high-risk plan must justify one readable complete-package review allowance;
no 300-line target permits dropping owners or proof. Final runtime scope and its
cumulative implementation review range require the later accepted amendment.
