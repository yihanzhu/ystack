---
spec-blob: e3b1396be8b1b6dbda1232d27a76cf7729d2b191
risk: high
drafted: 2026-10-24
allowed-paths:
  - work/fixed-evidence-publication/plan.md
---
# Plan: fixed-evidence-publication

Tracks #701. This high-risk plan retains the first private core checkpoint and
adds the shared offline admission checkpoint below. Each phase must pass its own
prerequisites. This amendment needs independent acceptance and protected merge
before second-phase implementation. The accepted intent blob is
`4a7f1573eb5c47947e2dc360d39f12e12847b7c6`.
The binding publisher contract remains `fixed-publisher-write-contract/spec.md`
blob `68ff3f7e673752b624710bebf540822164239234`, sections 1–7 in full.

Implementation source-phase review_size: accepted-exception — retain the first
phase's 4,500–8,000 added/changed-line allowance. Allow 2,500–6,500 for the second
phase and 31,000–36,500 for the combined inactive source. The new work covers one
shared owner, its real caller, exact loading, finite tests and provenance proof.
The dependency has 21,333 additions and 265 deletions across 25 paths against its
merge base; the first core checkpoint has 7,039 additions and one deletion across
13 paths. These are separate inputs to review, not an additive merged-diff claim.
Measure all overlapping paths and actual conflict resolutions after ordinary merges.
Count inherited code and the whole 16,899-line qualification suite in review; do
not deduct tests, compress code or weaken proof to meet the range. An overrun pauses
this same attempt for a separate amendment. Final runtime scope and its actual
PR range require a later accepted amendment after foundation merges.

## Files that change

This plan PR changes only its frontmatter path. After its gate, the first source
phase may change exactly the thirteen files below. No wildcard grants writes.

```text
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/modules/schema.jq
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/modules/profile_graph.jq
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/modules/stage_request.jq
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/modules/result_facts.jq
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/modules/result_truth.jq
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/core-ingress.sh
core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/contracts.jq
core/v3/generation-registry.json
scripts/test/portable-core-v3-publisher.test.sh
scripts/test/portable-core-v3-publisher-fixtures.jq
scripts/test/portable-core-v3-publisher-rules.tsv
scripts/test/portable-core-schema.test.sh
ci/required-files.txt
```

All seven new package members use regular mode 100644. The new test runner is
100755; fixture, rules and registry files are 100644. Existing guard and manifest
modes remain unchanged. Every new file is restore-critical and gets one exact
manifest entry. Preserve every old entry, including the existing wrapper entry.

The selected generation is `g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee`.
The G2 preimage and identity remain fixed. Recheck all core generation registries
and subtrees before code; none may have allocated this ID. An existing unexpected
subtree or record stops the attempt rather than being overwritten.

The new canonical registry is exactly one array entry, sorted-key JSON plus LF:

```json
[{"generation_id":"g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee","parent_plan_merge_commit":"ACTUAL_ACCEPTED_PLAN_MERGE_OID","parent_spec_blob":"e55e2aaeb179d7e06f229805744b2be49cbfa1bf"}]
```

The uppercase value is a documentation placeholder only. After the original
first-phase plan merges,
the manager records its actual protected merge OID and the plan blob, then supplies
that exact OID before the first code commit. Reject a placeholder, candidate head,
prediction or non-ancestor commit. The source registry must bind the actual merged
original plan and original G2. The immutable original plan blob is
`d8aa60b213cf7fce29c386b0eac49401c36643ff`; its accepted merge is
`c6c3f74181ea86f85be87ecf4431e67a5f272d82`. This amendment never replaces those
registry values. Never edit a plan to fill its own merge OID. Future registry
entries preserve the prior ordered prefix and unique IDs under the normal rules.

### Immutable source pins

The source base is `3167ca3f17cf4e25aa1a65916bd725773b0d87ef`.
The selected wrapper is mode `100755`, type `blob`, OID
`18748127ead49a22717723e9860210940010d84e`.
Freeze the whole old `core/v1` tree `4af76e02fc8b86ead009156bf165ee700aabe7f8`
and `core/v2` tree `79a4b1fdb78da8724836d6c6df7a646213d9de04`.
The old registry blobs are respectively
`a9cb0e4f6a05f4228fc219bef96ba52a324dc223` and
`0bc09fa56047b2e3fdecf22559f68468f0528797`.

Reconstruct the complete 28-row export snapshot with this exact command:

```text
git ls-tree -r 3167ca3f17cf4e25aa1a65916bd725773b0d87ef -- core/v1/generations core/v2/generations
```

Its raw UTF-8 stdout, including tabs and final LF, has SHA-256
`37e913e16928aa68aafb5cd2e4a0548f82e0d36338378ea4ace1e12ac80f3899`.
Each row freezes mode, type, blob and full path, not just a directory name. Require
identical current rows, both tree OIDs and wrapper blob before and after source
work. Resolve the comparison generation from the fixed v2 registry's last entry;
its selected ingress/root/modules provide the 3,405-line baseline. Never print old
generation literals in new tracked files or encode them to evade the existing guard.

Freeze the seven old ledgers below. Paths are `scripts/test/<name>`; each remains
byte-identical. Their closed aggregate is 34 review rows and 279 legacy rows.

| Name | Git blob |
| --- | --- |
| `portable-core-schema-ledger.tsv` | `3335f290b33d56c37d4386fc36051335d042ddc9` |
| `portable-core-ingress-ledger.tsv` | `64457f9e492acdfc150e0f56189e3b8a2ad6bfe0` |
| `portable-core-profile-graph-ledger.tsv` | `85c65af48ee14193ee12a3e4c0cf9c25dd3c4621` |
| `portable-core-stage-request-ledger.tsv` | `2ac759aac55110651c899a93b28e9a14df227ef8` |
| `portable-core-result-facts-ledger.tsv` | `702dd86f2b311015e5605ba76bbab358c5f5b5f8` |
| `portable-core-result-truth-ledger.tsv` | `0b2867c4064dc1eae22de985b3ca3b241ee40b6e` |
| `portable-core-assembly-ledger.tsv` | `4403ea649ea17fce35e3ff8a8e39276d9d7f518f` |

## Order of work

1. **Bind the accepted attempt.** The manager records the plan merge and exact
   `plan-base`, accepted spec/intent/plan blobs, risk high, gate mode artifact-high,
   the implementation branch and clean worktree. Before the first code commit,
   default must still equal plan-base; otherwise use the separate non-author
   base-reaffirmation gate. Check branch/path absence before creating the one new
   implementation attempt. Keep existing attempts, #183 and #412 untouched.
2. **Prepare the whole new generation.** Copy the seven pinned current members to
   the new exact paths. Add the canonical registry using the recorded actual plan
   merge. Add all new manifest entries. No non-test caller may load v3. Change only
   its envelope/reference major, semantic identity, literal generation and fixed
   physical `core/v3` paths where needed, then the publisher rules below. Old core,
   wrapper, profiles, installer and packager stay unchanged.
