---
spec-blob: cb207baacba6add70ebda50fb59048e67ca44c10
drafted: 2026-09-27
---
# Plan: step8-bounded-write-readiness

Tracks #427. Risk: high.

The accepted spec is a decision-only record. This implementation makes that decision
discoverable and restorable; it builds none of it. The spec binds intent blob
`b0a9fa194218778a555dd4c34ea37faa265caf31`. The spec stays the only source for the
first workflow, the write-shadow record, revision coverage, the enablement record,
the kill-switch register, the eval seeding rules and the ordered child concerns.
This plan follows `work/real-sandbox-boundary/plan.md`: docs, restore text and
manifest entries only, and no separate `decision.md`.

## Files that change

Only these three existing paths may change in the implementation:

- `docs/components.md`: one paragraph at the end of the
  `## Inactive workflow-scope qualification evaluator` section, after its last
  paragraph (the eval-catalog metadata rule) and before
  `## Inactive target packaging`.
- `RESTORE.md`: one paragraph at the end of
  `### Restore the inactive workflow-scope qualification evaluator`, after its
  existing paragraph and before `### Restore the inactive target packaging`.
- `ci/required-files.txt`: a new block immediately after the
  `# Inactive workflow-scope qualification evaluator` block (its last entry is
  `scripts/test/scope-qualification.test.sh`) and before
  `# Inactive target packaging`.

This plan-only stage changes only `work/step8-bounded-write-readiness/plan.md`. The
accepted intent, spec and plan stay byte-identical in the implementation PR.

## Order of work

1. Pass the high-risk plan gate first: independent review, green CI and operator
   merge of this plan-only PR. Then check that main still holds the spec at the
   `spec-blob` above, with `risk: high` and the intent blob above. Record the
   accepted plan blob and the merged default OID as `plan-base`. If main moves
   before the first code commit, follow the `work/README.md` base-move rule (fresh
   non-author `Plan-verdict` plus operator reaffirmation) before any edit.

2. On `ystack/impl/step8-bounded-write-readiness`, created from updated main, add
   this paragraph at the components location above, adjusting wrapping only:

   > The [accepted step 8 bounded-write readiness decision](../work/step8-bounded-write-readiness/spec.md)
   > names the first bounded-write workflow and the evidence that must exist before
   > any write scope can be proposed. It ships no runtime. No write scope is
   > proposable today, this evaluator still refuses an enabled or push-allowed
   > scope, and each of the decision's twelve ordered child concerns needs its own
   > gates before anything can write.

   Keep every existing paragraph of the section as it is. Do not copy the coverage
   table, the child table or any requirement into this paragraph.

3. Add this paragraph at the RESTORE location above:

   > Restore the step 8 bounded-write decision's
   > [intent](work/step8-bounded-write-readiness/intent.md),
   > [spec](work/step8-bounded-write-readiness/spec.md) and
   > [plan](work/step8-bounded-write-readiness/plan.md) from the same commit, using
   > the decision-record block in [the manifest](ci/required-files.txt). Read the
   > spec for the first workflow, the evidence required before any write and the
   > ordered child concerns. Restoring these records enables no scope, commits no
   > kill-switch register and grants no write, credential or publisher.

   Keep the existing focused-test command and paragraph intact. Add no install,
   enable, credential, publish or run command.

4. Add this block, each path once, and keep every existing manifest entry:

   ```text
   # Step 8 bounded-write readiness decision records
   work/step8-bounded-write-readiness/intent.md
   work/step8-bounded-write-readiness/spec.md
   work/step8-bounded-write-readiness/plan.md
   ```

   Separate it from its neighbours with one blank line on each side, as the other
   blocks are. If a path is already present at the implementation base, keep that
   one occurrence instead of adding another. A conflicting artifact identity stops
   work.

5. Read the full three-file diff, run the proof below and open the terminal
   documentation PR with `Closes #427`. Describe it as making the step 8 readiness
   decision discoverable and restorable. Do not claim a write scope, a sandbox
   receipt, a publisher, a kill-switch register, an enablement or a step 8
   completion. Required CI and a fresh independent exact-head/base review come
   before the protected merge.

## What does not change

- No runtime, policy, test or behaviour. `scope/v1/**`, `control/v1/**`,
  `config/**`, `adapters/dormant-publisher/v1/**`, `evals/v1/**` (including
  `evals/v1/eval-catalog.json`), `shadow/v1/**`, `maintenance/v1/**`, `ROADMAP.md`,
  `.github/**` and every `scripts/**` file stay byte-identical.
- No `config/kill-switch.json` and no `config/scope-enablement.json` is created.
  `config/construction-mode.json` keeps `allowed_live_writes: "none"`.
- No `README.md` component row: a row would suggest a component exists. README
  already leads readers to `docs/components.md`, as in the precedent.
- No new `decision.md`, no copied table, no new committed test.
- No credential, network scope, installation, target write, forge action or
  activation.

## Follow-up intakes

The spec's R8 table is the source. Each concern gets its own intake, intent, spec,
plan gate, paths and tests; those intakes are opened separately, and this plan
implements none of them. Landing order is the numbering.

