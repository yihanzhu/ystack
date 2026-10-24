---
intent-blob: a6ea35b514ec9150aa3695a01c7d81ec5e9bd8ca
risk: high
drafted: 2026-10-24
allowed-paths:
  - work/fixed-publisher-write-contract/spec.md
---
# Spec: first fixed publisher write contract

Tracks #173. G1 is PR #698. This is design only. It authorizes no implementation.

## Requirements

| ID | Required outcome |
| --- | --- |
| R1 | One closed, portable operation publishes the Step 8 R1.4 evidence candidate on its exact new branch and opens at most one pull request. |
| R2 | Request, profile, manifest, permission and result have exact relations. Their declarations never supply an external grant. |
| R3 | The existing withheld shadow request and planned write set map without changing their bytes or claiming publication. |
| R4 | A partial, refused, cancelled or unknown write cannot become success or cause another write attempt. |
| R5 | Existing core versions, dormant publisher and default profile retain their meaning. |
| R6 | A later implementation proves the same validation path in shadow and publisher consumers, with a separate read-only post-write check. |

The operation adds only the frozen evidence bundle under one incident root. It
cannot modify, rename or delete existing paths. It cannot push the default or a
protected branch, merge, approve, label, or comment outside the pull request body.
Publisher has no model access or candidate execution. Producer, verifier, reviewer
and publisher identities and execution boundaries remain separate.

G2 accepts this contract and its high risk. Core-validator, publisher-runtime and
integration code require a separate accurate implementation intake, hash-linked
artifacts, a separately accepted high-risk plan, CI and independent review.
The sole allowed path in this stage is the frontmatter path.

## Design

### 1. Version and existing contract

Use semantic identity `core.contracts.v3` and envelope/reference `schema_version:3`
for this new operation. Reuse the five document kinds and existing canonical-byte,
limit, error, reference, profile, execution-fact and status rules. No sixth core
kind, generic operation or extension map is added. Unchanged operations keep their
existing capability IDs and meanings within v3; their document envelopes and
references are v3. V1/v2 inputs are never relabelled or silently accepted as v3.

The comparison source is the current v2 generation selected by
`scripts/core-contract.sh`. It equals the last entry (`[1].generation_id`) in
`core/v2/generation-registry.json`, whose raw SHA-256 is
`3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94`.
Its registry and all published generations remain immutable. The accepted
`portable-core-contracts/spec.md` R5 and dormant-role version rule require a new
major for new capabilities, permissions or fields. An immutable generation alone
cannot add these under v2 semantics. V3 carries only this publisher delta; it
introduces no migration framework or redesign of other operations. V2 publisher
stays `protected-dormant` with empty capabilities.
The default dormant manifest stays empty. Its `squash-change-request` observation
normalizer remains inactive, authority-free, and unrelated to this operation.

A later accepted implementation must allocate an unused generation under `core/v3/`
through the existing immutable-generation and assembly gates. It must prove the
whole v3 package privately before any public selection. There is still one public
core command with the existing three validation forms. This spec selects no new
generation ID, wrapper switch, default profile, installed package or live caller.
An incompatible v2 consumer cannot use v3 until its own accepted migration binds
complete v3 profile/manifests, requests, results and references. Historical v2
records retain v2 validation. A version mismatch refuses, never falls back.

### 2. Closed registry delta

| Registry entry | Exact value in v3 |
| --- | --- |
| Capability | `core.publisher.publish-evidence.v3` |
| Role / execution | `publisher`, protected; `deterministic` only |
| Argument shape / outcome family | `publish-evidence` / `change` |
| New permission | `core.perm.evidence-publication.create.v3` |
| Permission resource | `exact-evidence-publication` |
| Resource actions | `create-branch`, `open-change-request` |
| Required and allowed evidence | `deterministic` only |

The publisher's sole capability is this entry. The exact sorted permission set is
`core.perm.evidence-publication.create.v3`, `core.perm.evidence.write.v1`,
`core.perm.target.read.v1`. The first permission denotes the compound operation,
not two independently callable capabilities. Its resource is the exact repository,
incident, scope, new branch, base, candidate commit/tree and pull request content
bound below. Evidence write remains append-only within current-attempt evidence.
Target read retains its existing exact-target meaning. No scratch, candidate write,
candidate execution, model, unrestricted network or credential permission is added.