3. **Implement one home per rule.** Use the accepted spec section 3 and the owner
   table below. Keep ordinary producer, verifier, reviewer and forge semantics in
   v3. Preserve exact refs, unknown-field rejection, fact gaps and error order.
   Schema owns new shared value predicates; dispatch/composition stays with the
   existing request/result owners. Root routes and composes only.
4. **Build the private proof with the rules.** Use one fixed test runner and owned
   fixtures. Call the actual fixed ingress and root for all three modes; direct
   predicate checks supplement this pipeline. Carry inherited positive/negative
   rule cases into v3, reusing existing fixture functions where possible. Only
   fixture envelopes/refs and the explicitly active publisher binding change;
   literal expected verdicts for unchanged rules do not. No fixture represents
   actual publisher credentials or execution.
5. **Extend only the narrow guard.** Add the exact v3 paths and closed reference
   inventory below. Preserve all old hit tables and failure tests. Add tests for
   new outside paths, public callers and imports, rather than widening an old
   predicate to permit all `core/v3` or all tests/work documents.
6. **Check the complete private checkpoint.** Run the static checks, finite new
   proof, all old core regressions and restoration proof below. Local functional
   tests are NOT RUN when the pinned runtime is absent. Use the explicit existing
   CI checkpoint for their real evidence. Have a separate reviewer examine the
   complete exact source head and raw proof. Preserve every failure and fix on
   this branch; a changed plan needs the separate plan author and gate.
7. **Stop after this checkpoint.** Record head/base, thirteen-path diff, export and
   registry pins, proof counters and clean state. No implementation PR, G3, issue
   closure or public selection follows. Resume this same attempt only after the
   later admission or runtime scope amendment and high-risk plan gate.

### Implementation mapping

| Owner | Required implementation |
| --- | --- |
| `schema` | Change v3 major/identity. Add protected deterministic publisher and its one capability, exact three permissions and deterministic evidence. Define reusable exact nine-argument, write-row and publication union value shapes. Preserve all existing primitives and closed registries. |
| `profile_graph` | Construct v3 document refs. Enforce exact publisher manifest offer/request, empty tools/skills and no model/prompt. Retain protected binding, instance, principal, boundary and authority separation plus all source/manifest projections. |
| `stage_request` | Dispatch new argument shape to schema. Add publication-contract delivered scope and all nine-argument/input/write-set relations from contract section 3. Enforce workflow/task/stage, safe incident and derived branch/title, present equal base/target, different root-tree candidate, repository/hash consistency, distinct data/instruction inputs and exact binding. Grant/qualification remain shape checks. |
| `result_facts` | Preserve deterministic metadata, actual binding/performer/environment/capability checks and unavailable facts. Registry/ref changes must not bypass the existing nonpassing incident path or permit passing mismatched execution. |
| `result_truth` | Add publication shape and all document-local state/status/output/delta relations. Stage-run enforces capability-specific presence, candidate head, attempt 1, exact separate verifier projection, all section-6 rows and existing evidence/actual-execution rules. |
| ingress | Rebind only fixed new generation/v3 physical paths/semantic identity. Preserve bounded snapshots, canonical bytes, hashes, fixed jq imports, accounting, cleanup, errors and three modes. |
| root | Keep five exact imports and full self-checks in document/profile-set/stage-run; preserve limits, shapes, refs then relations. Do not add policy to the dispatcher. |

For publisher, `publication` has branch, change_request and post_write with the
exact section-6 union fields. Locally reject PR attempts without created branch,
post-write results without both effects created, and effects without execution.
Stage-run alone can compare the candidate and resolved verifier. Completed changed
needs both effects created, matched independent-check claim, complete actual facts
and passed deterministic evidence. Completed metadata-gap is inconclusive with
reason/nonpassing evidence. Failed/cancelled and partial/unknown results remain
nonpassing. None of these document claims authenticates an external effect.

### Exact private loading and guard

The runner resolves the new generation from its fixed expected G2 identity and
uses only its fixed ingress. Call `portable_core_ingress_open`, then
`portable_core_ingress_begin` with document/profile-set/stage-run, snapshot each
input, finish_driver, validate and close under the existing cleanup discipline.
No public loader, callback parameter, candidate execution or transport is added.

Accept schema imports only from the seven exact new members and the named fixture/
runner where needed. Product import names remain exactly schema, profile_graph,
stage_request, result_facts and result_truth; schema itself stays import-free.
No include, search metadata, JSON import or path-valued module name is allowed.
The shared guard obtains the v3 ID from its registry and checks the G2 preimage;
it must not hardcode any old generation literal in newly added content.

The closed locations permitted to contain the new literal ID are its registry,
its ingress, the three new proof files, `ci/required-files.txt`, and exactly
`work/fixed-evidence-publication/spec.md` and `work/fixed-evidence-publication/plan.md`.
Not every permitted file must contain it. No other location is allowed. Normative
artifacts may bind identity but may not load code. The wrapper must keep the pinned
v2 selection. Test public/non-test caller and foreign-generation rejection. This is
normal private-generation proof, not a relaxation of the old hit lists.

## Risks

The highest risk is incomplete validation: a correct leaf predicate is useless if
a route skips it. Full ingress tests and forced-owner failures must demonstrate
all routes. A second schema or an isolated checker would lose this ownership proof;
use the existing package instead.

Copied legacy code counts in size and review. Compare its complete pinned baseline,
retain old bytes and ledgers, and review each v3 delta. Never rewrite the existing
schema guard broadly to make the new package green. Narrow new-path acceptance
must preserve rejection of every old forbidden path.

The registry cannot contain this plan's merge until the manager records the actual
receipt. Missing receipt stops code. A later base move requires normal revalidation;
no reset, rebase, force push, cleanup or duplicate attempt may fabricate the tuple.

The local fixed jq 1.6 cache was absent at planning. This is an environment fact,
not a native qualification probe. Do not download a replacement or run an unaccepted
executor. Keep local functional evidence NOT RUN and use the existing CI gate below.
Static-only success cannot establish package behavior.

Shared admission and source `22d25c96f28ed42da0a5722b6b5ea0e65946274c` remain
excluded from the first phase. The second phase below requires their separate
source preflight, adoption and exact merged-source review before new code.
Concrete transport, real identity/narrow credentials, durable reservation/dispatch
and authenticated readback need primary facts and accepted design/plan before any
dependent code. No empty adapter or arbitrary callable may fill the second route.

Final acceptance still requires both actual source callers, complete finite fake
publication/failure proof, separate authenticated readback, normal public assembly,
consumer/integration/restoration gates, real binding and reserved qualification.
The current packager selects from the existing wrapper/profile; do not change it
or claim that manifest restoration installs v3. Keep #558/#544/#681 and step-7 debts,
CPU wall NONE, native BLOCKED, production EMPTY and automation PAUSED. No new
network/credentials/install/target execution/activation/config or real write.

## Proof

### Fixed new cases and routes

The rules TSV has exactly the columns `rule_id`, `owner`, `case_id`, `mode`,
`expected`. Rule IDs are the nine `publisher-v3.` groups in the accepted spec.
Expand only the finite case sets below, plus inherited cases and forced-route rows.
Use the suffixes shown for derived case IDs; never generate expectations from
product code. D means document, P profile-set, T stage-run. Run each case through
every listed applicable route, with fully valid companion documents.

