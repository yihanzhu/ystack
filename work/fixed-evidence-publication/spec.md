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
| R4 | Implement the shared offline admission and real shadow caller specified in section 6 after exact dependency adoption and a separately accepted plan amendment. Preserve the future actual publisher caller as a final gate. |
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

### 6. Shared offline admission and the second source checkpoint

This section specifies the next bounded source checkpoint. It does not complete
R1. The actual shadow writer must use the shared admission. The actual publisher
caller and its six-field comparison remain final acceptance gates. No test caller,
helper import, preparation-only command or empty `publish.py` counts as that caller.

#### 6.1. Preserve and adopt the exact source dependency

Reconcile `yihanzhu/ystack` source
`22d25c96f28ed42da0a5722b6b5ea0e65946274c` on the preserved
`codex/impl/scope-gate-evidence-generation` attempt, including
`shadow/v1/write-shadow.py` blob `fc596350cab560a138c2059e8096542aa75554b8`.
Bind its exact local and remote heads or remote absence, PR state, old/current base,
clean/dirty worktree, whole inherited diff and required source proof. The comparison
main `c6c3f74181ea86f85be87ecf4431e67a5f272d82` has writer blob
`4790655f9378636cacf8f4ec7929c88abcfce9bc`. These are different source versions.
The preserved source is not an accepted foundation merely because it is locally
clean, has a source review, or passes pure tests.

The first private core-v3 checkpoint must finish its exact source review and required
full CI before checkpoint two starts. Preserve its actual source, fixture and registry
bytes. Section 6.6 permits one runner-only provenance correction for the later plan
amendment; every other first-checkpoint assertion and byte remains fixed. This amendment then needs independent G2 acceptance and a separate high-risk
plan amendment. That plan must record explicit dependency adoption and a read-only
source preflight. It must enumerate the complete inherited paths and cost separately
from the new paths below, bind the first checkpoint and the preserved dependency,
and state the exact ordinary merge sequence into the same #701 implementation branch.
Do not copy selected dependency files, reset, rebase, replace or discard either attempt.
The source preflight must cover conflicts and every inherited source change. If the
dependency changes, rebind and review its exact new source before adoption.

Early inactive source/tests may proceed after those source gates. Unfinished genuine,
native, integration and G3 proof remain due. Before final publication of #701's
implementation PR, #558/#541/#544/#681 must satisfy their original applicable proof
and protected foundation merges. Then merge current main normally, measure the
entire actual PR diff, and obtain fresh complete review and CI. Inherited code is not
already merged code. A source checkpoint never waives those final requirements.

#### 6.2. One shared owner, with shadow authentication left in place

Create the private module `publisher/v1/_admission.py`. It owns only the common
fixed-evidence byte, path and Git relations and the resulting publication plan.
It has no CLI, configuration, source selector, provider adapter, network action,
credential, reservation, subprocess callback or dispatch entry. It does not import
or activate core v3. Existing held Git inspection remains the only I/O it uses.

Use one `admit_write` function as the complete common admission boundary. Give it
closed private input fields for the actual incident, generated materialization input
and response bytes, frozen bundle bytes, candidate file bytes, outer file bytes,
write-section bytes, record form, scope ID, exact allowed paths, held policy/mode
bytes and the existing held source/candidate Git owners. The writer retains the original source
inventory captured before materialization as an immutable comparison input. The
future caller captures its own base inventory under its held owner and rechecks it;
a supplied inventory alone never proves Git facts. These
are evidence inputs, not caller-provided `checked` flags or authority. Do not accept
an arbitrary module, callable, Git runner, schema or policy predicate as an input.
The plan fixes these private field names and byte limits before code.

The module reuses the fixed `shadow/v1/_consumer.py` owners for canonical bytes,
`write_path_ok`, `evidence_patch`, `scope_policy_ref` and `_ReadOnlyGit`. Resolve that
one already loaded, fixed-origin consumer module; do not load a second consumer
instance or duplicate its schema and primitive predicates. The two Git owners use
the existing concrete owner and command ledger. Their repository identity, object
format, held paths, configuration exclusions and command allowlist remain unchanged.
The shared module does not gain a generic executor or a public extension interface.

