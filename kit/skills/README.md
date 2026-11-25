# Kit skills

Each folder here holds one skill: a `SKILL.md` whose `name` matches the folder,
which starts with `ystack-`. `kit/install.sh` links every folder into
`~/.claude/skills` and `~/.agents/skills`, so Claude Code and Codex both find it.

Skills change only through PRs. A skill holds no run records, session IDs,
private links or machine values; the public-repo check blocks the last two.

ymemory's nightly distill never writes here. It only proposes skill candidates
inside ymemory, and a PR here turns a candidate into a skill.
