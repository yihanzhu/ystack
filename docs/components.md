# Component write-ups (all inactive)

This file holds the per-component write-up for every unit built under construction
mode. It is the long-form companion to the "Components (all inactive)" index in
[`../README.md`](../README.md), which keeps one row per component; the full text
lives here.

**Everything described here is inactive and repo-only.** No component on this page is
selected, resolved, qualified, installed, or activated. None of them grants authority
or qualification, reads a credential, contacts a provider, invokes a model, publishes,
merges, or touches a target. They are source, contracts, and focused tests — proof that
a unit exists and holds its shape, not a running system. Activation happens only at the
operator-merged operating-mode transition described in [`../ROADMAP.md`](../ROADMAP.md).

**Convention for future construction PRs:** add your component's write-up *here*, in
this file, and add *one row* to README's "Components (all inactive)" index pointing at
it. Do not add a new `## Inactive …` section to README — README is the project's
introduction.

Sections appear in the order the components landed.

## Inactive portable profile resolver

`resolver/v1/` contains the first repo-only profile resolver. It reads exact local
Git objects, assembles the existing portable-core `resolved_profile`, and asks
`scripts/core-contract.sh` to validate the complete profile set. It does not select
or activate a profile, authenticate a repository map, execute selected content, or
access a remote or credential.

The `v1` directory names the resolver's request and repository-map transport. Those
invocation documents remain version 1 while emitted core documents use schema 2.

The shell runtime is deliberately mode 0644. A trusted parent must start it with a
direct fixed-path `execve`, an empty environment allowlist, fixed dependencies, and
the test-proven resource limits. `scripts/test/portable-profile-resolution.test.sh`
is the only shipped launcher today; it is proof, not a production activation path.
The private native snapshot helper is the exception recorded in
`work/portable-profile-resolution/spec.md`. Remove it only when every supported
runtime has an equivalent accepted descriptor-relative no-follow API.

## Inactive default profile assembly

`profiles/default/v1/` binds six default adapter packages to exact Git
objects from one durable main commit. Protected roles keep distinct principals,
execution boundaries, and authority scopes; their decision records cite the exact
accepted `ROADMAP.md` content. The producer manifest and binding also pin the
profile's immutable producer config. Requested capabilities and permissions are
inactive contract data, not grants. The profile requests no adapter tools, and
the CI and dormant-publisher roles request no capability or permission.
The current normalizer payloads only validate supplied records and return
observations; they do not execute a model, verifier, forge, or other adapter.
The GitHub forge normalizer remains a separate observation payload. Transport and
runtime wiring are not part of this inactive assembly.

This is source data only. It is not selected, resolved, qualified, installed, or
activated, has no authority or qualification, and cannot invoke a model, use a
credential, contact a provider, publish, or touch a target. Run
`bash scripts/test/default-profile-assembly.test.sh` for the focused proof.

## Inactive alternative profile assembly

`profiles/alternative/v1/` is the same six-role team as the default profile with
one swap: the producer is the Codex CLI harness instead of Claude Code. Its
producer manifest points at `adapters/codex-cli-producer/v1/normalize.jq` at the
durable main commit that carries it, and its producer binding asks for the
`openai` provider and pins `profiles/alternative/v1/producer-config.json` by Git
object. The other five manifests — CI, forge, publisher, reviewer, and verifier —
are the default ones, byte for byte. Protected roles keep distinct principals,
execution boundaries, and authority scopes, and the producer gets its own
`principal.codex-producer` and `boundary.codex-producer`. This is the item 6
wiring that shows one core contract can drive either harness.

This profile is inactive and selects nothing. It is not resolved, qualified,
installed, or activated, grants no authority, and cannot invoke a model, use a
credential, contact a provider, publish, or touch a target. GitLab stays an
observation payload the same way the GitHub forge does: neither is bound here.
Run `bash scripts/test/alternative-profile-assembly.test.sh` for the focused
proof, which also asserts the only differences from the default profile are the
producer binding and the profile id.

## Inactive portable core v2 fake-forge contract

`core/v2/` contains an inactive, repo-only contract for deterministic candidate
materialization by a fake forge adapter. The operation can read an exact target,
write only a caller-disposable candidate repository and scratch space, and append
deterministic evidence. It grants no network, credential, publish, push, merge, or
remote branch-write capability and is not qualified for a real forge.

The stable `scripts/core-contract.sh` wrapper and inactive resolver select this v2
generation together. This is a repo-only compatibility switch. It does not install
the resolver, select a live profile, or qualify a real forge.

The v2 registry also carries the selected evidence-identity correction. It requires
every passed evidence item to come from the exact selected execution; incident
mismatches remain valid only when all evidence is non-passing. The stable wrapper,
inactive resolver, Control closure, and scanner select it together. The prior
generation remains immutable and restorable.

## Inactive offline delivery replay

`delivery/v1/replay.py` replays one already-supplied local materialization input
through the existing local Git materializer. It then checks one repo-relative
candidate blob against a supplied SHA-256 and records a private, resumable state.
It never executes candidate code or a user command string.

Review and publisher records are supplied offline test observations. Each names the
exact request digest, candidate tree, and candidate commit, and all three must match
the recorded materialization: two candidate commits can carry one tree, so the commit
is what binds an observation to this candidate. They still do not authenticate an
actor or authorize a real publication. Missing review stays waiting; a completed
receipt is explicitly an offline simulation with no authority or qualification.

## Inactive fake adapter contract matrix

`adapter-tests/v1/` runs a fixed 2×2 producer/forge matrix against one unrelated
local Git fixture. Its accepted inventory and four distinct fake entrypoints are
digest-pinned. The runner revalidates each resolved profile with portable core v2,
validates every producer and forge stage request/result, then checks payload links,
package, target, candidate, receipt, and Git identities itself.

The result is observation only. It grants no authority, qualification, approval,
publish, merge, or branch-write capability. The fakes run with a cleared environment,
fixed limits, and disposable directories, but this test does not provide or claim
mechanical network or host-filesystem isolation. Real-adapter sandbox qualification
and an external-target smoke remain required.

## Inactive control policy-set validator

`control/v1/` defines the canonical shape and order for six Control foundation
policies: credentials, duty separation, immutable evidence, kill switch, risk
gates, and sandbox. Its validator checks the set shape and relations. It does not
contain or evaluate those policies.

The package stays inactive and fail-closed. It grants no authority, activates no
profile, reads no credential, launches no adapter, and performs no external write.
Later bounded units own each policy body and its enforcement.

## Inactive Control foundation roll-up

