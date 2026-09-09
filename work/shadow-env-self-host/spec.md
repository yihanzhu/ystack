---
intent-blob: a606f5f2f67d247d4d7827684322e15ae10b4dc9
risk: high
drafted: 2026-09-09
---

# Spec: shadow-env-self-host

The shadow driver refuses any execution environment not listed in
`shadow/v1/shadow-environments.json`. That file lists one environment today and it is
fixture-only, so no self-host run is permitted at all. This change lists one more —
the operator's own macOS checkout against ystack's own scrubbed bare source
repository — and makes the test and docs that count the entries true again. No run
happens here.

## Requirements

**R1.** The registry gains exactly one new entry, appended *after* the existing
`env.local-macos-fixture` entry (order: fixture first, new one second):
`environment_id` `env.local-macos-ystack-self`; `description` `Operator's local macOS
checkout, ystack's own scrubbed bare source repository.`; `evidence_scope`
`self-host`; `proof_state` `unproven`. No fifth member on the entry.

**R2.** `.body.activation_state` stays `inactive`, `.body.registry_version` stays
`v1`, and `.id` (`shadow.environments.v1`), `.kind` (`shadow_environment_registry`),
`.schema_version` (`1`) and the existing entry's four values are unchanged.

**R3.** The file stays exactly one canonical JSON text: `cmp` of the file against
`jq -S -c . <file>` succeeds. On main it is a single line whose last byte is `0a`
(verified) and that `cmp` passes; preserve both. `jq -S -c` emits the trailing newline
itself, so writing its output is enough. `reproduce.sh`'s `canonical_json` and the
test's `registry-canonical` check depend on this byte-exactly.

**R4.** `reproduce.sh` still accepts the registry. Its shape check (the `E_RELATION`
jq near line 183) requires `schema_version == 1`, the kind, `activation_state ==
"inactive"`, and an `environments` array of length 1–64 whose every `environment_id`
matches `\A[a-z0-9][a-z0-9._:-]{0,127}\z` — two entries and the new id satisfy all of
it. The per-run lookup (near line 265) requires `[.body.environments[] |
select(.environment_id == $id)] | length == 1`; the new id differs from the fixture
id, so the fixture run still finds exactly one.

**R5.** `scripts/test/shadow-slice.test.sh` (the `registry-contents` block, near lines
322–328) pins the two-entry registry: `map(.environment_id) ==
["env.local-macos-fixture","env.local-macos-ystack-self"]`, both `evidence_scope`
values (`fixtures-only`, `self-host`) and both `proof_state` values (both `unproven`).
Its `pass` message stops saying "exactly the one ... fixture environment" and states
something true of two entries, including that neither is proven.

**R6.** The five doc passages that say the registry has one entry are updated, with no
other prose change. Confirm each by grepping `shadow-environments`; line numbers are
indicative.
- `docs/components.md` ~1194 — "starts with exactly one entry" becomes two, named with
  scope and proof state.
- `docs/components.md` ~1247 — the fixture-proof-only paragraph must not read as if no
  self-host environment is listed: it is listed and unproven, its proof still a
  separate later step.
- `docs/transition.md` ~65 — "lists exactly one execution environment" becomes two,
  both `unproven`, so "nothing has ever run against a real target" stays true.
- `docs/transition.md` ~183 — the "added by its own reviewed PR" sentence notes the
  self-host environment is now listed and the external-target one is not.
- `docs/transition-kit.md` ~247 — "must first be listed" becomes "is now listed", the
  run itself still gated.

**R7.** No run writes the registry: the existing never-written check (same test, near
lines 604–610, re-digesting `shadow-environments.json` among the components after the
driver runs) must pass unchanged. Do not edit it.

**R8.** Nothing else under `shadow/v1/` changes — not `reproduce.sh`, the `.jq`
programs, or `validate-incident.sh`. `ci/required-files.txt` is unchanged: the registry
path is already listed and no new file is added.

**R9.** Proof: shellcheck 0.11.0 `-x -S style` clean on the one edited shell file,
`bash scripts/test/shadow-slice.test.sh` all-pass, `bash
scripts/test/portable-core-schema.test.sh` 0 failures, `bash scripts/check-rename.sh`
clean, required CI green.

