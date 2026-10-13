---
intent-blob: 71621be7e5f96c254ad470d593840fe84ad20904
risk: high
drafted: 2026-10-13
---

# Spec: harden scope qualification evidence core

Tracks #541. This is the nonterminal core delivery of Step 8 child 6. It
authenticates required-environment evidence and accepts the complete no-change and
withheld-write record forms at one exact revision. It changes no authority and
does not implement later-revision coverage.

## Requirements

### R1. Fixed inputs, record forms, and origin

1. Keep the existing scope document, shadow evidence set, eval dashboard, risk,
   kill and duty evaluations, and construction-mode marker. Snapshot their
   canonical bounded bytes once for an evaluation and bind every use by measured
   SHA-256.
2. A claimed shadow record must resolve to one completed child-5 consumer bundle.
   Read `bundle.json` and every listed file from one held directory. Require the
   exact sorted inventory, sizes and digests, then recheck the held and named
   objects before use and before success. A checksum inventory alone proves no
   origin.
3. Dispatch only these three forms:
   - no `record_form`: a legacy declaration, readable but unable to satisfy an
     authentic receipt or native qualification;
   - `record_form: "enforced-reproduction.v1"`: the complete 29-evidence-file
     child-5 reproduction bundle plus `bundle.json`, with a `no-change`
     materialization and no `write` field; or
   - `record_form: "withheld-write.v1"`: the complete child-5 write bundle, with a
     `changed` materialization and the exact R3 write section.
   Missing, extra, inferred or cross-form fields refuse. Parsing never promotes a
   legacy declaration to an enforced form.
4. Receipt validation reruns the existing fixed sandbox-receipt checker over the
   retained request, expectation, receipt, origin observation and sandbox
   evaluation. Policy, decision, policy set, environment registry and accepted
   identity set come only from the evaluator's fixed repository package. The
   caller cannot replace them.
5. The bundle copies of every fixed input must byte-match that current package.
   The record, completion marker, qualified identity, receipt check, materializer
   response, consumer provenance and, for a write, write section must bind those
   same bytes by their complete references and digests.
6. Accept source, candidate, parent, tree, path, mode and blob facts only from a
   bounded snapshot of the target's bare Git object database. Use the existing
   fixed read-only commands with replacement objects, hooks, filters, prompts and
   repository or global configuration disabled. Caller-supplied Git facts are not
   evidence.
7. Authenticate sandbox origin through the existing child-5 consumer and
   `controlled-storage.v1` contract. The fixed root-owned anchor selects the
   reviewed host-supervisor package, physical interpreter, dedicated writer
   principal, consumer group, store root and store id. Apply the existing owner,
   group, mode, ACL, link, no-follow, exact-inventory, bounded-read,
   held-descriptor and before/after metadata checks to every object.
8. The interactive caller and consumer cannot write that store. Only a fresh,
   complete recheck may produce authenticated origin. A copied origin label,
   archived observation, caller-created directory, supplied JSON or matching
   digest does not authenticate the bytes.
9. Do not add a source provider, collector, network reader, credential, trust flag,
   generic evidence registry or second evaluator. This core reads only the
   accepted fixed package, target Git objects and existing child-5 controlled
   storage.

### R2. Authentic enforcement and native qualification

1. A shape-valid declaration stays readable but contributes no satisfied required
   environment. It refuses qualification with
   `scope.sandbox-receipt-missing`.
2. Every environment required by the scope needs exactly one complete child-5
   bundle. Its fixed receipt check must be valid and its enforcement verdict must
   be `satisfied`.
3. The receipt, expectation, sandbox evaluation and shadow record must agree on
   attempt, candidate, environment, accepted set, policy, decision, policy set,
   evaluator, payload and store identities under the accepted receipt contract.
4. Both the fresh controlled-storage origin check and fixed receipt checker must
   pass. A recomputed document digest cannot replace either check.
5. The environment id selects exactly one entry in the current
   `shadow_environment_registry` and exactly one entry in the current
   `sandbox_accepted_identity_set`. Duplicate, missing, foreign or stale entries
   refuse.
6. The registry entry must say `proof_state: "native-qualified"`. The accepted
   entry and receipt identities must match field for field. A caller field named
   `native-qualified`, `trusted`, `checked` or `verified` grants nothing.
7. Registry and accepted-set changes remain outputs of the accepted VM
   qualification process. This concern defines no native test, runtime exception,
   alternate identity source or accepted production identity.
8. CPU and wall enforcement remain `none`. Native qualification remains
   `BLOCKED`, and the accepted production identity set remains empty. The shipped
   state cannot satisfy this requirement.
9. Any required environment missing the complete evidence above produces a
   deterministic not-proposable result with
   `scope.sandbox-receipt-missing`. Malformed or ambiguous evidence remains a
   closed error.