`control/v1/control-policy-set.json` pins the six shipped policy and decision files
in the required order. It also pins their shared core contract generation and
package. The focused test recomputes all twelve file digests and the core package
closure rather than trusting the refs in the set.

This is a static, repo-only identity bundle. It adds no aggregator runtime and
makes no enforcement, qualification, approval, authority, activation, or external
effect claim. The set stays inactive and fails closed.

## Inactive duty-separation evaluator

`control/v1/evaluate-duty.sh` checks one public core v2 stage tuple against the
shipped duty-separation ceiling. It binds that policy to the validated policy set
by exact content identity. Its shipped decision binds the policy, evaluator driver,
evaluator program, policy-set validator driver/program, and complete selected
public-core package closure. Only private mirrored validator/core packages execute.
It keeps publisher dormant and compares producer, forge, verifier, reviewer,
requester, performer, and reporter identities.

The canonical result is observation only: `satisfied`, `violated`, or
`inconclusive`. The evaluator grants no authority, activates nothing, reads no
credential, runs no candidate, and performs no network or external write. Sandbox,
credential, risk, kill-switch, evidence, and publisher enforcement remain later
Control foundation units.

## Inactive risk-gates evaluator

`control/v1/evaluate-risk-gates.sh` checks one public core v2 stage tuple, its
regenerated duty-separation result, and one caller-supplied decision claim against
the shipped risk-gates policy. It binds the policy-set, policy, decision,
evaluator, duty-separation, and selected public-core identities before producing a
canonical observation. Malformed, stale, ambiguous, rejected, downgraded, and
unsupported claims are `violated`.

The decision input is only an immutable, identity-bound claim. No qualified
decision-provenance adapter exists yet, so even an internally matching accept
claim is `inconclusive` with `decision.provenance-unqualified`; this evaluator has
no `satisfied` result. It grants no approval, authority, qualification, or
permission, activates nothing, and performs no candidate, credential, network,
publish, deploy, or external-write action.

## Inactive kill-switch evaluator

`control/v1/evaluate-kill-switch.sh` checks a caller-supplied stop-state snapshot
for one attempt across global, repository, workflow, stage, and attempt scopes. It
binds the policy-set, policy, decision, evaluator, duty-separation result, and
selected public-core identities before producing a canonical observation. Any
matching stop wins; stale, replayed, conflicting, or malformed state fails closed.

The evaluator is observation only. A fully cleared snapshot may be `satisfied`,
but that grants no authority or permission and does not cancel or run anything.
The package stays inactive, reads no credential, activates no profile, and performs
no candidate, network, publish, deploy, signal, or external-write action.

## Inactive sandbox-policy evaluator

`control/v1/evaluate-sandbox.sh` checks one execution-environment claim against
the shipped sandbox ceiling. It binds the policy set, policy, decision, evaluator,
duty-separation result, and selected public-core identities before producing a
canonical observation. The ceiling requires a cleared, allowlisted environment;
fixed roots, resources, tools, and limits; no host access; denied network; and no
credential, secret, target-write, or external-write exposure.

The result is declaration-only: `satisfied`, `violated`, or `inconclusive`. Even a
`satisfied` claim does not prove that a real sandbox enforced those properties and
grants no authority, qualification, or permission. The package stays inactive,
runs no candidate or adapter, reads no credential, activates no profile, and
performs no network, publish, deploy, or external-write action.

## Inactive credential-policy evaluator

`control/v1/evaluate-credential-policy.sh` checks one credential-boundary claim
against the shipped credential ceiling. It binds the policy set, policy, decision,
duty-separation result, evaluator, and selected public-core identities before
producing a canonical observation. The ceiling permits only brokered,
single-stage model inference for producer or reviewer roles, with no credential
material exposed to the execution boundary. Candidate write or execution
permissions are incompatible with credential access.

The result is `violated` or `inconclusive`; an unqualified input claim can never
produce `satisfied`. The package stays inactive, reads no credential material or
credential-like environment value, grants no authority or qualification, activates
no profile, and performs no candidate, adapter, network, publish, deploy, or
external-write action.

## Inactive evidence-integrity evaluator

`control/v1/evaluate-evidence-integrity.sh` compares caller-supplied evidence
references with one exact public-core stage tuple. It binds the policy set,
policy, decision, evaluator, and selected core package before returning a
canonical `satisfied` or `violated` identity observation. Evidence and prior
references must keep their canonical order and unique logical identities; one
prior result digest cannot describe multiple result documents.

The launcher is an explicit trusted shell boundary; it does not claim to
self-attest bytes that Bash already loaded. The decision separately binds the
exact marked evaluation payload. The launcher extracts those fragments from a
private no-follow snapshot, verifies their content identity, and gives only the
verified bytes to the worker. Scratch producers return full final descriptor
identities over an inherited, unlinked channel; consumers bind every read to
those identities. Public-core validation uses its accounted mode
with a fixed budget, an anchored receipt descriptor, and a worker-owned root.

The evaluator never reads proof bytes. Matching references do not prove a claim
or qualify a workflow, and equal proof digests may belong to different logical
references. The package stays inactive, stores nothing, grants no authority, and
performs no candidate, credential, network, adapter, publish, deploy, or external
write.

## Inactive canonical state scanner

`orchestrator/v1/scan-state.sh` reads one bounded canonical snapshot that binds an
explicit Git repository and commit and carries canonical stage request, resolved
profile, attempt, and result records. Run it with the same repository and commit
identities:

```text
orchestrator/v1/scan-state.sh scan REPOSITORY_ID COMMIT_ID SNAPSHOT.json
```

It emits a deterministic canonical observation that classifies each stage as
terminal, stale, blocked, retryable, stranded, or pending, with a recovery action
and reason. Those fields are messages for later recovery work, not commands. The
scanner is inactive and observation only: it does not deliver events, schedule,
dispatch, retry, reconcile, write state, use a credential or network, activate a
profile, or touch a target.

## Inactive reconciliation planner

`orchestrator/v1/reconciliation-plan.jq` is a pure jq 1.6 planning filter. It
accepts one canonical scanner observation, one canonical delivery ledger, their
caller-supplied exact references, and a bounded concurrency limit. It returns a
canonical inactive plan. A delivery key binds the stage key, request digest,
planned operation, and attempt number.

Pending and failed deliveries reappear with that same key until acknowledged.
Acknowledged deliveries are suppressed. New work uses only slots left after
pending deliveries, with redeliveries first and stable stage-key order; work that
does not fit is listed as deferred. Scanner recovery actions and reasons remain
data in the plan. The filter does not dispatch, schedule, execute recovery, write
state, use a credential or network, activate a profile, publish, or touch a target.

## Inactive GitHub forge normalizer payload