| Case ID/set | Owner / rule group | Routes | Literal expected |
| --- | --- | --- | --- |
| `ok-kind-{manifest,profile,resolved,request,result}` | all / routes | D for each; P for first three; T for last three | OK |
| `ok-operation-{producer,verifier,reviewer,forge,publisher}` | all / routes | T | OK |
| `major-{1,2,mixed-ref}` | schema / registry | D,P,T where the mutated document occurs | E_SHAPE |
| `registry-{unknown-cap,unknown-perm}` | schema / registry | D(request),T | E_SHAPE |
| `registry-{extra-perm,candidate-exec}` | stage_request / registry | D(request),T | E_RELATION |
| `registry-model-publisher` | profile_graph / registry | D(profile/resolved),P,T(resolved) | E_SHAPE |
| `dormant-offer` | profile_graph / profile | P | E_RELATION |
| `field-{missing,extra,type}` for each of the nine argument fields | schema/request / value-shapes | D,T | E_SHAPE |
| `union-{branch,pr,post}-{extra,missing,type,unknown-state}` | schema/result_truth / value-shapes | D,T | E_SHAPE |
| `profile-{tool,skill,model,prompt}` | profile_graph / profile | D(profile/resolved),P,T(resolved) | E_SHAPE |
| `profile-{wrong-cap,wrong-perm}` | profile_graph / profile | D(profile),P | E_SHAPE |
| `resolved-{wrong-cap,wrong-perm}` | profile_graph / profile | D(resolved),T | E_RELATION |
| `separation-binding` | profile_graph / profile | D(profile/resolved),P,T(resolved) | E_SHAPE |
| `separation-{instance,principal,boundary,authority}` | profile_graph / profile | D(profile/resolved),P,T(resolved) | E_RELATION |
| `projection-{manifest,package,config,skills,tools}` | profile_graph / profile | D(resolved),P,T | E_RELATION |
| `request-{workflow,task,stage,branch,title,base,target,candidate-source,candidate-equals-base,repository,algorithm}` | stage_request / request | D,T | E_RELATION |
| `incident-{empty,uppercase,slash,colon,129,dotdot,trailing-dot,lock}` | schema/request / value-shapes | D,T | E_SHAPE |
| `input-{missing,wrong-type,wrong-media,reused-data,instruction-collision,contract-mismatch}` | stage_request / request | D,T | E_RELATION |
| `input-duplicate` | stage_request / request | D,T | E_SHAPE |
| `required-{grant,qualification}` | stage_request / request | D,T | E_RELATION |
| `row-{mode,add-only,digest,malformed-oid,path-alias,path-backslash,path-control,path-4097,unsorted,duplicate,empty}` | schema / value-shapes | D,T | E_SHAPE |
| `row-257` | schema / value-shapes | D,T | E_LIMIT |
| `row-{outside-root,nested-filename,algorithm-length}` | stage_request / request | D,T | E_RELATION |
| `effect-<branch>-<pr>-<post>`: branch and PR each `{not-attempted,absent,created,unknown}`, post `{not-run,matched,mismatched,unknown}` | result_truth / publication-self | D,T | Exact ten OK triples below; the other 54 are E_RELATION |
| `no-execution-dispatch` | result_truth / publication-self | D,T | E_RELATION |
| `result-{outputs,delta,no-change,completed-partial,completed-unknown}` | result_truth / publication-self or outcome | D,T | E_RELATION |
| `publication-{missing,other-capability}` | result_truth / publication-cross | T | E_RELATION |
| `cross-attempt-zero` | result_truth / publication-cross | T | E_SHAPE |
| `cross-{head,attempt-two,verifier,verifier-shared}` | result_truth / publication-cross | T | E_RELATION |
| `status-{completed,skipped,stale,blocked,failed,cancelled}` | result_truth / outcome | D,T | OK with each contract row's exact presence/evidence |
| `failed-{pre-execution,execution,branch-only,unknown}` and `cancelled-{pre-execution,execution,branch-only,unknown}` | facts/truth / outcome | D,T | OK as nonpassing rows |
| `fact-gap-nonpassing` and `identity-mismatch-nonpassing` | facts/truth / outcome | T | OK, inconclusive only |
| `fact-gap-changed`, `identity-mismatch-passed`, `nonpassing-changed`, `post-mismatch-completed` | facts/truth / outcome | T | E_RELATION |
| `ref-{request,resolved}` | result_truth / publication-cross | T | E_REF |
| `time-before-request` | result_truth / publication-cross | T | E_RELATION |
| `guard-{foreign-generation,extra-module,public-caller,work-loader,wrapper-switch}` | test guard / private-package | guard | reject |
| `load-{missing,nonregular,symlink}` for each of seven members and six package ancestors | ingress / private-package | D,P,T | E_RUNTIME |
| `ambient-{cwd,home,search}` | ingress / private-package | D,P,T | OK; poison code not loaded |
| `restore-exact`, `old-exports-exact`, `registry-exact` | test guard / private-package | static/private | OK |

Every negative case changes one fact and preserves valid companion shapes. Unknown
IDs fail shape; registered-but-wrong request permissions fail relation. Publisher
binding tools/skills/model/prompt checks belong to binding shape. Request derived
branch/title, incident-root and algorithm-length comparisons belong to relations.
Case IDs expand the exact brace sets, with no runtime-selected cases or expectations.
The inherited parsed-limit pass rejects a 257-row write set before shape checks;
`row-257` therefore expects E_LIMIT through both complete routes.

The ten OK `(branch,pr,post)` triples are:
`(not-attempted,not-attempted,not-run)`, `(absent,not-attempted,not-run)`,
`(unknown,not-attempted,not-run)`, `(created,not-attempted,not-run)`,
`(created,absent,not-run)`, `(created,unknown,not-run)`,
`(created,created,not-run)`, `(created,created,matched)`,
`(created,created,mismatched)`, `(created,created,unknown)`.
All other 54 triples expect E_RELATION. Use failed execution with inconclusive
outcome, reason, diagnostics and nonpassing evidence for every triple except the
matched success triple, which uses completed/changed and passing evidence. Supply
all required proof/head/verifier fields for each selected union arm. The separate
status rows cover skipped/stale/blocked and pre-execution cases. These are literal
claim-validation cases, not authenticated publication observations.

Force failures in owned disposable copies of the complete new package, preserving
its fixed physical layout. Identify each cell by mode, unique target document ID,
and one exact owner call site/phase. First require that cell's complete valid input
set to return OK. Then make only that target invocation return false. Preserve
normal behavior for all other calls, including earlier companions and other uses
of the same predicate. The full ingress/root route must return the listed error.
Never make a shared predicate globally false. If its arguments lose document
identity, target the unique document's owner-call boundary; equal binding arrays
cannot identify a target. Run one fault per cell with every companion still valid.

For each cell, use a further disposable negative control that bypasses only the
target invocation while retaining the narrow injection. It must return OK, so the
cell's required-error assertion fails and catches that missing call. A remaining
companion failure invalidates the proof. Record baseline, targeted rejection and
caught missing-call control separately. Never edit a product working file for
fault injection. Restore/rebuild only owned disposable copies between cases.

