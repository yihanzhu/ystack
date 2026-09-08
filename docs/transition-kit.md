# Operating-mode transition — operator kit

This file is what the operator copies from when writing the transition PR that
[`transition.md`](transition.md) proposes. It records the answers to that document's
§6 questions (decision **TR-1**, ystack issue #259, approved by the operator on
2026-09-08) and turns them into exact file contents. It is documentation only:
committing this file changes nothing, and construction mode stays active until the
operator's own PR flips the record.

Who does what stays as `transition.md` §3.3 says: the operator authors and merges the
transition PR by hand. No agent edits `config/construction-mode.json`.

## 1. The ten answers (TR-1)

| # | Question | Answer |
|---|---|---|
| 1 | External target repo | `yihanzhu/ystack-dummy-target` — a fresh, public, unrelated repo created for this purpose. Its own greeter, its own test, its own `ci` check on pushes and pull requests. Nothing copied from ystack. |
| 2 | Keep `required_approving_review_count` at `0`? | Yes. The hard gates are CI plus the cross-vendor reviewer's clean verdict on the exact head; a counting approval would let an app token approve. |
| 3 | Cross-vendor separation re-established at the transition? | Yes. The transition PR is the first change reviewed under it: Claude produces, Codex reviews, the operator merges. |
| 4 | First unit to leave inactive status | The shadow slice's read-only self-host run on ystack itself (step 7). |
| 5 | `allowed_live_writes` and `delivery_credential` | `"none"` and `"short-lived-publisher-identity"`. Writes widen only by step 8's first scope PR; the publisher identity is minted per stage and is never the operator's own login. |
| 6 | Drop steps 8 or 12? | No. Both are merged. |
| 7 | Re-review any construction PR under the full artifact chain? | No. Every PR after #188 through #258 merged with a clean cross-vendor review on its exact head and green CI. |
| 8 | Frozen PR #183 and draft PR #146 | Close both without merging, each with a comment saying why: #183 is superseded by core v2 (`scripts/core-contract.sh`); #146 is the failure-modes record `ROADMAP.md` says must never merge. |
| 9 | Owner of step 12's generated intents | The operator, until an adopter names a service owner. Intents stay documents, not issues, until then. |
| 10 | Kill switch for the first enabled scope | `control/v1` kill-switch state set to stop, pulled by the operator through a PR to the kill-switch state. No agent identity may clear it. |

## 2. `config/construction-mode.json` — the complete new contents

Eleven fields change; every other field keeps its current value (in particular all
`*_blob` digests, so the PR must not touch `ROADMAP.md` or `NORTH_STAR.md`). The
`frozen_pr_183_state` change assumes #183 is closed in the same operator action (answer 8);
leave it `"OPEN"` if #183 is closed later.

| field | current | new |
|---|---|---|
| `status` | `"active"` | `"retired"` |
| `completion` | `"implementation-complete"` | `"construction-closed"` |
| `effects` | `"inactive-repo-only"` | `"operating"` |
| `real_target_use` | `"disabled"` | `"enabled"` |
| `real_target_and_production_credentials` | `"disabled"` | `"operator-supplied"` |
| `release_install_activation` | `"disabled"` | `"operator-action-only"` |
| `operating_transition_required` | `true` | `false` |
| `publisher` | `"current-operator-authorized-codex-construction-session"` | `"short-lived-publisher-identity"` |
| `allowed_live_writes` | `"same-repository-delivery-only"` | `"none"` |
| `delivery_credential` | `"current-gh-operator-yihanzhu"` | `"short-lived-publisher-identity"` |
| `frozen_pr_183_state` | `"OPEN"` | `"CLOSED"` |

Full file (keys sorted; `jq -S` of the current file with the eleven changes applied):

