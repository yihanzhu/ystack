---
intent-blob: d2ada8661ac87c6c9f1abfc8a751a38c8aeb33cf
risk: high
drafted: 2026-10-13
---

# Spec: authenticate later-revision scope coverage

Tracks #544. This is the mandatory second delivery of Step 8 child 6. It adds
the complete parent R3 later-revision rule after the #541 core has authenticated
the qualifying and current child-5 evidence. Both deliveries must pass before
child 6 completes or child 7 starts.

## Requirements

### R1. Classification and fixed evidence

1. Apply revision coverage only when `workflow_id` is
   `workflow.shadow-evidence-commit` and `task_class` is
   `task.commit-shadow-evidence`. A partial or mixed pair is malformed. A scope
   matching neither field keeps #541's exact-revision, full-identity and
   no-change rules. Record fields and caller booleans cannot select the class.
2. A covered write evaluation has one qualifying evidence set at
   `coverage_base` and one fresh current evidence set at revision R. Both sets use
   #541's authentic child-5 bundle, controlled-store origin, fixed receipt,
   native registry and complete record-form checks. The qualifying set is fixed;
   the current set is produced for this evaluation.
3. The scope records one exact coverage block: `coverage_base`,
   `coverage_rule_version: "scope-coverage.v1"`, and sorted unique refs to its
   qualifying shadow records. Existing `shadow_evidence_refs` name the current
   records. All refs resolve by raw digest in the same held shadow set and bundle
   root. This concern extends the closed `workflow-scope.jq` body schema to admit
   exactly this block for the fixed write pair and to forbid it for a scope matching
   neither field. The existing public `SCOPE` document remains the input; no new
   command argument, input file, caller-supplied source fact or authority is added.
   Shape acceptance is not source authentication.
4. Every required environment has exactly one qualifying record and one current
   record. Their environment ids, registry rows and accepted identities agree.
   Missing, duplicate, foreign, unproven or cross-form records refuse.
5. The evaluator reads the scope, shadow set, eval dashboard, risk, kill, duty,
   marker, completed bundles and bare Git snapshot through the existing #541
   input and private-reader boundaries. It adds no caller path for forge facts,
   source receipts, normalized observations, credentials, endpoints or trust flags.
6. `evaluate-scope.sh` continues to snapshot and validate `SCOPE` with the measured
   physical `workflow-scope.jq` before `scope-gates.jq` runs. For the fixed write
   pair, the gate derives the coverage anchor and qualifying refs only from that
   validated block, then requires them to match the authenticated qualifying
   records and Git facts. No caller field can mark a candidate attribute or source
   fact authentic.

### R2. Closed coverage identity

1. Compare one closed coverage identity between each qualifying record and its
   current record. It contains exactly:
   - scope id, `workflow_id`, `task_class` and `model_request`;
   - `adapter_config_refs`, `prompt_refs`, `skill_refs` and
     `verification_instructions_ref`;
   - resolved profile `profile_ref`, `profile_source`, `selection_ref` and the
     complete existing `bindings` array;
   - execution environment id and canonical registry entry bytes;
   - control policy-set ref and the sandbox and scope policy bytes bound by the
     evidence; and
   - `coverage_base` plus `coverage_rule_version`.
2. Preserve every existing resolved-profile binding exactly. In particular, the
   forge binding keeps its sole `core.forge.materialize-candidate.v2` capability.
   Coverage source reading is not a core stage operation, adapter capability,
   resolved-profile binding, duty capability or stage-request operation. It may
   not add, replace or rename that capability.
3. `model_request` remains in the identity although this workflow invokes no
   model. Any identity difference returns to the shadow gate. A caller-supplied
   identity digest cannot replace the field-by-field comparison.

### R3. Evaluator-owned current request

1. After authenticating both bundle sets and snapshotting the bare Git facts, the
   evaluator creates a fresh 32-byte random nonce. It derives a unique attempt id,
   constructs one canonical `coverage_source_request` and writes one canonical
   `coverage_source_expectation` exclusively in its private workspace. It fsyncs
   both files and their directory before any source process starts, then retains
   read-only descriptors until the evaluation ends.