A v3 publisher manifest can offer only this capability and these permissions for
this binding. The profile requests that exact set, with empty skills/tools and no
model or prompt fields. Existing protected-role separation applies to binding,
instance, principal, execution boundary and authority scope. The request must select
that exact resolved binding. Support, request, external grant and observed use are
four separate facts. The resolved profile is still a supplied claim.

### 3. Request and supplied bytes

Use a normal v3 `stage_request`. Its workflow is `workflow.shadow-evidence-commit`,
task class `task.commit-shadow-evidence`, and stage `stage.publish`. Its present
`target_revision` and `base` are equal to the accepted shadow base. `source` is the
present candidate root-tree artifact. All Git references name the same repository
and hash algorithm. Candidate commit differs from base. `grant_ref` and
`qualification_ref` are required for this operation; core checks only their shape.

`operation.arguments` has exactly the following fields; none is optional:

| Field | Type and relation |
| --- | --- |
| `incident_id` | Existing core ID; additionally matches `[a-z0-9][a-z0-9._-]{0,127}`, contains no `..`, and ends in neither `.` nor `.lock`. |
| `scope_id` | Existing core ID, equal to the admitted shadow scope. |
| `branch` | Exactly `ystack/evidence/` plus `incident_id`. |
| `candidate_input_id` | Names one root-tree Git artifact input, exactly equal to `source.value`. |
| `body_input_id` | Names one content artifact input of media type `text/plain`. |
| `shadow_input_id` | Names one content artifact input of media type `application/json`, containing the complete retained write record. |
| `title` | Exactly `Shadow evidence: ` plus `incident_id`. |
| `write_set` | The sorted unique rows specified below. |
| `publication_contract` | Existing delivered scope of purpose `output-contract`, naming the accepted contract's exact supplied text/JSON input. |

All three input-ID fields use the existing core ID type.
The three named data inputs are distinct and distinct from the existing finish,
verification and publication-contract instruction inputs. Each resolves exactly
once. Finish and verification instructions keep their existing delivered-scope
rules. Text is data; it cannot change the operation, paths, permissions or gates.
All referenced bytes are delivered through the caller-owned bounded input seam;
no content-store, pathname, command or URL authority follows from a content ID.

A write-set row is exactly `{path,mode,sha256,git_blob_oid,add_only}`. Mode is
`100644`, `add_only` is `true`, SHA-256 is lowercase 64-hex, and the Git blob ID
is lowercase hex with the base algorithm's length. Rows sort by `path` and never
repeat a path.
Each path passes core `repo_path_ok`, is at most 4096 UTF-8 bytes, and is directly
under `ystack-evidence/<incident_id>/` with one nonempty filename component.
Core bounds the array to 1–256 rows. Admission narrows it to the selected shadow
form's complete closed inventory: 32 files for `withheld-write.v1`, or 33 for
`withheld-write-policy.v1`. The latter adds only `scope-policy.json`. These are
existing inventories from `shadow-consumer-integration` R7, not configurable lists.
No files may be omitted or added to make a candidate fit a limit.

Core checks declared identities and relations. Shared admission verifies all raw
content references and recomputes the tree, blob IDs and SHA-256s from held bytes.
It proves the candidate commit has exactly one parent, the base, and its entire
diff is exactly the add-only write set. The whole incident root must be absent at
base. Symlinks, submodules, executable modes, path aliases, binary/non-UTF-8 data,
renames, deletes and modifications refuse. The existing 1,048,576-byte patch
ceiling and source-form content restrictions remain. Candidate code never runs.
Admission checks the exact accepted scope's allowed paths, held policy protected
paths/segments/root files, mode forbidden paths and target `.ystack/` boundary.
A supplied request cannot replace those authenticated policy inputs.

### 4. Exact shadow mapping and validation ownership

The source fact is `shadow/v1/write-shadow.py` at
`22d25c96f28ed42da0a5722b6b5ea0e65946274c`, blob
`fc596350cab560a138c2059e8096542aa75554b8`. `_publisher` builds the six-field request;
`_admit` checks its equality, write set, withholding and post-write plan.
That source and its real proof remain unaccepted dependencies.

