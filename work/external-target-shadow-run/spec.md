---
intent-blob: 7659bfdbf0175d5f6a0ab363038ac21f7b4e0568
risk: high
drafted: 2026-09-27
---

# Spec: first read-only external-target shadow run

Two runs examine real history of `yihanzhu/ystack-dummy-target` on the operator's
local macOS machine. The repository keeps their unchanged inputs, outputs and a
replay recipe. The point is portability: the same shipped pieces that reproduced a
ystack incident on ystack (#373) must reproduce an incident on a repository that
shares nothing with ystack, with no ystack special case. This is evidence of
deterministic file-digest reproduction only. It carries no model call, workflow
qualification, activation, target write or deployment authority.

`work/shadow-self-host-run/spec.md` (the self-host spec) is the sibling. Where a
requirement below says "as in the self-host spec", the named requirement applies
unchanged except that every self-host value is replaced by the value given here.

## Portability finding

The spec was drafted after reading every place a target repository id is handled.
The finding is normative: the implementation must re-confirm it, and a different
result stops the run (requirement 7).

- No executable component special-cases `repo.ystack`. Every target relation takes
  the id from its input and compares it: the incident validator
  (`shadow/v1/incident-record.jq`), the driver's registry lookup by
  `environment_id` **and** `target_repository_id` (`shadow/v1/reproduce.sh`), the
  assembler's first argument (`shadow/v1/assemble-materialization-input.sh`, copied
  into `target_repository_id`, `target_revision`, `source` and `base` by
  `materialization-input.jq`), the materializer's source repository argument and
  its protocol check, the core stage-request and result-truth relations, the
  qualified-identity shape (`shadow/v1/qualified-identity.jq` constrains only
  `target_revision`), the scope gates and the maintenance consumer.
- `repo.ystack` legitimately stays in the documents that describe the control
  plane, not the target: the pinned default profile's package, config, prompt and
  manifest references, and the selection scope. The assembler pins the default
  profile by bytes and by `profiles/default/v1/...` paths; those paths are in
  ystack, where the packages live. A mixed identity — packages in `repo.ystack`,
  target revision elsewhere — is what this run must record. Fixture tests
  (`scripts/test/shadow-assembler.test.sh`, target `fixture.target`) already
  exercise that mix; no real run has.
- The resolver needs nothing from the target unless its caller names a target
  object. Its only target-facing input is the caller-supplied
  `repository_context_ref`. The self-host run named ystack's own runtime tree there,
  so it never tested this. The resolver maps up to 1024 repositories and refuses a
  map with an unused or missing repository (`map-extra`, `locator-map-missing`).
- The materialization contract's fixed allowed path `.ystack/never-written` is a
  ystack-named path inside the target's namespace. With an empty patch nothing is
  written there. It does not block this run; it is recorded, not changed.
- The scope evaluator reads ystack's own `config/construction-mode.json`. That is
  the control plane's operating mode, not target state. It does not block this run.
- The real ystack-specific assumptions are in non-component material: the #373
  offline test (`scripts/test/shadow-self-host-evidence.test.sh`) hard-codes the
  bundle path, `repo.ystack`, the environment id, digests, revisions and its scope
  harness ids; and the #375 delegation rule excludes external-target execution.
  Requirements 15 and 16 generalise those two explicitly.

## Requirements

### Registry entry (own PR)

1. A separate PR, before any run, appends exactly one third entry to
   `shadow/v1/shadow-environments.json`, after the two existing ones:
   `environment_id` `env.local-macos-dummy-target`; `description`
   `Operator's local macOS checkout, a scrubbed bare copy of the external dummy target repository.`;
   `evidence_scope` `external-target`; `proof_state` `unproven`;
   `source_root_commit` `c1cacf5a1dbcc5030d66ecd300bf0b115c792e99`;
   `target_repository_id` `repo.ystack-dummy-target`. The two existing entries,
   `activation_state: inactive`, `registry_version: v1`, id, kind and schema version
   stay unchanged. The file stays one canonical `jq -S -c` text with its trailing
   newline.