```json
{
  "activation_base": "7a55da73b29c743e588accbcc5e2b0b67060feeb",
  "allowed_live_writes": "none",
  "authorized_north_star_source_blob": "b299f4bc240b02881c5ea2b64d94ed1a8f3a51eb",
  "authorized_roadmap_source_blob": "43dcaf2e921257f76bf8ecd7543c49745c6e0f39",
  "bootstrap_base_race": "late-base-check-with-recorded-residual",
  "bootstrap_single_writer": true,
  "completion": "construction-closed",
  "default_branch": "main",
  "delivery_credential": "short-lived-publisher-identity",
  "effects": "operating",
  "forbidden_paths": [
    "work/portable-core-contracts/plan.md",
    "CLAUDE.md",
    "config/construction-mode.json",
    "config/models.conf",
    "AGENTS.md",
    "REVIEW.md",
    "ROADMAP.md",
    "NORTH_STAR.md",
    "manager/CLAUDE.md",
    "templates/yshifu-command.md",
    "reviewer/codex-review.md",
    "scripts/merge-pr.sh",
    "scripts/codex-review.sh",
    "scripts/test/run-all.sh",
    "scripts/lib/gh-remote.sh",
    "scripts/lib/models-conf.sh",
    "scripts/lib/codex-degraded.sh",
    ".claude/settings.json",
    ".claude/hooks/no-merge-guard.sh"
  ],
  "forbidden_prefixes": [
    ".github/",
    "website/"
  ],
  "frozen_pr_183_base": "14988a8a5392e888ff1aaee4c48afa5024bee003",
  "frozen_pr_183_head": "ab4a7082f02e67b5748c5c54b9214f37d222f53f",
  "frozen_pr_183_labels": [
    "round-3",
    "needs-human"
  ],
  "frozen_pr_183_state": "CLOSED",
  "manifest_policy": "required-entry-set-is-immutable; additions-allowed",
  "merge_method": "squash",
  "north_star_blob": "d2bbe82a8b2a1bb14fde1c50995f7ecec9b58013",
  "operating_transition_required": false,
  "post_transition_ruleset": {
    "bypass_actors": [],
    "deletion_protection": true,
    "dismiss_stale_reviews_on_push": false,
    "enforcement": "active",
    "non_fast_forward_protection": true,
    "pull_request_required": true,
    "require_extra_approval_for_unattributed_changes": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0,
    "required_status_check": "ci",
    "required_status_check_app_id": 15368,
    "strict_required_status_checks_policy": true,
    "target": "default-branch"
  },
  "publisher": "short-lived-publisher-identity",
  "real_target_and_production_credentials": "operator-supplied",
  "real_target_use": "enabled",
  "release_install_activation": "operator-action-only",
  "repository": "yihanzhu/ystack",
  "repository_id": 1270665750,
  "required_ci_app_id": 15368,
  "required_ci_name": "ci",
  "required_manifest_entries": [
    "AGENTS.md",
    "CLAUDE.md",
    "REVIEW.md",
    "ROADMAP.md",
    "NORTH_STAR.md",
    "config/construction-mode.json",
    "config/models.conf",
    "manager/CLAUDE.md",
    "templates/yshifu-command.md",
    "reviewer/codex-review.md",
    "scripts/merge-pr.sh",
    "scripts/codex-review.sh",
    "scripts/test/run-all.sh",
    "scripts/lib/gh-remote.sh",
    "scripts/lib/models-conf.sh",
    "scripts/lib/codex-degraded.sh",
    ".claude/settings.json",
    ".claude/hooks/no-merge-guard.sh"
  ],
  "roadmap_blob": "4bb0fff1ee11c20441cc16182337f762300ac0f2",
  "ruleset_id": 21500323,
  "schema_version": 1,
  "scope": "full-roadmap",
  "status": "retired"
}
```

Check after pasting, from the repo root:

```bash
jq -S . config/construction-mode.json | diff - <(sed -n '/^```json$/,/^```$/p' docs/transition-kit.md | sed '1d;$d') && echo "record matches the kit"
```

## 3. The branch ruleset — verify, do not edit