2. The request envelope is schema 1, kind `coverage_source_request`. Its body has
   exactly:
   - attempt id, nonce, repository id, `coverage_base`, evaluated revision R and
     `coverage_rule_version`;
   - refs and measured digests for the scope and seven original evaluator
     documents;
   - sorted qualifying and current shadow-record refs;
   - current resolved-profile, stage-request and stage-result refs taken from the
     mutually bound scope, risk and duty documents;
   - current materialization, publisher-request and post-check refs measured from
     the authenticated current child-5 bundle;
   - the qualifying receipt refs and the bare-Git observation digest; and
   - the fixed source package ref and source accepted-set ref selected by the
     root-owned source configuration.
3. The expectation contains the attempt id, nonce, complete request SHA-256,
   scope ref, coverage anchor, current revision, current stage/profile/result refs
   source package ref and source accepted-set ref. None is accepted from the
   source response.
4. The evaluator starts the one fixed private source operation with these held
   request bytes. The operation cannot accept raw facts, normalized facts,
   endpoint names, host, credential, executable path, provider id or a trust flag
   from the request or environment.
5. A returned payload request must be byte-identical to the held request. Its
   receipt must bind that request digest, nonce and attempt id. The store attempt
   id is the same value. A second evaluation creates a different nonce, request
   and expectation; replaying the first evaluation's genuine attempt therefore
   refuses before its facts are considered.
6. A failed launch, duplicate nonce or attempt, changed expectation, late request
   write, timeout, nonzero source result, malformed output or uncertain reap
   fails closed. No response may create or alter the evaluator's expectation.

### R4. Fixed source boundary and origin

1. Reuse the existing root-owned sandbox installation anchor, dedicated
   supervisor principal, consumer group, controlled store and immutable package
   checks. Add one optional closed source configuration for the private operation
   `coverage-read.v1`. An absent source configuration is a normal fail-closed
   production state. It does not change existing sandbox launches.
2. This explicitly extends the trusted host-supervisor package with one read-only
   source operation. It does not create another trust root or share the supervisor
   principal with another process. The root-owned configuration fixes the source
   package bytes, operation version, finite endpoint vocabulary, collector bytes
   and a separate canonical `coverage_source_accepted_identity_set`. The caller
   cannot select them. The sandbox environment accepted set keeps its existing
   schema and meaning.
3. The production source provider, credential, network route, installation and
   accepted production source identity are absent. This concern implements the
   finite consumer and inactive operation boundary. Missing source configuration,
   collector or accepted identity refuses and does not count as a positive.
   No tracked or installed production host configuration is rewritten or populated
   by this concern. Defining the optional closed fields and validating a disposable
   fixture configuration does not authorize creating its fixed path, installing a
   package or changing a runtime host.
4. The source operation owns the controlled-store write. The interactive caller
   and evaluator consumer use distinct identities and cannot create or modify a
   store object. Apply the existing owner, group, mode, ACL, link, no-follow,
   exact-inventory, held-descriptor, bounded-read and before/after metadata checks
   to the source attempt.
5. The exact attempt inventory is:
   `receipt.json`, `payload/request.json`, `payload/raw-manifest.json`,
   `payload/observation.json`, and consecutive `payload/raw/0000` through
   `payload/raw/NNNN`. There is no stderr file, alternate marker, arbitrary
   sidecar or caller document. The receipt is the last durable file.
6. Permit at most 128 raw pages, one MiB per page, 64 MiB total raw bytes and one
   MiB for each request, receipt, manifest and observation. Page names are
   consecutive and the manifest is sorted. Reject extra, missing, duplicate,
   truncated or oversized content before normalization.

### R5. Source receipt and raw facts

1. `receipt.json` is one canonical schema-1
   `forge_coverage_source_receipt`. Its body has exactly operation and version;
   store and attempt ids; request digest; source identity; query; raw-manifest and
   observation digests; started and completed UTC times; outcome; and effects.
   Operation is `coverage-read.v1`, outcome is `complete`, and effects are exactly
   `read-forge-metadata` with no target write, publication or authority effect.
   The trusted host supervisor, not the collector or caller, writes the started
   and completed times when it owns the source attempt.