**R10.** Size: well under 60 changed lines across five files
(`shadow/v1/shadow-environments.json`, `scripts/test/shadow-slice.test.sh`,
`docs/components.md`, `docs/transition.md`, `docs/transition-kit.md`).
`review_size: standard`; no exception claimed.

## Design

1. **Registry.** Rewrite canonically in one step instead of hand-editing the line:
   `jq -S -c --arg d "Operator's local macOS checkout, ystack's own scrubbed bare
   source repository." '.body.environments += [{environment_id:
   "env.local-macos-ystack-self", description:$d, evidence_scope:"self-host",
   proof_state:"unproven"}]'` over the current file, to a temp file, then move it into
   place. `-S` sorts object keys while arrays keep their order (so the new entry lands
   second), and `-c` plus jq's trailing newline reproduce today's byte shape. This was
   tried on a copy while drafting: the result is canonical, and R4's shape check and
   fixture lookup both pass on it. Still verify with R3's `cmp` before committing.
2. **Test pin.** Update the `registry-contents` assertion and its pass message; the
   test must fail before step 1 and pass after both.
3. **Docs.** The five passages, nothing else.

Do not touch `reproduce.sh`: the registry is data it reads, and its shape check and
lookup already tolerate more than one entry.

**High-risk path, before any of the above.** Draft `work/shadow-env-self-host/plan.md`
on `ystack/plan/shadow-env-self-host` as a plan-only PR (`Tracks #263`), get
independent review and green CI, and let the operator merge it; record the merged
default OID as `plan-base`. Only then create `ystack/impl/shadow-env-self-host` from
updated main and write code there. That PR is the one using `Closes #263`.

## Out of scope

- Any shadow run. Listing an environment only permits one.
- A validator or enumerated values for `evidence_scope` / `proof_state`. None exists
  today; adding one changes the registry's contract and every consumer, so it is a
  second concern with its own risk decision. Carried forward as its own initiative.
- A Linux self-host environment. `reproduce.sh` pins jq only for `Darwin:*` and
  `Linux:x86_64` and the operator has no Linux runner, so a listed Linux environment
  could not be exercised. Carried forward.
- Deciding what proves an environment. `proof_state` leaves `unproven` only by a later
  reviewed change to this file citing recorded run evidence; that belongs to the
  self-host-run initiative.
- Any other environment including the external-target one; `activation_state`,
  real-target use, credentials, and every other gate.

## Areas of concern

- **High risk, and not because of size.** The registry is an authorization list:
  `reproduce.sh` refuses to run in an unlisted environment, so this file is the control
  deciding where the driver may execute. `work/README.md` classes security controls as
  high risk, so widening that list is high risk however small the diff — hence the
  plan-only PR, independent review, and operator merge. Do not re-argue it as routine
  on size grounds.
- **What it widens.** Afterwards the registry permits a read-only shadow run against
  ystack's own source: the intended step-7 unblock, but a real widening of the driver's
  allowed execution surface and the first entry that is not fixture-only.
- **Truthfulness rail (AGENTS.md).** Nothing may claim proof it does not have.
  `proof_state: unproven` and the doc edits exist for that: after the change no file may
  imply this environment has been exercised.
- **Construction mode is retired.** PR #261 set `config/construction-mode.json` to
  `status: retired`, and the `AGENTS.md` construction overlay applies only while that
  record says `active` — so it does not apply here, and the normal rules govern this
  initiative in full: the intake record, G1, this G2 spec with its accepted risk, the
  high-risk plan-only PR, and operator merge. The registry stays
  `activation_state: inactive`, and this change authorizes no real target, credential, or
  production action.
- **Constitution paths.** Nothing here touches `.github/**`, `.claude/**`, `AGENTS.md`,
  `CLAUDE.md`, `REVIEW.md`, or `ROADMAP.md`. If the work seems to need one, stop — that
  is a different initiative.
- **Prose counting a data file drifts.** The test pin is the durable check; the five doc
  passages move in the same PR so nothing is left saying "one environment."