Move the deterministic publisher-request/body construction and candidate Git relation
checks to private functions in that module. `admit_write` must invoke those same
owners. The writer may delegate its earlier candidate check and its `_publisher`
compatibility helper to them; it must not retain another common predicate. Keep
`_bundle_ref` construction in one owner as needed by common admission and its
existing reader-facing writer helper. A thin delegate supplies no separate decision.

| Boundary | Required owner and order |
| --- | --- |
| Original bundle and actual materialization | Writer keeps `_inventory`, `_authenticated_frozen`, `_materialize` and `_verify_write`, including same-anchor/principal/store checks, actual preparation, fresh receipt and evaluation. |
| Complete common admission | The real writer `_admit` calls shared `admit_write` on those retained inputs. The module recomputes all common relations in sections 6.3–6.5. Earlier candidate checks do not replace this final call. |
| Shadow-only completion | Writer retains captured claim/duty/input/response/preparation/identity/evaluation/verification-byte equality, fresh provenance construction, `_outer_record`, `_record_relations`, sealed rechecks, exclusive writes, fsync, native completion and cleanup. |
| Independent evidence reader | `scope/v1/read-shadow-evidence.py` retains its own authentication, historical/current policy and Git/receipt checks. Its writer dependency must include the new held module. It is not a publisher caller. |
| Future actual publisher | After the runtime fact gates in 6.8, the concrete publisher must call this same admission, compare the actual core-valid request against every mapped field, and obey the original runtime contract. |

A common admission result is private immutable data: exact candidate/revision facts,
canonical publisher-request bytes, exact title/body bytes, complete write-set bytes,
admission digests and post-write plan. It confers no permission, result success,
readback authentication or dispatch right. Discard it on any source/input/hold change.
Do not cache it across owner lifetimes. Any refusal still stops the actual writer
before a successful completion marker. Preserve the original error translation,
nonzero exit, overall deadline, held-object lifecycle and cancellation behavior.

#### 6.3. Closed publisher mapping and held text bytes

The publisher envelope remains schema 1, kind `shadow_publisher_request`. Its ID is
the incident ID. Its body has exactly these six fields. The table describes both
common admission now and the actual publisher comparison required later.

| Body field | Common evidence source | Future core request comparison |
| --- | --- | --- |
| `target_repository_id` | Original incident repository and held Git revision identity | `body.target_repository_id` |
| `branch` | Exactly `ystack/evidence/<incident_id>` | `body.operation.arguments.branch` |
| `base_revision` | Original incident `git_revision_ref`; actual source commit | The present `body.target_revision.value` and `body.base.value`, both equal to the admitted base/parent |
| `candidate_tree_id` | Actual candidate commit/tree and every admitted blob | Candidate source root-tree binding and the authenticated publisher-request field |
| `title` | Exactly `Shadow evidence: <incident_id>` as UTF-8 bytes | `body.operation.arguments.title` as UTF-8 bytes |
| `body_sha256` | SHA-256 of the held exact `publisher-body.txt` bytes | Raw body input selected by `body.operation.arguments.body_input_id` |

The envelope ID also equals `body.operation.arguments.incident_id`; it is not a seventh body
field. Here `arguments` means `body.operation.arguments`. The outer write scope equals
`arguments.scope_id`. The workflow/task remain
`workflow.shadow-evidence-commit` and `task.commit-shadow-evidence`; compare their
actual request fields. The future publisher also binds `candidate_input_id`,
`shadow_input_id`, `write_set` and `publication_contract` by the binding contract.
Do not infer a publish stage, profile, permission or grant from the shadow request.

Apply the binding contract's incident alphabet, length and exclusions before using
it in a root, branch or title: `[a-z0-9][a-z0-9._-]{0,127}`, no `..`, and no final `.`
or `.lock`, plus the existing core ID rule. Refuse malformed IDs without normalizing.
The sole body is the following UTF-8 text with exactly one final LF:

```text
Shadow evidence for <incident_id>. Publication is withheld.
```

The title has no added LF. Compute hashes from held raw bytes, with no newline
conversion, Unicode normalization or later reread from a replaceable path. Compare
raw body bytes as well as their hash. Hold and recheck their source files and parent
paths through the writer's final marker. A digest or shape check alone cannot bind a
different actual field. Changed legal values must fail the corresponding relation.

#### 6.4. Exact inventory, complete Git relation and path policy