2. Source identity contains the measured host-supervisor, source package and
   collector digests plus one accepted-source-identity ref. The installed
   `coverage_source_accepted_identity_set` must contain exactly one qualified
   entry with source id, operation version and those complete digests. The set is
   root-owned, package-bound and empty in production. A label in the receipt,
   equal digest, fixture name or existing forge binding does not qualify it.
3. Query repeats the request's repository, base, R, rule version and qualifying
   refs exactly. It also records the fixed default-branch, pull-request and
   branch-rule-history query families and their closed schema versions. The source
   operation, not the caller, chooses physical requests and pagination.
4. `raw-manifest.json` has one row per raw page with exactly query family, page
   index, request digest, response status, raw size and digest, input cursor and
   output cursor. For each family, indices start at zero, cursors form one chain,
   and the last row has the sole terminal cursor. Every required family is present
   and complete.
5. `observation.json` is rebuilt from held raw pages by the fixed package
   normalizer. Stored and rebuilt canonical bytes must match. The normalizer has
   a closed schema and cannot call the network, read caller files or load a
   provider plugin. Authentication comes from the source principal and raw-page
   chain, not from normalization.
6. The consumer compares request, receipt, manifest, pages and observation, then
   rechecks every held object and emits a fresh `controlled-storage.v1` origin
   observation. Copied bytes, archived origin, supplied JSON or recomputed hashes
   remain unauthenticated outside this channel.

### R6. Complete history and forge relations

1. The normalized observation has exactly `repository`, `default_branch`,
   `branch_snapshots`, `first_parent_commits`, `publisher_pull_requests`, and
   `branch_rules`. Repository contains the logical repository id and the source's
   immutable repository node id. Default branch contains its name and immutable
   branch node id. Snapshots are exactly `baseline` and `current`, each with branch
   node id, commit id and source observation time.
2. Each first-parent row has exactly zero-based index, commit id, parent commit id
   or null for the base row, and tree id. Each publisher-PR row has exactly source
   PR node id and number, publisher identity ref, base/head/merge commit ids,
   merged state and time, source branch, scope id, changed paths and retained
   publisher-request digest. Arrays are sorted by their fixed keys and unique.
3. Branch rules contain baseline and current arrays plus an event array. A rule
   row has exact source rule id, target pattern, enforcement state, sorted bypass
   actors, rule type and canonical bounded parameters. Include every rule that
   applies to the default branch, not only the four required rule kinds. An event
   has exact source event id, event time, actor identity, operation, rule id and
   before/after canonical rule-state digests. Events are in source order and
   unique.
4. Independently derive the Git commit, parent, tree, path, mode and blob facts
   from the held bare repository with #541's fixed Git reader. Require R to be the
   authenticated default-branch tip at the completed source observation and a
   first-parent descendant of `coverage_base`. The commit list must equal the Git
   first-parent interval in order, with no gap, duplicate or alternate parent.
5. For every commit in the interval, compare its own Git tree. No commit may
   change `.ystack/` or CI workflow files. Checking only endpoint trees is
   insufficient; A→B→A changes refuse.
6. Under `ystack-evidence/`, permit only additions associated with this scope's
   own publisher pull requests. Each accepted PR row binds repository, PR id,
   fixed publisher identity, base, head, merge commit, merged state, scope id,
   changed paths and the retained child-5 publisher request. The merge commit and
   actual Git changes must agree. Foreign, direct, rewritten or ambiguous changes
   refuse. Ordinary source changes outside these protected sets remain allowed.
7. Require one continuous branch-rule event interval from the authenticated
   baseline state through the current state. Replaying the events must reproduce
   both endpoint states. The complete sorted set of every rule applicable to the
   default branch must equal the baseline after every event and at the current
   endpoint. Reject any rule addition or deletion and any change to source rule
   id, target pattern, enforcement state, bypass actors, rule type or canonical
   parameters. Deletion, non-fast-forward, pull-request and required-status-check
   protection are the minimum required enforcing rule kinds at every state; they
   are not an exhaustive list of rules held unchanged. A permanent A→B change and
   a temporary A→B→A change in any fifth rule kind both refuse. Missing event
   history, an unexplained version jump or a source unable to provide the full
   interval refuses.
