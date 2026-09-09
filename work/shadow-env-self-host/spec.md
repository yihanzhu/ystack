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
repository — and, because an entry today authorizes an environment id against *any*
repository, binds every entry to the one target repository it is for and makes the
driver enforce that binding. The test and docs that count the entries become true
again. No run happens here.

## Requirements

**R1.** Registry schema: every entry carries exactly five keys — `description`,
`environment_id`, `evidence_scope`, `proof_state`, `target_repository_id` — and no
others. `target_repository_id` is a string matching `\A[a-z0-9][a-z0-9._:-]{0,127}\z`,
the same id charset `environment_id` already uses. The existing
`env.local-macos-fixture` entry gains `target_repository_id` `fixture.target` — the
repository id every fixture incident in the shadow test already carries — and keeps
its other four values unchanged.

**R2.** The registry gains exactly one new entry, appended *after* the fixture entry
(order: fixture first, new one second): `environment_id`
`env.local-macos-ystack-self`; `description` `Operator's local macOS checkout,
ystack's own scrubbed bare source repository.`; `evidence_scope` `self-host`;
`proof_state` `unproven`; `target_repository_id` `repo.ystack`, the id this repo
already uses for its own repository across `profiles/` and `packaging/v1/`.

**R3.** `.body.activation_state` stays `inactive`, `.body.registry_version` stays
`v1`, and `.id` (`shadow.environments.v1`), `.kind` (`shadow_environment_registry`)
and `.schema_version` (`1`) are unchanged.

**R4.** The file stays exactly one canonical JSON text: `cmp` of the file against
`jq -S -c . <file>` succeeds. On main it is a single line whose last byte is `0a`
(verified) and that `cmp` passes; preserve both. `jq -S -c` emits the trailing newline
itself, so writing its output is enough — and for the same reason R8's `cmp` of a
`jq -S -c`-built expectation is exact, needing no newline fixup on either side.
`reproduce.sh`'s `canonical_json` and the test's `registry-canonical` check depend on
this byte-exactly.

**R5.** Driver edit one, the shape check. The `E_RELATION` jq at
`shadow/v1/reproduce.sh:182-188` today requires `schema_version == 1`, the kind,
`activation_state == "inactive"`, and an `environments` array of length 1–64 whose
every `environment_id` is a string matching the id charset. It additionally requires
every entry's `target_repository_id` to be a string matching that same charset, so a
registry that omits the binding is refused with `E_RELATION` instead of silently
authorizing everything.

**R6.** Driver edit two, the per-run lookup. The lookup at
`shadow/v1/reproduce.sh:267-268` is today `[.body.environments[] |
select(.environment_id == $id)] | length == 1`, where `$id` comes from the
caller-supplied claim. It selects on **both** `environment_id == $id` **and**
`target_repository_id ==` this incident's `.body.target_repository_id` — a value the
driver already parses into `repository_id` at `shadow/v1/reproduce.sh:191`; pass it as
a second `--arg`. Exactly one entry must match, as today.

**R7.** No new outcome vocabulary. An entry that exists but is bound to a different
repository does not match, so the run falls through to the **existing**
`environment.unlisted` branch already initialized at `shadow/v1/reproduce.sh:258-264`:
`outcome: inconclusive`, `reason_id: environment.unlisted`, and the environment,
materialization and check sections all `absent`. No new reason id, no new record
field, no change to the record shape, no new error code.

**R8.** Consumers untouched, and proven so. Because R7 adds no reason id and no record
field, the reason/state table copied out of the driver into `scope/v1/scope-gates.jq`
(`slice_states`, ~lines 536-558, first row `environment.unlisted` → `inconclusive`
with every section `absent`) needs no change. Do not edit it; the only drift is the
indicative line range in the comment above it, left as is. Re-run `bash
scripts/test/scope-qualification.test.sh` and require 0 failures as the proof.

