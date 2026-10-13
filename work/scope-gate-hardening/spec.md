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
2. A claimed shadow record must resolve to one completed child-5 consumer bundle.
   The consumer reads the marker and every listed file from the same held
   directory. It dispatches only these three forms:
   - a record without `record_form` is a legacy declaration. It stays readable
     but can never satisfy receipt or native-qualification requirements;
   - `record_form: "enforced-reproduction.v1"` is the complete 29-file child-5
     reproduction bundle plus `bundle.json`. It has a `no-change`
     materialization and no `write` field; and
   - `record_form: "withheld-write.v1"` is the complete child-5 write bundle. It
     has a `changed` materialization and the exact write section in R3.
   A checksum inventory by itself proves no origin. A missing, extra, inferred,
   or cross-form field refuses instead of changing form.
3. Receipt checking uses the existing fixed sandbox-receipt checker. It reruns
   against the retained request, expectation, receipt, observation, and
   evaluation. Policy, decision, policy set, environment registry, and accepted
   identity set come from the evaluator's repository package. Caller-supplied
   replacements never count.
4. The bundle's copies of those fixed files must equal the current package bytes.
   The shadow record, bundle marker, qualified identity, receipt check,
   materializer response, and consumer provenance must name those same bytes by
   complete references and digests. A write bundle's write section must do so too.
5. Revision facts come from a bounded read-only snapshot of the target's bare Git
   object database. The evaluator runs only fixed read commands with replacement
   objects, hooks, filters, prompts, and repository or global configuration
   disabled. It derives commits, trees, parents, paths, modes, and blobs itself.
   A supplied list of those facts is not evidence.
6. Forge facts use one closed consumer input, `coverage-observation-bundle.v1`.
   Its held directory contains exactly `coverage-query.json`,
   `coverage-observation.json`, `sandbox-request.json`,
   `sandbox-expectation.json`, `sandbox-evaluation.json`,
   `sandbox-receipt.json`, `sandbox-check.json`,
   `verifier-observation.json`, `origin-observation.json`,
   `preparation-record.json`, `preparation-manifest.json`,
   `payload-stdout.txt`, `payload-stderr.txt`, `evidence-manifest.json`,
   `payload-evidence-0000.json`, and `bundle.json`. The marker lists the preceding
   15 files by sorted name, size, and SHA-256. There is no second receipt or
   identity format. The marker is schema 1, kind `scope_coverage_bundle`; its body
   has exactly `activation_state:"inactive"`,
   `contract_version:"coverage-observation-bundle.v1"`, `query_sha256`, and
   `files`.
7. `coverage-query.json` has the standard four-field envelope, schema 1, and kind
   `scope_coverage_query`. Its body has
   exactly `repository_id`, `coverage_base`, `evaluated_revision`,
   `default_branch`, `qualifying_observation_ref`, and `git_snapshot_ref`. The
   qualifying-base query uses null for its own prior observation ref; later
   queries use the complete ref to that unchanged qualifying observation. The
   coverage observation uses schema 1 and kind `scope_coverage_observation` in the
   same envelope. Its body has exactly those six query fields plus `query_ref`,
   `observed_at`, `first_parent_interval`, `publisher_merges`,
   `protected_workflow_paths`, and `branch_rule_history`.
   The interval has exactly
   `base`, `tip`, and `commits`; each ordered commit row has exactly `commit_id`,
   `parent_id`, and `tree_id`. Each publisher row has exactly `repository_id`,
   `scope_id`, `branch`, `pull_request_id`, `head_commit`, `base_commit`,
   `merge_commit`, and `publisher_identity_ref`. The rule history has exactly
   `start_observed_at`, `start_state_digest`, `events`, `end_observed_at`,
   `end_state_digest`, `terminal_cursor`, and `truncated`. Each ordered event has
   exactly `event_id`, `observed_at`, `before_digest`, and `after_digest`. The
   start values equal the authenticated qualifying baseline; the end values and
   cursor come from the same current observation; and `truncated` must be false.
   Thus A-to-B-to-A is a change even when endpoint digests match. Receipt payload
   digests and the held marker bind these raw bytes to the authenticated observer
   attempt.