| Forced ID | Owner predicate boundary | D | P | T | Expected |
| --- | --- | --- | --- | --- | --- |
| `force-schema` | `schema::envelope_ok` | each of five kinds | each supplied document | each supplied document | E_SHAPE |
| `force-profile` | `profile_graph::protected_role_separation_ok` | profile/resolved | profile/resolved | resolved | E_RELATION |
| `force-request` | new `stage_request::publisher_request_relation_ok` | request | n/a | request | E_RELATION |
| `force-facts` | `result_facts::execution_metadata_shape_ok` | result | n/a | result | E_SHAPE |
| `force-truth-self` | new `result_truth::publication_self_relations_ok` | result | n/a | result | E_RELATION |
| `force-truth-cross` | new `result_truth::publisher_result_relation_ok` | n/a | n/a | result | E_RELATION |

Freeze each concrete rule/case/mode row before its product predicate is written.
Print total/expected/passed per group and forced-route cell, reject duplicate IDs,
missing rows, unexpected rows or partial counts. Preserve all inherited owned-rule
positive/negative and forced-route coverage in the new package; run every old suite
unchanged as an additional regression. Keep separate counters for the pinned 34/279
legacy rows, not a fabricated new total that hides omissions.

### Commands and environment

From the implementation repository root, first verify the fixed old tree/export,
wrapper, registry and ledger pins above, the actual accepted plan merge, and the
thirteen-path allowlist. `git diff --check <plan-base> HEAD` must pass. No product
command or target execution belongs to this proof.

Run the three exact shell parse checks:

```text
bash -n core/v3/generations/g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee/core-ingress.sh
bash -n scripts/test/portable-core-v3-publisher.test.sh
bash -n scripts/test/portable-core-schema.test.sh
```

The existing local shellcheck path is
`/opt/homebrew/Cellar/shellcheck/0.11.0/bin/shellcheck`, a regular file with SHA-256
`f626614fd15e82b67c6566fd4f4d9eab796fa5dcff74ad90d702e5b96c01eba8`.
Recheck regular-file identity and that digest, then require its `--version` report
to say 0.11.0 before using it. Run the repository-wide static command:

```text
find . -name '*.sh' -not -path './.git/*' -exec /opt/homebrew/Cellar/shellcheck/0.11.0/bin/shellcheck -x -S style {} +
```

Missing or changed local tools mean NOT RUN and the existing CI static checks are
required. Never download a local tool or substitute another version. A static pass
still does not establish any functional behavior.

With verified existing jq 1.6 available, run these eleven commands exactly:

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

The new runner checks the accepted asset hash and jq-1.6 before fixtures; it never
downloads. If the local cache is absent, do not invoke old download-capable suites.
Record local functional NOT RUN. Push the same complete source branch without an
implementation PR and use only the existing `ci.yml` workflow_dispatch on that
exact ref. The existing six `run-all.sh --shard N/6` jobs run the new suite and all
old regressions. Preserve run ID, exact commit, full logs, each shard result and
all semantic counters. No workflow edit, alternate CI or #558 real-run window.
The manager may rerun this same checkpoint after bounded fixes; failed evidence
remains recorded. Automatic quick checks never replace this dispatched full matrix.

The new runner's restoration case reconstructs the manifest's exact tracked files
and executable modes in owned disposable storage, checks all seven new members and
registry, then repeats the three private forms through the restored v3 ingress.
Separately require the restored public wrapper to keep its unchanged v2 selection.
It proves source restoration, not install/release packaging. Check public selection,
default profiles, live paths and old export bytes remain unchanged after proof.

Only a complete exact-head private package proof and separate review may mark the
first source checkpoint complete. The second phase below may then start after its
remaining gates. Missing runtime facts stop their dependent runtime code. Neither
checkpoint permits an implementation PR or completes the publisher.


## Second phase: shared offline admission

The accepted spec section 6 is normative in full. This phase implements its common
byte/Git checks and the real shadow caller. It does not implement `publish.py`, a
transport, a grant, a new native interface or a second test-only caller.

### Dependency adoption and order

| Preserved input | Required identity |
| --- | --- |
| First checkpoint | `codex/impl/fixed-evidence-publication`, head `6daabc84067b32a57d7323457c9170887712ff2b`, original base `c6c3f74181ea86f85be87ecf4431e67a5f272d82` |
| Dependency D | `codex/impl/scope-gate-evidence-generation`, head `22d25c96f28ed42da0a5722b6b5ea0e65946274c`, including ancestor `787fbbf2799d22bc557ea957395c72fb40072c86` |
| D source writer | `shadow/v1/write-shadow.py`, blob `fc596350cab560a138c2059e8096542aa75554b8` |
| D comparison | merge base `573c02c0902a0b67a7168bef9a01263c0cf2b6a6`; comparison-main writer blob `4790655f9378636cacf8f4ec7929c88abcfce9bc` |
| Amendment base | `ff1b8462c012a194cc7abd4befda2ec6ecfd8d71`; current spec and intent are the frontmatter chain |

1. Close the first checkpoint on its exact head with independent complete source
   review and the required complete six-shard CI proof. Preserve all original
   R0/R1 failures and the rounds cap. A static-only acceptance or running/green
   aggregate without raw proof is insufficient. This plan grants no autonomous
   extra repair round. A genuinely later planned phase cannot hide an old failure.
2. Have a separate read-only reviewer preflight D's complete raw diff, all inherited
   source paths below, their original artifact/proof obligations and both source
   worktrees. The manager must freshly bind repository, branches, local/remote
   heads or remote absence, PR state, base, worktree state and hashes. Local
   tracking-ref absence cannot establish remote absence. Source preflight and
   adoption accept inactive source use only; unfinished foundation proof stays due.
3. After clean independent preflight and this plan's protected merge, the manager
   explicitly adopts that exact D on #701. Resume only its same clean first-phase
   carrier. Record new `plan-base`; merge that exact current main into the carrier,
   then merge exact D, using ordinary two-parent merges. First parents are the
   preserved carrier heads; second parents are the recorded main and D respectively.
   Do not cherry-pick, copy selected files, reset, rebase, force, replace a worktree
   or start a duplicate attempt. A moved D requires fresh preflight and adoption.
4. Capture actual merge exits, parents, every conflict and its complete resolution.
   Preserve conflict state; do not improvise a changed design. Only resolutions
   that preserve both accepted sources may advance under fresh independent review.
   Review the full combined tree, all inherited changes and source closures before
   new admission code. Compare the actual merged diff and counts against this range.
   No permission to change an inherited file follows from adopting it.
5. Implement only the ten second-phase paths below. Freeze helper bytes and the
   writer's literal SHA-256 together before source review. Run finite proof and
   the existing full matrix on the same branch. Rebind every changed head/base.
   Keep no implementation PR until the complete final contract is satisfied.

The full inherited path set is closed. The figures below are the additions and
deletions in D relative to its stated merge base, not new edit allowances:

