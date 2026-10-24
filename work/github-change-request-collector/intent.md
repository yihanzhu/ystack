# Intent: Collect bounded GitHub change-request observations
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #304.

## Problem

Roadmap step 4 needs a working GitHub forge adapter. The current
`adapters/github-forge/v1/normalize.jq` validates supplied snapshots but collects
nothing. Maintainers cannot use its synthetic tests as evidence that real provider
responses contain every required fact or describe one consistent change.

Three gaps need an honest answer. PR and file responses do not attest the reading
App's identity. Some changes may lack usable patch text. Paginated responses do not
form an atomic revision snapshot. Copying an expected App ID, substituting an empty
patch digest or treating matching reads as atomic would invent evidence.
This is a known implementation gap, not a reported production incident.

## Proposed outcome

Provide an inactive, bounded collector with a real HTTPS GET implementation for
GitHub.com change requests. The same request construction, response reading,
mapping and failure behavior can be exercised through a private scripted connection
in tests. The outcome is a functional capability, not another fake-only collector.

It checks the expected repository and change-request identity, binds head/base and
observation facts, handles pagination within explicit bounds, and returns truthful
collection evidence. Its relationship to the existing normalizer is defined and
reviewed. A missing identity, patch or consistency fact remains unavailable,
inconclusive or refused. It never becomes success by copying an expectation.

The done-signal is a restorable collector with passing tests of its real collection
path, including normalizer integration where the accepted mapping permits it and
clear failure or unavailable outcomes elsewhere. That proves the implemented
behavior under controlled inputs. It does not prove live transport, qualify GitHub,
or complete Roadmap step 4. A later consumer still checks freshness and authority.

## Affected users and systems

This serves maintainers building the default adapter path and later trusted
consumers of change-request observations. GitHub behavior stays in its adapter;
the portable core remains independent of the provider. The current default profile's
local Git materializer remains selected. No real target or provider is used here.

## Constraints

Keep this one change-request collection concern. Preserve normalizer safeguards
and tests. Any required adapter-contract amendment passes the affected artifact
gates explicitly. A change to an accepted proof standard or authority boundary
returns to the operator as a concrete decision; this intent does not approve one.
The security-sensitive identity and transport boundary retains the applicable risk,
plan, independent review and CI gates before implementation.

Use a fixed HTTPS origin and allowed GET routes, validated route inputs, pinned
API and media choices, certificate validation, bounded responses/pages/time and
safe error records. Exclude arbitrary URLs or commands, public fake-success
switches, inherited proxy/netrc/gh configuration, ambient token discovery and
credential helpers. Do not create tokens or perform POST/write actions. Exclude
provider retries, caching, Git object fetching or diff reconstruction, Actions
collection, other forges, model/harness execution and a general provider framework.

Implementing the capability does not authorize actual provider network or credential
use. Tests use no sockets, real credentials or provider services. If a trusted
credential-provider receipt is needed, name that dependency and its unavailable
behavior; never manufacture it. Credential supply or use, real-provider qualification,
installation, profile selection, activation and target execution remain separate
operator decisions.

Keep complete proof and restoration documentation. Tests cover missing facts,
malformed, truncated and oversized responses, pagination drift, duplicate or missing
files, unavailable patches, errors, limits, interruption, redaction and forbidden
destinations. Add new restore-critical files to the manifest. No passing fake result
stands in for real-provider evidence.

## Open questions

Which provider field identifies the change request? How do provider repository IDs
map to canonical head/base revisions, including changes from forks?

Which App and authentication facts can be established, by whom, and from what
trusted evidence? What happens when that evidence is absent?

What exactly does each patch digest cover? What do completeness and freshness mean
when patch material is unavailable or multiple responses are not atomic? Which
bounded outcome preserves the existing safeguards when a required fact is missing?

How will the collector feed the normalizer without weakening its checks? What
precise limits, redirect handling, cancellation and error behavior are required?
Resolve these questions from primary provider documentation in the spec and plan;
no particular research option is accepted by this intent.