8. The existing sandbox receipt contract authenticates that attempt without new
   checker behavior. The fixed observer is
   `tool.scope-coverage-observer.v1` in the package-selected exact environment
   `environment.scope-coverage-observer.v1`; its current registry entry must be
   unique and `native-qualified`, and its accepted entry must be unique. Its
   executable digest is the existing `verifier` identity:
   `verifier-observation.json`, `sandbox-evaluation.json`, the receipt's observed
   verifier identity, and that accepted entry must match as `check-bound` already
   requires. The launch subject's `environment_id`, entry digest, repository id,
   source commit/tree, candidate commit/tree, preparation record and manifest
   digests, and `incident_sha256` bind respectively to that environment, the
   query repository, base, R, the two held preparation files, and the raw
   `coverage-query.json`. The consumer rebuilds the one fixed observer instruction
   from the tool id and held query and requires its digest in the launch request.
   Expectation and receipt repeat that exact subject and attempt; expectation
   binds the raw launch request. Receipt control fields bind
   the existing fixed policy, decision, policy set, evaluator, and actual sandbox
   evaluation. Receipt payload fields bind `payload-stdout.txt` byte-for-byte to
   `coverage-observation.json`, empty `payload-stderr.txt`, and the exact one-item
   evidence manifest. That manifest names `payload-evidence-0000.json` with the
   same observation bytes, size, and digest. The fresh controlled-storage origin
   recheck binds the same
   store and attempt. Only a valid, satisfied `check-bound` output admits those
   bytes. Caller-authored JSON or equal digests outside that held attempt do not.
9. Qualification at the exact base uses child-5 Git source facts plus an
   authenticated qualifying coverage observation for that base. A later R uses
   that unchanged qualifying observation plus a current observation whose request
   starts from it. The fixed Git reader must independently derive the same commit
   interval, trees, protected paths, and snapshot binding. A gap, duplicate,
   reordered row, cursor discontinuity, truncation, or disagreement refuses.
10. The evaluator does not implement or qualify the observer. No production
   environment and verifier identity for this role are accepted today. Missing,
   unqualified, stale, malformed, or differently bound observations refuse.
   Fixtures use the same directory, schema, checker, origin, registry and accepted
   identity lookup with one identity pinned only in a private fixture package;
   they do not use a `trusted` or `qualified` switch.
11. The evaluator reads the host UTC clock once for the age check and records that
   value in its output. The time is not accepted from an input document. A clock
   read failure, invalid UTC value, or apparent future qualifying evidence refuses.
12. No input boolean or label such as `checked`, `trusted`, `native-qualified`, or
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
   A complete `enforced-reproduction.v1` bundle has this form and no `write`
   field. Legacy no-change evidence is not reinterpreted as authentic or as a
   write.
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
   equal child 5's fixed 32-file request inventory and the actual
   source-to-candidate additions. Each row must separately match at least one
   scope `allowed_paths` glob and pass the existing protected-path predicate;
   the globs need not equal the rows. No source path may already exist. No
   existing leaf, mode, blob, or unrelated sibling or subtree may change. The
   ancestor tree object ids required to add those new leaves may change, and no
   other tree change is allowed.
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
   exact base. Its separately held qualifying coverage bundle authenticates the
   target default branch and branch-rule baseline at that same base.
2. The exact base uses its authenticated child-5 Git source facts and qualifying
   coverage bundle. A later revision R is covered only when the current coverage
   bundle places R on the same authenticated target default branch and the fixed
   Git reader proves R is a first-parent descendant of `coverage_base`. Both
   coverage observations and Git results must name the same repository, base,
   revision, snapshot, commits, parents, and trees in the same order.
3. For commits after the base through R, changes under `ystack-evidence/` are
   allowed only when the authenticated coverage observation proves that commit was
   merged from this scope's own publisher pull request. Repository, scope, branch,
   pull request, head, base, and merge commit must all agree. A foreign, unmerged,
   rewritten, or merely similarly named pull request refuses.
4. Nothing may change under the target's `.ystack/` or its protected CI workflow
   paths. The fixed Git reader derives these path changes. The authenticated
   qualifying and current observations must show one continuous, complete
   branch-rule history with no event from the baseline through R. Endpoint digest
   equality cannot hide a temporary change.
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
9. The qualifying time is only
   `sandbox-receipt.json.body.timing.terminated_at` from the original enforced
   reproduction attempt inside the qualifying child-5 bundle. For a withheld-write
   bundle it is the inner reproduction receipt, never the outer write attempt.
   Reopening, copying, origin rechecking, or producing a current coverage
   observation cannot refresh it. The evaluator subtracts that authenticated UTC
   instant from its one R1.11 clock read. Age equal to exactly 30 times 24 times
   60 times 60 seconds is accepted. A greater age, negative age, future or invalid
   timestamp, or a time inconsistent with the checked original receipt refuses.
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
4. A proposable result still requires every scope, shadow, eval, duty, kill, risk,
   mode, and protected-path predicate not explicitly replaced here. R1.2 and R3
   replace the old no-change-only materialization predicate with the closed
   three-form dispatch. R4 replaces exact-revision and full-identity equality
   with coverage-base, closed-identity, and fresh-derived binding. Every other
   predicate remains unchanged.