`adapters/github-forge/v1/normalize.jq` validates one untrusted GitHub
change-request snapshot against caller-supplied repository, request, head, base,
app, time, instruction, and config bindings. It returns a canonical generic
observation for open, blocked, closed, merged, stale, incomplete, or unknown
state. Provider metadata stays opaque data.

This PR lands only the immutable normalizer payload. A later assembly PR can add
its manifest and default-set wiring after this payload has a durable commit on
main. The payload is offline and unqualified. It does not call GitHub or a CLI, use a
credential, change a repository or request, grant authority or qualification, or
activate a profile.

## Inactive GitLab forge normalizer payload

`adapters/gitlab-forge/v1/normalize.jq` is the first alternative forge. It
validates one untrusted GitLab merge-request snapshot against caller-supplied
project, merge-request iid, head, base, bot-user, time, instruction, and config
bindings and returns the same canonical generic observation the GitHub forge
returns: open-ready, open-blocked, closed-unmerged, merged, stale, or
inconclusive, with the same output keys, effect boundary, and stale-binding
shape, so a profile can swap one forge for the other. GitLab vocabulary stays at
the edge and is taken as the API reports it: `detailed_merge_status` values such
as `mergeable`, `conflict`, `ci_must_pass`, `security_policy_violations`, or
`checking` decide ready, blocked, or inconclusive; a locked request is inconclusive; a merged request is never
also closed; and the acting identity is the bot user the integration runs as,
since GitLab has no app id. Provider metadata stays opaque data.

This PR lands only the immutable normalizer payload. A later assembly PR can add
its manifest and profile wiring. The payload is offline and unqualified. It does
not call GitLab or a CLI, use a credential, change a project or merge request,
grant authority or qualification, or activate a profile.

## Inactive Codex native reviewer normalizer payload

`adapters/codex-native-reviewer/v1/normalize.jq` validates one untrusted
native-review snapshot against caller-supplied repository, change request,
review, head, base, GitHub app, time, instruction, policy, and execution-boundary
bindings. It returns a canonical generic observation for clean, findings,
dismissed, timeout, failed, stale, incomplete, or non-terminal state. Provider
severity and metadata stay opaque data, and unavailable hidden execution facts
remain explicit.

This stage lands only the immutable normalizer payload. A later assembly PR can
add its manifest and default-set wiring after this payload has a durable commit
on main. The payload is offline, read-only, and unqualified. It does not invoke a
model or CLI, use a credential or network, post a review, grant authority or
qualification, or activate a profile.

## Inactive GitHub Actions CI normalizer payload

`adapters/github-actions-ci/v1/normalize.jq` validates one untrusted GitHub
Actions workflow and check snapshot against caller-supplied repository, suite,
workflow, run, attempt, job, check, app, head, base, time, instruction, config, and
execution-boundary bindings. It returns a canonical generic observation for
queued, running, passed, failed, cancelled, timed out, action-required, stale,
or inconclusive state. Provider names, text, and details stay opaque data.

This PR lands only the immutable normalizer payload. A later assembly PR can add
its manifest and default-set wiring after this payload has a durable commit on
main. The payload is offline and unqualified. It does not call GitHub or a CLI,
use a credential, rerun or cancel work, dispatch a workflow, change a repository,
grant authority or qualification, or activate a profile.

## Inactive telemetry trace-record validator

`telemetry/v1/validate-trace-ledger.sh` validates one caller-supplied, bounded
canonical trace-record bundle against caller-supplied session and attempt
identities. Every event names that session and attempt plus its trace, carries explicit recorded,
computed, unavailable, or not-applicable facts, and joins a SHA-256 chain. A
sealed count and final digest expose tail truncation. The validator returns one
deterministic canonical receipt bound to the exact input bytes.
Each record digest covers its jq 1.6 sorted compact event without
`record_digest`, including the terminating line feed.
The receipt repeats a session, attempt, and final-digest replay key for a later
state store to consume once. It is not itself a durable ledger or write protocol.
Validation runs only with the repository's digest-pinned jq 1.6 runtime bytes.

```text
telemetry/v1/validate-trace-ledger.sh validate SESSION_ID ATTEMPT_ID LEDGER.json
```

The chain detects an unrehashed change; it is not a signature or an authority
grant. The package stays inactive and repo-only. It does not collect telemetry,
run a tool or adapter, read a credential, use a network, write a ledger, activate
a profile, qualify a workflow, publish, deploy, or touch a target. A later unit
must provide durable append, retention, access, and recovery behavior before it
can claim a telemetry ledger runtime.

## Inactive hermetic eval-record evaluator

`evals/v1/run.sh evaluate BUNDLE.json` validates already-recorded, bounded
canonical eval suites, cases, trials, and grades, then emits one deterministic
report. It does not execute trials or invoke graders. Every record is
content-bound. The suite pins its scope and framework version. Model cases require
multiple supplied trials, while deterministic, model, and human graders remain
immutable data references. Declared trial and attempt identities are exact, and
trial/grade timestamps must agree.

The runner snapshots a fixed jq program and the selected public-core schema into
a private directory. It accepts only canonical JSON, rejects stale links,
tampering, duplicates, and non-canonical order, and keeps `unavailable` distinct
from `inconclusive`. Failed grades cannot be hidden by another trial state. It
has no adapter or arbitrary-command seam, uses no network
or credential, grants no authority, and makes no activation or qualification
claim.

This is a bounded first slice for eval records, not a runnable eval system or
qualification evidence. A later unit must provide hermetic built-in trial and
grader execution before it can make either claim.
## Inactive local Git candidate materializer

`adapters/local-git-materializer/v1/` implements the existing portable-core v2
`core.forge.materialize-candidate.v2` capability without a Git forge. It reads one
exact, sanitized bare source repository and one contract-bound patch. It imports
reachable objects into a caller-disposable bare repository, applies the patch to a
scratch-only index, and returns a canonical receipt and validated stage result.
Reachable source history is limited to 65,536 objects and 256 MiB of uncompressed
object data; the streamed pack is capped at the same byte limit.
The complete source filesystem inventory is capped at 65,536 entries and 8 MiB,
and repository config is snapshotted at 1 MiB before parsing.
Each tree scan is limited to 65,536 entries, 1,024 tree objects, 64 path
components, and a 16 MiB encoded listing. Each commit or tree is size-checked
before a non-recursive tree step, and each step validates UTF-8 before its bounded
built-in path walk.
Before mutating the index, patch paths must already fit the contract and their
cumulative source blob sizes plus patch bytes must fit a 256 MiB candidate budget.