8. The qualifying observation compares only with `coverage_base`, its Git snapshot
   and its baseline rule state. The current observation compares only with R, its
   Git snapshot and the complete base-to-R interval. Do not require the two
   revisions, trees, intervals or observation times to be equal.

### R7. Fresh derived binding

1. The qualifying and current records share only R2's closed identity. Everything
   else is revision-derived and must be recomputed for R.
2. Current derived fields include target and materialization revisions and trees;
   candidate parent and tree; publisher base revision; stage-request source,
   repository and resolved-profile refs; resolved-profile repository ref; gate
   evidence refs; stage result; shadow record; sandbox evaluation and receipt
   refs; current source request, receipt, origin and Git observation.
3. Bind those fields to the actual held current scope, gate documents, child-5
   bundle, materialization and bare-Git facts. Preserve the existing
   `stage_request_resolved_relation_ok`, `stage_request_resolved_ref_ok`,
   materialization and gate-binding meanings. Matching the qualifying value is
   neither required nor sufficient.
4. The evaluator's fresh source request binds the same current stage, profile,
   result, materialization and R refs. Any mismatch between that request, source
   receipt, controlled-store payload or evaluated documents refuses with no
   fallback to exact-revision success.

### R8. Age, results and invalidation

1. Take qualifying age only from the original authenticated qualifying sandbox
   receipt's `timing.terminated_at`. Parse one exact whole-second UTC instant and
   compare it to the trusted host-supervisor `completed_at` in the authenticated
   current source receipt. Accept ages from zero through exactly
   2,592,000 seconds. A future time or any value greater than 2,592,000 seconds is
   stale.
2. A fresh store read, source observation, current attempt or copied timestamp
   cannot replace or refresh that original time. Lawful rereading of the fixed
   qualifying attempt remains allowed and preserves its age.
3. A changed coverage-identity field, rewrite, non-descendant R, foreign protected
   change or stale qualifying evidence returns to the shadow gate. Policy or eval
   catalog changes return through eval then shadow. Environment/runtime/image/
   verifier changes return through environment qualification then shadow. Risk,
   task, allowed paths or target changes require a new scope.
4. Use `scope.enablement-stale` for missing, incomplete, unauthenticated, replayed,
   stale or invalid later-revision coverage. Malformed shapes and runtime failures
   remain closed errors. Do not emit a positive enablement result.
5. Output remains inactive, observation-only, authority none, enabled false and
   qualification unavailable. It records measured source-request, receipt, origin,
   interval and current-binding refs only. It grants no tip read, credential,
   publisher, target write, activation or production authority.

### R9. Acceptance proof

1. Exercise the real evaluator, current-request owner, private source operation,
   controlled-store reader, fixed normalizer and Git reader. A separate parser,
   caller-written store, metadata stub or permanent refusal is not a positive.
2. Build a disposable root-owned fixture package on Linux CI and on the required
   macOS evidence host. Use a dedicated source-writer account and distinct
   read-only consumer account/group. The fixed fixture source is an authoritative
   offline forge with pinned raw repository, PR and rule-history pages inside its
   root-owned source package. The caller supplies no facts or page locator. It
   uses the same request, receipt, inventory, origin, normalization and decision
   code as the inactive production path and performs no network call.
   Root-owned fixture configuration selects the pinned pages and query families.
   The caller cannot name, replace or supply a page, cursor or observation.
   Run account, group, fixed-path and root-owned package setup only in an existing
   disposable environment where those actions are already authorized. If the
   required macOS environment is unavailable, implementation may prepare the code
   and ordinary tests, but the real positive and G3 remain blocked. A test may not
   create or install that environment under this specification.
