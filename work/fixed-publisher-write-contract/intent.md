# Intent: define the first fixed publisher write contract
Author: Codex (intent author). Status: draft.

## Problem

| Existing need | Contract gap |
| --- | --- |
| Step 8 R1.4: add evidence on one new branch, with at most one pull request | No executable publisher capability defines this bounded write |
| Step 8 R5 and child 11: separate publisher and post-write check | Operation, arguments, permission and result need one shared meaning |
| R2 write shadow: withhold the same planned publication | Its request cannot supply write authority or prove an actual write |

Tracks #173. The current manager's verified brief binds the proactive
[intake acceptance](https://github.com/yihanzhu/ystack/issues/173#issuecomment-6378603023)
to title SHA-256 `e97109a80ccb29b7c4a9aff4574c1e31756170bead59b02156d940aed563f5fc`
and body SHA-256 `f75f8d15ccc95f58ff4d84008f3487316e692d8faa60df515efadeee4f68af37`.

The accepted `portable-core-contracts/spec.md` defers the fixed publisher write to
#173. The current core keeps publisher protected and dormant, with no capability.
The default dormant publisher manifest offers no capability or permission.
Its normalizer only observes `squash-change-request` claims. It cannot perform the
first publication, and its observation does not confer merge authority.

The preserved source `22d25c96f28ed42da0a5722b6b5ea0e65946274c` already contains
`shadow/v1/write-shadow.py`. It constructs a `shadow_publisher_request`, checks its
write set, and records withheld publication and a post-write verification plan.
Its request binds target repository, branch, base revision, candidate tree, title
and body digest. These are existing consumer facts to map during design.
That source remains unmerged evidence with outstanding proof. It is no accepted
publisher implementation, real write, grant or qualification.

## Proposed outcome

Define the smallest portable contract needed by the first Step 8 publication.
It relates one fixed typed operation to its closed arguments, publisher role,
exact resource/action permission and result. The operation serves the bounded
add-only evidence workflow in `step8-bounded-write-readiness` R1.4, R5 and child 11.
Other deferred forge, CI, execution and identity contracts remain deferred.

The accepted design must let a later implementation author determine:

- Which exact target, new branch, base, candidate content and pull request content
  the operation names, and how each agrees with the planned write set.
- Which role can request this operation and which exact resource/action permission
  it needs. An arbitrary command, URL, branch write or operation cannot stand in
  for the fixed write.
- How manifest support, profile request, external grant and actual result stay
  separate. None of these records implies another or authenticates itself.
- How a result binds the original request and observed effects. Withheld, refused,
  incomplete or failed publication cannot become successful publication by claim.
  The design must account for a branch created without a completed pull request
  without permitting a second attempt or inventing missing effects.
- How the shadow request and the later publisher use the same contract checks,
  while the separate read-only post-write check compares actual content with the
  planned tree and blob digests. A valid document cannot replace this check.

Success is a reviewable contract with an identified downstream consumer and clear
acceptance cases. This initiative delivers design through G1 and G2 only.
It adds no implementation, validator, runtime, tests or live adapter.

## Affected users and systems

The operator, future contract and publisher authors, independent reviewers, core
contract validation, profile and manifest consumers, the Step 8 write-shadow
consumer, the later separate publisher, and its read-only post-write verifier.
Target repositories are affected only by a later separately authorized execution.

## Constraints

- Preserve the Step 8 boundary: add-only evidence under the one recorded incident
  root; exact allowed paths outside protected paths and target configuration;
  no modification, rename or deletion of existing files. An existing path refuses
  the write. Use the exact new incident branch. There is at most one new branch
  and one pull request per attempt, with one attempt per incident.
- Never push the default or any protected branch. Never merge, approve, label or
  comment beyond the pull request body. Preserve the separate target-ruleset
  refusal requirement. A contract declaration does not prove enforcement.
- Publisher has no model access or candidate execution. Producer, verifier,
  reviewer and publisher retain separate responsibilities and protected identities.
  The contract grants no credential or runtime authority to any role.
- Preserve all existing core meanings and the closed registry. Do not reopen the
  five minimal-core documents, copy schema into another home or add an isolated
  checker with no consumer. New semantics must respect the accepted version boundary.
  Core meaning stays harness-, model-, forge- and CI-neutral.
- G1 selects no capability or permission ID, wire field, public API or core version.
  G2 must bind the exact current registry and real consumer boundary. It must map
  the existing shadow facts and assign each validation rule one home. Reuse of
  source facts accepts neither the preserved implementation nor its missing proof.
- #173's no-implementation limit remains in force after this G1 and G2. Any later
  core-validator or publisher-runtime code needs a separate accurate implementation
  intake and its artifact and plan gates. It may consume the accepted contract.
  This design does not quietly authorize that work or the rest of #173.
- Credential identity, permissions, lifetime and storage; new network scope;
  bootstrap/config changes; target execution; installation and activation remain
  reserved operator decisions. No live profile is selected or synced. The dummy
  target remains read-only. No real write or external service access is authorized.
- The implementation-first decision in PR #680 permits inactive repository design
  before dependency acceptance. It does not accept #558, #544, #681, step 7 or any
  other missing proof. Preserve their full acceptance debts. CPU wall remains
  `NONE`, native qualification `BLOCKED`, production `EMPTY`, automation `PAUSED`.
- Keep PR #183 frozen, PR #412 parked and all existing attempts and worktrees
  preserved. This concern does not replace the minimal-core G2 or adopt an old
  publisher attempt. No cleanup or disposition is part of this design.
- G1 requires independent review and protected merge before G2. G2 must classify
  this security and permission design as high risk. Any later authorized code
  requires a separately accepted high-risk plan first. Exact hashes, independent
  review, required CI and the named manager's authority boundary remain gates.

## Open questions

- Which closed capability, argument, permission and result definitions fit the
  current core registry without changing old meanings? What version boundary is
  needed, and where does each rule belong?
- How does the existing withheld request map to that contract and the child 11
  consumer? Which facts are supplied claims, authenticated inputs and separately
  observed post-write evidence?
- What exact outcomes and evidence distinguish no write, branch-only publication,
  completed publication, refusal and failure while retaining the one-attempt limit?
- Which finite positive and rejection cases must a later implementation prove,
  including stale bindings, path or branch escape, extra permissions, and claimed
  success without matching observed content?