The fixed `materialize` command accepts only caller-named physical source,
candidate, and scratch boundaries, with every path independently absolute. It
also receives the execution boundary's compiled `ystack-object-closure-v1` helper,
whose source is private to this adapter package, and an explicit pinned jq 1.6
executable. It ignores the caller's executable search path.
It rejects worktrees, alternates, shallow or
partial repositories, replace or graft state, active hooks and filters, remote
configuration, unsafe paths, binary or copy/rename patches, empty subtrees,
symlinks, and submodules. It never
inherits host Git templates, checks out a worktree, or runs a transport command.
An empty producer patch returns the explicit `no-change` result. Tests cover both
SHA-1 and SHA-256 object formats with disposable local fixtures.

This PR lands only the inactive package payload. A later assembly PR may add a
manifest whose package reference points to this payload's durable commit on main.
GitHub and later GitLab change-request normalizers remain separate observation
inputs; they do not claim this materialization capability. The package is not
qualified, selected, installed, or activated. It reads no credential, contacts no
provider or real target during construction, and cannot push, publish, merge, or
grant authority.

## Inactive Claude Code producer normalizer payload

`adapters/claude-code-producer/v1/normalize.jq` validates one untrusted producer
snapshot against a caller-supplied core request, resolved profile, manifest,
target, package, config, prompt, skills, tools, model, effort, and execution
boundary. It returns a canonical observation for changed, unchanged, stale,
failed, timed out, degraded, or inconclusive work. Provider text stays data.
Before constructing the trust context, the caller must canonicalize the snapshot,
verify its SHA-256, and supply that verified content-and-digest pair. The
normalizer requires the untrusted snapshot to equal the pair, binds the expected
attempt ID and number, and requires `text/x-diff` output for a changed git patch.

This payload ships no adapter manifest. Its focused test owns a synthetic
manifest only to prove the caller-manifest and binding checks stay closed. A
later assembly PR can bind the durable main payload into the default profile.
The payload is inactive and unqualified. It does not call Claude Code, invoke a
model, use a credential or network, write a target, publish, or activate a
profile.

## Inactive default producer config

`profiles/default/v1/producer-config.json` is an immutable Git payload for the
default producer preference. It grants no capability and does not select a
profile, invoke a model, or contact a provider. Its focused test checks the
config shape and exact Git object identity.

## Inactive alternative producer config payload

`profiles/alternative/v1/producer-config.json` is an immutable Git payload for
the producer preference the alternative profile (Codex CLI producer, openai
provider) will pin by Git object. It grants no capability and does not select
a profile, invoke a model, or contact a provider. Its focused test checks the
config shape and exact Git object identity.

## Inactive Codex CLI producer normalizer payload

`adapters/codex-cli-producer/v1/normalize.jq` is the first alternative harness.
It is the Claude Code producer normalizer with only the harness identity
swapped: the snapshot kind and content id, the manifest id, the recorded
snapshot fact, the adapter id, and the model provider the binding must name
(`openai`). Every trust relation, snapshot relation, state, reason, and the
generic observation are the same, so a profile can select either harness under
one core contract. The focused test proves the two programs differ only in
those six tokens and that a snapshot, fact, or binding from the other harness
is refused.

This payload ships no adapter manifest and is inactive and unqualified. It does
not call Codex, invoke a model, use a credential or network, write a target,
publish, or activate a profile.

## Inactive local Git materializer protocol

`adapters/local-git-materializer/v1/protocol.jq` defines the pure input, receipt,
and stage-result boundary for the existing portable-core v2
`core.forge.materialize-candidate.v2` capability. It validates a complete profile,
resolved profile, manifest set, exact stage request, materialization contract, and
patch payload links before projecting a canonical path-free receipt and core-valid
result. The caller first canonicalizes and hashes both payloads, supplies those
verified content-and-digest pairs in the trust context, and keeps raw payloads
separate; changed bytes are rejected before any projection.

Successful result projection likewise requires the raw materialization receipt and
its caller-verified content-and-digest pair. The protocol rechecks the receipt's
request, attempt, source, candidate, path count, and changed/no-change relation
before its digest may back passing evidence.

This stage contains no materialization executable. Its fixture builder is test-only
and creates synthetic JSON under a caller-owned test directory; it is not a product
execution seam. The protocol cannot read a repository, write a candidate, invoke a
hook or filter, use a credential or network, contact a provider, or perform an
external effect.

A later runtime PR can consume this exact protocol and test fixture without copying
them. That PR must separately prove the physical Git and scratch boundaries before
any manifest or profile may bind the package. Nothing here is qualified, selected,
installed, or activated.

## Inactive dormant publisher normalizer payload

`adapters/dormant-publisher/v1/normalize.jq` validates one bounded publisher
decision claim against caller-supplied attempt, idempotency, repository,
change-request, head, base, tree, allowed-path, CI, review, decision-record, time,
and execution-boundary bindings. Before calling it, the caller canonicalizes and
hashes the claim, then supplies that verified content-and-digest pair. The
normalizer requires the input to equal the pair and returns only a canonical
dormant, stale, or inconclusive observation. A permit claim remains unqualified
data; it never becomes approval or authority.

This stage intentionally ships no adapter manifest. A later assembly PR can bind
the durable main payload as the default profile's deterministic publisher with no
capabilities, permissions, or tools. The payload is not the temporary construction
publisher gate and cannot call it. It uses no credential or network, performs no
merge or external write, and activates no profile.

## Inactive deterministic verifier normalizer payload

`adapters/deterministic-verifier/v1/normalize.jq` validates an already-supplied
portable-core v2 verifier request, resolved profile, adapter contract, and stage
result. It reuses the core's request, profile, and result relations, then returns
one canonical observation. It does not interpret provider or CI status as verifier
evidence. GitHub Actions remains a separate CI observation boundary. The caller
first canonicalizes and hashes the snapshot and stage result, supplies those
verified content-and-digest pairs, and fixes the expected attempt ID and number.
The normalizer rejects any mismatch before emitting their references.

This payload is offline and unqualified. It does not execute a candidate or tool,
read proof bytes, enforce a sandbox, use a credential or network, write evidence,
grant authority or qualification, or activate a profile. A later assembly PR may
add its manifest and inactive default-set binding only after the payload has a
durable commit on main. A runnable verifier still requires a separately qualified
sandbox launcher and fixed verification implementation.

## Inactive eval and trace framework

`evals/v1/run-evals.sh` runs one offline eval pass over a caller-supplied seed set
and returns one canonical run result:

```text
evals/v1/run-evals.sh run SEED-SET.json OBSERVED_AT
evals/v1/run-evals.sh dashboard OBSERVED_AT SEED-SET.json RUN-RESULT.json [SEED-SET.json RUN-RESULT.json]...
```

