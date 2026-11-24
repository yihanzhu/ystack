---
name: ystack-repository-cleanup
description: "Preserve unique Git content and verify session scope before authorized branch, worktree or repository cleanup."
---

# Repository Cleanup

Inputs: the authorized repositories and cleanup scope, live branches/worktrees and associated sessions. Output: verified recovery references, completed removals and explicitly pending items. This workflow grants no deletion, archival, pruning or permission-bypass authority.

1. Inspect the cleanup tool's actual repository scope and dirty-worktree selection before using it. Session archival and filesystem removal are separate actions. Leave active/unarchived session worktrees pending. If archival effects on a main checkout are unclear, skip it. Do not bypass a rejected action.
2. Before deleting a merged branch, compare its tip with the PR head. For squash merges, compare branch and squash-commit trees: equality preserves final files, not individual history. For other branches, establish reachability from main or a retained PR-head ref; save unmatched commits under `refs/archive/branch/<name>`.
3. Preserve each required worktree HEAD under `refs/archive/worktree/<name>`. HEAD alone does not save uncommitted or untracked files. Where authorized, use a temporary index to commit required dirty content under `refs/archive/uncommitted/<name>`, then compare the saved files with the originals. Keep the ordinary index unchanged. Stop removal if preservation is incomplete.
4. Before any separately authorized reflog expiration or object pruning, preserve required reflog-only commits under `refs/archive/reflog/<sha>`. Do not discard tool-owned refs such as `refs/codex/turn-diffs` while a diff view depends on them. Immediate pruning is destructive and requires full preservation first.
5. Use normal `git worktree remove` for eligible clean worktrees. Verify the actual directory and registered-worktree result; an archived session is not evidence of removal. Do not treat force as a routine fallback.
6. Recheck recovery before concluding. An authorized restore may use `git checkout refs/archive/<name> -- <path>` in a safe destination; this writes files. If pruning was in scope, run an integrity check. Check expected PRs/remote branches. Fast-forward local main and refresh locked dependencies only when within the task's authorized closeout scope.

## Missing tracked files

When an authorized recovery must leave HEAD and the index unchanged, prepare an absent-file-only reconstruction. Bind each missing path to its original HEAD blob, length, hash and mode. Create only missing files; overwrite nothing. Compare this minimal recovery with a new branch before changing references. Keep the existing scene intact while any required approval remains pending. This method supplies no recovery authority.

## Limits

Check the cleanup tool's include-uncommitted option: enabling it can include dirty worktrees in other repositories. Session archival does not remove worktrees. Verify the tool's behavior in the current environment before applying it.