Preserve both existing forms. An old `withheld-write.v1` candidate has exactly 32
files. A `withheld-write-policy.v1` candidate has exactly 33. The 32 consist of the
29 names in the existing fixed `SHADOW_EVIDENCE_NAMES`, the original `bundle.json`,
`eval-seed.json` and `README.md`. The only 33rd name is `scope-policy.json`.
Every candidate file is directly below `ystack-evidence/<incident_id>/`.
Do not confuse that candidate with the new outer bundle: its payload is the 29 fixed
names plus `publisher-body.txt`, plus `scope-policy.json` only in the policy form;
its own `bundle.json` completes that outer bundle. It is never the frozen inner
`bundle.json`. Keep their separate bytes, digests and references.

The original 30 frozen files must equal their actual candidate bytes. Reuse the
actual incident-to-eval converter for `eval-seed.json`; preserve the exact existing
README bytes. For the policy form, compare the held current package policy, actual
candidate policy blob and outer policy bytes; verify the closed
`{name,size_bytes,sha256}` reference against raw bytes. Keep the historical/current
policy authenticity and evaluator-held-current equality in their existing owners.
Do not backfill old forms, infer policy from a current package, mix forms or let an
old form satisfy a policy-authenticated R3 claim. No existing historical proof is
reissued or relabelled.

Common admission must independently establish all of the following from its held
inputs. The fixed Git reader may supply the raw facts; neither a response receipt
nor a supplied write set may substitute for actual object inspection.

1. Source repository ID, hash algorithm and base equal the incident revision. The
   source inventory still equals the pre-materialization snapshot. Candidate commit
   differs from base, uses the same algorithm/repository identity, and has exactly
   one actual parent equal to base. Its actual root tree equals the claimed tree.
2. Enumerate the complete base and candidate trees. Every old leaf remains at the
   same path, mode, type and OID. Only necessary ancestor tree OIDs may change.
   Added leaves equal the entire expected 32/33-row write set. Added trees equal
   only their necessary directories. Refuse unrelated changes, deletions, type or
   mode changes, submodules, symlinks, executable files and extra empty trees.
3. The incident root and any case-folded alias or descendant are absent at base.
   An existing `ystack-evidence` ancestor must be exactly that named tree, with no
   differently cased alias or non-tree object. Retain strict parent-path/held-path
   checks and the Git owner's replace/graft/shallow/alternate/worktree exclusions.
4. Each sorted unique write-set row has exactly `path`, `mode`, `sha256`,
   `git_blob_oid`, `add_only`; mode is `100644`, and add_only is boolean true.
   Recompute byte count, SHA-256 and Git blob OID from each actual blob. Compare
   its exact bytes against the retained candidate file. Both SHA-1 and SHA-256
   Git object formats retain their correct native OID lengths.
5. The actual paths equal the caller's already accepted exact `allowed_paths`.
   Reuse `write_path_ok` on held package policy and mode for every path. Keep
   `.git`/`.ystack`, protected segments/root files/prefixes, traversal, aliases,
   control characters, UTF-8 path length and all existing limits. A request does
   not grant its own path allowance; shadow keeps its original scope checks and
   the future publisher keeps its actual permission, scope and kill-switch gates.
6. Recompute the full add-only patch and all rows with `evidence_patch`. Keep the
   1,048,576-byte patch limit, 4,096-byte UTF-8 path limit, UTF-8/nonbinary rules,
   raw-size checks, exact inventory and current helper limits. Do not weaken them
   to make a fixture pass. Recheck both held Git owners and all source bytes before
   returning and at the existing final sealed boundaries.

#### 6.5. Withholding, admission and the post-write plan

Retain the exact nine keys of the shadow write section: `bundle_ref`, `scope_id`,
`workflow_id`, `task_class`, `write_set`, `publisher_request`, `admission`,
`publication`, `post_write_verification`. Compare the frozen bundle reference,
actual generated `stage_request.content` workflow/task, scope, complete write set,
publisher request and held body bytes. Do not misread the stage content wrapper.

Publication remains exactly `{state:"withheld",reason_id:"shadow.write-not-published"}`.
Admission remains exactly `{state:"checked",effect:"none",request_sha256:...,write_set_sha256:...}`,
using canonical request and write-set bytes. The exact post-write plan remains
`{target_revision:<base>,candidate_tree_id:<actual tree>,write_set:<complete rows>}`.
It is the plan for later verification, not evidence that publication happened or
that readback matched. The shared result must expose these actual values to both
callers; a boolean result is insufficient. Preserve the current record and receipt
shapes. No new authority, success status or provenance event is introduced.