`evals/v1/eval-catalog.json` names the nine regression families the roadmap
requires before any autonomous write (stale and moved artifacts; repeated,
cancelled, and missed events; approval invalidation; actor and re-run identity;
malicious instructions; protected-path, credential, network, and publisher
boundaries; empty, fake, timed-out, and degraded reviews; reviewer severity; and
adapter contract compliance). Each family declares which grader kinds may judge
it, its trial policy, and the core evidence kinds it produces. Seven families are
seeded; the other two are declared and wait for their own seeds.

The seeded cases in `evals/v1/seed-set.json` replay canonical core-v2 stage runs
through the real portable core (`scripts/core-contract.sh validate-stage-run`).
The core is the only judge: the framework records whether the core accepted or
rejected each run and with which token, then grades that observation against the
case's expectation. A wrong expectation is graded `failed`. A family that only a
model or a human can grade is graded `inconclusive`, never guessed.

The repeated, cancelled, and missed events family is seeded from
`evals/v1/seed-set-events.json`. Its cases replay canonical orchestrator state
snapshots through the real inactive state scanner (`orchestrator/v1/scan-state.sh`),
staged inside the same private runtime: a missed attempt deadline must classify as
stranded, a cancelled stage must stay terminal even when the target moves, a
failed stage must be retryable until its retry limit and blocked after it, and a
snapshot that repeats a stage or mixes a live attempt with a terminal result must
be refused. The scanner is the only judge; the framework records its
classification or refusal token and grades that against the case's expectation.

The same family is also seeded from `evals/v1/seed-set-plans.json`, which replays
observation-plus-ledger bundles through the real inactive reconciliation planner
(`orchestrator/v1/reconciliation-plan.jq`): a repeated delivery of the same key is a
redelivery, not a second effect; an acknowledged delivery is suppressed; a retry is
planned as the next attempt and refused past the retry limit; a stranded attempt is
recovered; deliveries beyond the in-flight limit are deferred with redeliveries
first; duplicate classifications or ledger entries are refused. Only what the plan
would deliver, defer, suppress, or hand to an operator is graded. A seed set may
only feed families the catalog says draw on its source.

The protected-path, credential, network, and publisher boundaries family is seeded
from `evals/v1/seed-set-boundaries.json`. Its cases replay execution-environment
claims through the real inactive sandbox-policy evaluator
(`control/v1/evaluate-sandbox.sh`), staged with its policy-set validator and policy
in the same private runtime: a cleared, allowlisted sandbox is satisfied; a
publisher role, an allowed network or endpoint, a tool that asks for network, an
inherited environment or a secret-looking variable, a credential reference, a write
root outside the fixed sandbox, and any target or external write are violated with
their exact reason ids; unknown network or sensitive-material state is
inconclusive; a claim with an unknown field or a wildcard path is refused. The
evaluator is the only judge; the framework records its verdict and reason set.

The adapter contract compliance family is seeded from
`evals/v1/seed-set-adapters.json`. Its cases replay recorded provider snapshots
with caller bindings through the real inactive default normalizers for the GitHub
forge, GitHub Actions CI, and Codex native reviewer adapters, each staged in the
private runtime at a pinned digest: open, blocked, merged, and closed change
requests; queued, running, passed, failed, cancelled, timed-out, and
action-required runs; clean, findings, dismissed, timed-out, and failed reviews;
stale bindings named exactly; incomplete or unknown provider state kept
inconclusive; provider text that can never decide a state; and malformed
envelopes, bindings, or snapshots refused with the normalizer's own error id. The
normalizer is the only judge; the framework records the generic state, reason, and
stale-binding set it reports.

The same family also replays the GitLab forge normalizer and the Codex CLI
producer normalizer, the alternative forge and harness from roadmap item 6,
through the same contract and safety evals as the GitHub defaults. The GitLab
cases cover ready, conflict, security-policy-blocked, merged, closed, locked, and
still-running merge requests; stale bindings named exactly; provider text that
can never decide a state; and GitHub-shaped or legacy merge-status inputs
refused. The Codex producer cases cover changed and no-change snapshots;
provider failure, timeout, and degraded runs kept inconclusive; stale inputs and
incomplete metadata; a moved attempt; another harness's provider; an unknown
state; a moved untrusted snapshot; and a caller manifest ceiling, each refused.
This is the roadmap item 6 proof that the alternative forge and harness meet the
same contract and evals as the defaults.

The approval-invalidation and no-push-after-approval family is seeded from
`evals/v1/seed-set-approvals.json`. Each case carries a whole decision tuple
(policy set, core request, resolved profile, result, duty evaluation, decision
claim) and replays it through the real inactive risk-gates evaluator
(`control/v1/evaluate-risk-gates.sh`), which regenerates the duty-separation
evaluation and validates the core tuple from a mirror built out of the same
private runtime. A request whose basis moved after the decision is violated
(decision.stale); a decision recorded after the request, a missing, rejected,
downgraded, wrong-role, wrong-kind, unbound-actor, unbound, ambiguous, or
malformed claim is violated with its exact reason; a duty violation is violated;
an honest accept claim is still only inconclusive because no qualified
decision-provenance adapter exists; a forged duty evaluation is refused. Each
expectation's verdict and primary reason were hand-written and checked against
the real evaluator before being recorded.

The actor and re-run identity family is seeded from `evals/v1/seed-set-duty.json`.
Each case carries the four documents the duty-separation evaluator binds (policy
set, core request, resolved profile, result) and replays them through the real
inactive duty-separation evaluator (`control/v1/evaluate-duty.sh`), which checks
its policy set with its own validator pair and the core tuple against a mirror
built out of the same private runtime. A clean stage and a skipped stage are
satisfied; a request from a denied requester role, a result whose execution kind,
capability, or reporting role does not match the binding it claims, is violated
with its exact reason; an unclassified capability is only inconclusive, never
guessed; a policy set naming the wrong duty policy, a request over the producer
permission ceiling, and a profile that collides two protected roles are each
refused with one token. Each expectation's verdict and primary reason were
hand-written and checked against the real evaluator before being recorded.