### R3. No-change and withheld-write forms

1. The existing no-change materialization keeps its shape and meaning. A complete
   `enforced-reproduction.v1` record has outcome `no-change`, preserves the full
   29-file child-5 evidence set and contains no `write` field. Legacy no-change
   evidence gains no authenticity by remaining readable.
2. Accept outcome `changed` only in a complete child-5
   `withheld-write.v1` record. Its materialization names the fixed local Git
   materializer, one source commit and tree, one candidate commit whose sole
   parent is that source commit, the candidate tree, and the exact retained stage
   result and materializer response.
3. The write section has exactly `bundle_ref`, `scope_id`, `workflow_id`,
   `task_class`, `write_set`, `publisher_request`, `admission`, `publication`, and
   `post_write_verification`.
4. The only write pair is
   `workflow.shadow-evidence-commit` with
   `task.commit-shadow-evidence`. Scope, repository, incident, source revision,
   qualified identity, request, result and bundle references must resolve to the
   same held bytes.
5. Each write-set row has exactly `path`, `mode`, `sha256`, `git_blob_oid`, and
   `add_only`. Rows are sorted and unique. Every row is add-only mode `100644`.
   Its raw-byte digest and Git blob id must equal the held candidate blob.
6. The rows must equal child 5's fixed 32-file request inventory and the actual
   source-to-candidate additions. Each path separately matches at least one scope
   `allowed_paths` glob and passes the existing protected-path predicate. The
   globs do not replace or need to equal the exact rows.
7. No source path may already exist. No existing leaf, mode, blob or unrelated
   sibling or subtree may change. Ancestor tree object ids needed only to add the
   accepted leaves may change. No other tree change is allowed.
8. Rebuild and compare the exact bounded text patch from the held rows. It contains
   no binary, symlink, submodule, rename, deletion, hidden extra path, unsafe alias
   or protected path.
9. The publisher request has exactly one target repository, the fixed evidence
   branch for the incident, source revision as base, actual candidate tree, fixed
   title and retained body digest. Its canonical digest equals
   `admission.request_sha256`.
10. Admission is exactly `state: "checked"`, `effect: "none"`, plus matching
    request and write-set digests. Publication is exactly
    `{state:"withheld", reason_id:"shadow.write-not-published"}`.
11. Post-write verification repeats the source revision, actual candidate tree and
    exact write set. It is a verification plan only. Nothing is published or
    written to a target.
12. The candidate contains only the completed evidence bundle and unchanged
    deterministic seed output accepted by child 5. The child-5 completion marker
    is the last durable output. A partial directory, early marker, failed consumer,
    simulated production bundle or drifted fixed input is not evidence.
13. A missing or different relation makes the changed form malformed. The
    evaluator does not fall back to no-change, infer another form or accept a
    subset.

### R4. Exact-revision classification and compatibility

1. Every scope keeps the existing exact target-revision and full qualified-identity
   checks. Evidence from another revision refuses. This core records no
   `coverage_base`, accepts no later revision and claims no parent R3 coverage.
2. Only the exact R3.4 workflow/task pair is a legal write class. It may consume a
   complete enforced no-change or complete withheld-write form. Record contents or
   a caller boolean cannot choose the class.
3. A partial or mixed pair is malformed. It cannot fall back to read-only.
4. A scope matching neither field remains read-only. It keeps its existing
   exact-revision, full-identity and no-change predicates, and also requires R2's
   authentic sandbox receipt. It cannot consume a changed or write form.
5. Preserve every existing scope, eval, duty, kill, risk, mode, protected-path,
   request, profile, materialization and gate-binding predicate not explicitly
   tightened here.
6. Issue #544 must later implement the complete parent R3 result: authenticated
   default branch and first-parent descent, own-publisher evidence changes,
   complete protected configuration, CI and branch-rule history, the closed
   coverage identity, fresh per-attempt binding and the original 30-day limit.
   Both deliveries must pass before child 6 completes or child 7 starts.

### R5. Results and authority

1. Add `scope.sandbox-receipt-missing` to the closed policy reason vocabulary with
   the meaning in R2. Do not add or emit a positive enablement result.
2. `scope.enablement-stale` remains assigned to the later parent coverage and
   enablement work. This core does not implement it, fetch the ystack tip, read an
   enablement record or grant tip-reading authority.
3. Shape-valid declarations and no-change records stay readable. Missing authentic
   facts produce a deterministic not-proposable evaluation. Malformed documents,
   duplicate identities, invalid canonical bytes and runtime failures remain
   closed errors and never become proposable.
4. Evidence output records only the measured child-5 bundle, receipt-check, origin,
   registry, accepted-set, Git snapshot and materialization/write refs needed by
   R1-R4. It contains no coverage observation, source request, source receipt,
   coverage age or later-revision success field.
