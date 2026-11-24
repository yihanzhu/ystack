---
name: ystack-layer-pass
description: "Go over a codebase one layer at a time (design, checks, verification, written rules, a person), write findings for the owner to pick from, and set which kinds of change may merge without the owner."
---

# Layer Pass

Inputs: the target repository and the main-branch commit the pass starts from. Output: a list of findings for the owner to pick from, then one small PR for each picked finding. This skill grants no merge, write or settings authority.

Each layer has one question. Each layer down costs more. A fix goes into the highest layer that can hold it. Only what no layer can answer reaches the owner.

## Steps

1. Start read-only. Name the base commit. Change no code during the review.
2. Go over the five layers in order. For each layer, write what holds today, then the findings.
3. Put each fix in the highest layer that can hold it: design before checks, checks before written rules. A written rule that must hold every time becomes a check.
4. Show the owner the findings, with a recommendation for each. The owner picks. Do only what the owner picked. When the target is private, keep the findings out of public repositories.
5. Open one PR for each picked finding, in this order:
   - First make one local command run the same steps as CI.
   - Then design fixes and new checks.
   - Then written rules, after the checks they depend on have merged. A rule that a check now holds stays out of the written rules.
   - The merge gate last.
6. Leave the result in the target repository: in its checks and in its `AGENTS.md`.

## The five layers

| Layer | Question | What to look at | How to get evidence |
| --- | --- | --- | --- |
| 1. Design | Does the design take wrong choices away, so an agent cannot make them? | Shared constants and components, schemas, types, generated assets. Hand-written copies that skip the shared code. | Search for hand-written copies of a shared rule. List the schema fields that accept free text. |
| 2. Checks | Do lints, types, tests and CI run on every change, and can they stop one? | CI steps, hooks and tests. The rules in force on main and the required checks. Direct pushes to main. Whether the local command matches CI. | Read the rules in force on main. Read check results on recent merged PRs. List commits on main's first-parent line that have no PR. Compare the local command with each CI step. |
| 3. Verification | Can someone verify what the code does when it runs, with runtime checks or evals? | Whether tests run on the real build and runtime. The platform layer: headers, routes, functions. Output that a person judges by looking. Evals where a model makes decisions. What breaks outside the code: links, scheduled jobs. | Read the test server setup. Read what the docs say the tests do not cover. Find claims of "same output" that only an agent's word supports. |
| 4. Written rules | Are the rules for agents written next to the code they are about? | `AGENTS.md`, notes and comments. Rules that live only in one agent's private memory. | Compare agent memory and the owner's notes with the repository. Find written rules that must hold every time. |
| 5. A person | Which changes must a person still look at? | Who merges, and how. Which kinds of change a check could let through. | Sort recent PRs by kind of change. Read the owner's rules for the codebase. |

## A finding

Give each finding an ID: the layer letter and a number (D1, C2, V1, R1, P1). Write these parts:

- **Now**: what holds today, with the evidence.
- **Gap**: what can go wrong, and how it gets through today.
- **Fix**: the change.
- **Layer**: the layer that the fix goes into.
- **Cost**: small, medium or large. Name any new dependency.
- **Recommendation**: do, do later, or do not.
- **Owner decision**: needed when the fix costs money, changes an earlier owner decision, or needs a judgment that no check can make.

Give a recommendation even when the owner decides. With no recommendation, the current state stays.

After the findings of each layer, list what stays as it is and what was checked but needs no new check. Give one reason for each.

## Merges without the owner

Until every layer has been checked and every finding the owner picked has merged, the owner merges every PR. After that, a kind of change may merge without the owner only when all of the rules below hold. Write them into the target's `AGENTS.md`.

### The gate

- Main has an enforced gate: PRs are required, the required checks must pass, and nobody can push to main directly. Without an enforced gate, this rule is only a written rule.
- A check shows what the owner would judge by looking. For example, it compares the screenshots and content of the PR's build with its base branch's build.
- A required check gives each PR its kind.

### Who decides the kind

- Merged code decides the kind: the base branch's copy of the check script. The PR's own code never decides it. If the PR's code decides its kind, the rule is not a gate.
- The PR's code runs only in a job with no write token. The job that decides the kind and writes the result runs only the base branch's code.
- The default kind is "owner". A PR gets another kind only when the script can prove it. An unknown kind goes to the owner. So does a PR whose base is not main, and a PR whose comparison is incomplete.

### Each kind

- Name the only files that the kind may change, and the checks that it must pass.
- Judge the content, not only the path. A path rule lets these through: a skip added to an existing test, a major version in a lockfile or an override, a change to a script that CI runs.
- Test the script with one case for each kind and one for each way out of it.

### Always the owner

- Changes the owner judges by looking: design, copy, new pages, posts.
- Changes to the gate: CI workflows, test settings, check scripts, removed or weaker tests, `AGENTS.md` and other written rules.
- Privacy, identity and security settings.
- New dependencies, major versions, and CI action versions.
- Deleted content.
- Requests for more test runs or more permissions that no check or written rule answers.

### How an agent reads the gate

- Read the rules in force on main, not only the list of rule sets. On GitHub: `gh api repos/OWNER/NAME/rules/branches/main`.
- Trust only a result that the CI bot wrote for the PR's current head commit.
- The owner's OK counts only in the owner's own words. A relayed approval does not count.