#### 6.6. Source closure and exact second-checkpoint paths

The new module must be part of the existing authenticated source closure. Load it
only from the fixed physical package path, never from caller input, environment,
ambient search paths or a directory-wide module allowance. The writer pins its exact
SHA-256 in writer source, checks held raw bytes before loading those same bytes,
and keeps the held module and its parents under the existing rechecks. This makes
`consumer_source_sha256` of the writer bind the new helper without changing the
provenance envelope. The plan fixes the module's final digest before review; any
helper edit requires updating that one pin and fresh source proof.

Add only that exact module origin to `_runtime_module_origins`. Load it before the
startup module-origin snapshot, and preserve origin equality and no-hook/thread
checks throughout. Reader loading must hold the same fixed module and verify its
writer pin and fixed consumer identity. Reuse existing held-byte/path machinery;
no new source trust root, native ABI, owner registration or provenance command is
needed. A pure Python call must not fabricate an external command-ledger row.
Missing, replaced, aliased, changed or unbound module bytes refuse completion.

After the accepted adoption/plan gates, only these nine paths may change for the
new second-checkpoint concern. They are not permission to edit other inherited code.

| Exact path | Allowed purpose |
| --- | --- |
| `publisher/v1/_admission.py` | One private common admission owner and its fixed data helpers |
| `shadow/v1/write-shadow.py` | Exact helper load/pin/hold; common delegates and actual `_admit` call; preserve shadow-only gates |
| `shadow/v1/enforced-reproduction.py` | Admit only the exact new fixed module origin; no other runtime change |
| `scope/v1/read-shadow-evidence.py` | Hold/check the new fixed writer dependency; no change to authentication or coverage rules |
| `scripts/test/publisher-admission.test.sh` | Closed offline common-boundary and source-closure proofs through actual functions and real disposable Git objects |
| `scripts/test/shadow-write.test.sh` | Actual writer-route paired proof, retained safety assertions and finite private-copy closure updates |
| `scripts/test/shadow-enforced.test.sh` | Exact private fixture source-copy update for the new module; retain all original assertions |
| `scripts/test/portable-core-v3-publisher.test.sh` | Correct only the original-plan provenance check inside `static_case` / `registry-exact`, as specified below; preserve all other checks |
| `ci/required-files.txt` | Restore entries for the new private module and its test only |

The reader path is absent from the comparison main and belongs to the preserved
source dependency. Its adoption must be explicit before editing. Do not silently
copy it into this allowlist. Keep `_consumer.py`, core generations/registries,
`write-materialization-input.jq`, existing policies, live config, native helpers,
workflows and public wrappers byte-identical to the adopted baseline in this phase.
Keep all first-checkpoint core-v3 package, fixture and registry files and counters
intact. The sole runner exception below does not reopen its other assertions. No `publish.py`, extra
fixture product, new public argument or production configuration is in this list.
The plan must justify a readable new and cumulative review-size range from the
actual adoption diff and test inventory. An overrun returns through that gate;
never reduce proof or hide inherited changes to meet a size target.


The existing v3 runner's `registry-exact` case correctly fixes the registry's
`parent_plan_merge_commit` to `c6c3f74181ea86f85be87ecf4431e67a5f272d82` and its
`parent_spec_blob` to `e55e2aaeb179d7e06f229805744b2be49cbfa1bf`. It then hashes the
current working-tree `work/fixed-evidence-publication/plan.md` as the old plan.
That last check must use the actual initial parent commit's bytes instead. A later
accepted plan amendment changes current planning; it cannot rewrite the generation's
original provenance. Keep the registry and all published generation bytes unchanged.

Limit the runner edit to obtaining and checking that initial plan provenance:

1. First verify the canonical registry and its exact fixed entry as before. Require
   the full pinned commit to resolve as that same commit object. Read the fixed path
   `work/fixed-evidence-publication/plan.md` from that commit's tree, with regular-file
   mode `100644`, not from HEAD, a branch name, working files or a declared blob.