5. Output stays inactive and observation-only, with authority `none`, authority
   effect `none`, enablement false and qualification unavailable. It carries no
   grant, activation, credential, publisher capability or production identity.

### R6. Acceptance proof

1. Test the real evaluator, child-5 consumer, fixed receipt checker and fixed Git
   reader. Do not duplicate their predicates in a test-only implementation.
   Preserve every existing scope-qualification case whose required outcome is not
   changed here.
2. Receipt and registry cases include one genuine same-contract fixture control;
   every required environment; declaration only; missing bundle, receipt, origin
   or checker output; wrong attempt, candidate, environment, policy, payload or
   store; fixed-input drift; registry `unproven`; empty, absent, duplicate or
   foreign accepted entry; forged satisfied/native labels with recomputed JSON
   digests; copied origin; and every cross-form masquerade.
3. The genuine origin control uses the existing fixed child-5 store writer under a
   dedicated fixture writer principal and the real consumer under a distinct
   read-only identity/group. Root-controlled fixture configuration pins reviewed
   package bytes, store and identities. The writer creates the exact bounded
   attempt; the consumer performs the real owner, ACL, link, descriptor and
   metadata checks. The caller never writes store objects or supplies accepted
   facts.
4. That fixture proves the existing consumer contract only. Its identities stay in
   disposable test data and never enter production registry or accepted-set files.
   If CI cannot supply the required principal separation, G3 remains blocked until
   an authorized environment can run this positive; permanent refusal, a same-UID
   directory, copied metadata or a mock origin cannot count as proof.
5. Form cases include complete enforced no-change and withheld-write outputs from
   the fixed child-5 package, plus missing, extra, inferred and cross-form fields.
   Fixed-package fixtures are legal only when their source, interpreter, helper,
   native release, policies, materializer, verifier, bundle inventory and current
   repository bytes pass the same checks as the real consumer. A fixture flag or
   alternate parser cannot bypass those checks.
6. Write cases cover every R3 field and relation. Include the exact 32-file legal
   write set; deterministic repeat; missing, extra, reordered or unmatched path;
   changed source, parent, tree, blob, mode, body or request; existing or protected
   path; unrelated sibling or subtree change; publication other than withheld;
   post-check mismatch; partial directory; and marker-before-completion. A legal
   new leaf with only its necessary ancestor-tree changes passes.
7. Classification cases pair the fixed workflow and task with legal no-change and
   withheld-write positives. Reject each partial and mixed pair. A neither-field
   read-only scope has an exact-revision/full-identity/no-change positive and a
   cross-revision refusal. Added record fields or caller flags cannot change class.
8. Run the complete scope-qualification suite, child-5 consumer and write suites,
   sandbox-receipt suite, materializer and fixed-digest suites, relevant schema and
   integration suites, and required CI. Quick CI is not full-suite proof.

## Design

The existing scope driver remains the only public entry. It snapshots inputs,
measures fixed components, invokes the current scope program, rechecks every byte
and emits one canonical evaluation. It gains no command registry, network client,
credential input, source-provider interface or caller-selected trust flag.

A private evidence reader consumes one completed child-5 directory. It reuses the
existing bundle rules, controlled-storage origin checks, fixed receipt checker,
materializer protocol, fixed Git reader and qualified-identity checks. It passes
only measured facts and canonical digests to the scope program.

The scope program dispatches the closed record form, authenticates every required
environment, validates exact revision and identity, validates either complete
no-change or the fixed-pair withheld-write form, then runs every unchanged
proposable predicate. Missing authenticity maps to
`scope.sandbox-receipt-missing`; malformed relations retain closed failure.

Implementation is high risk and requires a separately accepted plan. The plan
records exact paths, proof and an evidence-based review-size classification before
code.

## Out of scope

- Parent R3 later-revision coverage, source authentication, request correlation,
  freshness and `scope.enablement-stale`; these remain mandatory in #544.
- A forge or target source provider, network access, credential, collector,
  production identity, generic provider framework or new host responsibility.
- Native qualification standards, VM execution, installation or accepted
  production identity changes.
- Enablement, ystack-tip reads, target execution or write, publication,
  post-publication action, activation, deployment or production use.
- A public fixture switch, caller-selected trust, second evaluator, or schema field
  that grants authority.

## Areas of concern

- **Risk is high.** This tightens identity, provenance and qualification controls.
  A separate reviewed plan must land before implementation.
- **Production remains blocked.** CPU and wall proof is absent, native registry
  entries are unproven and the accepted production identity set is empty. Fixture
  success cannot close those gaps.
- **Compatibility is limited.** Legacy and read-only records remain readable and
  exact-revision bound. Readability does not make them authentic or writable.
- **Child 6 remains open.** This core cannot claim complete revision coverage.
  #544 remains mandatory before child 6 completion and child 7.
