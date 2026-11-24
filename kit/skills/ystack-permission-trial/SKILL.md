---
name: ystack-permission-trial
description: "Validate an authorized local permission-advice trial with reversible installation, real prompt checks and decision-based evaluation."
---

# Permission Advice Trial

Inputs: an approved local advice feature, target applications, allowed request types and trial period. Output: coverage and visible-output evidence, an undo path and a usefulness assessment. This skill grants no installation, network, model or account permissions.

1. Implement the smallest reversible feature within scope. Keep advice distinct from the approval decision. Hook failure must neither block the agent nor decide for the user. Avoid warnings on low-risk requests.
2. Obtain independent read-only source review; repair findings and re-review. Install only when authorized, with backups and an undo path.
3. Test representative cases in a temporary state directory so synthetic results do not enter trial records. Check platform/request coverage and approval mode early.
4. Observe both hook invocation and user-visible advice in each actual application. Test shell escalation separately from app/network permissions and human prompts separately from automatic review. A hook log or documentation example does not prove display. If display is absent, report the limitation rather than declaring the user-facing trial successful.
5. Keep execution and trial records local, including advice and deliberate silence. At the accepted end date, assess whether advice changed an actual allow-once, persistent-allow or deny decision, or was noise. Do not count installation or invocation alone as success. A hosted-model extension needs its own decision.

Limits: a shell hook can run without showing user-visible text. An app-level network request may not invoke the hook. Automatic review can approve once silently. Do not treat these observations as universal hook behavior.