2. Capture all original plan bytes with `git show <pinned-commit>:<fixed-plan-path>`.
   Require the actual tree entry and recomputed Git blob to equal
   `d8aa60b213cf7fce29c386b0eac49401c36643ff`, and the raw-file SHA-256 to equal
   `810ec947448c9731d1cb47e3acb0f26e7e7fe11e982b36b25caaf2a13f4ae4e3`.
   Check its `spec-blob` against the registry's original `parent_spec_blob`. These
   checks consume actual bytes; an OID printed in registry or plan text is not proof.
3. A shallow checkout may lack the pinned commit or its required tree/blob objects.
   In the existing, manager-authorized
   CI job for `yihanzhu/ystack` only, first require the existing `origin` to identify
   one of `https://github.com/yihanzhu/ystack` or
   `https://github.com/yihanzhu/ystack.git`, with no other resolved fetch URL,
   embedded credential, alternate host or repository. Use that existing checkout's read-only Git access.
   It may run this single fixed read, at most once and within the existing job deadline:

   ```text
   git -C <existing-checkout> -c fetch.recurseSubmodules=false -c gc.auto=0 -c http.followRedirects=false fetch --no-tags --no-prune --refmap= --no-recurse-submodules --no-write-fetch-head --depth=1 origin c6c3f74181ea86f85be87ecf4431e67a5f272d82
   ```

   Probe local objects without an implicit lazy network read; a partial-clone or
   object-indirection setup cannot trigger another read. The plan must make this
   condition explicit for its existing checkout. The commit and repository are fixed
   constants, not caller parameters. No branch
   destination/refspec, tags, submodule fetch, push, new remote, credential change,
   tool install, HTTP/API downloader or second host is allowed. This fills only the
   CI checkout's object/shallow metadata; it does not move its checked-out branch
   or rewrite published history. Then repeat the commit/tree/raw-byte checks above.
   Preserve the exact argv, exit and resulting object/byte hashes in the proof.
4. Outside that already authorized CI read context, missing objects stop the local
   proof as NOTRUN with a nonzero suite result. A missing object, denied read, timeout,
   wrong repository, failed fetch or mismatched actual byte/hash is never a skip or
   green fallback. Do not use a supplied hash, current plan, cached text without its
   actual commit/tree binding, or an unverified archive as a substitute. No fetch is
   needed when the pinned object and its required tree/blob objects are already local.

Keep the canonical/exact registry assertion, public-wrapper and old-export hashes,
restore check, complete 606 case/route rows, 626 inherited assertions, forced routes,
all original result counters and execution ledgers intact. Add bounded provenance
proof alongside them: an amended current plan with the unchanged actual original
parent must pass; missing original objects without authorized read must fail;
wrong original tree/blob/raw SHA must fail; and a real shallow CI checkout must obtain
and check the pinned bytes through the single allowed read. Preserve existing failures.
The new admission suite may own these additional closed cases, but it must exercise
the runner's actual provenance code, not a copied predicate. The separate high-risk
plan fixes the exact local and shallow-CI test procedure and records all actual
outputs. No ordinary suite success or declared registry value replaces this proof.
This narrow CI repository read grants no publisher transport or runtime authority.

#### 6.7. Finite source proof and accurate checkpoint status

The high-risk plan must enumerate each case below with a stable ID, actual entry,
assertion, paired positive and raw receipt. Expand the stated closed families into
individual rows before code. Count all rows and preserve every existing assertion.
Do not replace meaningful relations with malformed-shape examples or static text
search. A passed private helper test proves neither an actual caller nor genuine
native qualification.