1. Step-7 external-target run (#426, in flight). Depends on: none. Reserved: already
   under DR-6; step 7 closes only with it.
2. Enforcement-evidence binding: authentic receipt kind, exact byte identities,
   consumer checks. Depends on: none. Reserved: none beyond review; no signing
   credential selected.
3. Fixed file-digest verifier (subsumes #314; preparation in #396). Depends on: 2.
   Reserved: none beyond review.
4. VM launcher and supervisor. Depends on: 2, 3. Reserved: installation and native
   qualification on the operator's machine.
5. Shadow-consumer integration: real receipt in the driver and the R2 write-shadow
   record. Depends on: 1, 2, 3, 4. Reserved: the first real write-shadow run.
6. Scope-gate hardening: R7, R2.5 and R3. Depends on: 2, 5. Reserved: none beyond
   review.
7. Kill-switch register bootstrap: commit `config/kill-switch.json` with observation
   cleared and no write entry. Depends on: 4, 6. Reserved: the operator commits the
   register; operator merge of `config/**`.
8. Durable telemetry (subsumes #307). Depends on: none. Reserved: none beyond review.
9. Real gate evidence bound to the scope's own `stage_request_ref`, plus the R5.4
   kill projection. Depends on: 5, 7. Reserved: none beyond review.
10. Eval seeding (R6). Depends on: 5, 9. Reserved: model graders; any grader or
    trial-policy change.
11. Real short-lived publisher and post-write check (#304). Depends on: 6, 8, 9.
    Reserved: credential, identity, network scope, first real write.
12. Enablement PR: `config/scope-enablement.json`, the scope's write entry in
    `config/kill-switch.json` and `allowed_live_writes`. Depends on: 1-11 closed and
    step 7 closed. Reserved: activation; operator merge of `config/**`.

**Parallel drafting.** Concerns 2, 3, 8 and the deterministic part of 10 may be
drafted now. Drafting is not landing: each still lands in the order above, and
concern 10's seeds that need the concern 5 and 9 evidence wait for it. Concern 12
strictly follows every other concern and step 7's close.

## Review size

- Implementation PR: `review_size: standard`, about 20-40 added lines across the
  three files (two paragraphs plus one five-line manifest block).
- This plan-only PR is within the soft budget (standard) and needs no separate
  record.

## Risks

- **Overclaiming.** The main risk is wording that reads as if a write scope, a real
  sandbox, a kill-switch register or a publisher now exists. Review both paragraphs
  against the whole spec, not only against the word "decision". Each must say no
  write scope is proposable and nothing is enabled.
- **A second source of truth.** Copying the coverage table, the child table or the
  boundary map into docs would create a copy that drifts. The paragraphs only point
  at the spec. This is why no `decision.md` and no README row are added.
- **Link paths.** `docs/components.md` needs `../work/...`; `RESTORE.md` needs
  `work/...`. A wrong prefix passes CI but breaks restore. The proof resolves each.
- **Manifest drift.** The manifest names the plan, which exists on main only after
  this plan merges, so the implementation must start from updated main. Never
  change artifact bytes to make a check pass.
- **Nearby text.** The existing workflow-scope restore paragraph is left as it is;
  fixing its wording is out of scope here and would widen the diff.
- **Order dispute.** The spec's child order differs from the intent's list. This
  plan restates the accepted order and does not reopen it; a change returns to G2.
- **Rejected alternatives.** An empty PR restores nothing. Implementing concern 2 or
  8 in this initiative would bundle a separate gated concern into a docs PR.

## Proof

Use the recorded implementation base (BASE, a full OID) and the final head in every
report. Record these identity checks before edits and again on the final commit:

```sh
git rev-parse HEAD:work/step8-bounded-write-readiness/intent.md
git rev-parse HEAD:work/step8-bounded-write-readiness/spec.md
git rev-parse HEAD:work/step8-bounded-write-readiness/plan.md
git show HEAD:work/step8-bounded-write-readiness/spec.md | sed -n '1,5p'
git show HEAD:work/step8-bounded-write-readiness/plan.md | sed -n '1,4p'
```

Require the intent blob and `spec-blob` above, the accepted plan blob, `risk: high`,
and both hash links.

Diff scope:

```sh
git diff --name-only BASE HEAD
git diff --stat BASE HEAD
git diff --check BASE HEAD
```

Exactly `RESTORE.md`, `ci/required-files.txt` and `docs/components.md` may differ.
`git diff --check` must print nothing. Read the full `git diff BASE HEAD`.

Required files (the CI `Check required files exist` step, run locally):

```sh
grep -v -e '^$' -e '^#' ci/required-files.txt | while IFS= read -r f; do
  [ -f "$f" ] || echo "missing required file: $f"
done
for f in intent spec plan; do
  grep -Fxc "work/step8-bounded-write-readiness/$f.md" ci/required-files.txt
done
```

The first loop must print nothing; each count must be `1`.

Docs guards (one-time checks, not a new committed test):

```sh
git ls-files --error-unmatch work/step8-bounded-write-readiness/spec.md
(cd docs && test -f ../work/step8-bounded-write-readiness/spec.md)
for f in intent spec plan; do test -f "work/step8-bounded-write-readiness/$f.md"; done
test -f ci/required-files.txt
```

Every new link resolves from its own file to a tracked file, and no heading anchor
is added. Read both changed sections whole to confirm every existing paragraph and
manifest entry is intact.

Gates and tests, without changing them:

```sh
bash scripts/check-rename.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/scope-qualification.test.sh
```

`check-rename.sh` must exit 0; both tests must pass unchanged, which shows the
evaluator still behaves exactly as before. Record the command, head, platform and
full output.

On the exact final head and base, require every existing CI job: checks (required
files, ShellCheck, sharding proof, rename gate), the six test shards of
`scripts/test/run-all.sh` and the ci aggregate. Do not rerun a failed suite until it
passes. A separate read-only reviewer applies Bugs, Security and Compliance passes to
the full diff, the hash links and this evidence; the manager reads the complete raw
review and resolves every Important finding before merge.