| Inherited path | Added / deleted |
| --- | --- |
| `RESTORE.md` | 87 / 1 |
| `ci/required-files.txt` | 4 / 0 |
| `control/v1/control-policy-set-sandbox-bound.json` | 1 / 1 |
| `control/v1/control-policy-set.json` | 1 / 1 |
| `control/v1/kill-switch-decision.json` | 1 / 1 |
| `control/v1/kill-switch.jq` | 3 / 1 |
| `docs/components.md` | 136 / 3 |
| `sandbox/v1/coverage-source.py` | 813 / 0 |
| `sandbox/v1/host-supervisor.py` | 319 / 1 |
| `scope/v1/evaluate-scope.sh` | 258 / 7 |
| `scope/v1/generate-gate-evidence.py` | 617 / 0 |
| `scope/v1/read-shadow-evidence.py` | 1294 / 0 |
| `scope/v1/scope-gates.jq` | 131 / 32 |
| `scope/v1/scope-policy.json` | 1 / 1 |
| `scope/v1/workflow-scope.jq` | 19 / 5 |
| `scripts/test/control-kill-switch.test.sh` | 13 / 0 |
| `scripts/test/scope-gate-generation.test.sh` | 480 / 0 |
| `scripts/test/scope-qualification.test.sh` | 15604 / 64 |
| `scripts/test/shadow-enforced.test.sh` | 341 / 19 |
| `scripts/test/shadow-self-host-evidence.test.sh` | 18 / 4 |
| `scripts/test/shadow-write.test.sh` | 183 / 11 |
| `shadow/v1/_consumer.py` | 881 / 15 |
| `shadow/v1/enforced-reproduction.py` | 46 / 54 |
| `shadow/v1/write-materialization-input.jq` | 11 / 1 |
| `shadow/v1/write-shadow.py` | 71 / 43 |

### Exact second-phase edit set

| Path | Sole purpose |
| --- | --- |
| `publisher/v1/_admission.py` | Private common admission, fixed construction and candidate relation helpers |
| `shadow/v1/write-shadow.py` | Held helper load/pin, thin delegates and actual `_admit` call |
| `shadow/v1/enforced-reproduction.py` | One exact helper origin in existing runtime-origin guard |
| `scope/v1/read-shadow-evidence.py` | Hold/check that writer dependency; preserve independent authentication |
| `scripts/test/publisher-admission.test.sh` | Closed admission, real Git, closure and original-plan provenance cases |
| `scripts/test/shadow-write.test.sh` | Actual writer-route paired cases and exact private-package/cache closure |
| `scripts/test/shadow-enforced.test.sh` | Exact helper copy into its existing private package and closure proof |
| `scripts/test/scope-qualification.test.sh` | Exact helper copy at four package sites and paired closure proof only |
| `scripts/test/portable-core-v3-publisher.test.sh` | Original-plan provenance check inside `static_case` / `registry-exact` only |
| `ci/required-files.txt` | Append the exact helper and new test path once |

The new helper is mode 100644; the new shell test is 100755. Keep all first-phase
core, registry, fixture, rules and guard bytes unchanged. The sole runner allowance
cannot alter any other assertion, 606 case/route rows, 626 inherited assertions,
forced routes, result counters or ledgers. Keep `_consumer.py`, policies, native
helpers, materialization builder, wrapper, profiles and live configuration unchanged.

### Closed interface and real route

Use `admit_write(inputs)` with one frozen private `_AdmissionInputs` value. Its
fields are closed below. Freeze mappings as sorted immutable tuples of raw bytes;
no caller mutation or later path reread may change their meaning. Each body or
record is parsed with the fixed existing consumer and its original limits.

| Fixed input fields | Limit and source |
| --- | --- |
| `incident_raw`, `generated_response_raw`, `write_raw` | Each at most 1 MiB; retained actual bytes |
| `generated_input_raw` | At most 8 MiB; inspect `stage_request.content.body` |
| `frozen_files`, `candidate_files`, `outer_files` | Exact form inventories; 1 MiB per file except materialization input 8 MiB and preparation manifest 2 MiB; at most 48 MiB per collection |
| `seed_raw` | At most 1 MiB; actual retained incident-to-eval converter output |
| `record_form`, `scope_id`, `allowed_paths` | Closed form/core ID and exact sorted authorized paths, at most 33 rows and 4096 UTF-8 bytes per path |
| `policy_raw`, `mode_raw` | Each at most 1 MiB; existing held package sources |
| `source_inventory` | Immutable complete pre-materialization snapshot; never a replacement for fresh Git inspection |
| `source_git`, `candidate_git` | The two actual fixed-consumer `_ReadOnlyGit` owners; original command ledger and lifetimes |

Resolve only the already loaded `ystack_shadow_consumer` at the fixed physical
`shadow/v1/_consumer.py`; require identity with the actual writer's `e.c`. No
consumer module, predicate, callable, executor, runner or checked flag is accepted
as a field. Reuse its canonical/parse primitives, `write_path_ok`, `evidence_patch`,
`scope_policy_ref` and `_ReadOnlyGit`. Check concrete owner identity, repository
identity, object format and holds. Translate its refusal through the writer's
existing error path; keep nonzero exits, deadlines and cancellation behavior.

Move `_publisher`, `_bundle_ref` construction and `_candidate_facts` common
relations to this module. The writer retains thin delegates for earlier checks and
reader compatibility; there is one common decision owner. `admit_write` itself
calls those same helpers and re-establishes spec 6.3–6.5 from actual held inputs.
It enumerates full source/candidate trees, reads the actual commit and blobs,
recomputes native OIDs, sizes, SHA-256, rows and the complete add-only patch, and
rechecks both Git owners before returning. Keep their 16 MiB inspection ceiling,
1 MiB patch limit, all config/replace/graft/shallow/alternate/worktree exclusions
and original command allowlist. No new command-ledger role is added for Python.

The result is a frozen private `_AdmissionResult` with only `base_revision_raw`,
`candidate_commit_id`, `candidate_tree_id`, `publisher_request_raw`, `title_raw`,
`body_raw`, `write_set_raw`, `admission_raw` and `post_write_plan_raw`. JSON values
use canonical bytes; title/body use exact raw UTF-8. The value grants no authority,
execution, readback authenticity or successful publication. Discard it when any
input/source/hold changes; never cache it beyond its owners' lifetime.

The real `write` → `_materialize` → `_admit` route remains. `_inventory`,
`_authenticated_frozen`, actual converter/materializer, `_verify_write`, same
anchor/principal/store and fresh receipt checks stay in the writer. `_admit` makes
the final common call before its existing retained-byte equalities, provenance,
`_outer_record`, `_record_relations` and sealed rechecks. `write` keeps exclusive
writes, fsync, native completion and cleanup. Neither early candidate validation
nor a standalone helper test replaces this final call. The reader keeps its own
historical/current policy, authentication, Git and receipt checks.

### Source closure and all private package sites

Use one fixed module name `ystack_publisher_admission` and physical origin
`publisher/v1/_admission.py`. The writer holds the regular file and physical parents,
checks a literal SHA-256 pin, and executes those same held bytes. It must load the
module before the existing startup origin snapshot. Resolve the existing consumer,
not another instance. Keep helper and parents held/rechecked through final marker.
Add only the exact origin to `_runtime_module_origins`; keep origin equality,
no-hook and no-thread checks. The reader holds the helper before writer loading,
checks the writer pin against those same bytes and verifies both module identities.
No directory allowlist, source trust root, native ABI or provenance shape changes.