The `dashboard` operation aggregates one to sixteen run results into one canonical
flow-and-quality document. Each seed set is first replayed in the same private
runtime at the result's own recorded time, and a result counts only if that replay
reproduces it byte for byte. Nothing embedded in a supplied result is trusted: a
result from another framework version or platform, or with any altered
observation, verdict, or summary, never counts. The dashboard reports seeded-family coverage,
per-family and overall pass, fail, and inconclusive counts, and the recovery
evidence the events family produced (missed attempts recovered, cancellations kept
terminal, repeats redelivered once or suppressed, retry limits enforced, malformed
or over-limit events refused). Every number is a count over the results handed in. Latency,
cost, and token telemetry are recorded absent because no live run exists to
measure, and the operating-flow metrics the roadmap names (intent-to-spec and
plan-to-merge time, queue and human-gate wait, first-pass success, rework, review
latency, precision, recall, and stale rate, escaped defects and vulnerabilities,
DORA throughput and instability, target outcome) are recorded absent with the
reason that there is no operating history yet. Nothing is estimated.

Every run result carries the exact catalog, seed set, program, driver, launcher,
and core-closure digests, plus one trace event per case in the shape the
Observability interface names (tool, adapter, gate, identity, latency, cost).
Latency and cost are recorded as absent in this unit; the framework performs no
model call, so there is nothing honest to charge. The framework is inactive and
observation only: it does not run a candidate or adapter, invoke a model, use a
credential or network, write outside its scratch, grant qualification, or
activate a profile.


## Inactive target packaging

`packaging/v1/` is the roadmap item 10 pair: `build-release.sh` writes a versioned
release manifest, and `install.sh` copies exactly what that manifest names into a
fresh target directory. Both are inactive. Running the installer against a real
target is a versioned operator action and stays disabled until the operator-merged
operating-mode transition; the focused test is the only thing that runs it today,
and only against an empty directory it created itself.

`build-release.sh build-release COMMIT PROFILE_ID...` reads this repo at one exact
commit and prints one canonical JSON release manifest. The manifest records the
release id (a SHA-256 of its own body), the source commit, the profile ids
included, and every packaged file with its Git object id, file mode, and SHA-256,
plus the core contract generation read out of `scripts/core-contract.sh` at that
same commit rather than hardcoded. Two builds at the same commit produce the same
bytes. Packaging is fail closed: a path is refused unless it is a profile file, an
adapter payload the profile binds, a core v2 contract file, or the contract
validator itself. Personal configuration, the operator's harness directory, the
manager persona, ystack's own north star, and the prompts a target writes for
itself are outside that closed set and can never be packaged, so a hand-edited
profile cannot smuggle one in.

`install.sh install MANIFEST PROFILE_ID TARGET` writes the profile's files into
`TARGET/.ystack/`, keeping their repo-relative layout so the installed
`scripts/core-contract.sh` validates the installed profile and manifests in place.
The target must already exist and be an empty, real directory: a non-empty
directory, a symlink, a path inside this repo, and a path under the home directory's
dotfiles are each refused.

Install reproduces the release manifest from the commit and refuses any difference.
Before anything is staged it rebuilds the release with `build-release.sh` for the
commit and the profile ids the supplied manifest itself names, and requires the
supplied bytes to equal the rebuilt bytes. That one comparison settles the release
id, every per-profile file list, every file mode, Git object id, and digest, and the
core generation at once, so a hand-edited manifest cannot install even when it has
been made internally consistent. Two derived checks stand in front of it for a
reader with no repository: the release id must be the SHA-256 of the manifest's own
canonical body, and each profile's file list must be the set derived from its own id
and the manifest's generation — the core files for that generation, its own
`profile.json`, `producer-config.json`, and six adapter manifests, no other
profile's files, no other generation's files, and nothing packaged that no profile
claims. That derived set is written once, in `packaging.jq`, and the builder reads
it rather than repeating it, so the two cannot drift apart.

Nothing is written until every packaged blob has additionally matched
the manifest's Git object id and SHA-256 and has passed a content denylist for home
paths, credential-shaped tokens, and the shipped-default north-star marker. A
malformed, oversized, multi-root, non-canonical, symlinked, or moved manifest is
refused, and so is one that names a commit this repo does not have, another core
generation, an unknown profile, or a tampered digest.

The install writes two files the release does not contain. `TARGET/.ystack/north-star.md`
is a target-owned placeholder: it states no goal, carries no approval record, and
carries no shipped-default marker, so nothing about ystack's own direction is copied
in as if the target had approved it. `TARGET/.ystack/install-record.json` is a
canonical record of the release reference, every installed path with its digest and
mode, the north star's placeholder-unset state, `activation: "none"`, and
`qualification: {"state": "unavailable"}`. Installing the same release and profile
twice produces byte-identical trees.

Neither script uses a credential or the network, invokes a model, reads a git
remote, touches `config/`, `.claude/`, `manager/`, or anything under the home
directory, selects or resolves a profile, grants qualification, or activates
anything. The installer's only new reach is its own sibling `build-release.sh`,
resolved beside it and required to be a regular file; without it nothing installs.
Run `bash scripts/test/target-packaging.test.sh` for the focused proof:
it builds a release from HEAD, installs the default and alternative profiles into
fresh temporary directories, validates each installed tree with its own installed
contract validator, proves the repeat install is byte-identical, greps the
installed trees for personal data and credential patterns, and walks every refusal
above. One packaged upstream source file cites its exception boundary by public
pull-request URL; the test pins that one line as the only permitted operator-name
hit and fails on any other.

The builder packages the exact Git objects a profile pins: every package, config, and prompt reference must resolve at the release commit to the object id (and, for a blob, the mode) recorded in the profile, so a bound adapter whose bytes drifted after the profile was assembled makes the release refuse instead of shipping the drift.

The six manifest files a profile carries are also checked against the profile's own `manifest_ref` pins by id and digest, so a manifest edited after the profile was assembled refuses the release instead of shipping beside a binding that no longer matches it.

Before anything is derived from a profile, the builder requires it to be a valid core document with six complete bindings (each with a manifest reference and a package reference), so a binding missing its package reference refuses the release instead of silently dropping that adapter. The installer's content denylist covers home directories on any host (`/Users/`, `/home/<name>/`, `/root/`), not only macOS.

Each manifest is also validated as a core document, and the package it offers must be the very object the profile's binding for that manifest packages, so re-pinning a profile to an edited manifest that points its package elsewhere refuses the release as well.

## Inactive review-fix loop planner

`loop/v1/plan-review-fix.sh` is the deterministic planner for roadmap step 9, the
safe review-fix loop. It reads six already-recorded documents — one normalized
review observation from the Codex native reviewer, the change's own head/base
context, a credential-policy evaluation, a reconciliation plan, a risk-gate
evaluation, and the change's attempt ledger — and returns exactly one canonical
`review_fix_plan`. That plan holds either one bounded fix request or one refusal
with a named reason. It never calls a model, a producer, a forge, or a network,
and it dispatches nothing: the request is a document, not an action.