2. `evidence_scope` has no validator and no enumerated set; the driver never reads
   it. A value is allowed only by being in the reviewed registry and in the places
   that pin or describe it. So the registry PR also:
   - adds the third entry to the expected registry built in
     `scripts/test/shadow-slice.test.sh` (the `registry-contents` byte pin), with its
     description passed as its own `--arg`, and updates that pass message to three
     environments;
   - updates `docs/components.md` to list three entries with their scope and state.
   No validator or enumeration is added; that stays carried forward, as in
   `work/shadow-env-self-host/spec.md`. The driver, the assembler test and the
   self-host evidence test must still pass unchanged. The self-host evidence keeps
   the old registry digest in its records; those bytes stay recoverable as the Git
   object at its frozen runtime commit, which its README names.

3. The target repository id is `repo.ystack-dummy-target`. There is no fixed
   naming rule. The schema allows any id matching `\A[a-z0-9][a-z0-9._:-]{0,127}\z`
   (`schema::id_ok` in the pinned core generation, repeated in
   `shadow/v1/incident-record.jq`, the assembler's argument check and the
   registry rule of `work/shadow-env-self-host/spec.md` R1). The `repo.<name>` form
   follows the existing `repo.ystack` convention. The same id appears in the
   registry entry, both incidents, the assembler argument, the materializer's source
   repository argument and every target-facing field of the evidence.

### Precondition gate

4. Before either real run, all of these hold, and the README records each:
   - the registry PR of requirements 1-2 is merged, and the run's frozen runtime is
     a clean checkout of a main commit that contains it and the operator-merged
     high-risk plan for this slug;
   - the #373 components are unchanged since `a73bd8c` (checked while drafting):
     the driver, the resolver entry and
     trusted launcher, the assembler, the local-git materializer, the
     declaration-only sandbox evaluator, and the scope and maintenance consumers;
   - DR-6 on #426 is accepted (recorded on #426 from the operator's direct approval);
     it covers this intake only;
   - the operator has confirmed the registry entry and the frozen incident inputs
     (requirement 16);
   - the pinned jq 1.6 and the closure helper are provisioned before the boundary,
     exactly as the self-host plan provisions them.

5. The frozen incident inputs are:
   - check `file-digest` at `src/greet.sh`;
   - post revision `e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e` (adds the `-u`
     option), whose single parent is the pre revision
     `413a2f02a46ababa987039be65089e95c1916765`; both use SHA-1 object ids and share
     the root `c1cacf5a1dbcc5030d66ecd300bf0b115c792e99`;
   - `src/greet.sh` at the pre revision: blob `bbea64b735dfc55fff76ce32c477cb0ccc5e21ef`,
     121 bytes, raw-byte SHA-256
     `c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c`;
   - `src/greet.sh` at the post revision: blob
     `2abe3e52f6c35685cc4e0adc9cd68695072bff8f`, 330 bytes, raw-byte SHA-256
     `9a3eecedc5f314cbc921ac8768b7651c3324afa355d42c90686ee8efb803dd90`.
   These were checked while drafting against both the operator's local clone and the
   forge API. Recompute the parent relation, root, blob ids and raw digests from Git
   inside the boundary before execution. A mismatch stops the run. Never hash
   re-serialized bytes or change an expectation to fit an outcome.

6. The source is a disposable, scrubbed bare copy made from the operator's existing
   local clone of the dummy target, with the self-host plan's isolated Git
   configuration, clone flags and scrub steps. It must contain both revisions,
   their ancestors and every object the materializer's closure needs. No remotes,
   credentials, alternates, replacement refs, active hooks, shallow boundary or
   external object. Scrubbing applies to the copy only, never to the operator's
   clone. If the local clone lacks an object, the operator fetches it before the
   boundary; nothing inside the boundary fetches. Source preparation and execution
   use no network and no credentials, with fresh private disjoint candidate, scratch
   and state directories, exactly as the self-host spec's requirements 9 and 10.
   Compare the copy's refs and object inventory before the first run and after the
   last; both digests go in the README and must be equal.

### Identity and run

