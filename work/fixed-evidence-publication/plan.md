---
spec-blob: e55e2aaeb179d7e06f229805744b2be49cbfa1bf
risk: high
drafted: 2026-10-24
allowed-paths:
  - work/fixed-evidence-publication/plan.md
---
# Plan: fixed-evidence-publication

Tracks #701. This is the high-risk plan for the first complete private source
checkpoint. It grants no implementation before independent acceptance and protected
merge. The accepted intent blob is `4a7f1573eb5c47947e2dc360d39f12e12847b7c6`.
The binding publisher contract remains `fixed-publisher-write-contract/spec.md`
blob `68ff3f7e673752b624710bebf540822164239234`, sections 1–7 in full.

Implementation source-phase review_size: accepted-exception — propose 4,500–8,000
added/changed lines for this one complete private package and its proof. The
unchanged seven-member baseline alone is 3,405 lines; count all copied lines.
Allow about 400–900 lines for publisher predicates and 700–3,500 for readable
fixtures, full-route/legacy proof, guard and manifest work. Do not trim tests or
compress code to fit. A predicted overrun pauses this same attempt for a separate
plan amendment. This allowance does not accept a final runtime implementation PR;
its cumulative scope/range remains a later amendment gate.

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

The uppercase value is a documentation placeholder only. After this plan merges,
the manager records its actual protected merge OID and the plan blob, then supplies
that exact OID before the first code commit. Reject a placeholder, candidate head,
prediction or non-ancestor commit. The source registry must bind the actual merged
plan and G2. Never edit this accepted plan to fill its own merge OID. Future registry
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

Shared admission, source `22d25c96f28ed42da0a5722b6b5ea0e65946274c`, and all publisher
runtime paths remain excluded. Reconcile source identity/attempt/worktree and its
outstanding proof through source preflight and an accepted G2/plan amendment first.
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

Only a complete exact-head private package proof and separate review may mark this
source checkpoint complete. Missing runtime dependencies then stop progress under
the accepted spec's later amendment gates; they do not turn this checkpoint into
an implementation PR or a complete publisher.
