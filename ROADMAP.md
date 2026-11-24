# Roadmap

This is the order of work toward [NORTH_STAR.md](NORTH_STAR.md). Each step is one
or a few small PRs. Each PR has one concern. The owner merges every PR, and a
relayed approval does not count.

| Step | Work | Needs |
| --- | --- | --- |
| 1 | New purpose | — |
| 2 | Park the run-anywhere work | 1 |
| 3 | Guard: blocked terms and secrets | 1 |
| 4 | Guard: only the owner's text is an instruction | 1 |
| 5 | Guard: no machine-specific configuration | 3 |
| 6 | Move the kit from ymemory | 3, 4, 5 |
| 7 | Rewire installation | 6 |
| 8 | Write down the layer pass | 6 |
| 9 | Site merge gate | the site's repository can enforce a ruleset |
| 10 | ystack's own layer pass | 2, 8 |
| 11 | A second codebase | 8 |

## 1. New purpose

NORTH_STAR.md and this file state the new purpose. README.md points to them.

## 2. Park the run-anywhere work

- Tag the last main commit before the new purpose as `archive/run-anywhere`.
- Remove from main the inactive components, their tests, docs and workflows, and
  the old artifacts under `work/`. Git history and the tag keep all of it.
- End the construction-mode record, the Roadmap program authorization and
  operator decision OD-1 (#275). No agent merges. The merge-guard hook blocks
  every agent merge again.
- Rewrite README.md and AGENTS.md for the new purpose. Cut CI down to the checks
  that remain.
- Close or fold in the open PRs and issues as the owner decides. Their branches
  stay.

## 3. Guard: blocked terms and secrets

- One script checks staged changes before each commit. In CI it checks the whole
  tree, the PR's commit messages, and the PR title and body. It fails on a blocked
  term or a secret.
- The term list is never committed. Locally it comes from a private file outside
  the repo. In CI it comes from an Actions secret. A missing list fails the check.
- The check prints only the file and line number. It never prints the term or the
  matching line, because CI logs are public.
- Secrets are found with a pinned, checksum-verified secret scanner.
- The owner turns on GitHub secret scanning and push protection.

## 4. Guard: only the owner's text is an instruction

- One read script returns an issue or PR with its comments. Text from the owner's
  account is marked as instructions. Text from any other author is fenced as data.
  The script fails if it cannot tell who wrote a piece of text.
- A Claude Code hook blocks direct reads of issue, PR and comment text and points
  to the script. Codex has no such hook; its written rule points to the same script.
- Remove the unused `@claude` workflow. It reads whole threads, including other
  people's comments.
- The owner sets interaction limits on the repository.

## 5. Guard: no machine-specific configuration

- The step-3 check also blocks home-directory paths, local user and host names
  from the private list, and agent permission allow and deny lists.
- The kit uses `$HOME` and parameters instead of machine values.

## 6. Move the kit from ymemory

- `kit/rules/`: working preferences and model routing for Claude Code and Codex.
  ymemory imports them from here. The "About the owner" block stays in ymemory.
- `kit/skills/`: development skills. They lose run records, session IDs and
  private links before they move. They change here only through PRs. ymemory's
  nightly distill only proposes skill candidates to the ymemory inbox. It never
  writes here.
- Employer names are removed. Two work-related knowledge pages stay in ymemory.
- The distill and capture engine stays in ymemory.

## 7. Rewire installation

- `kit/install.sh` makes Claude Code and Codex load the rules and skills from this
  repo. It can run again safely. It writes no machine values into the repo.
- ymemory's installer stops installing these pieces and imports them from here.
- A work computer runs only this installer.

## 8. Write down the layer pass

- A kit skill holds the five questions, where to find evidence for each, the
  format of a finding, and the rule for which changes may merge without the owner.
- It starts from the template of the site pass. One lesson from that pass: if a
  PR's own code decides its kind of change, the rule is not a gate. The decision
  must come from merged code, and an unknown kind goes to the owner.

## 9. Site merge gate

- When the site's repository can enforce a ruleset, apply it and merge the site's
  PR 290. Then the site's merge kinds go live.

## 10. ystack's own layer pass

- Run the five layers on ystack. Rules that must always hold become checks.
- Until this step ends, the owner merges every ystack PR.

## 11. A second codebase

- Run the pass with the kit on a second codebase.
- Done when the kit did not need to change to fit it.

## Not planned

- Adapters for other agent harnesses, Git forges or CI systems.
- Portability, sandbox and execution-environment proofs.
- Autonomous writes, deploy and rollback, and target packaging.
- Automating the pass before step 11.