| Existing shadow value | V3 relation |
| --- | --- |
| `id` | Equals `arguments.incident_id`. |
| `target_repository_id` | Equals request target repository. |
| `branch` | Equals `arguments.branch`. |
| `base_revision` | Equals both present request base and target revision. |
| `candidate_tree_id` | Equals the candidate input's root tree object ID. |
| `title` | Equals `arguments.title`. |
| `body_sha256` | Equals the body input content-ref digest and recomputed raw-byte digest. |
| Outer `scope_id`, workflow, task and `write_set` | Equal the request's corresponding values. |
| `post_write_verification` | Exactly the same base, candidate tree and write set. |

Retain the exact shadow body bytes: `Shadow evidence for <incident_id>. Publication
is withheld.\n`, with the final LF as an actual byte. Retain the shadow title and
body unchanged in the planned pull request. The text describes the retained shadow;
only later observed results can establish publication. Neither text nor digest
proves an external effect. Keep the schema-1 shadow envelope unchanged as content;
it is not a v3 core document or a successful publisher stage result.

Shadow `publication` remains exactly `{state:"withheld",
reason_id:"shadow.write-not-published"}`. Its `admission` remains checked/effect-none,
with request and write-set digests. Its proof does not consume a real publisher
attempt, obtain a grant, or synthesize actual publisher execution metadata.

The following are proposed future ownership paths, not allowed edits in this G2:

| Owner | Responsibility |
| --- | --- |
| V3 `modules/schema.jq` | One closed registry, argument/result value shapes and reused primitives. |
| V3 `modules/stage_request.jq`, `profile_graph.jq` | Request, input, scope, offer/request and role relations. |
| V3 `modules/result_facts.jq`, `result_truth.jq` | Actual-execution checks and the result rules below. |
| `publisher/v1/_admission.py` | One shared byte/Git/shadow admission boundary; returns checked facts for the mapping above. |
| `shadow/v1/write-shadow.py` | Supplies its retained source facts to that shared boundary; publication stays withheld. |
| `publisher/v1/publish.py` | Child 11's future fixed consumer; validates the v3 core request/profile, compares it with shared admission facts, then calls its separate write adapter. |
| Child 11's separate read-only checker | Authenticates remote observations and compares planned and observed effects. |

The later implementation adopts the existing private `_admit` checks into the one
shared boundary instead of copying them. Shadow calls its offline byte/Git checks
without constructing a publisher stage request, resolved binding or grant. The
publisher must additionally validate its v3 documents and compare every mapped
field against those checked facts before dispatch; the offline result cannot bypass
that validation. Keep materialization and path-policy primitives in their existing
owners. Core never reads Git, fetches content or checks grants; admission never maintains a second core schema or permission list.
The public core entry applies complete document self-checks in all three existing
modes; stage-run adds request/profile/result relations. No new standalone checker
or public command is needed. A future implementation must prove both real caller
routes, not ship only a schema fixture. A preserved source cannot be adopted before
its identity and outstanding acceptance are handled by the relevant artifact gates.

### 5. Grant and one-attempt boundary

The permission names no credential provider or transport. The external grant must
bind the canonical request digest, repository, incident, scope, candidate, branch,
content, publisher principal/boundary and the exact permission set. A different
scope, request, identity or content cannot inherit it. The grant's authority,
validity and revocation are checked externally; an exact hash alone proves none.
The existing credential policy does not grant this publisher a credential class.

Before any external effect, the trusted coordinator must durably reserve the
unique `(target_repository_id, incident_id)` once, bound to request digest, scope
and publisher attempt ID. The publisher attempt number is exactly 1. Atomic
reservation and crash recovery require proof in child 11's separate implementation.
A missing, ambiguous or unavailable reservation refuses. Changing the scope,
request ID or process cannot create another attempt for the incident. Reservation
is never cleared automatically, including after refusal or a pre-write crash.

