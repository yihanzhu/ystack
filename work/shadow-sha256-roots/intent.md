# Intent: Support algorithm-bound SHA-256 shadow source roots
Author: Codex (intent author under the operator's Roadmap program). Status: draft.

Tracks #280.

## Problem

The shadow environment registry and driver currently require source roots to be
40 lowercase hexadecimal characters. A repository using Git's SHA-256 object
format has a 64-character root, so it cannot pass this admission check even though
other source checks already support its algorithm.

The completed `shadow-env-self-host` initiative deliberately registered SHA-1
repositories and accepted the 40-character rule. It fulfilled that scope. This
follow-up supersedes that width restriction in its spec's R1/R5 and root comparison,
and the corresponding plan requirement. The earlier SHA-1 registration outcome
remains complete; this is a separate extension.

## Proposed outcome

The registry can represent a SHA-256 source root, and the driver compares it using
the validated incident algorithm: 40 lowercase hexadecimal characters for sha1,
64 for sha256. The selected registry root, observed root and actual source object
format must agree. Accepting either width without its algorithm binding is not
sufficient.

The existing SHA-1 path remains valid. A malformed registry still fails its shape
check; a well-shaped but nonmatching source remains inconclusive with
`environment.unlisted`, before sandbox evaluation or materialization.

## Affected users and systems

This supports future shadow workflows whose source history uses Git SHA-256.
It concerns the shadow driver, its registry representation contract, full-registry
byte checks, documentation and regression tests. It contributes to the Roadmap's
portable source identities and step 7 shadow slice.

## Constraints

Keep both committed registry entries and the full registry bytes unchanged. Do not
replace an existing root, add a real environment, or broaden authorization to
manufacture a positive test. A private copied runtime with a synthetic registry
can provide test evidence only; it is not a committed registration or real-environment
qualification.

Preserve exactly one matching environment/repository entry, source purity and
object-format checks, the bounded root query and captured success status, a single
nonempty lowercase root, exact equality, and admission ordering. Retain registry
snapshot/digest binding and rechecks, source/component non-mutation checks, and all
existing negative cases. No fallback or algorithm inference replaces those checks.

Design must require a full driver-chain positive with an actual synthetic SHA-256
history and coherent incident, qualified identity and materialization inputs.
A regex-only check or materializer-only SHA-256 success is not enough. Preserve the
complete SHA-1 path and test algorithm/width mismatch and malformed versus unlisted
outcomes. Describe private copied-runtime evidence honestly.

This changes a security admission boundary and retains the high-risk design and
separate plan gates. No real target execution, activation, credentials, network,
new sandbox policy or broader runtime authority is included. Earlier accepted
artifacts remain historical records; this chain records the explicit supersession.

## Open questions

Design must choose the smallest representation and comparison change that binds
root width to the validated algorithm without weakening admission. It must specify
the private synthetic fixture's complete identity chain, prove the shipped registry
stays byte-identical, and make failed admission's lack of downstream effects visible.