Freeze the actual helper SHA-256 in the writer and the exact source-review tuple
before review, not a guessed pre-code digest. Any helper edit updates that one pin
and reruns complete source closure proof. `consumer_source_sha256` continues to
bind the writer including its pin. Missing/replaced/unbound code refuses completion.

At each site below, copy only the exact helper leaf and necessary `publisher/v1`
parents. Check source/destination physical regular files, parents, raw equality,
digest and the package's existing modes/owners. Never copy the whole directory.

| Site ID | Exact existing source point at D | Required closure |
| --- | --- | --- |
| Q1 | qualification lines 10134–10139, portable package | Helper reaches original portable reader assertions |
| Q2 | qualification lines 10182–10187, marker-race package | Helper reaches each existing marker-race assertion |
| Q3 | qualification lines 10255–10258, terminal-controls package | Helper reaches actual terminal reader/frontend assertions |
| Q4 | qualification lines 10737–10738, genuine package; writer load 12407 | Copy before original root-owner/mode normalization at 10740–10741 |
| S1 | enforced lines 3844–3845, real/package component loop | Exact helper leaf; existing runtime/package controls unchanged |
| S2 | writer lines 1234–1237, derived enforced fixture | Retain S1's one helper copy when extending existing component loop |
| S3 | writer lines 24–30 and 1219–1224; public writer load 1310–1312 | Save/restore new module cache with original names; each actual writer import binds its own fixed consumer and helper |

S2 and S3 share the actual fixture package; count sites and package instances
separately. Do not copy into consumer-only installed-source fixtures at enforced
2316–2318/2379, which do not load the writer. Existing enforced origin checks at
3507/3511 retain their original assertions. Scope generation uses the real root,
so its test file needs no edit. Missing/altered-helper tests at Q4 remain genuine
NOTRUN/BLOCKED until original authorization/environment exists; a premature loader
failure is never the original normal-path positive. Preserve all original execution
modes, assertions, native classifications, #558 budgets/ledger hashes and failures.

### Finite admission proof

The new suite owns the table below; writer and existing closure suites own the
routes explicitly named. Every row has literal expected success/refusal. For each
negative, run the same valid 32-form baseline through that exact predicate first,
then change one fact, and restore it for a final success. Policy-only rows use the
33 form; rows marked both run both. All legal-value mutations recompute linked
outer hashes so the stated relation, not a stale digest or shape, causes refusal.
Record case ID, route, input/object/source hashes, stdout, stderr, exit, expected
result, completion-marker absence and before/after hold checks in raw receipts.
The runner fails on duplicate, missing, unexpected or partial case counts.

Entries: A = actual `admit_write`; W = real writer `_admit` through its existing
fixture route; G = A using actual `_ReadOnlyGit` and disposable bare repositories;
C = actual writer/reader loader/final recheck; P = runner's actual provenance check.
Test doubles for native launch stay fixture-classified. G may use only the fixed
Git owner's real object inspection, never a fabricated inventory/read callback.

