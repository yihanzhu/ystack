# Roadmap

This is the order of work toward [NORTH_STAR.md](NORTH_STAR.md). Each step is one
or a few small PRs. Each PR has one concern.

## Done

1. New purpose: `NORTH_STAR.md` and this file (#840).
2. Park the run-anywhere work at the tag `archive/run-anywhere` (#841).
3. Guard: blocked terms and secrets (#842, #843).
4. Guard: only the owner's text is an instruction (#844).
5. Guard: no machine-specific configuration (#845).
6. Move the kit from ymemory: rules and skills (#846, #847).
7. Rewire installation: `kit/install.sh` for Claude Code and Codex (#846).
8. Write down the layer pass: `kit/skills/ystack-layer-pass` (#849).

Step 9 is still open, below.

10. ystack's own layer pass: checks and written rules for this repo (#851 to #865).

## ystack merges

- ystack has no merge kinds. Every file here is a kind the owner always sees: gate
  files, written rules or site copy. So every ystack PR needs the owner's OK.
- Revisit this only if a frequent kind of change appears that a check could judge.

## Owner to-do

- Confirm that every machine with the kit ran `kit/install.sh` after #846. Then
  the removal of the parked yshifu command can leave `kit/install.sh` and its tests.

## 9. Site merge gate

- Before any codebase lets a kind merge without the owner, decide P2: a separate
  agent identity on GitHub, a machine user or an App, so that GitHub can tell an
  agent's merge from the owner's. The owner deferred this from step 10.
- When the site's repository can enforce a ruleset, apply it and merge the site's
  PR 290. Then the site's merge kinds go live.
- Until P2, text that agents write on GitHub shows as the owner's account.
- Agents keep the current admin-capable `gh` token until ystack development is
  finished.

## 11. A second codebase

- Run the pass with the kit on a second codebase.
- Done when the kit did not need to change to fit it.

## Not planned

- Adapters for other agent harnesses, Git forges or CI systems.
- Portability, sandbox and execution-environment proofs.
- Autonomous writes, deploy and rollback, and target packaging.
- Automating the pass before step 11.