**R9.** `scripts/test/shadow-slice.test.sh` (the `registry-contents` block, near lines
322-328) pins the *complete* registry document, not a subset of its fields: build the
whole expected registry with `"$jq_bin" -S -c` (the way that file already builds
canonical fixtures) and `cmp` it byte for byte against the committed
`shadow/v1/shadow-environments.json`, failing `registry-contents` on any difference.
The expectation spells out both entries in order (`env.local-macos-fixture` then
`env.local-macos-ystack-self`), each with all five keys and no others, plus the five
header fields. This *replaces* the partial id/scope/proof-state assertion, under which
a wrong `description`, a missing or wrong `target_repository_id`, or an extra key
would still have passed — unacceptable for an authorization file. Its `pass` message
stops saying "exactly the one ... fixture environment" and states something true of
two entries: neither proven, each bound to one repository. Any later registry change
must move this pin in the same PR — that is the point of it, not a burden.

**R10.** One new negative case in the same test, beside the existing
`unlisted-environment` case (near lines 436-443), proving the binding is what refuses:
the fixture incident (`target_repository_id` `fixture.target`) run with a claim whose
`.id` is mutated to `env.local-macos-ystack-self` — a *listed* id, bound to
`repo.ystack` — yields `outcome: inconclusive`, `reason_id: environment.unlisted`,
environment evaluation `{state:"absent", reason_id:"environment.unlisted"}`, and
materialization and check execution `absent`. Use the existing `mutate` and
`expect_outcome` helpers; add no new helper. Every other case keeps its current
outcome: the fixture claim id `env.local-macos-fixture` with the fixture incident's
`fixture.target` still matches the fixture entry, so `reproduced`, `no-change`,
`unsatisfied-environment`, `refused-environment` and the rest are unaffected. Any
other changed outcome means the change is wrong.

**R11.** No run writes the registry: the existing never-written check (same test, near
lines 604-610, re-digesting `shadow-environments.json` among the components after the
driver runs) must pass unchanged. Do not edit it.

**R12.** Nothing else under `shadow/v1/` changes — not the `.jq` programs, not
`validate-incident.sh`. `ci/required-files.txt` is unchanged: the registry path is
already listed and no new file is added.

**R13.** The doc passages that count the entries, plus the two describing what the
driver enforces, are updated, with no other prose change. Confirm each by grepping
`shadow-environments`; line numbers are indicative.
- `docs/components.md` ~1194 — "starts with exactly one entry" becomes two, named with
  scope and proof state, and the passage states the binding: an entry authorizes an
  environment for exactly one target repository, and the driver treats a listed id
  bound to another repository as unlisted.
- `docs/components.md` ~1203 — "the claim's document id is listed in the environment
  file" becomes listed *and bound to this incident's target repository*, matching R6.
- `docs/components.md` ~1247 — the fixture-proof-only paragraph must not read as if no
  self-host environment is listed: it is listed and unproven, its proof still a
  separate later step.
- `docs/transition.md` ~65 — "lists exactly one execution environment" becomes two,
  both `unproven`, so "nothing has ever run against a real target" stays true.
- `docs/transition.md` ~183 — the "added by its own reviewed PR" sentence notes the
  self-host environment is now listed and the external-target one is not.
- `docs/transition-kit.md` ~247 — "must first be listed" becomes "is now listed", the
  run itself still gated.

**R14.** Proof: shellcheck 0.11.0 `-x -S style` clean on both edited shell files
(`shadow/v1/reproduce.sh`, `scripts/test/shadow-slice.test.sh`), `bash
scripts/test/shadow-slice.test.sh` all-pass, `bash
scripts/test/scope-qualification.test.sh` 0 failures, `bash
scripts/test/portable-core-schema.test.sh` 0 failures, `bash scripts/check-rename.sh`
clean, required CI green.

**R15.** Size: well under 120 changed lines across six files
(`shadow/v1/shadow-environments.json`, `shadow/v1/reproduce.sh`,
`scripts/test/shadow-slice.test.sh`, `docs/components.md`, `docs/transition.md`,
`docs/transition-kit.md`). `review_size: standard`; no exception claimed.

## Design

In this order, because each step is checkable by the one after it.

1. **Registry.** Rewrite canonically in one step instead of hand-editing the line:
   `jq -S -c --arg d "Operator's local macOS checkout, ystack's own scrubbed bare
   source repository." '.body.environments[0].target_repository_id = "fixture.target"
   | .body.environments += [{environment_id: "env.local-macos-ystack-self",
   description:$d, evidence_scope:"self-host", proof_state:"unproven",
   target_repository_id:"repo.ystack"}]'` over the current file, to a temp file, then
   move it into place. `-S` sorts object keys while arrays keep their order (so the new
   entry lands second), and `-c` plus jq's trailing newline reproduce today's byte
   shape. Tried on a copy while drafting: canonical, and it satisfies R5's
   strengthened check. Still verify with R4's `cmp` before committing.