The fix request is bounded by construction. It is bound to the exact reviewed head
and base, lists the findings it wants addressed by their provider finding IDs, and
its allowed paths are exactly the files those findings point at — nothing wider.
Only inline findings count, because a top-level finding names no file and so
cannot bound anything. Severity comes from the committed
`loop/v1/review-fix-policy.json`: a finding is actionable only when its
lower-cased provider severity is on that policy's actionable list, so nits, P3s,
and severities the policy does not recognise are never acted on. The same policy
carries the hard attempt limit (2). `push_allowed` is always `false`, and when the
change carries any approval the request says so with
`loop.no-push-after-approval`; the planner has no way to say `true`, because
nothing here is authorized to push.

Refusal comes first and wins, in a fixed order: `kill-switch`,
`boundaries-unproven`, `review-stale`, `degraded-review`, `approval-present`,
`attempt-limit`, `no-actionable-findings`. Boundaries are unproven whenever the
credential, reconciliation, risk, or attempt-ledger document handed in is not the
exact one the change context pins by kind, id, and SHA-256; whenever the
credential or risk verdict is anything but `satisfied`; whenever the reconciliation
plan still carries pending, in-flight (`concurrency.active_pending`), or deferred deliveries or operator messages; or whenever the ledger
belongs to another change or was recorded after the context was observed. The
three boundary documents are checked field for field against the full shapes
their own producers emit — `control/v1/credential-policy.jq`,
`control/v1/risk-gates.jq`, and `orchestrator/v1/reconciliation-plan.jq`, down to
every reference's kind, schema version, and media type and every delivery,
deferral, suppression, and operator message — so a stub carrying nothing but an
envelope and a verdict cannot prove a boundary.

The planner never trusts the observation's own list of stale bindings. It
recomputes every binding the Codex native reviewer checks — repository, change
request, head, base, review id, GitHub app id, and observation time — from the
observation's trust context against its own snapshot, and refuses `review-stale`
when any recomputed binding differs, so an observation whose list was cleared
after the fact cannot drive a fix. A list that disagrees with the recomputation is
itself a refusal, in either direction: a cleared list over a genuinely stale
review, and a list claiming staleness the recomputation does not find, are both
`review-stale`. The review is stale as well when the adapter reports the stale
state, or when its head, base, repository, or change request is not the change's
current one.

A review is degraded when it was dismissed, timed out, failed, is not complete, or
never reached `COMPLETED`; a partial review can never scope a fix, so
`complete: false` always refuses. When a review does claim to be complete, its
reported top-level and inline counts must equal the lengths of the arrays it
carries; a complete review whose counts and findings disagree is a malformed
document, refused as a shape violation rather than planned from the short array.
An approval recorded on the exact reviewed head refuses outright; an approval on
an earlier commit only forbids the push.

Every input is treated as untrusted. The driver requires each of the six inputs to
be an absolute path to a regular non-symlink file of at most 1 MiB, holding exactly
one JSON text in canonical `jq -S -c` bytes within fixed depth, member, and string
limits; it pins jq 1.6 by release digest and runs from a private copy; and it
re-checks the driver, policy, program, jq, and all six inputs after the plan is
built, so an input moved during the run is refused rather than used. Every failure
prints one `E_*` class and nothing else. The planner re-validates the whole shape
of each document it reads, so a forged adapter observation, an extra field, or a
miscounted ledger is refused, not interpreted.

The planner proves nothing about the boundaries themselves. It reads their
recorded verdicts as input claims and binds them by identity; a credential or
risk evaluation only becomes `satisfied` when a qualified evaluator says so, which
no shipped evaluator can do while everything here is inactive. So on today's repo
this planner refuses with `boundaries-unproven` for real inputs, which is the
intended construction-mode answer. Enabling this loop for real is a step-8/9
operator decision taken after the operating-mode transition; this unit only
produces a request document and grants no authority, qualification, or activation.

Run the focused proof with:

```sh
bash scripts/test/loop-review-fix-planner.test.sh
```

The planner also re-derives the observation's own facts before trusting it: a terminal status must carry `terminal_at`, only a dismissed review may carry `dismissed_at`, an open status carries neither, timestamps must be ordered, and the claimed `state` and `reason_id` must be exactly what the normalizer derives from the snapshot. A snapshot that says completed while also dismissed, or a review marked incomplete that still claims a settled state, is refused as malformed rather than planned from.

