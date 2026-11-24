---
name: ystack-script-backup
description: "Back up an approved allowlist of agent scripts and small state files to a private Git repository, with secret scanning and remote commit verification."
---

# Script Backup

Use an existing authorized destination and schedule. This skill grants no repository access, publishing rights or new automation permissions.

1. Confirm the destination repository is private. Recheck visibility after settings changes. Select only approved scripts and small state files; exclude credentials, large data and private personal data. Pattern scans can miss unusual secret formats.
2. Copy the allowlist into its local checkout. Preserve unrelated work. Inspect the exact staged changes and run the required secret scan on that content. Stop on any hit; never bypass the scan.
3. Commit only changed approved content. Push within the existing authorization. If nothing changed, verify synchronization before claiming success.
4. Check that the remote branch HEAD equals the intended local commit. Report a single success marker only after this check; otherwise report the failed stage without claiming completion.

## Limits

Confirm private visibility before the first push. A synchronized commit is not proof of full environment recovery. A backup run does not test long-term reliability or restoration.

## Separate memory from domain records

Where the owner has approved this layout, keep summarized lessons and decisions in shared memory, and code, prompts and concrete records in per-domain private repositories. Encrypt personal data at its authorized destination. Apply separate backup allowlists; a private repository does not authorize copying all its data. Keep backup verification distinct from reconstruction of an assistant from descriptions or a template. This pattern does not authorize creating repositories or schedules.

For repetitive scriptable work, use deterministic scripts and reserve model judgment for interpretation. Develop with a coding agent using public or fake test data, never real personal data. Where this layout is authorized, keep scripts in their owning bot's private repository so ownership and backup scope remain distinct.
