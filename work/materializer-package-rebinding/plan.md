---
spec-blob: 5ceb8bf6e99feeb8aed5e7ee2983fd4e12c14bb5
risk: high
drafted: 2026-09-25
---

# Plan: Restore the inactive materializer package bindings

Tracks #397. The accepted intent blob is
`129f1bd0829df002d39f5d3cb0d8650dfb017853`. Independent review and protected merge
of this plan must precede implementation. Record the resulting main as plan-base;
apply the existing base-reaffirmation gate if main moves before code.

## Scope and sequence

Use `ystack/impl/materializer-package-rebinding` from the accepted plan-base after
the manager verifies no existing attempt and records the build claim. Preserve any
existing attempt instead of replacing it. Implementation `review_size: standard`.
Change only these ten paths:

- `profiles/default/v1/manifests/local-git-materializer.json`
- `profiles/alternative/v1/manifests/local-git-materializer.json`
- `profiles/default/v1/profile.json`
- `profiles/alternative/v1/profile.json`
- `scripts/test/default-profile-assembly.test.sh`
- `scripts/test/alternative-profile-assembly.test.sh`
- `shadow/v1/materialization-input.jq`
- `docs/replay-materialization-result.md`
- `shadow/v1/assemble-materialization-input.sh`
- `scripts/test/shadow-assembler.test.sh`

Keep all unrelated fields, grants, capabilities, authority records, Roadmap
digests, model choices, package/prompt pins, predicates and runtime behavior.
Use the existing tools and suites; add no abstraction or redundant test suite.

### 1. Verify the already published source S

Use S `fc1fc01ff9963f5b8ccab5b26d4d572b9c1a0203`. Verify it is an ancestor of
the accepted base and the implementation branch. At
`adapters/local-git-materializer/v1`, require mode `040000`, type `tree`, object
`5c3607a765cc5d95372a0146be08832ecf554bfc`, and identical current package bytes.
Independently fetch exact S into a fresh isolated history repository through the
assembly suites' existing `history_fetch` boundary, with unchanged source/auth
handling, depth one and no tags. Check exact revision, reachable count one, no
tags and package path/mode/type/object. Preserve raw proof; local objects alone
do not count. A changed package stops for the affected artifact gate.

### 2. Commit and verify the six-file profile checkpoint B

In both materializer manifests, change only `body.package_ref.object_id` and
`body.package_ref.revision.commit_id` to S's tree and commit. Use the existing
digest-verified jq 1.6 with `-S -c` and one final newline. In each profile's sole
`adapter.local-git-materializer.v1` binding, copy that package reference and set
only `manifest_ref.sha256` to the canonical manifest SHA-256. Change only the
independent `materializer_package_commit` constant in each assembly suite to S.
Retain every other expectation and all isolated-fetch and object checks.

Compare the four documents structurally against plan-base and require only those
field changes. Commit precisely these six paths as B. Record its actual full OID;
push the existing implementation branch normally, verify its exact remote head and
S/B ancestry, and fetch exact B into another fresh isolated depth-one, no-tags
repository. Require exact revision, count one, no tags, four regular `100644` blobs,
complete bytes matching the checkout, their canonical SHA-256s, and S's unchanged
package tree. The manager records this tuple/proof before the dependent update.
This checkpoint push does not claim green packaging or implementation acceptance.

### 3. Finish the dependent pins, span provenance and source record

Set only `profile_pin`, `manifest_pins.forge` and the pinned-from header in
`shadow/v1/materialization-input.jq` to B's default profile digest, materializer
manifest digest and actual commit. Retain all other pins, texts and predicates.

In the assembler, replace old span 271–332's markers with adjacent spans 271–276
and 284–339 without changing their copied bytes. Rename 333–347 to 340–354 and
348–360 to 355–367. Do not copy the inserted private-index helper. Update the
existing `check_span` calls and their exact anchors accordingly. Preserve line
counts, anchor uniqueness and full byte comparisons against S/current source.
For the existing reproduction-driver comparison, concatenate the two split spans
to supply the original full sequence and update the other range-derived temporary
filename reference. Keep that comparison's existing first-seven-line selection,
all other spans, entry adaptations and every negative assertion unchanged.

