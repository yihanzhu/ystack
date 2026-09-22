# Current Roadmap program authorization

Status: accepted by the operator; the continuing rules take effect when this
reviewed policy PR is merged. No runtime installation or activation is included.

## Direct decision and identity

- Repository: `yihanzhu/ystack` (repository ID `1270665750`).
- Manager/publisher: Codex session `01a09ae7-9bd4-77f3-8c15-966143bebff4`.
- Date: 2026-09-13.
- Durable decision record: https://github.com/yihanzhu/ystack/issues/292
- Operator: yihanzhu, directly replying “接受并授权” in that session to the complete
  `roadmap-approval-consolidation.md` proposal after asking to reduce repeated approvals.
- Accepted proposal SHA-256: `4f3a1bc5813e9d60cc0be81d28ada2cd90fb5b429cbecfc0cfd4345f7442f8ef`.
- Accepted source base: `e9a230e6ba0f5b4828a0dd916d6fefb5313912bf`.
- Accepted Roadmap source blob: `4bb0fff1ee11c20441cc16182337f762300ac0f2`.
- Accepted north-star source blob: `d2bbe82a8b2a1bb14fde1c50995f7ecec9b58013`.

The source blobs pin the agreed product scope. ROADMAP.md stays byte-identical: the
shipped profiles bind its exact digest as an authority input. The current-session
delegation belongs in AGENTS.md, REVIEW.md and this record, not in that product
input. The first CI attempt caught a redundant Roadmap note; its removal preserves
the profile bindings and all tests. A future product-scope change still needs the
operator. This does not change the shipped profile publisher or live self-host rules.
The manager verified its session identity through CODEX_THREAD_ID and directly
received the decision. This file preserves that evidence; it cannot appoint a new
manager or authorize a future session by itself.

## What the operator accepted

The named manager may complete in-scope intake, intent, spec, plan, implementation,
necessary dependency and test/CI repair, and protected PR merges. Record the artifact
chain, exact digests, risk and scope mapping. Separate independent acceptance replaces
repeated human decisions, including reasonable size amendments for complete tests and
non-semantic base updates. Preserve the existing stage and amendment order.

Every PR remains one concern with exact paths, substantive independent review, no
unresolved Important finding, fresh head/base evidence and all required CI green.
The manager reads the complete review before merging and records the receipt. Keep
read-only reviewers, the rounds cap, one manager, claims, recovery and restoration.
Do not weaken tests or safeguards, bypass protection, directly push main, rewrite
published history or silently replace preserved work. Frozen #183 and unresolved
dirty attempts are excluded. A resolved process pause need not be asked again.

The operator still decides goal or acceptance changes, material scope expansion,
safety/authority expansion, new credential/network/write scope, installation,
activation, release, deployment, production actions, first real target execution,
unauthorized external writes and destructive disposition. The dummy target is still
read-only. Existing development/CI code and test verification remains authorized.
No live yshifu sync, profile selection or construction-mode change occurs here.

## Bounded transition authorization

The same direct decision authorizes this limited governance rule change and
necessary restore records, with independent review and all required CI
before the named manager merges it. No protection bypass is permitted. These are the
only policy changes this bootstrap may make; a broader change returns to the operator.

The decision also explicitly accepts #291's exact intake and its separately reviewed
intent, design, plan, bounded test synchronization repair and merge before this policy
if needed. The repair remains a separate PR with full CI and unchanged safety scope;
it is not a prerequisite if policy CI already passes. This avoids a circular rule
that requires a CI fix before authorization but authorization before the fix.

- #291 title SHA-256: `42687e01ee1928a36907ce8343d1a1d6b64e9496c62f9e8a39865b4b43a7fc2c`.
- #291 body SHA-256: `28d3fcb94780d6cb226485d013ae5f12e528470d399ea0462fc34771e8db3a33`.
- Immediate exact-string recheck and acceptance: issue #291 comment `5654477118`.

Before this policy lands, other stages without individual authorization stay paused.
After it lands, reconcile old attempt identities and obtain fresh CI/review before
continuing; prior proof is not carried onto a changed head/base. A successor needs an
explicit handoff. This record restores context, not live credentials or authority.

These are manually enforced working rules. No new hook, daemon, publisher capability
or automatic scope classifier is claimed.

## Manager succession — 2026-09-18

The Codex delegation above ended on 2026-09-18. Codex session
`01a09ae7-9bd4-77f3-8c15-966143bebff4` is ended, and that end is recorded on
https://github.com/yihanzhu/ystack/issues/275. No manager authority remains with it.

