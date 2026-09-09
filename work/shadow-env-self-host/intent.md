# Intent: Register the self-host execution environment
Author: Yihan Zhu (operator). Status: draft.

## Problem
The shadow driver will only run in an environment that is already listed in the
committed registry. Today that registry lists one environment, and it is for
fixture repositories only. So the first self-host run cannot happen at all: there
is no listed environment that describes working against ystack's own source. The
roadmap is explicit that each environment is added by its own reviewed change and
that no run may add one, so the block cannot be worked around at run time. I feel
this as the operator: step 7 is the next thing I want to do and it is stalled.

## Proposed outcome
My own local macOS checkout, working against ystack's own scrubbed bare source
repository, is listed as a self-host environment. It is still marked unproven,
because nothing has proven it yet. The registry stays inactive. Every place in
the docs and tests that today says the registry has one entry says something
true instead. After this, a self-host run is permitted by the registry; whether
one happens is a separate decision.

## Affected users and systems
Me, as the only operator. The ystack repo: the shadow environment registry, the
test that pins it, and the three documents that count its entries. Nothing
outside this repo, and no other environment.

## Constraints
- The registry is an authorization list, so this is a security control. By the
  repo's own rule that makes it a high-risk change: plan-only PR path, and I
  merge it myself.
- The registry file must stay exactly one canonical JSON text.
- The test that pins the registry and the docs that count its entries move in
  the same change, so nothing is left saying "one environment."
- No run happens as part of this. No validator or enum work happens here.

## Open questions
- Do `evidence_scope` and `proof_state` deserve a validator with enumerated
  values? None exists today. Separate follow-up, or not worth it?
- Is a Linux self-host environment wanted now, or later?
- What would actually prove an environment, so `proof_state` can stop being
  `unproven`?
