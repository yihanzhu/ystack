---
intent-blob: 9910c6f10b58b98a308cc6bbbe1a3c237c26342b
risk: high
drafted: 2026-10-13
---

# Spec: harden scope qualification evidence

Tracks #541. This concern implements Step 8 child 6. It changes qualification
evidence only. It does not enable a scope or grant write authority.

## Requirements

### R1. Trusted inputs and source boundaries

1. Keep the existing scope document, shadow evidence set, eval dashboard, risk
   evaluation, kill evaluation, duty evaluation, and construction-mode marker.
   They remain canonical, bounded, immutable for one evaluation, and bound by
   their measured SHA-256 values.
2. A claimed shadow record must also resolve to one completed child-5 consumer
   bundle. The consumer reads the bundle marker and every listed file from the
   same held directory. It requires the exact inventory, sizes, digests, and
   cross-document relations of `record_form: "withheld-write.v1"`. A checksum
   inventory by itself proves no origin.
3. Receipt checking uses the existing fixed sandbox-receipt checker. It reruns
   against the retained request, expectation, receipt, observation, and
   evaluation. Policy, decision, policy set, environment registry, and accepted
   identity set come from the evaluator's repository package. Caller-supplied
   replacements never count.
4. The bundle's copies of those fixed files must equal the current package bytes.
   The shadow record, bundle marker, qualified identity, receipt check, materializer
   response, consumer provenance, and write section must name those same bytes by
   complete references and digests.
5. Revision facts come from a bounded read-only snapshot of the target's bare Git
   object database. The evaluator runs only fixed read commands with replacement
   objects, hooks, filters, prompts, and repository or global configuration
   disabled. It derives commits, trees, parents, paths, modes, and blobs itself.
   A supplied list of those facts is not evidence.
6. For a revision after `coverage_base`, default-branch identity, first-parent
   membership, publisher pull-request provenance, and protected branch-rule state
   require a receipt from an already accepted read-only target/forge observation
   provider. The exact base uses its child-5 source facts. The later-revision
   receipt binds the repository id, provider identity, observed default branch and
   revision, the first-parent commits it attests, merged pull-request identities and merge
   commits, protected workflow paths, branch-rule digest, observation time, and
   the Git snapshot digest used here.
7. The evaluator does not create or qualify that provider. No such production
   provider is accepted today. Missing, unqualified, stale, malformed, or
   differently bound provider evidence refuses qualification. Test fixtures may
   model its closed output contract, but fixture acceptance is not production
   provider qualification.
8. The evaluator reads the host UTC clock once for the age check and records that
   value in its output. The time is not accepted from an input document. A clock
   read failure, invalid UTC value, or apparent future qualifying evidence refuses.
9. No input boolean or label such as `checked`, `trusted`, `native-qualified`, or
   `verified` substitutes for these source checks. Equal digests, a pull request's
   existence, or well-shaped JSON also do not establish provenance on their own.

### R2. Authentic enforcement and native qualification

1. Declaration-only environment evidence remains shape-valid and readable. It
   never contributes a satisfied required environment.
2. Every environment required by the scope needs exactly one child-5 bundle whose
   receipt check is valid and whose enforcement verdict is `satisfied`. Its receipt,
   expectation, sandbox evaluation, and shadow record must agree on the attempt,
   candidate, environment, accepted-set, policy, decision, policy-set, evaluator,
   payload, and store identities defined by the accepted receipt contract.
3. The bundle must carry the authenticated controlled-storage origin produced by
   the existing consumer. The fresh origin recheck and fixed receipt checker must
   both pass. Copying the origin label or its digest into another record does not.
4. The environment id must select one exact entry in the repository's current
   `shadow_environment_registry` and one exact entry in the current
   `sandbox_accepted_identity_set`. The registry entry must have
   `proof_state: "native-qualified"`. The accepted entry and receipt identities
   must match field for field.
