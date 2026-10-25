# Intent: verify historical shadow archives against their recorded controls
Author: Codex (intent author). Status: draft.

## Problem

The offline shadow evidence suite compares two historical declaration-only
archives with current control bytes. The kill-switch decision has changed.
The suite now rejects its first historical positive case before reaching the
remaining checks. The current-control mismatch is real and must still refuse
current use. The archives also need independent proof of their original source
relationships. One comparison cannot establish both facts.

This blocks complete integration proof and makes retained historical evidence
harder to validate. Tracks #727.

## Proposed outcome

Prove historical archive authenticity and current runtime applicability separately.
Both results must follow from independently checked bytes.

- Verify both original archives against independently verifiable frozen control
  dependencies. A digest stated by the archive alone is not source proof.
- Keep current control drift as a hard refusal of current use. Historical validity
  gives no current qualification or fallback trust.
- Run the complete existing suite, including its positive and negative cases.
  Missing, modified, wrongly referenced or extra inputs must still fail.
- Preserve restoration checks and all original archive bytes and classifications.
  Passing these checks establishes offline compatibility, not native qualification.

## Affected users and systems

Repository maintainers, independent reviewers and CI rely on the retained
self-host and external-dummy-target shadow evidence. The affected area is the
existing shadow-self-host-evidence test and any necessary fixed test dependencies,
restore documentation and manifest entries selected through the later gates.

## Constraints

- Preserve both 45-leaf historical archives, their READMEs, digests and recorded
  declaration-only classifications byte for byte. Do not recreate or recapture them.
- Keep all production policy, decision, reader and qualification rules unchanged.
  Historical evidence must not become sandbox-enforced, currently qualified or
  genuine native proof. Its demonstration identities remain demonstration data.
- G2 must settle risk, exact allowed paths, source dependencies, provenance,
  closed inventories and restoration requirements before implementation.
  This intent accepts no fixture-copy or source-reading solution.
- If G2 selects fixed test-only control fixtures, require independently verified
  original bytes, precise provenance, non-executable files and complete backup.
  Do not add a general archive, downloader, diagnostic framework or Git-read protocol.
- Scope is historical test compatibility and its necessary test/docs/manifest work.
  Do not include #701's stale guard or shadow-write fixes. Do not edit production
  code or the historical archives to make the test pass.
- Preserve every existing assertion, relevant CI failure, review limit and final
  acceptance debt. Do not reset #681 R0–R3, #701 R0/R1/R2 or core R0–R3 through #727.
- Keep the artifact chain, separate review, applicable plan gate, full required
  proof and protected merge. No skipped guard, weaker check or renamed test can
  substitute for the two byte-backed results above.
- No new network, credential, SDK/native probe, installation, activation, target,
  deployment, runtime collection or historical execution authority is granted.
  Changes stay inactive. Independent authorized #439 work need not pause.

## Open questions

- Which exact frozen control objects and source relationships must G2 bind for
  each archive, and how will the test verify them independently without execution?
- Which exact test-only paths, non-executable modes and restore entries are needed?
- How will the complete suite prove historical positives and current mismatches
  separately while retaining every original negative and restoration check?
- What risk classification and plan gate follow from that precise design?