Immediately before each write, recheck the grant, enablement, kill switch,
qualification, authenticated coverage, write set and exact target/base. Follow
Step 8 R5's fresh kill-switch checks at start, pre-write and post-write. Missing
or stale facts refuse. The target must independently refuse default/protected-branch
pushes. The authenticated repository context and grant identify the one destination
base branch; it must still point to the bound base revision.

Before branch creation, require both the exact branch and the incident's pull
request to be absent. Create only that new branch at the verified candidate commit.
Before opening the pull request, require proof that this attempt created the branch
and that the branch still has the exact candidate head. The incident's pull request
must still be absent. Refuse a foreign, replaced or mismatched branch. Then open
exactly one pull request against the bound destination. These action-specific
checks do not replace the common checks above or permit another dispatch.
No update or force operation, repair push, cleanup deletion, duplicate pull request
or automatic write retry is permitted. Check the base before each write and in the
separate post-write read.
A base race makes the attempt nonpassing and preserves any partial effects; never
claim that a check followed by a write was atomic. This spec proves no forge API
behavior or race-prevention mechanism.

Dispatch each side-effecting action at most once, durably recording dispatch
before calling the transport. A timeout, lost response, cancellation or crash after
dispatch makes an unproved effect unknown. Do not equate no response with no write.
Do not open the pull request unless this attempt's exact branch creation is proven.
Read-only reconciliation may gather new evidence; it cannot issue more writes,
change the immutable original result or renew the incident's attempt budget.
Any later recovery action needs its own explicit decision outside this contract.

### 6. Results and partial effects

V3 adds optional `publication` to `stage_result.body`. Stage-run requires it exactly
for this capability and forbids it for all others. It is exactly
`{branch,change_request,post_write}`. Existing request/profile references, attempt,
actor, execution facts, time ordering and status-presence rules still apply.
The publication object records supplied observations; core cannot authenticate them.

`branch` and `change_request` each have `state` from the following closed union:

| State | Exact additional fields and meaning |
| --- | --- |
| `not-attempted` | None. That action was never dispatched. |
| `absent` | `proof_ref` (content ref). Owned observations establish no effect from the dispatched action. |
| `created` (branch) | `proof_ref`, `head` (Git revision ref equal to the candidate input revision). |
| `created` (change request) | `proof_ref`, `change_request_id` (core ID naming one forge-neutral object in this target). |
| `unknown` | `proof_ref`. Retained dispatch/recovery evidence cannot establish the external outcome. |

A change request may be attempted only after branch `created`. If branch is
`not-attempted`, `absent` or `unknown`, change request must be `not-attempted`.
An existing foreign branch or pull request is never reported as this attempt's
`created`. Scope or request coincidence is insufficient ownership evidence.

`post_write` is `{state:"not-run"}` or exactly `{state,proof_ref,verified_by}`.
The latter state is `matched`, `mismatched` or `unknown`; `proof_ref` is a content
ref and `verified_by` the actor projection of the resolved profile's unique
protected verifier binding. Its principal, instance and execution boundary differ
from publisher. The later authorized #304 reader supplies authenticated read-only
observations; the separate verifier compares them without candidate execution.
This adds no verifier capability or network grant. The observation must bind this
request, attempt, repository, branch, pull request ID, head commit/tree, base,
complete diff, blob modes and raw byte digests,
and exact title/body. All must match; absent/partial observations are `unknown`.
Only two `created` actions may have a post-write state other than `not-run`.
No publisher self-claim, API acknowledgement or old shadow proof substitutes for it.

| Situation | Required stage result |
| --- | --- |
| Refused/stale/skipped before execution | Existing matching status; no execution/outcome; both actions `not-attempted`, post-write `not-run`. |
| Runtime fails or is cancelled, even before dispatch | Existing `failed` or `cancelled` rules; if execution exists, `change/inconclusive`, nonpassing evidence and actual facts. |
| Branch created; PR absent, not attempted or unknown | `failed` or `cancelled`, with `change/inconclusive` and retained partial effects. |
| Either effect unknown, or post-write mismatched/unknown | `failed` or `cancelled`, with `change/inconclusive`; scope stops for operator review. |
| Both effects created, separate check matched, complete actual metadata and passing deterministic evidence | `completed`, `change/changed`. |
| Both created and matched, but required actual metadata unavailable | `completed`, `change/inconclusive`, reason and nonpassing deterministic evidence. |

