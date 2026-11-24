## Codex model routing

Use these defaults when Codex delegates work. Explicit user choices and project
requirements take precedence. Do not call another provider to follow Claude routing.

| Work | Model | Reasoning effort |
| --- | --- | --- |
| Coordination, architecture, diagnosis, independent review | `gpt-6.2-astra` | `high`; `xhigh` for critical safety or architecture decisions |
| Implementation under a clear plan | `gpt-6.2-sol` | `medium` |
| Small, isolated edits with clear acceptance checks | `gpt-6.2-sol` | `low` |
| Extraction, classification, structured log summaries | `gpt-6-luna` | `low` |

- Choose the role, model, and effort before dispatch, and specify them explicitly; a
  role name alone does not select a model. Record the requested model and the actual
  model the runtime reports. If it reports none, say so instead of guessing.
- Keep the chosen coder model for revisions. A failed attempt calls for diagnosis, a
  clearer plan, or smaller tasks, not automatic escalation.
- Keep authors and independent reviewers separate. Astra does judgment. Do not turn the
  reviewer into the author. Summaries do not replace raw-evidence review, tests, or
  acceptance gates.
- Use direct tools for hashes, counts, file comparisons, and status queries. Delegate
  only useful bounded work. Do not create agents just to fill these tiers.
- If a model is unavailable, report it. Do not silently use another default.