Read the live ruleset and compare with the record's `post_transition_ruleset` block:

```bash
gh api repos/yihanzhu/ystack/rulesets/21500323 \
  --jq '{target, enforcement, bypass_actors, rules: [.rules[] | {type, parameters}]}'
```

Expected: `target` `branch` on the default branch, `enforcement` `active`, empty
`bypass_actors`; a `pull_request` rule with `required_approving_review_count` `0`, no
stale-review dismissal, no last-push approval, no extra approval for unattributed changes,
squash as the only merge method; a `required_status_checks` rule, strict, with the single
check `ci` from integration `15368`; and the `deletion` and `non_fast_forward` rules.

Verified on 2026-09-08 against that command: the live ruleset `ystack-main-gate`
matches the record field for field. The PR body records the date of the operator's own
re-check.

## 4. The three documentation edits in the same PR

The repo rule that README and docs stay in sync applies to the transition PR. Exactly
these passages change; nothing else in those files does.

**`README.md`, the construction-mode paragraph** (currently begins "The repo is in
**construction mode**"). Replace the whole paragraph with:

> The repo ran in **construction mode** from its activation base through 2026-09-08
> (`config/construction-mode.json`, now `status: retired`, kept as the record of what the
> exception covered): the portable harness was built ahead of use, so every component it
> carries landed **inactive** — repo-only source, contracts, and tests. The operating-mode
> transition has happened; each component is still activated only by its own reviewed,
> operator-gated change, in the order [`docs/transition.md`](docs/transition.md) §4
> gives. Components are indexed under [Components](#components-all-inactive) below, with
> the full write-ups in [`docs/components.md`](docs/components.md).

**`docs/components.md`, the preamble.** Change the second paragraph's last sentence from
"Activation happens only at the operator-merged operating-mode transition described in
[`../ROADMAP.md`](../ROADMAP.md)." to:

> The operating-mode transition happened on <date of the transition PR's merge> (see
> [`transition.md`](transition.md)); a component leaves this inactive state only through
> its own reviewed, operator-gated change, and this page is updated when one does.

Leave the title and the convention paragraph as they are: the write-ups still describe
inactive units until each is activated.

**`docs/transition.md`, the opening.** Change the first paragraph's last two sentences
("Construction mode is still active; every component in this repo is still inactive.") to:

> This transition was carried out in PR #<n>, merged <date>; construction mode is retired.
> Every component in this repo is still inactive until its own activating change.

## 5. The PR body

```
Title: Retire construction mode: the operating-mode transition

Precondition: every row of docs/transition.md §1 reads merged. The last construction PR
(#258) merged 2026-09-08; main was at bd31d4f when this PR was opened.

Scope (docs/transition.md §3): the mode record, ruleset verification, and the three
documentation passages that describe the mode as active. No component code, tests, or
ci/required-files.txt entries.

Decision: TR-1 (issue #259), answers recorded in docs/transition-kit.md §1.

Record: config/construction-mode.json — eleven fields changed exactly as
docs/transition-kit.md §2; verified with the diff command there.

Ruleset: ystack-main-gate (21500323) re-read on <date>; matches post_transition_ruleset
field for field. No ruleset edit.

Docs: README construction-mode paragraph, docs/components.md preamble,
docs/transition.md opening — per docs/transition-kit.md §4.

Risk: high (constitution path + security control). Gate: this plan, cross-vendor review
on the exact head and base, required CI green, operator merges by hand.
```

## 6. After the merge, in order

1. Close #183 and #146 with the reasons in answer 8.
2. Step 7, first live action: the shadow slice's read-only self-host run on ystack, as its
   own PR (Claude produces, Codex reviews, the operator merges). Its execution environment
   must first be listed in `shadow/v1/shadow-environments.json` by its own reviewed PR.
3. Step 7, external-target run on `yihanzhu/ystack-dummy-target`, likewise gated.
4. Only then step 8's first scope PR, which is the first change to `allowed_live_writes`.