5. The registry and accepted-set change remains the output of the accepted VM
   qualification process. This concern defines no native qualification test,
   runtime, exception, or alternative identity source.
6. CPU and wall enforcement remain `none`. Native qualification therefore remains
   `BLOCKED`, and the accepted production identity set remains empty. The shipped
   state cannot satisfy this requirement.
7. If any required environment lacks the complete evidence above, the evaluation
   is not proposable and contains `scope.sandbox-receipt-missing`.

### R3. Materialization and withheld-write form

1. Existing `no-change` materialization retains its current shape and meaning.
   Old no-change evidence is not reinterpreted as a write.
2. A `changed` materialization is accepted only in a complete child-5
   `withheld-write.v1` record. Its materialization names the local Git materializer,
   outcome `changed`, one source revision and tree, one candidate commit whose only
   parent is that source commit, the candidate tree, and the exact stage-result
   reference produced by the retained response.
3. The write section has exactly `bundle_ref`, `scope_id`, `workflow_id`,
   `task_class`, `write_set`, `publisher_request`, `admission`, `publication`, and
   `post_write_verification`.
4. `workflow_id` is `workflow.shadow-evidence-commit` and `task_class` is
   `task.commit-shadow-evidence`. Scope, repository, incident, source revision,
   qualified identity, request, result, and bundle references must all resolve to
   the same retained bytes.
5. Each write-set row has exactly `path`, `mode`, `sha256`, `git_blob_oid`, and
   `add_only`. Rows are sorted and unique. Every row is add-only mode `100644`;
   its raw-byte digest and Git object id equal the held candidate blob. The rows
   equal the scope's allowed paths and the actual source-to-candidate additions.
   No source path may already exist. No existing path, mode, blob, tree entry, or
   unrelated sibling may change.
6. The candidate patch is the exact bounded text patch rebuilt from those rows.
   It contains no binary, symlink, submodule, rename, deletion, hidden extra path,
   unsafe alias, or protected path.
7. The publisher request has exactly one target repository, the fixed evidence
   branch for the incident, the source revision as base, the actual candidate tree,
   the fixed title, and the retained body digest. Its canonical digest equals
   `admission.request_sha256`.
8. Admission is exactly `state: "checked"`, `effect: "none"`, plus the request and
   write-set digests. Publication is exactly
   `{state:"withheld", reason_id:"shadow.write-not-published"}`.
9. Post-write verification repeats the source revision, actual candidate tree, and
   exact write set. The candidate contains only the completed evidence bundle and
   unchanged deterministic seed output accepted by child 5.
10. The child-5 completion marker must be the last durable output. A partial
    directory, an early marker, a failed consumer, a simulated production bundle,
    or a bundle whose current fixed inputs drifted is not evidence.
11. Missing or differing relations make the changed form malformed. The evaluator
    must not fall back to no-change or accept a subset of the record.

### R4. Revision coverage

1. A scope records `coverage_base`, its repository id and object algorithm, and one
   coverage rule version. The qualifying child-5 evidence was produced at that
   exact base.
2. The exact base is covered by its already authenticated child-5 source facts. A
   later revision R is covered only when the accepted target/forge receipt places R
   on the authenticated target default branch and the fixed Git reader proves R is
   a first-parent descendant of `coverage_base`. Receipt and Git results must name
   the same commits in the same order.
3. For commits after the base through R, changes under `ystack-evidence/` are
   allowed only when the accepted provider receipt proves that commit was merged
   from this scope's own publisher pull request. Repository, scope, branch, pull
   request, head, base, and merge commit must all agree. A foreign, unmerged,
   rewritten, or merely similarly named pull request refuses.
4. Nothing may change under the target's `.ystack/` or its protected CI workflow
   paths. The fixed Git reader derives these path changes. The accepted provider
   receipt must also show the protected branch-rule digest unchanged from the
   qualifying evidence through R.
5. Other ordinary source changes are allowed. They do not need to come from this
   scope's publisher. They remain subject to the fresh derived-evidence rule below.