7. Use the #373 components through their supported public interfaces, unchanged. No
   component edit, local patch, fabricated profile, copied implementation or ystack
   special case may make this run pass. If any component refuses the non-ystack
   target, or the portability finding above proves wrong, stop: that component
   returns to its own artifact gate with its own tests before this run resumes. The
   README states that no generalisation was needed, or the run does not complete.

8. The requester is the DR-5 six-field `actor_ref`, byte-shaped as in #373: role
   `operator`, principal `principal.operator.yihanzhu`, adapter instance
   `instance.operator.local-macos`, execution boundary
   `boundary.operator.local-macos`, implementation id `ystack-operator-cli`, and
   implementation version equal to this run's frozen runtime commit. Only the
   version differs from #373, because the runtime differs. It is emitted with the
   pinned `jq -S -c`, retained as `requester.json`, and its digest is pinned in the
   offline test. No provenance keys or authority reference are added.

9. One resolution is shared by both runs, through `resolver/v1/resolve-profile.sh`,
   of the real, assembler-pinned default profile at the frozen runtime:
   - `selection_ref` names this slug's operator-merged `plan.md` blob at the frozen
     runtime commit, in `repo.ystack`;
   - `repository_context_ref` names the dummy target's root tree at the post
     revision (`1c173494765089b1cce2dac6e061135e7fee5c77`, recomputed before use)
     in `repo.ystack-dummy-target`, with the frozen runtime's registry bytes as its
     decision record;
   - the map therefore has exactly two repositories: `repo.ystack` (the frozen
     runtime) and `repo.ystack-dummy-target` (the disposable bare copy).
   The README records the request and map digests and the map's repository ids, not
   its local roots. The producer settings (provider `anthropic`, model
   `claude.sonnet`, effort `high`, prompt `routines/coder.md`) are recorded
   configuration, never evidence that a model ran.

10. The prerequisite stage run, control policy set copy, core package closure, duty
    evaluation and environment claim are built in the self-host plan's fixed acyclic
    order, with the prerequisite materialization on the dummy target at the pre
    revision and the claim id `env.local-macos-dummy-target`. DR-4's division applies
    unchanged (extended to this run by DR-6): the retained evaluation is
    declaration-only, the shipped all-ones verifier digest is retained and labelled
    the shipped demonstration value, and every other reference digest named in the
    self-host spec's requirement 2 must equal the SHA-256 of the real committed bytes
    it names, or the run stops.

