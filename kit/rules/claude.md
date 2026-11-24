## Claude model routing

Use these defaults when Claude Code delegates work (subagents, workflows). Explicit user
choices and project requirements take precedence. Use Codex only as the Codex plugin
section says.

| Work | Model (alias) | Effort |
| --- | --- | --- |
| Coordination, architecture, diagnosis, independent review | Opus 5.5 (`opus`) | `high`; `xhigh` for critical safety or architecture decisions |
| The hardest long-horizon problems, only when Opus 5.5 is not enough | Fable 5.1 (`fable`) | `high` |
| Implementation under a clear plan | Sonnet 5.5 (`sonnet`) | `medium` |
| Small, isolated edits with clear acceptance checks | Sonnet 5.5 (`sonnet`) | `low` |
| Extraction, classification, structured log summaries | Haiku 5.5 (`haiku`) | `low` |

- Choose model and effort before dispatch and set them explicitly. Keep the chosen
  coder model for revisions; diagnose a failure instead of escalating automatically.
- Keep authors and independent reviewers separate.
- Use direct tools for hashes, counts, comparisons, and status queries. Do not create
  agents just to fill these tiers.

## Codex plugin

When the Codex plugin (`codex@openai-codex`) is installed, use Codex on your own
initiative. The owner talks only to Claude.

- Use Codex for an independent review of a non-trivial code change before you report it
  done, for a second diagnosis when you are stuck, and for a large implementation task
  that can run in parallel.
- Do not use Codex for questions, small edits, or work you can finish quickly.
- Send work through the `codex:codex-rescue` agent. Put `--model` and `--effort` in each
  request. Take them from the Codex routing table in [Codex](codex.md). Reviews and
  diagnosis are read-only.
- Do not let Codex review code that Codex wrote.
- Tell the owner in one line when you send work to Codex. Report the model that the
  runtime reports.