For this capability, `outputs` is always empty and `delta_ref` absent. Publication
facts carry external effects; a patch is not a published result. `no-change` is
forbidden. `completed` requires both effects created and post-write matched.
Pre-execution `failed` or `cancelled` is also allowed under the existing no-execution
rules, with both actions not attempted. A runtime failure with execution keeps
started/finished times, actual binding and evidence; `failed` retains diagnostics.
A metadata or execution-identity mismatch can retain incident facts only through
the existing nonpassing incident path; it can never yield `change/changed`.
A post-write mismatch uses reason `publisher.post-write-mismatch` and stops the
scope as Step 8 R5 requires. A shape-valid `matched` claim still needs independent
authentication before use.

### 7. Acceptance proof for a later implementation

These are required future proofs, not tests run or authorized by this G2:

- Preserve all v1/v2 byte and behavior tests. Reject version mixing, unknown IDs,
  fields and permissions, model execution, candidate execution, wrong roles, shared
  protected identities and a dormant manifest presented as a publication offer.
- Exercise document, profile-set and stage-run validation through the real core
  entry. Force a failing publisher rule in each applicable route and prove it runs.
- Exercise the same shared admission through shadow and child 11 fixture consumers.
  Prove exact six-field mapping, body bytes, both closed inventories, all write-set
  digests and the post-write plan. Reject modified, missing and additional files,
  source substitution, unsafe incident IDs, path aliases, existing roots, bad
  parents, stale base, branch escapes and protected/default branch targets.
- Prove request/grant/actual-use separation. A valid request, offered capability,
  profile or digest alone must not dispatch anything. Missing policies, credentials,
  reservation, qualification or kill-switch state refuse without a write.
- With an owned finite fake transport, prove the full success and every result row.
  Success creates the branch first, then opens the pull request exactly once after
  proving this attempt owns the branch and its head still equals the candidate.
  Reject a foreign same-name branch, a replaced branch head and an existing pull
  request. Cover definite branch refusal, branch-only effect, pull request refusal,
  lost responses, cancellation and crash at each dispatch boundary, post-write
  mismatch and unknown observations. Re-entry under another request/scope cannot
  repeat either action.
- Prove the post-write reader has distinct authenticated identity and no write
  capability. Fabricated acknowledgement, stale proof or an incomplete remote diff
  cannot pass. Retained evidence must reconstruct what was dispatched and observed.
- Complete package/consumer integration and restoration evidence must cover the
  exact later implementation head. Fixture success proves no real credential,
  ruleset, API, network boundary, target execution or runtime qualification.

## Out of scope

No code, runtime tests, credential acquisition, provider documentation/SDK access,
new network access, external write, target execution, install, activation or config
bootstrap. No new credential class, live grant, kill-switch clear, enablement or
production action. No general forge, CI, execution, identity, retry or scheduler
contract. No reopening the minimal-core five-document G2 or changing the dormant
squash observer. No adoption, cleanup or disposition of old attempts.

The implementation-first order from PR #680 permits this inactive design while
bound dependencies remain unaccepted. It accepts no #558, #544, #681 or step-7
proof. All debts remain. PR #183 stays frozen and #412 parked. CPU wall is `NONE`,
native qualification `BLOCKED`, production `EMPTY`, automation `PAUSED`.

## Areas of concern

This is high risk because it defines external-write authority and role separation.
The design chooses the operation, fields, version boundary, result table and rule
owners. The intent's open questions are answered by sections 1–7.

Real feasibility remains a reserved dependency: the chosen identity/credential and
transport must enforce exactly the new branch, one pull request, fixed base and
content, finite lifetime, storage isolation and no other writes. No local source
proves that a forge API, token or ruleset can do so. Child 11 must establish those
facts under separate operator-authorized access before implementation depends on
them. A missing primitive blocks that transport; it never permits broader
credentials, simulated qualification or a weaker contract.

V3 package publication and consumer migration require their own accurate accepted
implementation scope. This document supplies their contract, not their authority.
The missing proof, actual grant and runtime mechanism cannot be filled by claims.