| ID | Entry | Required assertion or single mutation |
| --- | --- | --- |
| `A01` | W | 32-form reaches common call, preserves exact old bytes and withheld result |
| `A02` | W | 33-form reaches common call, policy bytes/ref and withheld result match |
| `A03` | W | Target common-call refusal propagates before completion |
| `A04` | W | In owned copy remove only final shared call: A03 required-refusal assertion fails; valid baseline passes |
| `A05` | A | Legal different target_repository_id |
| `A06` | A | Legal different branch |
| `A07` | A | Legal different base_revision |
| `A08` | A | Legal different candidate_tree_id |
| `A09` | A | Legal different title |
| `A10` | A | Different held body with recomputed body_sha256 |
| `A11` | A | Envelope incident ID mismatch |
| `A12` | A | Outer scope mismatch |
| `A13` | A | Actual stage workflow mismatch |
| `A14` | A | Actual stage task mismatch |
| `A15` | A | Wrong actual candidate bytes despite coherent claimed rows |
| `A16` | A | Body missing final LF |
| `A17` | A | Body extra final LF |
| `A18` | A | Stale body hash |
| `A19` | A | Wrong canonical request digest |
| `A20` | A | Wrong canonical write-set digest |
| `A21` | A | Changed frozen bundle marker and recomputed surrounding references |
| `A22` | A | Inner marker substituted for outer marker |
| `A23` | A | Outer marker substituted for frozen marker |
| `A24` | A | Altered policy bytes with recomputed outer hashes (33) |
| `A25` | A | Wrong policy reference size with matching name/hash (33) |
| `A26` | A | Backfilled policy in old 32 form |
| `A27` | A | Mixed candidate/outer forms |
| `A28` | A | Extra candidate leaf |
| `A29` | A | Wrong incident root |
| `A30` | A | Case alias of required filename |
| `A31` | A | Nested candidate filename |
| `A32` | A | Duplicate write row |
| `A33` | A | Unsorted write rows |
| `A34` | A | Wrong exact allowed_paths |
| `A35` | A | Changed actual seed differs from retained converter output |
| `A36` | A | Changed README bytes |
| `A37` | A | Publication reports anything other than exact withheld record |
| `A38` | A | Admission record adds authority or changes effect-none |
| `A39` | A | Post-write plan base differs |
| `A40` | A | Post-write plan tree differs |
| `A41` | A | Post-write plan rows differ |
| `G01` | G | Both forms pass actual SHA-1 object database |
| `G02` | G | Both forms pass actual SHA-256 object database |
| `G03` | G | Candidate equals base |
| `G04` | G | Candidate has zero parents |
| `G05` | G | Candidate has two parents |
| `G06` | G | Candidate has one wrong parent |
| `G07` | G | Actual root tree differs from claimed tree |
| `G08` | G | Unrelated existing leaf changed |
| `G09` | G | Unrelated existing leaf deleted |
| `G10` | G | Unrelated existing leaf mode changed |
| `G11` | G | Unrelated existing leaf type changed |
| `G12` | G | Extra added leaf |
| `G13` | G | Extra added empty tree |
| `G14` | G | Incident root already exists at base |
| `G15` | G | Case-folded incident-root alias exists at base |
| `G16` | G | Base root has descendant under incident root |
| `G17` | G | Existing evidence ancestor is a non-tree |
| `G18` | G | Existing evidence ancestor has a case alias |
| `G19` | G | Candidate added symlink |
| `G20` | G | Candidate added submodule |
| `G21` | G | Candidate added executable |
| `G22` | G | Wrong actual row SHA-256 |
| `G23` | G | Wrong native row blob OID |
| `G24` | G | Truncated held raw blob/size mismatch |
| `G25` | G | Source inventory changed since captured snapshot |
| `G26` | G | Source repository identity differs from incident |
| `G27` | G | Candidate object algorithm differs |
| `G28` | G | Exactly 1,048,576-byte actual patch passes |
| `G29` | G | 1,048,577-byte actual patch refuses |
| `G30` | G | Non-UTF-8 candidate blob |
| `G31` | G | NUL/binary candidate blob |
| `G32` | G | Forbidden control in otherwise UTF-8 blob |
| `L01` | A | Path .git segment |
| `L02` | A | Path .ystack segment |
| `L03` | A | Traversal segment |
| `L04` | A | Case alias of protected segment |
| `L05` | A | Held policy protected prefix |
| `L06` | A | Held policy protected root filename via actual write_path_ok |
| `L07` | A | Held policy protected segment |
| `L08` | A | Held mode forbidden path |
| `L09` | A | Held mode forbidden prefix |
| `L10` | A | Absolute path |
| `L11` | A | Backslash path |
| `L12` | A | Empty path segment |
| `L13` | A | Trailing-dot segment |
| `L14` | A | Trailing-space segment |
| `L15` | A | Control-character path |
| `L16` | A | 4096-byte path primitive passes; 4097 refuses |
| `L17` | A | 64-segment primitive passes when otherwise valid; 65 refuses |
| `I01` | A | Incident uppercase |
| `I02` | A | Incident starts punctuation |
| `I03` | A | Incident contains double dot |
| `I04` | A | Incident ends dot |
| `I05` | A | Incident ends .lock |
| `I06` | A | Incident exceeds 128 characters |
| `I07` | A | Incident slash/branch escape |
| `C01` | C | Missing helper |
| `C02` | C | Missing writer pin |
| `C03` | C | Wrong writer pin |
| `C04` | C | Wrong module origin |
| `C05` | C | Symlink helper leaf |
| `C06` | C | Symlink publisher parent |
| `C07` | C | Symlink v1 parent |
| `C08` | C | Helper changed before admission |
| `C09` | C | Helper changed after admission before marker |
| `C10` | C | Held source Git changed after admission |
| `C11` | C | Held candidate Git changed after admission |
| `C12` | C | Held body changed after admission |
| `C13` | C | Foreign consumer instance |
| `C14` | C | Foreign callback/runner field refused by closed input shape |
| `C15` | C | Concrete Git-owner substitution refuses |
| `M01` | A | Remove required candidate `accepted-identities.json`; both forms |
| `M02` | A | Remove required candidate `claim.json`; both forms |
| `M03` | A | Remove required candidate `consumer-provenance.json`; both forms |
| `M04` | A | Remove required candidate `decision.json`; both forms |
| `M05` | A | Remove required candidate `duty-evaluation.json`; both forms |
| `M06` | A | Remove required candidate `evaluator-driver.txt`; both forms |
| `M07` | A | Remove required candidate `evaluator-program.txt`; both forms |
| `M08` | A | Remove required candidate `evidence-manifest.json`; both forms |
| `M09` | A | Remove required candidate `file-digest-result.json`; both forms |
| `M10` | A | Remove required candidate `incident.json`; both forms |
| `M11` | A | Remove required candidate `materialization-input.json`; both forms |
| `M12` | A | Remove required candidate `materialization-response.json`; both forms |
| `M13` | A | Remove required candidate `origin-observation.json`; both forms |
| `M14` | A | Remove required candidate `payload-stderr.txt`; both forms |
| `M15` | A | Remove required candidate `payload-stdout.txt`; both forms |
| `M16` | A | Remove required candidate `policy-set.json`; both forms |
| `M17` | A | Remove required candidate `policy.json`; both forms |
| `M18` | A | Remove required candidate `preparation-manifest.json`; both forms |
| `M19` | A | Remove required candidate `preparation-record.json`; both forms |
| `M20` | A | Remove required candidate `qualified-identity.json`; both forms |
| `M21` | A | Remove required candidate `registry.json`; both forms |
| `M22` | A | Remove required candidate `sandbox-check.json`; both forms |
| `M23` | A | Remove required candidate `sandbox-evaluation.json`; both forms |
| `M24` | A | Remove required candidate `sandbox-expectation.json`; both forms |
| `M25` | A | Remove required candidate `sandbox-receipt.json`; both forms |
| `M26` | A | Remove required candidate `sandbox-request.json`; both forms |
| `M27` | A | Remove required candidate `shadow-record.json`; both forms |
| `M28` | A | Remove required candidate `trace-ledger.json`; both forms |
| `M29` | A | Remove required candidate `trace-receipt.json`; both forms |
| `M30` | A | Remove required candidate `bundle.json`; both forms |
| `M31` | A | Remove required candidate `eval-seed.json`; both forms |
| `M32` | A | Remove required candidate `README.md`; both forms |
| `M33` | A | Remove required candidate `scope-policy.json`; 33 form |
| `Q1a` | C | Exact helper reaches original intended assertions at Q1 |
| `Q1b` | C | Missing helper refuses at actual closure at Q1 |
| `Q1c` | C | Altered helper refuses at actual closure at Q1 |
| `Q2a` | C | Exact helper reaches original intended assertions at Q2 |
| `Q2b` | C | Missing helper refuses at actual closure at Q2 |
| `Q2c` | C | Altered helper refuses at actual closure at Q2 |
| `Q3a` | C | Exact helper reaches original intended assertions at Q3 |
| `Q3b` | C | Missing helper refuses at actual closure at Q3 |
| `Q3c` | C | Altered helper refuses at actual closure at Q3 |
| `Q4a` | C | Exact helper reaches original intended assertions at Q4 |
| `Q4b` | C | Missing helper refuses at actual closure at Q4 |
| `Q4c` | C | Altered helper refuses at actual closure at Q4 |
| `S1a` | C | Exact helper reaches original intended assertions at S1 |
| `S1b` | C | Missing helper refuses at actual closure at S1 |
| `S1c` | C | Altered helper refuses at actual closure at S1 |
| `S2a` | C | Exact helper reaches original intended assertions at S2 |
| `S2b` | C | Missing helper refuses at actual closure at S2 |
| `S2c` | C | Altered helper refuses at actual closure at S2 |
| `S3a` | C | Exact helper reaches original intended assertions at S3 |
| `S3b` | C | Missing helper refuses at actual closure at S3 |
| `S3c` | C | Altered helper refuses at actual closure at S3 |

For A03/A04, inject one targeted common-rule failure into an owned helper copy
and bind its actual new digest in that owned writer copy. Preserve all other
source-closure/authentication gates and prove the normal route reaches the call.
Then remove only that call in a further owned writer copy. The refusal assertion
must fail; an earlier loader/authentication failure invalidates this control.

The closed table has 166 IDs. Both-form rows expand into two executions;
baseline/refusal/restoration receipts are separate from ID totals. Count inherited
assertions independently. Path-only L06/L16/L17 call the actual fixed consumer
primitive because the closed evidence inventory cannot contain a root file or an
arbitrary long filename; they supplement, never replace, A/G route proof. For each
of L01–L15, record whether the common boundary or fixed primitive owns the refusal.
Use real valid companion inputs; a malformed request cannot count as a legal-value
six-field mismatch. Preserve all original shadow/reader authentication, fresh-receipt,
retained-byte, record, provenance, sealed-fsync/native-completion assertions.

