# Intent: capture one owned producer invocation and its response

Tracks #329.

| Deliverable | Boundary retained |
| --- | --- |
| One inactive invocation and response path for the default producer | Existing producer capability and neutral core contracts |
| Actual input, response, terminal state and retained artifact bytes | One owned attempt; no invented execution facts |
| Finite hermetic proof through the same path | No real-provider qualification or activation |

## Problem

The default Claude Code producer normalizer accepts a snapshot and trust context.
It checks their agreement and binds them to the request, profile, target and attempt.
It does not invoke the named harness or capture its response.
An output digest alone does not retain the returned patch bytes.
Consistent declarations therefore leave an execution-to-evidence gap in Roadmap
items 2 and 4.

## Outcome and success criteria

Add one inactive adapter path that starts or submits one owned producer attempt,
captures its bounded complete response and actual terminal state, and retains its
returned artifact bytes. It constructs verified inputs for the existing normalizer.
Invocation, capture, evidence construction and retention form one concern.

Success requires all of the following:

- Bind the actual request, resolved profile, target revision and attempt to the
  delivered input, executable or transport identity, and returned output.
  Conflicting or stale identities cannot produce a usable result.
- Establish what was delivered and returned from the owned invocation itself.
  Requested model, version and cost settings are not measured facts.
  Unavailable facts remain unavailable. Preserve the normalizer's inconclusive
  behavior when required metadata is missing.
- Distinguish changed, no-change, failure, timeout and incomplete response.
  Failure, truncation or incomplete capture cannot manufacture a patch or success.
  A complete no-change response must not require a fabricated artifact.
- Own completion, cancellation and timeout for the same attempt. Retain bounded
  recovery evidence and actual returned artifact bytes with their identities.
  Later consumers must be able to check the retained bytes against the result.
- Exercise the same invocation, capture and retention path with finite owned
  fixture processes or fake connections. Prove exact delivered and captured bytes,
  completion and failure, cancellation and timeout cleanup, partial and oversized
  responses, identity conflicts, and retained recovery evidence.
  Supplied snapshots alone or a disconnected checker do not satisfy this outcome.
- Preserve existing normalizer behavior and its compatibility tests. Keep
  `authority: none`, unavailable qualification and empty effects for an unqualified
  adapter. Add meaningful integration proof and restore records for the new path.

## Security and scope

Keep the current credential policy: model inference is brokered, single-stage,
with no credential exposure, and uses the model execution kind.
Candidate execution and candidate-repository writes remain incompatible with that
credential boundary. Candidate code and returned patches must never execute there.
The default manifest offers evidence and scratch writes, target read and model
invocation, with no offered tools. It does not itself prove enforcement.
The producer receives no forge write credential or publication authority.
Verifier, reviewer and publisher responsibilities remain separate.

This concern belongs to the existing default producer adapter.
It does not rewrite core contracts or add a scheduler, general broker service,
generic sandbox, credential provisioning service or alternative-adapter bundle.
Receiver results, trace persistence, candidate preparation and verifier execution
remain separate work. This intent does not accept or close those dependencies.

No real CLI or provider invocation, credential acquisition, new network access,
installation, activation, real-target execution, release or deployment is authorized.
Hermetic proof establishes local implementation behavior only.
It cannot establish real authentication, enforcement or provider qualification.
A mechanism that needs wider authority returns to the operator with the precise
conflict; it must not silently expand this scope.

## Decisions required at G2

G2 must establish a feasible mechanism for the named default Claude Code producer
within the unchanged credential ceiling. This intent selects no transport.
A raw provider API cannot silently stand in for the named CLI harness.
A configuration flag or mutually consistent declarations cannot prove enforcement.
If the named identity and ceiling cannot both be met, preserve that concrete
conflict for review before implementation. Fixture success cannot resolve it.

The design must specify the actual invocation and broker or transport contract,
input and response framing, ownership, finite limits, cancellation and cleanup,
terminal-state interpretation, retention and recovery boundary, and the verified
handoff to the existing normalizer. It must name exact paths and complete proof.
Security and execution identity make this high-risk work; G2 formally accepts the
risk and design. A separately reviewed, protected-merged high-risk plan precedes code.

## Intake and delivery order

This is the original user-directed #329 concern. The current manager's
[intake resume acceptance](https://github.com/yihanzhu/ystack/issues/329#issuecomment-6378343261)
binds title SHA-256 `c88159574a1a3b0f4bcc59ac0f3fa6634e43da8fcdb447b953433f1568eba1e8`
and body SHA-256 `cdd02678a51c679c557a2c34d2bac1e6b30022a90521f830ab28ee33a2b0c210`.
It follows the direct implementation-first decision recorded by PR #680 in
`work/roadmap-program-authorization/decision.md`.

Complete remaining inactive repository implementation and tests first, through the
required artifact gates. An explicitly bound dependency may remain unaccepted during
implementation. This does not accept that dependency or complete a Roadmap milestone.
Preserve all #558 acceptance debts for final closure together, including native proof,
restoration, independent G3 and protected merge. Do not reopen completed proof or
extend diagnostic engineering. CPU wall remains `NONE`, native qualification
`BLOCKED`, production `EMPTY`, and automation `PAUSED`.

G1 needs independent review and protected merge before G2.
Exact artifact hashes, required CI, independent implementation review and final
acceptance remain gates. Existing attempts and exclusions remain preserved.
