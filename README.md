# ystack

The owner's kit, and a layer-by-layer pass over each codebase.

- **The kit** is what the owner carries to every codebase: working preferences,
  how work is split between models, and development skills. Claude Code and
  Codex load it from this repo.
- **The layer pass** goes over a codebase one layer at a time: design, checks,
  verification, written rules, and last a person. Only what no layer can answer
  reaches the owner.

Read [`NORTH_STAR.md`](NORTH_STAR.md) for the purpose and rules, and
[`ROADMAP.md`](ROADMAP.md) for the order of work. Agents read
[`AGENTS.md`](AGENTS.md).

## What is here

| Path | What it does |
| --- | --- |
| `NORTH_STAR.md` | The purpose, its rules and the done signal. |
| `ROADMAP.md` | The order of work. |
| `AGENTS.md` | Rules and checks for agents in this repo. `CLAUDE.md` imports it. |
| `.claude/hooks/no-merge-guard.sh` | Blocks Claude Code from merging PRs and pushing to `main`. |
| `.claude/hooks/owner-only-guard.sh` | Blocks Claude Code from reading issue and PR text directly. |
| `scripts/gh-read.sh` | Reads an issue or PR and hides text from accounts other than the owner's. |
| `scripts/check-public.sh` | Blocks the owner's blocked terms and secrets. The term list is never committed. |
| `scripts/get-gitleaks.sh` | Gets the pinned secret scanner and checks its digest. |
| `.githooks/` | Runs the public-repo check before each commit. |
| `tests/` | Tests for the checks. |
| `.github/workflows/ci.yml` | The `ci` check that `main` requires. |
| `.github/workflows/tripwire.yml` | Fails when anyone but the owner lands a commit on `main`. |
| `website/` | The landing page at ystack.yihanzhu.com. |

The last public-repo guard and the kit arrive in roadmap steps 5 to 7.

## Earlier work

From June to November 2026, ystack was an autonomous coding team and then a
portable control plane meant to run on any agent harness and any Git forge.
688 PRs merged, almost all of them into ystack itself. That work stopped on
2026-11-23. The tag `archive/run-anywhere` keeps its last state, and Git keeps
its full history.