### Original-plan provenance and shallow CI

Correct only the `registry-exact` original-plan check. Keep its canonical registry
entry fixed to original commit `c6c3f74181ea86f85be87ecf4431e67a5f272d82` and spec
`e55e2aaeb179d7e06f229805744b2be49cbfa1bf`. Require that exact commit object and its
fixed `work/fixed-evidence-publication/plan.md` tree entry, mode 100644. Capture
`git show` raw bytes without shell command-substitution newline loss. Recompute
blob `d8aa60b213cf7fce29c386b0eac49401c36643ff`, raw SHA-256
`810ec947448c9731d1cb47e3acb0f26e7e7fe11e982b36b25caaf2a13f4ae4e3`, and original
`spec-blob`. Never compare current planning bytes to original registry provenance.

Factor that one check into a private fixed function in the same runner, called by
`static_case`. The new suite exercises the actual function text from that file in
owned disposable copies, preserving its fixed constants and command path. Require
one exact function definition and call site; no copied predicate, new product or
public runner argument. Bounded test fault injection may change one expected
pin in an owned copy to prove a mismatched actual tree/blob/raw hash is rejected;
the normal runner and registry remain unchanged. Keep all other runner bytes fixed.

Before any object probe, use `GIT_NO_LAZY_FETCH=1`, disable replace objects and
reject partial-clone/promisor config or packs, alternates, grafts, common-dir or
object-directory/environment indirection. Inspect existing config without includes
or network; reject URL rewrite rules, extra fetch URLs, credential-bearing URLs,
HTTP redirect overrides and proxy redirection. These restrictions apply to this
provenance read, not to public runtime or the shared Git owner. Reject ambiguous
context rather than broadening read access.

When objects are absent, only the manager-authorized existing `yihanzhu/ystack`
CI checkout may use its existing read-only Git access. Require the actual job
repository identity and exactly one resolved origin URL equal to the spec's two
HTTPS forms. No caller-controlled approval flag enables this. Once only, within
the job's existing deadline, run this exact argv (with the existing checkout path):

```text
git -C <existing-checkout> -c fetch.recurseSubmodules=false -c gc.auto=0 -c http.followRedirects=false fetch --no-tags --no-prune --refmap= --no-recurse-submodules --no-write-fetch-head --depth=1 origin c6c3f74181ea86f85be87ecf4431e67a5f272d82
```

Preserve the argv, exit, before/after HEAD/refs/FETCH_HEAD/shallow metadata and all
object/tree/raw-byte hashes. Repeat exact checks after fetch. No new remote/ref,
credential, host, tags, submodule, redirect, downloader or second fetch. Objects
already present need no read. Missing/denied/timed-out/wrong objects or context are
nonzero NOTRUN/refusal, never green fallback. Local proof never performs this fetch.

| ID | Actual P procedure and required receipt |
| --- | --- |
| P01 | Full local objects plus amended current plan: actual original bytes pass; current plan differs |
| P02 | Owned shallow object database lacks original commit, no CI read context: nonzero NOTRUN, no network |
| P03 | Same real original commit with one wrong expected tree-entry blob pin in owned function copy: reject |
| P04 | Same actual original bytes with one wrong expected raw SHA pin in owned function copy: reject |
| P05 | Actual different parent commit/tree in owned function copy with original blob/SHA pins retained: reject |
| P06 | Actual required tree/blob object missing in owned database: nonzero, no unauthorized read |
| P07 | Existing same-head CI job starts shallow without pinned objects, verifies origin/context, performs the one fixed read and checks real original bytes: pass |
| P08 | Wrong repository/origin or multiple resolved URLs with missing objects: refuse before network |
| P09 | Partial/promisor/alternate/replace/graft/object indirection: refuse before object probe or network |

Use a real disposable local bare object database for P02/P06, copying only the
current commit and its required tree closure, never deleting objects in the working
checkout. For P07 use the new suite's own existing
CI checkout while required objects are absent. Recompute the actual sorted
run-all inventory after merges: this closed inventory places the v3 runner on
shard 4 and the new suite on shard 6, in separate checkouts. The new suite runs
P07 before any local-object positive in its own checkout; local negatives use
separate disposable databases. Do not assume lexical ordering puts the new suite
first, and do not delete existing objects to manufacture this case. If the actual job is not shallow/missing, P07 remains NOTRUN and needs
another authorized existing-CI run with its normal shallow checkout. No workflow
change, new download or alternative CI is authorized. The new suite records that
one fetch for the provenance function; later callers in that same checkout only
use those objects. Pin the extracted function bytes to the runner's actual function
and require its one real `registry-exact` call site. Each CI job/checkout must prove
its own context, fetch count and actual object bytes. Shard 6 receipts cannot prove
shard 4's read or success. The same spec contract bounds each authorized existing
checkout to at most one fixed read; this plan grants no extra read or cross-job
credential transfer. Until actual outputs exist, P07 stays NOTRUN.

### Validation and final stop

Run `git diff --check`, Python compile checks without executing imports or leaving
bytecode, shell parsing and the pinned shellcheck on all affected shell files.
Verify the ten-path new edit set separately from the exact 25-path adoption set
and preserved thirteen-path core checkpoint. Check full manifest restoration of
the helper/test and unchanged public selection. Run these actual suites:

```text
bash scripts/test/publisher-admission.test.sh
bash scripts/test/shadow-write.test.sh
bash scripts/test/shadow-enforced.test.sh
bash scripts/test/scope-gate-generation.test.sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/portable-core-v3-publisher.test.sh
```

Use their original supported modes and existing environment only. No genuine
mode, privileged setup or native qualification follows from these default commands.
Retain full existing core regressions above and the complete six-shard dispatched
matrix at this source milestone. Bind exact head/base, all source pins, individual
case/route/inherited/closure/provenance counts and complete exits/stdout/stderr.
Existing suites retain their assertions and genuine/native NOTRUN/BLOCKED status.
No local tool install, workflow edit, substitute runtime or #558 budget is granted.
A missing requirement leaves this checkpoint pending even if the quick gate passes.

Only clean independent exact-source review plus all required source proof may mark
`SOURCE_SHARED_ADMISSION_SHADOW_ONLY`. Preparation-only or NOTRUN cannot claim that
status. Future genuine proof stays separately due; fixture results cannot upgrade it.
The actual publisher caller still must compare all six mapped fields, envelope,
scope/workflow/task, actual candidate/body/shadow inputs and publication contract.
Concrete transport, identity, narrow credentials, durable reservation/dispatch and
authenticated readback require primary facts and a later accepted design/plan.
Stop their dependent runtime work until then; do not invent an adapter or success.

Before the complete implementation PR, #558/#541/#544/#681 must satisfy their
original applicable proof and protected foundation merges. Normally merge current
main into this same carrier, measure the actual entire PR diff, then obtain fresh
complete review and CI. Keep both actual callers, fake publication/failure/crash/
partial-effect/at-most-once proof, independent authenticated readback, normal
assembly, complete integration/restoration and G3. No checkpoint closes #701.
CPU wall remains NONE, native BLOCKED, production EMPTY and automation PAUSED.
