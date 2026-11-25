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
| `kit/rules/` | The owner's working preferences and model routing, loaded by Claude Code and Codex. |
| `kit/skills/` | Development skills, linked for both agents. |
| `kit/install.sh` | Installs the kit on this machine. Safe to run again. |
| `ROADMAP.md` | The order of work. |
| `AGENTS.md` | Rules and checks for agents in this repo. `CLAUDE.md` imports it. |
| `.claude/hooks/no-merge-guard.sh` | Blocks Claude Code from merging PRs and pushing to `main`. |
| `.claude/hooks/owner-only-guard.sh` | Blocks Claude Code from reading issue and PR text directly. |
| `scripts/gh-read.sh` | Reads an issue or PR and hides text from accounts other than the owner's. |
| `scripts/check-public.sh` | Blocks the owner's blocked terms, secrets and machine-specific values. The term list is never committed. |
| `scripts/get-gitleaks.sh` | Gets the pinned secret scanner and checks its digest. |
| `.githooks/` | Runs the public-repo check before each commit, and refreshes the kit after each pull. |
| `tests/` | Tests for the checks. |
| `.github/workflows/ci.yml` | The `ci` check that `main` requires. |
| `website/` | The landing page at ystack.yihanzhu.com. |

## Install the kit

On each machine, clone this repo to `~/git/ystack` (another place works too), then run:

```bash
cd ~/git/ystack && kit/install.sh && git config core.hooksPath .githooks && scripts/get-gitleaks.sh
```

`kit/install.sh` adds a marked block to `~/.claude/CLAUDE.md` and to `~/.codex/AGENTS.md`,
links the kit skills, and changes nothing else. The first install is always this manual
run. After that, a `git pull` that merges or fast-forwards in this checkout refreshes it. `kit/install.sh --check` says whether it is current.
A work computer installs only this repo.

## Earlier work

Earlier work is parked at the tag `archive/run-anywhere`. See [`NORTH_STAR.md`](NORTH_STAR.md).