The [Git worktree documentation](https://git-scm.com/docs/git-worktree) confirms that normal removal requires a clean worktree and cannot remove the main worktree.

## Absent-directory restoration

Use only within explicit recovery authority. A completed absent-file repair does not authorize rebuilding a whole worktree when its directory later disappears. Stop source scheduling and plan commits; preserve surviving references and indexes and do not infer the disappearance's cause.

Inventory the complete original tracked tree, modes, symlinks/submodules and Git connection files. State that tracked-tree reconstruction does not recover old untracked content or ACLs. Require the original paths to remain entirely absent and exact metadata identities to match. Archive surviving metadata first. Restore exclusively without overwrite, cleanup or rollback; stop and preserve the scene on partial failure. Preserve original HEAD, refs, index and registration metadata.

Before freezing the restorer, inventory metadata membership including empty directories such as `refs`. Preserve the minimal required existing environment, including TMPDIR where read-only Git probes demonstrate its need; keep prior warning evidence. Check directory-chain identity before and after protected writes. Bound internal operation records with operation IDs, return codes, lengths and hashes while retaining the contract's complete original outer failure. Verify each restored file against its original blob, mode and post-write hash. Review the exact outer invocation with the restorer.

Verify physical restoration separately from budget closure. Read back files, gitfiles, directory/backup inventories and unchanged Git identities. A clean worktree and rc0 do not establish complete cumulative accounting or refund a consumed attempt.

## Archive and comparison refinements

Use these experience-based checks only within the existing cleanup authority. Refuse empty comparison inputs, preserve occupied archive refs under a different name and bind archives to the exact remote tips before deleting authorized branches.

Preserve existing archive refs during repository cleanup. When a proposed `refs/archive/worktree/…` name already points to another commit, save the additional worktree HEAD under a new name and leave the existing ref unchanged. Check session associations before removing worktree directories. Inactive but unarchived sessions can still depend on those directories. Check the current app before relying on its session archival behavior.

Validate shell parsing before trusting a bulk Git comparison. In zsh, an unquoted `$pair` is not split into words as in bash. Every comparison then receives empty input and prints a false SAME result. Reject such output and rerun the check in bash. Empty-input comparisons must not count as preservation evidence.

Before deleting authorized remote preview branches, bind each local archive ref to the exact current remote branch tip. Compare local and remote tips first. Create refs under refs/archive/branch/<name> without overwriting existing refs. Verify every archive target before deletion, then verify that the remote branches are absent and the archive refs still resolve. Archive refs in the shared Git repository are accessible from the main checkout. Restore a branch with `git branch <branch-name> refs/archive/branch/<name>`. This method grants no deletion authority.

## Recovery with surviving tracked files

Compare surviving files with retained HEAD before and after an authorized absent-file restore. Inventory required parent directories and Git metadata. Exclusively create the approved missing files and gitfile, and fully read back each creation. Keep original index, refs, metadata and surviving files unchanged. Account for the restore's own directory-link changes and register creations before a later step can fail.

For a frozen, single-attempt recovery contract, retain its unique GO, identity and directory-chain checks, no-cleanup rule and no automatic retry. Check the real hash-bound interpreter against resolved paths while retaining alias evidence. Review supplemental invocation paths as well as the main restorer. Preserve failed preparation charges, shutdown costs and unknown totals across revisions; a shutdown bound does not prove total capacity.

## Exact reference-name preflight

For a preservation package that requires exact Git reference matching, verify reference names as well as their target objects before staging. Object identity alone does not satisfy an exact-match condition. If reference names have changed while their target objects remain identical, stop before `git add`, leaving source, index and branches unchanged. Propose a narrow independent review to determine whether those references can be rebound within the existing scope.

## Preserve a bound working state during integration

Where the existing contract requires it, inspect attributes before status can trigger conversion. Bind reference names and objects separately; a name change with an identical object satisfies only an explicitly permitted exception. Keep failed-stop records and consumed attempts. Authenticate and parse a manifest from the same captured bytes. Safety checks must survive interpreter optimization; reject abnormal Git configuration before external commands and invalid execution authority before logging or subprocess startup. Classify closure errors precisely rather than treating every OSError as proof of closure.

Preserve uncommitted drafts while normally integrating accepted non-overlapping specification/plan changes. Verify the full manifest, contents, modes, required metadata, index and refs before author resumption with fresh bindings. For a sealed single-attempt contract, stop on mismatch and retain the scene; do not restore or retry automatically. Correct stale receipts forward from the actual parent chain and original merge receipt, retaining originals. After a stale write response, use read-only local/remote/PR checks before repeating any write. Bind branch creation to observed remote-ref absence and comment operations to the actual Issue or PR endpoint.

## Recover a worktree lost from temporary storage

Prefer durable storage for long-lived worktrees. A worktree in temporary storage can disappear while its registration metadata survives; other registrations may then be prunable. Where recovery is authorized and registration metadata survives, reconstruct the tracked tree from its HEAD with `git archive`, restore separately frozen dirty files, reconnect the gitfile to the surviving metadata, then use `git worktree repair <durable-path>`. Verify with a temporary-index `write-tree` against the recorded pre-loss tree hash. Preserve the ordinary index. Without a separate copy, this method cannot recover lost uncommitted edits. This is a recovery option within the applicable contract, not permission to move or reconstruct a guarded worktree.