11. Write two canonical `shadow_incident_record` documents,
    `incident.dummy-target-greet.post` and `incident.dummy-target-greet.pre`. Each
    names its revision, `repo.ystack-dummy-target`, the check, the expected digest
    `c5ddea82…274a41c` (the pre file's), `deploy_authority: none` and
    `reporter_actor_ref: actor.operator` (Yihan Zhu, who reported the incident in the
    accepted intent). The pre record's symptom says it is a control observation, not
    a second incident. `observed_at` is the real UTC time the digest was checked for
    this exercise, frozen for replay. Each run's `qualified_identity`
    (`identity.dummy-target-greet.post` / `.pre`) is built as in the self-host spec's
    requirements 12-14: references equal the assembler's emitted files, and
    `target_revision` names the dummy target at that case's revision.

12. The expected outcomes are exact:
    - post (`e7da8f7b…`): `reproduced` with `check.failed-at-revision`, observed
      digest `9a3eeced…803dd90`;
    - pre (`413a2f02…`): `no-change` with `check.passed-at-revision`, observed digest
      `c5ddea82…274a41c`.
    Both materializations are completed `no-change` with empty outputs. An
    `inconclusive` result is kept for diagnosis only and closes nothing. Run each
    tuple twice in fresh directories and require byte-identical assembler and driver
    outputs, as the self-host spec's requirement 18.

### Evidence and offline proof

13. Store the pair under `shadow/evidence/external-dummy-target/v1/` in the same
    45-file layout as `shadow/evidence/self-host-transition/v1/`: shared `README.md`,
    `verification-instructions.md`, `checksums.json`, `resolved-profile.json`,
    `requester.json`, `environment-claim.json`, `control-policy-set.json`,
    `core-package-closure.json`, `duty-evaluation.json`; the six `prerequisite/`
    documents; and for each of `pre/` and `post/` the incident, identity,
    declaration-only sandbox evaluation, materialization receipt, the assembler's
    seven outputs under `assembled/` and the driver's four under `state/`. All JSON is
    the producers' canonical bytes, never redacted or normalized. `checksums.json`
    inventories every file but itself. Every referenced document is recoverable from
    this directory or from a Git object the README names. Do not commit the bare
    copy, candidates, scratch, binaries, credentials, maps or absolute paths.
    `verification-instructions.md` is the only hand-written document an identity
    binds, as in the self-host spec's requirement 14.

14. The README follows the self-host README's sections: what this is and is not;
    dependencies and frozen runtime; provisioning; the two input tuples; shared and
    per-case digests; source integrity; repeatability; unsuccessful attempts; capture
    limits; replay recipe; verification. It also states the portability result: which
    fields name `repo.ystack` and why, and that every target-facing field names
    `repo.ystack-dummy-target`.

15. The offline integrity test is one harness shared by both bundles. Generalise
    `scripts/test/shadow-self-host-evidence.test.sh` so every bundle-specific value
    (directory, repository id, environment id, incident and identity ids, revisions,
    path, digests, requester and closure pins, runtime commit, scope-harness ids)
    comes from a per-bundle table, and run every check for both bundles. For the
    self-host bundle no check may be removed, weakened or renamed, and its pass
    count must not drop; the PR shows the before and after pass lines. For the new
    bundle the harness proves, offline and without network, credentials or a model:
    - inventory and digests, canonical JSON, incident validation, identity and
      reference equality, exact revisions and outcomes, empty patch in both input
      locations, network deny, no-change materialization, trace seal and result
      reference, the retained sandbox evaluation and its marker, and requirement
      10's placeholder division, all as the self-host spec's requirement 15;
    - portability: every `target_repository_id`, `target_revision`,
      `git_revision_ref`, materialization revision and source-tree revision names
      `repo.ystack-dummy-target`; `repo.ystack` appears only inside the profile,
      manifests and resolved bindings and in the selection scope; the resolved
      profile's repository context names the target tree;
    - the requester is exactly requirement 8's six fields with its pinned digest;
    - the step-8 scope evaluator (inactive compatibility harness, scope for
      `repo.ystack-dummy-target` requiring `env.local-macos-dummy-target`) and
      `maintenance/v1/incident-to-eval.sh` accept both unchanged records, with
      family `stale-moved-artifacts`, post `{accepted, stale}`, pre
      `{accepted, completed}`; cross-pairing fails; and the consumers classify the
      run as unqualified and not proposable, as the self-host spec's requirements
      2, 16 and 17;
    - corruption: a missing file, a changed byte in any retained document, a
      re-serialized JSON document, a swapped pre/post record, an identity or incident
      naming `repo.ystack` as target, and a checksum mismatch each fail.
    A separate sibling copy of the 1,200-line test is not allowed; a shared harness
    is what proves the two bundles pass the same checks.

16. The manager may run the session on the operator's Mac under the #375 delegation
    rule, extended to this intake by DR-6: same machine and account, the manager
    session only, never CI, a remote or cloud session, or a coder subagent. The
    README's requester-provenance section names the executor, machine, account,
    session and DR-6 as the source; `requester.json` stays the operator identity.
    The README quotes, word for word with their comment or session reference, the
    operator's direct confirmation of (a) the registry entry of requirement 1 and
    (b) the frozen incident inputs of requirement 5 with the two `observed_at` times.
    Each must come from the operator in chat or on #426. A manager note, audit read
    or silence supplies neither.

17. Append every evidence file to `ci/required-files.txt`. Add a component
    documentation entry, a README index row and a RESTORE block, as #373 did.
    Restoring preserves evidence; it runs nothing and registers, activates or
    qualifies nothing.

18. Completion means both real outcomes, repeatability, and the offline and consumer
    proof are committed together, reviewed and operator-merged. Final proof names the
    implementation head, frozen runtime and dependency commits, commands, outcomes,
    reason ids, reference checks, repeatability comparisons and consumer results.
    The records keep `authority: none`, `deploy_authority: none`, `shadow: true`,
    `activation_state: inactive` and unavailable qualification exactly as emitted.

## Design

Order: this spec (G2); one high-risk plan covering both PRs (independent review,
operator merge); the registry PR (requirements 1-3); the operator's confirmations;
the delegated run against a frozen runtime that contains the registry and plan; the
evidence PR (requirements 13-17). The registry is its own PR because it changes a
security-relevant allow list and a byte pin on its own review, and because the run
must record the registry digest it ran under, which must be on main first. The
evidence PR follows directly under the same plan; no second plan is needed unless a
stop condition fires.

The evidence PR is one concern: the first external-target evidence pair and its
shared offline verification. Its parts are the 45 retained files, the generalised
test, the manifest lines and the docs entry. The harness change is made first on the
self-host bundle alone (same pass lines before and after), then the new bundle's
table is added.

## Out of scope

- Any write to the target, any forge mutation, network inside the boundary,
  credentials, a model call, qualification, activation of this or any environment,
  and a live scope.
- Any change to the driver, resolver, assembler, materializer, evaluator, consumers,
  profile or core contracts. A needed change goes back to that component's gate.
- A `proof_state` change. Both new and existing entries stay `unproven` in this
  intake, as in #373. Deciding what proves an environment is a later reviewed change
  citing this evidence; it is carried forward.
- A validator or enumeration for `evidence_scope` / `proof_state` (carried forward).
- A Linux environment, a SHA-256 repository, or another external target.
- Any claim that step 7 as a whole, step 8 or the Roadmap is complete. This run
  supplies the external-target half of step 7's evidence; closing step 7 is a
  Roadmap record with its own review.

## Areas of concern

Risk is **high**: it moves a security-sensitive workflow to real history of an
external repository, edits an execution-environment allow list, and records
execution and identity claims. G2 accepts this spec and that value. A separate,
independently reviewed, operator-merged high-risk plan must come before the
registry PR, the run and any code. This spec authorizes no execution.

The intent says no component may change, and asks whether the pieces special-case
ystack. The finding above says none do, so no component generalisation is required.
Two things are generalised and named: the offline test (requirement 15) and the
delegation rule (requirement 16). The #375 plan's rule says it authorizes no
external-target execution; this spec relies on DR-6 to extend it, and the plan must
quote that basis. If the operator reads DR-6 as not covering delegation, the operator
runs the session by hand.

`repository_context_ref` naming the target (requirement 9) is a design choice: it is
the only way the resolver's half of the portability question is tested at all.
Naming ystack's runtime tree instead would pass trivially and prove nothing about the
resolver. If the resolver refuses the bare copy as a map root, that is a stop under
requirement 7, not a reason to fall back silently.

No real sandbox exists. As in #373, the retained evaluations are declaration-only
and never enforcement proof; `work/real-sandbox-boundary/spec.md` remains the record
of what step 8 needs.

The dummy target is public and small (9 commits). Its history could be rewritten on
the forge later; the evidence binds object ids and raw bytes, and the offline test
never needs the forge.

Open questions from the intent, answered: the id is `repo.ystack-dummy-target`,
allowed by the schema's id charset and recorded by the registry, its byte pin and the
component docs (requirements 2-3). Two PRs under one plan (Design). `proof_state`
stays `unproven` (Out of scope).

`review_size` for the implementation (evidence) PR:
`review_size: accepted-exception` — 1,000-1,400 net lines, one concern (the first
external-target evidence pair and its shared offline verification). Evidence from
#373 (51 paths, +1,706/−1): about 290-340 lines for the README and verification
instructions, 45-60 canonical document and inventory lines, 45-50 manifest lines,
40-70 docs lines, and 550-850 lines for the harness generalisation plus the new
bundle's table and portability and corruption checks, instead of a 1,200-line
copy. Canonical JSON is wide, so review reads the expanded documents too. The
registry PR and this spec PR are within the soft budget and need no record. The
waiver covers the line signal only; CI, independent review and operator merge stay
required. An unexplained overrun returns to the plan gate.