Update only the existing containing-source section in
`docs/replay-materialization-result.md`: actual S/B IDs, package tree, four document
hashes, retaining implementation branch and isolated-fetch/retention requirements.
Point its retention procedure to this plan; do not claim a completed merge receipt.
Commit these four remaining paths on the same history. Final HEAD must contain
S's exact package and B's exact four profile files. No file names its own future
commit, and no historical source substitutes for actual HEAD in positive packaging.

### 4. Prove the complete repair

Record final head/base and run these existing suites completely from the worktree:

```sh
bash scripts/test/default-profile-assembly.test.sh
bash scripts/test/alternative-profile-assembly.test.sh
bash scripts/test/target-packaging.test.sh
bash scripts/test/shadow-assembler.test.sh
bash scripts/test/shadow-slice.test.sh
```

Retain complete output and exits; no filtering, skipping failures or weaker
assertions. Check the exact ten-path diff, allowed JSON fields, unchanged copied
executable bytes and unaffected pins/predicates. Run `git diff --check`; lint the
changed shell files with pinned shellcheck 0.11.0, `-x -S style`. Repeat S/B ancestry
and fresh isolated exact fetch/content proof before implementation PR publication
and before protected merge. Required automatic `ci` remains the quick gate under
`work/ci-minimum-roadmap/decision.md`; require fresh independent exact-head/base
review with no unresolved Important finding and all required CI green.

Preserve the failed full-matrix evidence. After this repair closes, the manager
refreshes preserved #395 to the merged base, rechecks its tuple and dispatches the
blocked integration matrix on that exact branch/head, using
`gh workflow run ci.yml --ref <verified-receiver-branch>`. Record actual run/head
and all shard results before accepting the milestone. Quick green is not that proof.

### 5. Obtain separate retention permission, then publish and verify

B must remain reachable from the original implementation branch after squash merge.
Automatic deletion would remove that guarantee. Once complete implementation,
independent review and required green proof are ready, present the exact tuple and
request direct operator approval for this one merge's `delete_branch_on_merge`
true-to-false change and restoration to true, including failure cleanup. Neither
the prior replay permission nor today's two-path authorization supplies it.

After approval, the manager uses the established procedure in
`work/replay-materialization-result/plan.md`, section 6:

1. Reserve a single-merge window. Record repository identity, expected setting true,
   protection/rules, exact branch/head/base/PR, S/B proof and green review/CI. Stop
   before any write on an unexpected setting, moved tuple or concurrent merge.
2. Set only that deletion setting to false and read it back. Recheck the exact
   review/CI tuple; perform only the protected squash merge pinned to reviewed head,
   without a deletion request or any protection, merge-method or permission change.
3. Verify the actual merge receipt, main, merged PR, unchanged remote branch head,
   S/B ancestry and fresh isolated exact fetch/content. Restore true and verify it;
   verify protection unchanged and repeat branch/source checks after restoration.
4. On failure or uncertainty after the setting write, stop other merges, reconcile
   actual PR/main/branch before any retry, preserve the attempt and restore/verify
   true even if merge failed. If restoration cannot be verified, notify the operator
   and keep all merges stopped. Never silently recreate a lost branch or source.

Record S/B, package tree, document digests, retaining branch, raw fetch proof and
restored settings with the merge receipt. Keep the branch while provenance names B.
If permission is declined or retention cannot be proven, leave the attempt unmerged
for an accepted alternative; do not add refs or rely on dangling objects or PR refs.

No live install, profile selection, activation, credentials, real target execution,
release publication, deployment, history rewrite, direct-main push or destructive
disposition is included. Preserve the separate #392 and #395 scopes and attempts.