3. The positive covers base A, ordinary source commit B, own-publisher evidence
   commit C and current R; a complete first-parent interval; stable protected Git
   paths; stable branch rules; identical closed identity; fresh current bundle and
   source request; and qualifying age at exactly 30 days.
4. Include paired negatives for another repository/default branch, non-descendant
   or second-parent path, missing commit/page/cursor, foreign/direct evidence
   change, wrong publisher/PR/base/head/merge/path, protected Git change,
   branch-rule addition/deletion or field change, a fifth rule kind's permanent
   A→B and temporary A→B→A, incomplete history, wrong source identity, caller
   copy, owner/group/mode/ACL/link swap, changed raw page or observation, and
   fixed package drift. Preserve a positive whose complete applicable rule set,
   including at least the four required enforcing kinds and one fifth kind, is
   unchanged at every event and endpoint.
5. Request cases prove a fresh second evaluation at the same R rejects the first
   genuine current attempt, while a new genuine attempt passes. Rereading the
   original qualifying attempt passes without changing `terminated_at`; test one
   second before, exactly at and one second after the 30-day boundary,
   plus future and malformed times.
6. Identity cases preserve the existing single forge materialization capability.
   Adding a coverage capability, replacing materialization with it, or claiming
   source authority through a profile binding refuses. Change every closed
   identity field separately and every current derived ref separately.
7. Classification cases cover the exact write pair, each partial/mixed pair and a
   neither-field read-only exact-revision positive/cross-revision refusal. A forged
   write or coverage block cannot change classification.
8. Run complete scope, child-5 consumer/write, sandbox receipt/launcher, core
   profile/stage/duty, materializer, schema and integration suites plus the full
   CI matrix. The exact plan must name paths and commands. Quick CI is not proof.

## Design

The existing scope evaluator stays the sole decision entry point. For a covered
write it first authenticates qualifying and current child-5 evidence and derives
Git facts. It then owns a fresh source request and expectation, invokes one fixed
private source operation, authenticates its controlled-store output and compares
the normalized forge interval with Git and current attempt facts. Jq receives only
the resulting measured observation.

The source operation is separate from the portable core forge adapter. This is
the compatibility boundary that preserves the actual profile, duty and stage
contracts. The operation uses the already trusted root anchor and supervisor
principal, but its new responsibility is explicit and limited to one inactive,
read-only protocol. A future production provider still needs its own accepted
artifact, credential/network decision, installation and source identity. Its
absence keeps production closed without making the consumer contract incomplete.

The offline fixture is a real provider for a disposable fixture forge. Root-owned
package bytes, the source principal and controlled store authenticate its raw
facts. It proves the same consumer protocol and replay boundary. It does not claim
GitHub access, a production credential, native VM qualification or a production
source identity. It does not change the existing native qualification predicate or
populate an accepted production environment.

Implementation is high risk. A separately accepted plan must select exact paths,
bound every fixed document and command, estimate readable size, and map all R9
proof before code starts.

## Out of scope

- A production forge provider, credential, network access, installation,
  accepted production source identity or native qualification.
- A mutation of an installed production host configuration, source path, account,
  group, runtime or package anchor.
- A generic provider registry, caller-selected source, public fixture flag,
  signature scheme or second trust root.
- Publisher execution, target write, enablement, activation, deployment or
  production action.
- Changes to portable core capability tables, resolved-profile bindings, duty or
  stage capability meaning.
- Read-only later-revision coverage. Read-only scopes retain exact revision.

## Areas of concern

- **Risk is high.** This extends the root-owned supervisor package with a new
  inactive source operation and changes an identity/authentication gate.
- **Production stays closed.** No production provider, credential, source identity,
  CPU/wall qualification or accepted production environment is supplied here.
- **Completeness is mandatory.** Endpoint snapshots cannot prove an interval.
  First-parent, protected Git paths and branch-rule events must cover every step,
  including A→B→A.
- **Current means current.** Store authenticity does not prevent replay by itself.
  The evaluator-owned request and expectation are required for every evaluation.
- **Child 6 remains ordered.** #541 and #544 each need accepted artifacts, plan,
  implementation, full proof and independent review before child 7 starts.