A finding that names a constitution or protected path (the policy's protected prefixes, root files, and segments, compared case-insensitively) is never handed to the autonomous producer: it is left out of the fix request's allowed paths and listed under `excluded_protected_findings` for a human, and a review whose only actionable findings are protected refuses with `no-actionable-findings` and the detail `findings.protected-path-excluded`.

The observation is checked with the normalizer's own shape predicates, copied verbatim from `adapters/codex-native-reviewer/v1/normalize.jq`, so the planner accepts exactly what the normalizer emits and nothing else.

## Inactive shadow reproduction slice

`shadow/v1/` is the Roadmap's step-7 shadow vertical slice: one narrow, read-only
workflow, run here only on fixtures. The workflow is incident reproduction —
take a reported failure, go back to the exact revision where it was seen, run the
failing check again, and say whether it still fails. `no-change` and
`inconclusive` are real answers, not failures of the run.

An **incident record** is the canonical intake artifact. It names the incident
id, the target repository, the exact source revision, the failing check (a
repo-relative path plus an expected SHA-256, or a named deterministic check id),
a short symptom line, who reported it, when it was observed, and an explicit
`deploy_authority: "none"`. `shadow/v1/validate-incident.sh` checks one record
against `shadow/v1/incident-record.jq` and returns one canonical receipt. It runs
on the pinned jq 1.6 and refuses anything that is not exactly one canonical JSON
text in a regular, non-symlink file inside a fixed size. Validating a record
creates no issue, no change request, and no deploy authority.

`shadow/v1/shadow-environments.json` is the committed list of execution
environments a shadow run may use. It starts with exactly one entry,
`env.local-macos-fixture`, marked `fixtures-only` and `unproven`. Adding an
environment is a reviewed change to that file; no run may add one.

`shadow/v1/reproduce.sh` is the driver. It takes one incident record, one
execution-environment claim, the control policy set and duty evaluation that
claim binds, one materialization input, a local source Git directory, and three
caller-owned directories (candidate, scratch, state). It refuses to run unless
the claim's document id is listed in the environment file **and** the real
sandbox-policy evaluator (`control/v1/evaluate-sandbox.sh`) returns `satisfied`
for it. It then materializes the incident's exact revision through the local Git
materializer with an empty producer patch — a materialization input that carries
any patch bytes, or that asks for network, is refused outright — so the candidate
commit is the incident commit and nothing is changed. It reads the named blob out
of that candidate repository and compares its SHA-256 with the expected one.

The run emits one **shadow record** whose outcome is exactly one of `reproduced`
(the check still fails there), `no-change` (the check passes there, so the
incident does not reproduce at that revision), or `inconclusive` (the environment
was not listed, the claim was not satisfied or was refused, the check has no
runner here, materialization was impossible, or the check path could not be
read). Every inconclusive answer carries a reason id. The record is a documented
wrapper: it does not mint a core v2 `stage_result` of its own, it binds the
materializer's real one by schema version, kind, id, and digest, and writes that
document beside it so the reference is recoverable. The run also seals one
telemetry trace ledger and validates it through `telemetry/v1`'s own validator.

Every output says what it is not: `authority: "none"`,
`deploy_authority: "none"`, `qualification: {state: "unavailable"}`,
`shadow: true`, `activation_state: "inactive"`. The driver produces no patch, no
change request, and no forge or network call; the only Git it runs is reading
objects. All timestamps come from the incident record, never the clock, so two
runs of the same inputs produce byte-identical output.

This is the fixture proof only. The self-host proof and the external-target
proof happen after the operator-merged operating-mode transition, and each new
execution environment is a separate reviewed addition to
`shadow/v1/shadow-environments.json` with its own evidence.

Run the focused test with `bash scripts/test/shadow-slice.test.sh`.

The read-only guards on the materialization input (no producer patch bytes, network mode deny, revision equal to the incident's) run on every invocation before the environment verdict is consulted, so an unlisted or unsatisfied environment can never turn a writable input into an inconclusive shadow record: it is refused outright.

The read-only guards now run before the environment registry is consulted and before the sandbox evaluator is invoked, so the ordering the paragraph above promises holds in the code as well. A `file-digest` check whose path names a directory or any non-blob object at the incident revision is an unreadable check (`check.unreadable`, inconclusive), never a failed run.

## Inactive maintenance loop

`maintenance/v1/` is the maintenance half of the loop the Roadmap's twelfth item
describes: deterministic control bands and scans turn what the repo already
measures into new intents for a service owner to triage, and a shipped incident
that was reproduced turns into an eval seed case. It is inactive. It files no
issue, opens no change request, deploys nothing, installs nothing, activates
nothing, invokes no model, reads no credential, touches no network, and grants
no authority. Everything it produces is a JSON document written into a
caller-owned directory that the caller supplied empty.

`control-bands.json` is the band policy: seven named bands, each with a fixed
threshold and one plain-English line saying what it is for. No eval case may be
failed. No eval case may be inconclusive. The sealed trace ledger may record no
refused event. At least one recorded case must show a repeated event suppressed
after it was acknowledged, and at least one must show a stranded attempt
recovered. A rollback rehearsal that succeeded must be no more than thirty days
old. Every stale-and-moved-artifact case must pass, counted as a rate in parts
per thousand.

`bands.jq` holds the shape every input must have and one pure function from the
supplied documents to a per-band observation. Each metric is a count or an age
over the documents handed in: the eval dashboard's own quality and recovery
counts, the events in the sealed telemetry trace ledger, and the rollback
rehearsal records. The rehearsal age is whole days between the newest successful
rehearsal and the dashboard's own recorded time, so nothing reads a host clock.
A metric that cannot be counted from the documents supplied — no rehearsal
record at all, an empty family — is reported out of band with the reason
`maintenance.metric-unmeasurable`. It is never quietly treated as in band.

`scan.sh` takes one eval dashboard, one sealed trace ledger, one kill-switch
evaluation, an empty output directory, and up to thirty-two further documents
that are each either a security-scan finding or a rollback rehearsal record.
A `maintenance_scan_finding` is deliberately small: the scanner that reported
it, the rule it matched, a severity, a repository-relative path, and the digest
of the evidence the scanner kept. The driver pins jq 1.6 by digest and refuses
to run an unverified one, snapshots every input without following a symlink,
requires each file to be exactly one canonical JSON text inside a size bound,
and proves the ledger is really sealed by running it through the existing
telemetry trace-record validator before any band counts an event in it.

The output is one canonical `maintenance_scan` record naming every band, whether
it held, the value that was measured, and the digest of every document the scan
read. For each crossed band and each high-severity finding it also writes one
canonical intent document, named `intent-band-<band id>.json` or
`intent-finding-<finding id>.json`, so the same inputs always produce the same
file names and one intent per band per scan. Each intent carries the sections
this repo's own `work/<slug>/intent.md` uses — problem, proposed outcome,
affected users and systems, constraints, open questions — plus `owner:
unassigned`, `triage_state: pending`, `deploy_authority: none`, a guessed risk
tier, and the evidence digests behind it. They are drafts for a human, not work
orders. If the kill-switch evaluation is anything other than `satisfied`, the
scan records the bands and writes no intent at all, with the reason
`maintenance.kill-switch-engaged`.

`incident-to-eval.sh` closes the loop the other way. Given one shadow incident
record and the shadow reproduction record for it, it writes one eval seed case
skeleton for the eval family the incident belongs to. The map from an incident's
failing check to a family is closed: a file-digest check belongs to the
stale-and-moved-artifacts family, and anything else is refused with `E_FAMILY`
rather than guessed at. The two records must actually belong together — the
shadow record's incident digest, id, failing check, revision, and repository all
have to match the incident it was handed. A reproduced run becomes the
expectation `{accepted, stale}`; a run that found nothing becomes the passing
baseline `{accepted, completed}`; an inconclusive run proves nothing and is
refused. The expectation, the case's field list, and its request role are all
read out of that family's real seed set in `evals/v1/`, and the produced
expectation must already be one that seed set uses. The skeleton names the
fields it filled and the fields still pending, and carries a provenance block
binding the incident and shadow digests. It never modifies a seed set: the
skeleton is written to the output directory for a later reviewed change.

Everything fails closed with one token on standard error and no output:
`E_USAGE`, `E_PARSE`, `E_CANONICAL`, `E_LIMIT`, `E_SHAPE`, `E_RELATION`,
`E_FAMILY`, `E_WORKSPACE`, `E_RUNTIME`. A relative path, a symlink, a named
pipe, a file holding two JSON documents, a non-canonical file, an oversized
file, an unsealed or tampered ledger, an unknown extra document, two findings
with the same id, and a non-empty output directory are all refused, and nothing
is written.

Run the focused test with:

```sh
bash scripts/test/maintenance-loop.test.sh
```

It builds its own fixtures, seals its own trace ledgers, and proves the happy
paths byte for byte on a repeat run alongside every refusal above.