| Proof family | Required cases and actual route |
| --- | --- |
| Real writer integration | Both 32/33 forms reach the shared boundary from real writer `_admit` and retain withholding. Existing actual producer/receipt checks remain in that route. Demonstrate refusal propagation and that bypass/removal of the shared call would fail an owned route assertion. Tests cannot be the second caller. Keep fixture/native-launch classifications explicit. |
| Six fields and linked identity | One legal-value mismatch for each of the six body fields; envelope incident ID, scope, workflow and task mismatches; wrong actual candidate/body bytes. For each, a genuine matching offline-data baseline reaches the same predicate. |
| Text and hashes | Wrong held body bytes with a recomputed hash, missing/extra final LF, wrong legal title, stale body hash and wrong request/write-set digest. Restore the exact bytes/digests and observe the paired admission. No normalization. |
| Forms and inventory | Both forms; remove each required name, add an extra name, wrong root and case alias, nested path, duplicated/unsorted rows, mixed forms, old-form policy backfill, altered frozen marker and actual policy bytes with recomputed outer hashes. Retain old 32-form byte compatibility and policy-authenticated R3 refusal rules. |
| Full Git and raw rows | Both object algorithms; candidate equal to base; zero, two or wrong parent; wrong actual tree; unrelated old file modification/deletion/mode/type; extra leaf/tree; preexisting root/alias; symlink/submodule/executable; wrong raw SHA/OID/size; patch-limit boundaries. Cases use real disposable object databases through the fixed reader. |
| Path and scope | Exact allowed-path mismatch and each existing path-policy refusal family, including `.ystack`, traversal, case alias, protected prefix/root/segment and held mode restrictions. Keep limits and original policy bytes. |
| Source closure and lifetime | Missing/wrong pin, wrong origin, symlinked parent/leaf, module mutation before/after admission, changed source/candidate or held body after admission. Verify refusal at existing final checks with no successful marker. A private copy is enumerated and counted; it cannot widen production loading. |
| Preserved shadow and reader gates | Keep original frozen authentication, fresh receipt, same anchor/principal/store, retained bytes, provenance/record rebuild, historical/current policy, nonce/lifecycle, sealed rechecks and completion assertions. Run unchanged scope generation/qualification regressions as applicable; no stub success or weakened fallback. |

Use the existing test environment and CI workflow only. Run the new named suite and
existing `shadow-write.test.sh`, `shadow-enforced.test.sh`,
`scope-gate-generation.test.sh` and `scope-qualification.test.sh` suites with their supported modes, plus the complete
six-shard matrix at the source milestone. Keep explicit pure, fixture, genuine and
native labels. A missing runtime/configuration/authorization yields NOTRUN or BLOCKED
for that proof, never a simulated pass. Bind exact head/base, source pins, all case
counts, stdout/stderr and exits. Keep all previous failure records and original debts.
The reviewer reads the actual named assertions and complete relevant outputs; aggregate
green alone is insufficient. No workflow edit, installation or widened execution
permission follows from this source plan.

Record checkpoint two as `SOURCE_SHARED_ADMISSION_SHADOW_ONLY` only when its exact
static review and all source-checkpoint proof required by the accepted plan have passed. If required source tests are NOTRUN,
record preparation only and keep the checkpoint pending. This status explicitly
leaves the actual publisher caller, final integration and G3 incomplete. No partial
implementation PR or completed #701 is permitted. The same preserved branch may be
pushed solely for the accepted existing-CI checkpoint, as in section 5.

#### 6.8. Scoped runtime STOP and complete final acceptance

Child 11's concrete transport actions/failures, actual identity and narrow credential
enforcement, durable incident reservation/dispatch mechanism and independent
authenticated readback need primary facts under the proper separate access
authorization. Until accepted exact design and plan bind those facts, stop before
writing their dependent runtime code or making any real call. Missing facts at this
boundary do not prevent the fully defined inactive source work above. Do not create
an empty publisher, generic adapter, arbitrary callable, invented native authority,
synthetic credential or success result to fill the gap. No new network or credential
access is needed to prepare this offline source.

Final #701 acceptance retains the binding contract section 7 in full: both actual
source caller routes through the same admission, exact six-field and surrounding
request/input comparisons, real concrete publisher binding, finite fake branch-then-PR
success, foreign/replaced branch and existing-PR refusal, partial effects,
crash/cancellation/lost response, durable at-most-once dispatch, no retry or renewed
incident budget, separate authenticated read-only post-write verification, normal
package/consumer assembly, full integration and restoration. Runtime qualification,
credential/sandbox/identity enforcement and first real write remain separate reserved
gates. Fixtures establish no such real-world evidence.

## Out of scope

This G2 writes only its frontmatter path. No plan, code or tests are written here.
The first source phase excludes admission/runtime paths. The second permits only
section 6.6 after its gates. Both source phases exclude public assembly,
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

Sections 2–5 define the private package checkpoint. Section 6 defines the shared
admission and actual shadow checkpoint, its adoption gates and its exact limits.
Its runtime-fact STOP remains specific to the dependent runtime code.
The complete seven-member baseline is about 3,405 lines before new rules/tests.
The high-risk plan must justify one readable complete-package review allowance;
no 300-line target permits dropping owners or proof. Final runtime scope and its
cumulative implementation review range require a later accepted amendment.
The second source plan must separately justify its new and inherited cost.