5. The evidence section records the measured child-5 bundle and receipt-check refs.
   For coverage it records `coverage_base`, evaluated revision, rule version,
   measured Git snapshot ref, qualifying and current coverage bundle refs,
   evaluation time, the original reproduction receipt ref and qualifying
   `terminated_at`, and computed age seconds.
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
   environment; a forged satisfied label with recomputed JSON digests; the complete
   enforced no-change form; and every legacy/enforced/write cross-form masquerade.
3. Write-form cases cover every field and relation in R3. They include the complete
   real child-5 fixture output, deterministic repeat, the exact 32-file write set
   under legal scope globs, missing and extra field, unmatched or extra path,
   changed source/parent/tree/blob/mode/path/order/body, existing path, protected
   path, foreign scope, unrelated sibling or subtree change, publication other
   than withheld, post-check mismatch, partial directory, and
   marker-before-completion refusal. A legal new leaf and its necessary ancestor
   tree changes pass.
4. Coverage cases include exact base, direct descendant, multi-commit first-parent
   descent, allowed ordinary source edits, and this scope's verified evidence-root
   merge. The fixed fixture observer produces the exact held contract and passes
   the same checker, origin, and identity lookup as production. Negative cases
   include caller-authored identical JSON, wrong observer or store, missing or
   reordered interval row, duplicate or discontinuous cursor, truncated history,
   non-descendant and rewritten history, second-parent-only membership, foreign
   publisher pull request, unmerged or mismatched merge, protected `.ystack/` or
   CI change, changed closed-identity field, stale derived field, missing
   observation fact, malformed Git input, and branch rules A-to-B-to-A.
5. Freshness cases fix the clock and test just before, exactly at, and just after
   30 days, plus future, invalid, and inconsistent timestamps. A 31-day-old
   reproduction stays stale after a fresh origin recheck and current coverage
   observation. A write fixture with different inner and outer receipt times uses
   only the inner reproduction `terminated_at`.
6. Development uses disposable repositories and the one closed fixture coverage
   contract. Tests show that the production package's absent accepted observer
   identity, empty accepted set, `unproven` registry entries, and CPU/wall gaps
   all refuse. No
   fixture identity or byte may enter production package data.
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

A private coverage reader consumes only the held, versioned observation bundle in
R1. It authenticates the fixed observer attempt through the existing receipt,
origin, and package identity boundaries, then combines those facts with fixed
read-only Git results. Git proves object relationships and path changes. The
observation proves facts Git cannot prove alone: default-branch identity,
publisher pull-request origin, and the complete branch-rule event interval. Neither
source can replace the other. When the accepted observer or bundle is unavailable,
the reader returns a closed refusal.

The scope program compares the measured receipt, write, coverage, identity, and
fresh-binding facts with the scope's existing evidence. The driver maps a missing
authentic receipt to `scope.sandbox-receipt-missing`; malformed or internally
inconsistent inputs keep the existing closed failure behavior.

Work order is: dispatch the three record forms; authenticate each required
environment; validate the exact enforced no-change or withheld-write form;
authenticate qualifying and current coverage observations; prove revision
coverage; rebuild all revision-derived relations; apply freshness; then run every
unchanged proposable predicate. The high-risk plan will choose exact files, split
work if needed, and map each assertion to tests.

Implementation PR: `review_size: standard`.

## Out of scope

- Native qualification, its standard, VM execution, installation, or accepted
  production identity changes.
- A target/forge observation provider, observer qualification, network access,
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
  target/forge observer exists. Code and fixture tests cannot close
  those gaps.
- **Git is incomplete provenance.** Git objects prove ancestry and bytes. They do
  not prove which default branch, pull request, publisher, or branch rule the forge
  used. Missing authenticated observation must refuse instead of inferring those
  facts.
- **Clock trust is bounded.** The local clock supplies an evaluation instant, not
  external time attestation. A backward or invalid relation refuses. Adding an
  authenticated time service would require a separate scope and authority decision.
- **Compatibility is one-way.** Old declarations and no-change evidence stay
  readable. They do not gain authentic enforcement or revision coverage by being
  parsed successfully.
