# Operating-mode transition — the proposal

This is the checklist and the exact proposed edits for ending construction mode. It
is **not** the transition, and reading it changes nothing. Construction mode is still
active; every component in this repo is still inactive.

The transition itself is one pull request the **operator** writes and merges by hand.
No agent may author it: `config/construction-mode.json`, `AGENTS.md`, `REVIEW.md`,
`ROADMAP.md`, the whole `.github/` tree, and the `.claude/` settings and hook are all
forbidden paths for agents under the mode record, and construction mode explicitly
cannot activate or broaden itself. So this file names the fields, the values, and the
order — the operator supplies the judgment and the commit.

## 1. What construction mode built

Construction mode was a bounded exception: instead of running each roadmap item
through the full intent → spec → plan → review chain, the accepted `ROADMAP.md` acted
as the program authorization, and the twelve rollout items are being implemented
directly as dependency-ordered units. Every unit is inactive and repo-only — source,
contracts, and a focused hermetic test — and each one reaches `main` only after
required CI and an independent review. The table below is the current state, not a
completion claim: steps 1–6 are on `main`; steps 7, 9, 10, and 11 are open PRs; steps
8 and 12 are still being built. Construction is implementation-complete only when
every row reads `merged`, and the transition PR in §3 must not be written before
then. What construction produces is a portable control plane that has never been
switched on.

| Roadmap step | Unit path | Status |
|---|---|---|
| 1 — Portable control-plane core | `core/v1/`, `core/v2/`, `resolver/v1/`, `adapter-tests/v1/`, `scripts/core-contract.sh` | merged |
| 2 — Control foundation | `control/v1/` | merged |
| 3 — Durable orchestrator | `orchestrator/v1/` | merged |
| 4 — Default adapters | `adapters/github-forge/v1/`, `adapters/github-actions-ci/v1/`, `adapters/claude-code-producer/v1/`, `adapters/codex-native-reviewer/v1/`, `adapters/deterministic-verifier/v1/`, `adapters/dormant-publisher/v1/`, `adapters/local-git-materializer/v1/`, `profiles/default/v1/`, `delivery/v1/` | merged |
| 5 — Agent evals and telemetry | `evals/v1/`, `telemetry/v1/` | merged (framework only — see §2) |
| 6 — Alternative adapters | `adapters/gitlab-forge/v1/`, `adapters/codex-cli-producer/v1/`, `profiles/alternative/v1/` | merged |
| 7 — Shadow vertical slice | `shadow/v1/` | pending PR #251 |
| 8 — Bounded autonomous writes | `scope/v1/` | in progress (no branch or PR yet) |
| 9 — Safe review-fix loop | `loop/v1/` | pending PR #249 |
| 10 — Target packaging | `packaging/v1/` | pending PR #250 |
| 11 — Deploy and rollback | `deploy/v1/` | pending PR #252 |
| 12 — Maintenance loop | `maintenance/v1/` | in progress (no branch or PR yet) |

The per-unit write-ups are in [`components.md`](components.md), indexed from
[`../README.md`](../README.md). A pending PR's write-up lives on its own branch until
it merges.

## 2. What "implementation-complete" means, and what it does not

`completion: implementation-complete` in the mode record means the code exists and
holds its shape. It does not mean the system works.

What is genuinely proven: each unit's contract, refusals, and fail-closed behaviour,
by a focused hermetic test on pinned jq 1.6 against fixtures it builds itself; that
the contracts, the six control policies, the scanner and planner, nine adapter
packages, two profiles, and the eval and telemetry framework all validate against the
same core generation; and — via the 2×2 fake adapter matrix and the alternative
profile — that swapping a harness or a forge does not change the contract.

What is **not** proven, and should not be described as if it were:

- **Nothing has ever run against a real target.** Every run in this repo used
  fixtures or this repo's own Git objects. `real_target_use` is `disabled`, and
  `shadow/v1/shadow-environments.json` (pending PR #251) lists exactly one execution
  environment, `env.local-macos-fixture`, marked `fixtures-only` and `unproven`.
- **Two of the nine required eval families have no seeds.** `evals/v1/eval-catalog.json`
  records `malicious-instructions` and `reviewer-severity-false-positive-negative` as
  `seed_status: declared` with a multi-trial policy and no seed sources. Both need
  real model trials, which construction mode does not authorize. The other seven are
  seeded from deterministic replays of the real inactive evaluators.
- **There is no live default-adapter regression or qualification evidence.** Roadmap
  step 5 asks for regression and qualification evidence from the real default
  adapters. What exists is the framework plus deterministic seeds. No qualification
  record has ever been earned; every component's outputs say
  `qualification: {"state": "unavailable"}`.
- **Cost and latency are absent, not zero.** The dashboard records token, latency,
  and cost telemetry as absent with the reason that no live run exists to measure,
  and records every operating-flow metric the roadmap names (intent-to-spec time,
  plan-to-merge time, queue and human-gate wait, first-pass success, rework, review
  latency, precision and recall, escaped defects, DORA throughput) as absent for the
  same reason. Nothing is estimated.

So the honest summary is: the harness is built and self-consistent; its behaviour
against reality is untested.

## 3. The transition PR

**Precondition:** every row of the table in §1 reads `merged`. Until then this section is a draft of a future PR, not an instruction.

One PR, authored and merged by the operator. Its scope is the mode record, the
ruleset verification, and the documentation that describes the mode as active
(README's construction-mode paragraph, the preamble of `docs/components.md`, and the
present-tense text of this file), so that README and docs stay in sync with the record
as the repo rules require. Nothing else: no component code, tests, or manifest entries.

### 3.1 The fields in `config/construction-mode.json`

Current value → proposed value, and why:

- **`status`**: `"active"` → `"retired"`. This is the load-bearing field. The
  `AGENTS.md` construction overlay applies only while the record is committed on main
  with `status: active`; the `REVIEW.md` review overlay reads the same flag, and
  `scripts/construction-publisher-gate.sh` requires `.status == "active"` before it
  will publish anything. Flipping it turns all three off at once and restores the
  ordinary intake, artifact, plan, and operator-merge rules. The record must stay in
  the tree — `config/construction-mode.json` is a required manifest entry in
  `ci/required-files.txt`, so deleting it fails CI's structure check; it becomes a
  historical record of what the exception covered.
- **`completion`**: `"implementation-complete"` → `"construction-closed"`. The
  construction program is over; the phrase should stop reading like a claim about
  readiness.
- **`effects`**: `"inactive-repo-only"` → `"operating"`. Outputs stop being repo-only
  by definition. Note that this permits activation; it does not perform one. Each
  component is still activated by its own reviewed change.
- **`real_target_use`**: `"disabled"` → `"enabled"`. A named external target may be
  used. Which target is open question 1.
- **`real_target_and_production_credentials`**: `"disabled"` → `"operator-supplied"`.
  Credentials exist, are supplied by the operator per environment, and are never
  committed to this repo or pasted into a chat session.
- **`release_install_activation`**: `"disabled"` → `"operator-action-only"`. Building
  a release and installing it into a target become possible, and remain explicit,
  versioned, human actions — never something a run does for itself.
- **`operating_transition_required`**: `true` → `false`. The transition this file
  proposes has happened.
- **`publisher`**: `"current-operator-authorized-codex-construction-session"` → a
  short-lived, single-purpose publisher identity. The construction session's
  authority to publish its own PRs was the exception; it must not survive the
  transition. The Security architecture section of `ROADMAP.md` names the shape:
  no model, no candidate-code execution, one fixed external write per stage.

Two neighbouring fields are not in the list above but stop being accurate at the same
moment, and the operator should decide them in the same PR:
`allowed_live_writes: "same-repository-delivery-only"` and
`delivery_credential: "current-gh-operator-yihanzhu"`. See open question 5.

### 3.2 The branch ruleset

The record's `post_transition_ruleset` block describes the ruleset that must be in
place on the default branch afterwards: target `default-branch`, enforcement
`active`, pull request required, `required_approving_review_count: 0`, no stale-review
dismissal, no last-push approval, no extra approval for unattributed changes, strict
required status checks with the `ci` check (app id 15368), deletion protection,
non-fast-forward protection, and an empty `bypass_actors` list.

Worth being clear about: the ruleset on `main` today (`ystack-main-gate`, id
21500323) **already matches that block field for field**. Construction mode never
loosened the branch rules. The relaxation lived entirely in the `AGENTS.md` overlay
and in the construction session's publish authorization. So §3.2 is a verification
step, not an edit — confirm the live ruleset still matches, and record that it does.

That also means the transition does not by itself add a human approval requirement to
`main`. If the operator wants one, `required_approving_review_count` has to be raised
deliberately, in both the record and the live ruleset. That is open question 2.

### 3.3 The transition PR is itself high risk

It changes constitution paths and a security control, so it takes the high-risk gate
in full: a plan the operator accepts before the change, review by the cross-vendor
reviewer against the exact head and base, required CI green, and a merge the operator
performs by hand. No agent publishes it, and the construction publisher gate will
refuse it anyway once the record no longer says `active`.

Order matters. The mode record pins `roadmap_blob` and `north_star_blob`; while the
gate is live, a PR that edits `ROADMAP.md` or `NORTH_STAR.md` without updating those
digests fails closed. Keep the transition PR to the record, the ruleset
verification, and the documentation that describes the mode as active — nothing
more. The repo rule that every PR keeps README and docs in sync applies to this one
too: the same PR updates README's construction-mode paragraph, the preamble of
[`components.md`](components.md), and the present-tense text of this file so that
none of them still says construction mode is active once the record says it is
retired. Component code, tests, and `ci/required-files.txt` entries do not change.

## 4. What becomes possible only after the transition

In dependency order, mapped to the rollout steps.

**Step 7 — the shadow slice runs for real.** First the **self-host run**: reproduce
one real ystack incident, read-only, on ystack itself. Then, separately, the
**external-target run**: the same workflow on a fresh unrelated repo the operator
names, with no ystack-specific state copied in. Neither substitutes for the other —
`ROADMAP.md` requires both. Each execution environment must be added to
`shadow/v1/shadow-environments.json` by its own reviewed PR before a run may use it;
the driver refuses an environment that is not listed, and no run may add itself.
`no-change` and `inconclusive` remain honest outcomes.

**Step 5, the live parts.** Authorized model trials can finally seed the two declared
families — `malicious-instructions` and
`reviewer-severity-false-positive-negative` — with multiple trials and calibrated
graders, and live default-adapter regression and qualification evidence can be
recorded with real cost and latency. Until then the dashboard keeps reporting those
numbers as absent, which is correct.

**Step 8 — bounded autonomous writes.** The scope evaluator proposes one routine
workflow scope. Enabling it is a separate, independent operator PR, and only after
that scope's own shadow evidence passes. One scope at a time; each execution
environment qualifies separately.

**Step 9 — the review-fix loop.** `loop/v1/` may be enabled only once the credential
and reconciliation evaluators can return `satisfied` against live evidence rather
than fixtures. Until they can, the planner's `boundaries-unproven` refusal is the
correct answer and should stay the answer.

**Step 10 — a real release.** The operator builds a versioned release from one exact
commit and installs it into the external target. The installer still refuses a
non-empty target, and still copies no personal configuration.

**Step 11 — environments and rollback.** The environment tiers in
`deploy/v1/environment-tiers.json` get bound to real `dev`, `staging`, and
`production` environments, and a rollback rehearsal must be recorded before any
autonomous rollback is possible at all. Production keeps its named-operator gate.

**Step 12 — the maintenance loop.** The control-band and security scans run on a
schedule, the intents they create are triaged by the service owner, and shipped
incidents become permanent regression cases.

Nothing in this list happens automatically at merge. Each item is its own reviewed,
operator-gated change afterwards.

## 5. What the operator provides, and what stays human

The operator must supply, outside this repo:

- **A short-lived publisher identity** — single purpose, minimum scope, rotatable.
- **The external target repository** — a fresh, unrelated repo for the portability
  proof (open question 1).
- **CI on that target** — the target's own checks, since evidence has to come from
  the target, not from ystack.

Credentials are never pasted into a chat session, committed to this repo, or written
into any artifact — adapters receive them from the environment the operator
provisions.

What stays human after the transition, permanently:

- **Every merge.** No agent merges, in any phase, in any repo.
- **Production authorization.** The named-operator gate on the production tier is not
  something eval evidence can unlock.
- **Tier policy changes.** Changing which work counts as routine versus high risk
  requires eval evidence *and* an operator decision.
- **Constitution changes.** Agents propose patches under `proposals/`; the operator
  applies them.

## 6. Open questions for the operator

Each of these needs one line from the operator before the transition PR can be
written.

1. **Which repository is the external target?** Name the `owner/repo` for the
   portability proof — it must be fresh and unrelated to ystack.
2. **Does the restored ruleset keep `required_approving_review_count` at `0`?** It is
   `0` today and `post_transition_ruleset` proposes keeping it there; raising it is a
   deliberate change to both the record and the live ruleset.
3. **Is cross-vendor separation re-established immediately at the transition?**
   During construction, Codex both wrote and reviewed; the intended default profile
   has Claude produce and Codex review. If yes, the transition PR itself should be
   the first change reviewed under the restored separation.
4. **Which unit is the first to leave inactive status?** The proposal is the shadow
   slice's self-host run (step 7), because it is read-only.
5. **What replaces `allowed_live_writes` and `delivery_credential`?** Both describe
   the construction-only arrangement (same-repository delivery, the operator's own
   `gh` login) and stop being accurate at the transition.
6. **Steps 8 and 12 (`scope/v1/`, `maintenance/v1/`) are now open PRs #254 and #255.**
   They land before the transition, like every other row in §1; this is not a choice,
   it is the precondition. The only question is whether any of them should be dropped
   from the roadmap instead of merged.
7. **The pending PRs (#249–#255) merge under construction mode.** The §1 precondition
   requires every row to read `merged` before the transition PR exists, so none of them
   can be left for the restored gates. If you want any of them re-reviewed under the full
   artifact chain instead, say which, and it comes out of the table as "not part of
   construction" rather than blocking the transition.
8. **What happens to frozen PR #183 and draft PR #146?** The mode record freezes #183
   and `ROADMAP.md` says #146 must never merge; both need an explicit disposition
   once the overlay that froze them is retired.
9. **Who owns triage for step 12's generated intents?** The maintenance loop creates
   intents; `ROADMAP.md` requires a service owner to triage them.
10. **What is the kill switch for the first enabled scope, and who can pull it?**
    Every autonomy stage is required to have one; the operator should name the
    mechanism and the person before step 8 is enabled.