2. **Driver, two small edits, nothing else.** In the `E_RELATION` shape jq
   (`shadow/v1/reproduce.sh:182-188`), extend the `all(.[]; ...)` predicate so each
   entry must carry a `target_repository_id` string matching the id charset alongside
   its `environment_id`. In the lookup (`shadow/v1/reproduce.sh:267-268`), add
   `--arg repository "$repository_id"` and require
   `.environment_id == $id and .target_repository_id == $repository`. Both were tried
   against the step-1 registry while drafting: the fixture claim with the fixture
   incident still matches exactly one entry; the self-host id against a
   `fixture.target` incident matches none — the `environment.unlisted` fall-through.
3. **Test.** Turn `registry-contents` into a full-document byte comparison — the
   expected registry built with `"$jq_bin" -S -c` and `cmp`'d against the file — update
   its pass message, and add the R10 negative case. The pin must fail before step 1 and
   pass after; the negative case must fail before step 2 (the entry would match on id
   alone) and pass after. That ordering shows each edit does what it claims.
4. **Docs.** The six passages, nothing else.

**High-risk path, before any of the above.** Draft `work/shadow-env-self-host/plan.md`
on `ystack/plan/shadow-env-self-host` as a plan-only PR (`Tracks #263`), get
independent review and green CI, and let the operator merge it; record the merged
default OID as `plan-base`. Only then create `ystack/impl/shadow-env-self-host` from
updated main and write code there. That PR is the one using `Closes #263`.

## Out of scope

- Any shadow run. Listing an environment only permits one.
- Any driver change beyond the two edits in R5 and R6: no new reason id, no new record
  or registry field, no reordering of the driver's stages, no change to the read-only
  guards or the error codes.
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

- **The registry alone was an id allowlist, and that was the P1.** The lookup at
  `shadow/v1/reproduce.sh:267-268` matched on `environment_id` only, and that id comes
  from the caller-supplied claim, so listing `env.local-macos-ystack-self` as data
  alone would have let any caller name that id and run the driver against *any* bare
  source repository handed to it — far wider than "self-host = ystack's own source",
  this change's whole scope. A registry-only edit cannot close that: the driver has to
  compare the entry against something the caller does not choose freely.
- **Why binding to the incident's repository closes it, without touching consumers.**
  The incident already carries `.body.target_repository_id`, the driver already parses
  it (`shadow/v1/reproduce.sh:191`), and the read-only guards already force the
  materialization input's repository and revision to equal the incident's — so
  requiring the entry to name that repository ties authorization to the target the run
  is actually about. A mismatch is simply "not listed for this incident", so the run
  takes the existing `environment.unlisted` branch: same outcome, same reason id, same
  absent sections. That is why `scope/v1/scope-gates.jq`'s copied reason/state table
  stays as it is, and why R8 makes `scripts/test/scope-qualification.test.sh` prove it.
- **The fixture entry's binding preserves today's test semantics.** Every fixture
  incident in `scripts/test/shadow-slice.test.sh` already carries
  `target_repository_id: "fixture.target"`, so binding `env.local-macos-fixture` to
  `fixture.target` leaves every existing case matching as before: no fixture behaviour
  changes, and the only new refusal is a claim naming an environment bound elsewhere.
- **High risk, and not because of size.** The registry is an authorization list:
  `reproduce.sh` refuses to run in an unlisted environment, so this file is the control
  deciding where the driver may execute — and this change now edits that driver's
  enforcement too. `work/README.md` classes security controls as high risk, so widening
  that list is high risk however small the diff — hence the plan-only PR, independent
  review, and operator merge. Do not re-argue it as routine on size grounds.
- **What it widens.** Afterwards the registry permits a read-only shadow run against
  ystack's own source: the intended step-7 unblock, but a real widening of the driver's
  allowed execution surface and the first entry that is not fixture-only. The binding
  holds that widening to the one repository the entry names.
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
- **Prose counting a data file drifts.** The test pin is the durable check; the doc
  passages move in the same PR so nothing is left saying "one environment" or
  describing the lookup as id-only.