6. The closed coverage identity is exactly the parent R3.3 set:
   - scope id, `workflow_id`, `task_class`, and `model_request`;
   - `adapter_config_refs`, `prompt_refs`, `skill_refs`, and
     `verification_instructions_ref`;
   - resolved profile `profile_ref`, `profile_source`, `selection_ref`, and
     `bindings`;
   - execution environment id and exact registry entry bytes;
   - control policy-set ref and the sandbox and scope policy bytes;
   - `coverage_base` and coverage rule version.
   No field may be added, removed, substituted, or reselected during coverage.
7. Everything outside that set is revision-derived. For every evaluation it is
   freshly rebuilt from R, the actual request, resolved profile, target Git facts,
   and materialization. Existing stage-request, request/incident,
   materialization, gate-binding, qualified-identity, and cross-document checks
   must bind every derived reference and digest to those current bytes.
8. Revision-derived values include the target revision; source and candidate
   commits and trees; publisher base; stage request target and source refs;
   repository-context and resolved-profile refs; gate evidence refs; shadow record;
   materialization and stage result; sandbox evaluation; receipt; and the complete
   withheld-write relations. Matching old evidence is not proof. A different value
   is not proof either.
9. The qualifying shadow evidence is fresh through exactly 30 days after its
   authenticated observation time. Age equal to 30 days is accepted. Any later
   instant, future timestamp, invalid time, or inconsistent receipt time refuses.
10. A coverage-identity change, history rewrite, non-descendant revision, foreign
    evidence-root change, protected change, branch-rule drift, stale evidence, or
    failed fresh binding returns to the parent R3 gate named for that change.

### R5. Result and refusal behavior

1. Add `scope.sandbox-receipt-missing` and `scope.enablement-stale` to the closed
   policy reason vocabulary. The first has the meaning in R2.7.
2. `scope.enablement-stale` remains reserved for the parent R4.4 consumer. This
   concern does not fetch the ystack tip, read a real enablement record, or emit a
   positive enablement result. Adding the reason id grants no tip-reading or
   publisher authority.
3. Shape-valid declarations and no-change records remain readable. Missing or
   invalid later-revision coverage facts use the existing
   `scope.shadow-evidence-missing` refusal. Other missing authentic facts produce a
   deterministic not-proposable evaluation. Malformed
   documents, ambiguous duplicate identities, invalid canonical bytes, and runtime
   failures remain closed errors and never produce a proposable result.
4. A proposable result still requires every existing scope, shadow, eval, duty,
   kill, risk, mode, and protected-path predicate. The new checks only narrow that
   result.
5. The evidence section records the measured child-5 bundle and receipt-check refs.
   For coverage it records `coverage_base`, evaluated revision, rule version,
   measured Git snapshot ref, target/forge observation ref or `absent` at the exact
   base, evaluation time, qualifying observation time, and computed age seconds.
6. Output remains inactive, observation-only, authority `none`, authority effect
   `none`, enablement false, and qualification unavailable. It never contains a
   grant, activation, credential, publisher capability, or production identity.

### R6. Acceptance proof

1. Test the actual evaluator and fixed consumers, not a second implementation of
   their predicates. Preserve every existing scope-qualification case byte for byte
   where this spec does not change its required outcome.
2. Receipt and registry cases cover: one complete fixture control; every required
   environment; declaration only; missing bundle, receipt, origin or checker
   output; wrong attempt, candidate, environment, policy or store; current fixed
   input drift; registry `unproven`; absent or foreign accepted entry; duplicate
   environment; and a forged satisfied label with recomputed JSON digests.
3. Write-form cases cover every field and relation in R3. They include the complete
   real child-5 fixture output, deterministic repeat, missing and extra field,
   changed source/parent/tree/blob/mode/path/order/body, existing path, protected
   path, foreign scope, publication other than withheld, post-check mismatch,
   partial directory, and marker-before-completion refusal.
