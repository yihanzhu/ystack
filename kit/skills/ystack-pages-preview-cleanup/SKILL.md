---
name: ystack-pages-preview-cleanup
description: "Design and validate bounded Cloudflare Pages preview cleanup for closed PRs and dry-run sweeps."
---

# Pages Preview Cleanup

Inputs: authorized project/repository scope, deployment inventory and current open PRs. Output: a dry-run target list, bounded authorized deletion results and verification. This skill grants no deletion, credential, deployment or merge rights.

1. Keep open-PR previews when Functions, headers or rate limits need real deployment checks. Old previews can expose old versions. Assess production, project and preview hosts separately.
2. Complete all paginated listings before deleting anything. Stop all deletion on listing failure, repeated pages or malformed/HTML responses. Protect production, main and every branch with any open PR.
3. A closed-PR trigger deletes only that branch's previews, merged or unmerged. It must not sweep unrelated branches. A manual old-preview sweep defaults to dry run and selects only branches with no open PR. Execute only within explicit cleanup authorization.
4. Have the account holder authenticate and enter any account-scoped Pages Edit token directly into the repository secret, using a prompt such as `gh secret set CLOUDFLARE_API_TOKEN --repo <owner>/<repo>`. Never receive, print or store its value in agent output. Set the secret before merging if PR closure triggers the first run. Fail clearly when it is missing; secretless Dependabot runs may skip with a notice.
5. Recheck current Wrangler syntax and exact targets. One manual command is `npx wrangler pages deployment delete <deployment-id> --project-name <project> --force`; force reportedly handles branch aliases refused by the dashboard. Do not assume that report establishes today's behavior.
6. Test with fake API/gh implementations: pagination, protected production/open branches, another open PR on the same branch, closed-PR-only scope, manual dry run, delete failure, missing secret, repeated pages and HTML error responses. Report partial failures clearly.
7. After authorized deletion, repeat dry run and sample old URLs while checking production and its project hostname remain available. Deleting deployments does not delete Git branches/code. Another push or a deployment finishing after PR closure can create new previews; a prior empty sweep is not permanent closure.

## Alternative

Per the [Cloudflare preview documentation](https://developers.cloudflare.com/pages/configuration/preview-deployments/), previews are public by default. Settings → General → Enable access policy protects previews, not the production pages.dev or custom domain. Authentication setup and any free Zero Trust prerequisite need separate checking.

Recheck [Wrangler Pages commands](https://developers.cloudflare.com/workers/wrangler/commands/pages/) and [branch controls](https://developers.cloudflare.com/pages/configuration/branch-build-controls/).

## Check queued-trigger loss

Check the workflow's concurrency semantics against several closures during an active cleanup. A manual dry-run sweep can identify leftovers from dropped queued triggers; deletion still needs its original authorization. A shared concurrency group can lose queued work when several PRs close during one run; verify that mechanism before applying it.