- Succeeding manager: yshifu running as Claude — Claude Code desktop session
  `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, model Claude Fable 5.1.
- Date: 2026-09-18.
- Operator: yihanzhu, directly handing the manager role back in that session's chat:
  “你可以直接接回manager了。处理所有目前还open的东西，然后继续完成roadmap”.
- Review lane: the operator's Codex default model (gpt-6-astra) through
  `scripts/codex-review.sh`. The coder ceiling stays `YSTACK_CODER_MODEL=sonnet`.

The same bounded delegation recorded above now applies to that named Claude session,
and to no other session. Nothing else changes. The reserved operator decisions, the
one-manager invariant, one concern and exact allowed paths per PR, substantive
independent review with no unresolved Important finding, fresh exact head/base
evidence, all required CI green before merge, read-only reviewers, the rounds cap,
claims, recovery and restoration, and the exclusion of frozen #183 and unresolved
dirty attempts all stand unchanged. ROADMAP.md stays byte-identical and the accepted
source blobs still pin the agreed product scope; a product-scope, goal, acceptance,
safety or authority change still returns to the operator.

Publishing mechanism. The successor merges with
`gh pr merge --squash --match-head-commit <reviewed head>` under operator decision
OD-1 (issue #275, 2026-09-09), re-affirmed by this 2026-09-18 handoff, and only when
the newest review is clean at the exact head and base, `ci` is green, and the labels
are consistent. Constitution-path PRs (`.github/**`, `.claude/**`, `AGENTS.md`,
`CLAUDE.md`, `REVIEW.md`, `ROADMAP.md`, `NORTH_STAR.md`, `config/**`) stay the
operator's to merge. `.claude/hooks/no-merge-guard.sh` is unchanged, but be exact
about whom it still binds in this session. This manager session's Claude Code project
directory is `/Users/yihanzhu/git`, the parent of the checkout, so the repository's
`.claude/settings.json` is not loaded — and the coder, fix-coder and reviewer
subagents this session spawns inherit that same project directory. Running their Bash
commands inside the checkout does not load it either. So for this session's subagents
the deterministic layer is absent: the hook is not what stops them. What does hold for
them is weaker and worth naming precisely: (1) `routines/coder.md` and the spawn brief
forbid any merge, any label change on the intake, and any push to `main`; (2) the
`ystack-main-gate` ruleset on `main` — required `ci`, strict up-to-date, squash only,
no direct pushes — blocks a red or stale merge regardless of who calls it; (3) every
merge is pinned with `--match-head-commit` to a head the manager verified against the
newest review, and only the manager session runs `gh pr merge` at all; and (4) the
hook still protects every agent launched with the checkout itself as its project
directory — a standalone Claude Code session opened in the repo — while the Codex
review lane is read-only and never merges. That is a weaker boundary for this
session's subagents than the hook was, and it is recorded as weaker rather than
papered over. The operator accepts it for this session only. Restoring a
deterministic layer for subagent Bash calls — for example a user-level `PreToolUse`
hook that reuses `no-merge-guard.sh` while exempting only the manager's pinned
`--match-head-commit` merge form — is a named follow-up, not something this record
claims is done. That is the whole of the narrowly scoped, operator-approved
publishing path, for the named session only, and the operator can revoke it by
saying so.

The manager verified its own session identity from its scratchpad path, which the
Claude Code harness derives from the session id. That is identity evidence, not
authority. This file still cannot appoint a manager, and the named session cannot
authorize a later session by itself; a further successor needs another explicit
operator handoff recorded here.

## Manager succession — 2026-09-21

The operator directly told Codex session `01a09ae7-9bd4-77f3-8c15-966143bebff4`:
“继续我们的roadmap，从claude那边接手，我们要完成整个roadmap”.
The manager verified that session through `CODEX_THREAD_ID`.

The Claude manager authority granted to Claude Code desktop session
`dd83267a-8ae2-4699-9afa-a8ca0bf3421c` ends with this direct handback.
The original bounded Codex delegation in this record is reinstated only for Codex
session `01a09ae7-9bd4-77f3-8c15-966143bebff4`, in this repository and within the
accepted Roadmap scope. The preceding 2026-09-18 succession section remains
historical: its stated Codex end applied until this 2026-09-21 handback.

This direct handback, not this restored record, supplies the successor authority.
No other session, clone, live yshifu, target, or future manager is authorized by it.
The original artifact chain, exact hashes, risk and scope checks, stage order,
separate author and read-only reviewer roles, one-manager rule, claims, recovery,
restoration, exact head/base evidence, required CI, Important-finding resolution,
and rounds cap remain required. These are manual working rules; this record does
not claim mechanically enforced separation.

Use the current AGENTS.md GPT routing: `gpt-6-astra`/high for coordination,
architecture, diagnosis and independent review; `gpt-6-astra`/xhigh for critical
safety or architecture decisions; `gpt-5.6-sol`/medium for implementation;
`gpt-5.6-terra`/medium for small isolated edits; and `gpt-5.6-luna`/low for
extraction and structured summaries.

It does not permit goal, acceptance, safety, authority, credential, network, or
write-scope expansion; installation, activation, release, deployment, production
action, destructive disposition, or first real target execution. The dummy target
remains read-only. Frozen #183 and unresolved dirty attempts remain excluded.

Prepared against base `8b3e3f55037de84c441cfe4ca5231c98814a7bbd`.