4. Coverage cases include exact base, direct descendant, multi-commit first-parent
   descent, allowed ordinary source edits, and this scope's verified evidence-root
   merge. Negative cases include non-descendant and rewritten history, second-parent
   only membership, foreign publisher pull request, unmerged or mismatched merge,
   protected `.ystack/` or CI change, branch-rule drift, changed closed-identity
   field, stale derived field, missing provider fact, and malformed Git input.
5. Freshness cases fix the clock and test just before, exactly at, and just after
   30 days, plus future, invalid, and inconsistent timestamps.
6. Development may use disposable repositories and closed fake provider receipts.
   Tests must label those inputs as fixtures and show that the production package's
   empty accepted set, `unproven` registry entries, absent qualified provider, and
   CPU/wall gaps all refuse. No fixture byte may enter production identity data.
7. Run the complete scope qualification suite, child-5 consumer and write suites,
   sandbox receipt suite, materializer and fixed digest suites, relevant schema and
   integration suites, and required CI. A quick CI pass is not full-suite proof.

## Design

The existing scope driver remains the only public evaluator entry. It snapshots
inputs, measures fixed components, invokes the current scope program, rechecks every
byte, and emits one canonical evaluation. It gains no generic command registry,
network client, credential input, or caller-selected trust flag.

A private evidence reader consumes the completed child-5 directory. It reuses the
child-5 bundle rules, fixed receipt checker, materializer protocol, and qualified
identity checks. It gives the scope program only measured facts and canonical
digests after all checks pass.

A private coverage reader combines fixed read-only Git results with one accepted
target/forge observation receipt. Git proves object relationships and path changes.
The provider receipt proves facts Git cannot prove alone: default-branch identity,
publisher pull-request origin, and branch-rule state. Neither source can replace the
other. When the provider is unavailable, the reader returns a closed refusal.

The scope program compares the measured receipt, write, coverage, identity, and
fresh-binding facts with the scope's existing evidence. The driver maps a missing
authentic receipt to `scope.sandbox-receipt-missing`; malformed or internally
inconsistent inputs keep the existing closed failure behavior.

Work order is: preserve old readable shapes; authenticate each required environment;
validate the exact no-change or withheld-write form; prove revision coverage; rebuild
all revision-derived relations; apply freshness; then run every existing proposable
predicate. The high-risk plan will choose exact files, split work if needed, and map
each assertion to tests.

Implementation PR: `review_size: standard`.

## Out of scope

- Native qualification, its standard, VM execution, installation, or accepted
  production identity changes.
- A target/forge observation provider, provider qualification, network access,
  credentials, target inspection, or a real publisher.
- Real enablement, ystack-tip reads, config bootstrap, activation, target writes,
  publication, post-publication verification, or production use.
- Public schema fields that grant authority, caller-selected trust, a test bypass,
  a generic evidence provider, or a second evaluator.
- Changes to the parent coverage identity, write boundary, safety standard, Step 8
  order, frozen attempts, or dirty-worktree disposition.

## Areas of concern

- **Risk is high.** This changes identity, provenance, and security-control
  qualification. A separately reviewed and merged high-risk plan is required before
  implementation.
- **Production remains blocked.** The current accepted identity set is empty,
  registry entries are `unproven`, CPU and wall proof is absent, and no accepted
  target/forge observation provider exists. Code and fixture tests cannot close
  those gaps.
- **Git is incomplete provenance.** Git objects prove ancestry and bytes. They do
  not prove which default branch, pull request, publisher, or branch rule the forge
  used. Missing provider evidence must refuse instead of inferring those facts.
- **Clock trust is bounded.** The local clock supplies an evaluation instant, not
  external time attestation. A backward or invalid relation refuses. Adding an
  authenticated time service would require a separate scope and authority decision.
- **Compatibility is one-way.** Old declarations and no-change evidence stay
  readable. They do not gain authentic enforcement or revision coverage by being
  parsed successfully.
