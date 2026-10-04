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

## Manager succession — 2026-09-27

The Codex delegation reinstated on 2026-09-21 ended on 2026-09-27. Codex session
`01a09ae7-9bd4-77f3-8c15-966143bebff4` is ended, and that end is recorded on
https://github.com/yihanzhu/ystack/issues/275 (operator handoff comment
`5857532064`). No manager authority remains with it.

- Succeeding manager: yshifu running as Claude — Claude Code desktop session
  `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, model Claude Fable 5.1.
- Date: 2026-09-27.
- Operator: yihanzhu, directly handing the manager role back in that session's chat:
  “我用codex做了一部分roadmap，你现在接管回来，继续完成roadmap”.
- Review lane: unchanged — the operator's Codex default model through
  `scripts/codex-review.sh`. The coder ceiling stays `YSTACK_CODER_MODEL=sonnet`.

The same bounded delegation recorded above now applies to that named Claude session,
and to no other session. The 2026-09-18 and 2026-09-21 succession sections remain
historical: each applied until the handback that followed it. Nothing else changes.
The reserved operator decisions, the one-manager invariant, one concern and exact
allowed paths per PR, substantive independent review with no unresolved Important
finding, fresh exact head/base evidence, all required CI green before merge,
read-only reviewers, the rounds cap, claims, recovery and restoration, and the
exclusion of frozen #183 and unresolved dirty attempts all stand unchanged.
ROADMAP.md stays byte-identical and the accepted source blobs still pin the agreed
product scope; a product-scope, goal, acceptance, safety or authority change still
returns to the operator.

Publishing mechanism. The successor merges with
`gh pr merge --squash --match-head-commit <reviewed head>` under operator decision
OD-1 (issue #275, 2026-09-09), re-affirmed by this 2026-09-27 handoff, and only when
the newest review is clean at the exact head and base, `ci` is green, and the labels
are consistent. Constitution-path PRs (`.github/**`, `.claude/**`, `AGENTS.md`,
`CLAUDE.md`, `REVIEW.md`, `ROADMAP.md`, `NORTH_STAR.md`, `config/**`) stay the
operator's to merge. `.claude/hooks/no-merge-guard.sh` is unchanged, but it does not
bind this session. This manager session's Claude Code project directory is
`/Users/yihanzhu/git`, the parent of the checkout, so the repository's
`.claude/settings.json` is not loaded — and the coder, fix-coder and reviewer
subagents this session spawns inherit that same project directory, so running their
Bash commands inside the checkout does not load it either. For this session's
subagents the deterministic layer is absent. What holds for them is weaker, exactly
as stated in the 2026-09-18 section: (1) `routines/coder.md` and the spawn brief
forbid any merge, any label change on the intake, and any push to `main`; (2) the
`ystack-main-gate` ruleset on `main` — required `ci`, strict up-to-date, squash only,
no direct pushes — blocks a red or stale merge regardless of who calls it; (3) every
merge is pinned with `--match-head-commit` to a head the manager verified against the
newest review, and only the manager session runs `gh pr merge` at all; and (4) the
hook still protects every agent launched with the checkout itself as its project
directory, while the Codex review lane is read-only and never merges. That boundary
is weaker for this session's subagents than the hook, and it is recorded as weaker
rather than papered over. The operator accepts it for this session only. Restoring a
deterministic layer for subagent Bash calls remains a named follow-up, not something
this record claims is done. That is the whole of the narrowly scoped,
operator-approved publishing path, for the named session only, and the operator can
revoke it by saying so.

The manager verified its own session identity from its scratchpad path, which the
Claude Code harness derives from the session id. That is identity evidence, not
authority. This direct handback, not this record, supplies the successor authority.
This file still cannot appoint a manager, and the named session cannot authorize a
later session by itself; a further successor needs another explicit operator handoff
recorded here.

Prepared against base `89f840fb5d1ea3683c2950e0d6712fec976632b3`.

## Program decision — post-self-host-milestone sequencing (2026-09-27)

The self-host milestone of step 7 of the Roadmap rollout sequence, the shadow
vertical slice, is complete: the first self-host shadow reproduction (intake #264)
merged as PR #373 at `a73bd8c`. It ran under decision request DR-4's
declaration-only sandbox evaluation and claims no execution boundary. The real
sandbox boundary is the prerequisite for step 8, not a step-7 result.

Step 7 itself is not complete. ROADMAP.md requires it to run on real self-host and
external-target changes, and the #373 run explicitly excluded external-target proof
from its scope. Step 7's external-target shadow run or runs, on the dummy external
target `yihanzhu/ystack-dummy-target` named in `docs/transition-kit.md`, remain
outstanding and are the program's next work. This record makes no change to that
external-target requirement; changing it would be an operator scope decision.

- Operator: yihanzhu, deciding directly in the manager session's chat.
- 2026-09-18: “同意，先把 step 7 跑通再改 roadmap”. The shape agreed then: steps 8
  (bounded autonomous writes) and 10 (target packaging) are the product; step 9 (safe
  review-fix loop) follows step 8; step 11 (deploy and rollback) is dropped; step 12
  (maintenance loop) is deferred.
- 2026-09-27, once the self-host run had merged: “可以按照你推荐的”.

That sequence now applies as the program's working order once step 7 closes: 8,
then 9, then 10.

ROADMAP.md stays byte-identical. Its digest is bound in the shipped profiles,
`config/construction-mode.json`, the tests and the merged self-host evidence, and
this record requires it unchanged, so the roadmap's own text of steps 11 and 12 is
not edited. This record is where the drop and the deferral live. Draft PR #424, which
would have edited ROADMAP.md, is held and closed in favour of this record.

The drop of step 11 — environment tiers, a named production gate, rehearsed rollback
and delivery evidence — is an operator decision and is reversible. While it stands, no
workflow may deploy, invoke rollback or take a production action; that authority stays
with the operator, as the reserved decisions above already say. While it stands, the
north star's done-signal cannot be reached through a rehearsed rollback.

Step 12 resumes only when both hold: step 10 has installed ystack into a target that
emits control-band, scan or production signals, and a rehearsed rollback exists for
every action the loop may invoke. The second condition means restoring step 11, or an
equivalent gate, first.

Everything else in this program authorization stays unchanged: the reserved operator
decisions, the one-manager invariant, one concern and exact paths per PR, independent
review, fresh head/base evidence, required CI, the rounds cap, and the exclusion of
frozen #183 and unresolved dirty attempts. Restoring step 11, resuming step 12 early,
or any other change to scope, goal, acceptance, safety or authority returns to the
operator. This record is evidence of the operator's decision, not a source of
authority.

Prepared against base `c70334efe7708c8ebd59dff9c4342b18d1958f50`.

## Roadmap completion authorization RC-1 — 2026-09-27

- Date: 2026-09-27.
- Operator: yihanzhu, deciding directly in the manager session's chat. Asked whether
  the remaining roadmap could be finished with fewer per-item approvals, the operator
  accepted the manager's proposal and replied: “可以，approve RC-1”.
- Manager session: Claude Code desktop session `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`,
  the manager named in the 2026-09-27 succession above.
- Durable decision record: https://github.com/yihanzhu/ystack/issues/275 (comment
  `5858293672`, “RC-1 — roadmap completion authorization”).

Covered by RC-1 (the manager decides without a per-item request), for Roadmap steps
7-10 only:

- intake acceptance for initiatives that implement steps 7-10 (recorded as
  user-directed, with the digests and this decision as `acceptance_source`);
- decision requests whose subject is read-only or declaration-only (further read-only
  target reproductions, DR-4-style evaluator boundaries, frozen-input selections,
  registry entries with `proof_state: unproven`, requester identities within the DR-5
  shape);
- plan-base reaffirmations, review_size records and amendments, artifact hygiene
  changes;
- record-only PRs (decision records, succession appendices, docs) even when they touch
  a constitution path, merged under OD-1's conditions (newest independent review clean
  at exact head/base, required CI green).

Still reserved for the operator (each gets its own decision request):

1. the first activation of any write scope — the step-8 enablement PR that changes
   `config/**` (`allowed_live_writes`) or any scope record with `enabled: true` /
   `push_allowed: true`;
2. any use of credentials, network beyond CI, a real (non-dormant) publisher identity,
   or installation of ystack into a target (step 8 publisher; step 10 packaging into a
   target);
3. code or policy changes to `ROADMAP.md`, `AGENTS.md`, `REVIEW.md`, `NORTH_STAR.md`,
   `.github/**`, `config/**`, `scripts/merge-pr.sh`, `scripts/codex-review.sh`,
   `scripts/test/run-all.sh`, `scripts/lib/*.sh`;
4. restoring step 11, resuming step 12, or any other change of scope, goal, acceptance
   standard, safety property or authority.

Everything else in this program authorization, OD-1 and the 2026-09-27 succession
stays unchanged: one manager, one concern and exact paths per PR, substantive
independent review with no unresolved Important finding, fresh exact head/base
evidence, all required CI green before merge, the rounds cap, and the tiering
(frontier models author and diagnose, `YSTACK_CODER_MODEL=sonnet` codes, the
operator's Codex model reviews). ROADMAP.md stays byte-identical, and the
post-self-host-milestone sequencing above is unchanged.

This record is evidence of the operator's decision, not a source of authority.

Prepared against base `32836eff287fb94a4b73b1c543b2c68bb217029c`.

## Manager succession — 2026-10-01

Operator yihanzhu directly told Codex session
`01a09ae7-9bd4-77f3-8c15-966143bebff4` on 2026-10-01:
“之前是claude接管了，现在我们接回来完成roadmap”.

That direct handback ends the 2026-09-27 delegation to Claude Code session
`dd83267a-8ae2-4699-9afa-a8ca0bf3421c` and reinstates the named Codex session as
the sole manager/publisher for `yihanzhu/ystack` (repository ID `1270665750`).
The earlier succession entries remain historical. This direct operator decision
supplies authority; this record does not transfer permissions, appoint a manager,
or authorize another session, clone, live yshifu or target.

The same bounded program continues, including RC-1 accepted on 2026-09-27 for
steps 7–10. The working sequence remains 7, then 8, 9 and 10; step 11 is dropped
and step 12 deferred on the conditions already recorded above. The accepted source
blobs and ROADMAP.md remain unchanged. This appendix records succession only,
under the direct handback and RC-1's record-only scope; it changes no governance
policy, product scope, code or acceptance standard.

All reserved operator decisions remain reserved, including RC-1's first write-scope
activation, credentials, network beyond CI, non-dormant publisher identity, target
installation, and listed code or policy changes. Safety or authority expansion,
release, deployment, production actions, first real target execution and destructive
disposition still require the operator. The dummy target remains read-only.
Construction mode stays retired; no live command, prompt or profile is installed,
activated or synced.

Use the current global AGENTS.md GPT model routing for Codex delegation, including
its author/reviewer separation and model-identity reporting. The historical Claude
coder alias does not select a Codex model. The earlier Claude-specific hook and
project-directory observations are historical, not claims about this Codex session.

OD-1's protected publishing path remains
`gh pr merge --squash --match-head-commit <reviewed head>`. The manager must first
read the complete fresh independent review, resolve every Important finding,
verify exact head/base, required green CI and consistent labels, then record the
merge receipt. No protection bypass, direct main push or published-history rewrite
is allowed. Artifact hashes, risk checks, stage order, read-only reviewers, claims,
recovery, restoration and the rounds cap remain required. This is manual process,
not a claim of mechanical enforcement or fresh review acceptance.

The manager's handback reconciliation preserves the vm-launcher-supervisor PR 6
attempt (a planned slice, not a GitHub PR number):

- Repository: `yihanzhu/ystack`; branch: `ystack/impl/vm-launcher-supervisor`.
- Local HEAD: `b6ea9e96c78ac86eb03718b4858cbb7558906dca`.
- Parent and old base: `a00777c34e648d347cfb1eb4ca1f2e01b2a5bbc1`.
- Remote branch/head: absent; PR: absent; worktree: clean.
- Intake: #463, still `claimed`; prior claim ID:
  `claim-vm-launcher-supervisor-pr6-20261003T2300Z-3b7e5c21`.
  The claim comment was created on 2026-09-30. The ID is opaque; its embedded date
  does not establish the comment's time or authority.

Preserve and reverify that same attempt before resuming. Do not reset, discard or
replace it, or launch a duplicate coder. No review acceptance carries forward
without fresh raw independent review at the applicable exact head/base. Frozen
#183 and unresolved dirty attempts, including the dirty credential-export plan
attempt, remain excluded without an explicit disposition.

Prepared against base `a00777c34e648d347cfb1eb4ca1f2e01b2a5bbc1`.

## Manager succession — 2026-10-04

Operator yihanzhu directly handed the manager role back to Claude Code desktop
session `dd83267a-8ae2-4699-9afa-a8ca0bf3421c` in that session's chat on
2026-10-04: “继续接管roadmap implementation”. The handback is recorded on
https://github.com/yihanzhu/ystack/issues/463 (comment `5981059003`).

That direct handback ends the 2026-10-01 delegation to Codex session
`01a09ae7-9bd4-77f3-8c15-966143bebff4`. No manager authority remains with it.

- Succeeding manager: yshifu running as Claude — Claude Code desktop session
  `dd83267a-8ae2-4699-9afa-a8ca0bf3421c`, model Claude Opus 5.5.
- Date: 2026-10-04.
- Review lane: the operator's Codex default model (gpt-6-astra) through
  `scripts/codex-review.sh`. The coder ceiling stays `YSTACK_CODER_MODEL=sonnet`.
  The historical Codex GPT routing in the 2026-10-01 section does not select a
  Claude model.

The same bounded program now applies to that named Claude session, and to no other
session. The earlier succession sections remain historical: each applied until the
handback that followed it. Nothing else changes. RC-1, OD-1, the working sequence
(7, then 8, 9 and 10; step 11 dropped and step 12 deferred on the recorded
conditions), the reserved operator decisions, the one-manager invariant, one concern
and exact allowed paths per PR, substantive independent review with no unresolved
Important finding, fresh exact head/base evidence, all required CI green before
merge, read-only reviewers, the rounds cap, claims, recovery and restoration, and
the exclusion of frozen #183 and unresolved dirty attempts all stand unchanged.
ROADMAP.md and the accepted source blobs remain unchanged. This appendix records
succession only, under the direct handback and RC-1's record-only scope; it changes
no governance policy, product scope, code or acceptance standard.

OD-1's protected publishing path remains
`gh pr merge --squash --match-head-commit <reviewed head>`, under the conditions and
with the weaker subagent boundary stated in the 2026-09-27 succession section, which
apply to this session unchanged. No protection bypass, direct main push or
published-history rewrite is allowed.

The manager's handback reconciliation preserves the vm-launcher-supervisor PR 7
attempt (a planned slice):

- Repository: `yihanzhu/ystack`; branch: `ystack/impl/vm-launcher-supervisor`.
- PR #490: open, draft, head `9b760d5e65c672f9d9ca8e4f60be9ca658deea3e`, base
  `b007df89f1dd4f5c263197edb559f0db35f7c43f`.
- Claim: `codex-vm7-option-b-continuation-20261003-9b760d5e`, with its one
  remaining formal candidate unconsumed.
- Local worktree: the original author's uncommitted tracked edits to
  `sandbox/v1/guest/probe.c` and `scripts/test/sandbox-guest.test.sh`, preserved
  untouched.
- Plan-only amendment PR #496: open.

Preserve and reverify that same attempt before resuming. Do not reset, discard or
replace it. No review acceptance carries forward without fresh independent review
at the exact head/base.

The manager verified its own session identity from its scratchpad path, which the
Claude Code harness derives from the session id. That is identity evidence, not
authority. This direct handback, not this record, supplies the successor authority;
a further successor needs another explicit operator handoff recorded here.

Prepared against base `b007df89f1dd4f5c263197edb559f0db35f7c43f`.
