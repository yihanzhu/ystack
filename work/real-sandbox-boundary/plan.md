---
spec-blob: db2b42de4e3ba0828292e40086a27f132a6b7eb8
drafted: 2026-09-14
---
# Plan: real-sandbox-boundary

Tracks #287. Risk: high. Review size: standard.

The accepted decision is blocked for real execution. This implementation makes that
decision discoverable and restore-critical; it does not implement a sandbox. The
spec was read on main 0d58293ae68e4ddc52e6370ec8512c7e8f9a9a96 and binds intent
blob e344e7d1fead76bc5f238d9796e279fd5816297f. The accepted spec remains the sole
source for the boundary map, blockers and four separately gated child concerns.

## Files that change

Only these three existing paths may change in the implementation:

- `docs/components.md`: one paragraph after the inactive sandbox-policy evaluator
  description, before the credential-policy heading (base lines 195–208).
- `RESTORE.md`: one paragraph after the existing sandbox restore/test explanation,
  before the credential-policy restore instructions (base lines 606 onward).
- `ci/required-files.txt`: a separate decision-record block immediately after the
  five existing sandbox-policy/evaluator paths (base lines 207–212).

Estimate: 20–30 net added lines across the three files, including Markdown wrapping,
three manifest paths and their block heading. No size exception is needed. This
plan-only stage changes only `work/real-sandbox-boundary/plan.md`; that artifact is
not an implementation edit. Accepted intent, spec and plan remain unchanged in the
terminal documentation PR.

## Order of work

1. Complete the separate high-risk plan gate before implementation. Verify that
   main still contains the exact spec and intent above, with spec risk high and
   matching intent-blob. Record the accepted plan blob and plan-base. If the base
   moves, use the current program's fresh independent base review and manager
   record before starting; no old review or CI carries over automatically.

2. On the deterministic implementation branch `ystack/impl/real-sandbox-boundary`,
   add this paragraph at the components location above, adjusting wrapping only:

   > The [accepted sandbox boundary decision](../work/real-sandbox-boundary/spec.md)
   > is complete as an architecture decision; real execution remains blocked.
   > Its boundary map and four separately gated implementation concerns define what
   > must be resolved before use. This decision ships no runtime, and the evaluator's
   > declaration-only result still grants no enforcement proof or qualification.

   Preserve the existing evaluator description and its no-authority statement.
   Do not duplicate the map, numerical ceiling or runtime candidate in this paragraph.

3. Add this paragraph after the complete existing sandbox restoration explanation:

   > Restore the sandbox decision's [intent](work/real-sandbox-boundary/intent.md),
   > [spec](work/real-sandbox-boundary/spec.md) and
   > [plan](work/real-sandbox-boundary/plan.md) from the same commit, using the
   > decision-record block in [the manifest](ci/required-files.txt). Read the spec
   > for the accepted blockers and later implementation dependencies. Restoring
   > these records and the declaration evaluator does not restore a qualified
   > launcher; real execution remains blocked.

   Keep the existing focused-test command and declaration-only explanation intact.
   Add no installation, VM-start, probe or self-host-run command.

4. Add a block headed `# Sandbox boundary decision records` containing exactly
   these paths, once each. Preserve every existing manifest entry:

   ```text
   work/real-sandbox-boundary/intent.md
   work/real-sandbox-boundary/spec.md
   work/real-sandbox-boundary/plan.md
   ```

   If an entry is already present at the accepted implementation base, retain its
   existing occurrence instead of duplicating it. A conflicting artifact identity
   stops work; a duplicate is not a reason to remove unrelated manifest records.

5. Inspect the full three-file diff, run the proof below, and publish a terminal
   documentation PR using `Closes #287`. Describe its outcome as delivering and
   restoring the blocked sandbox architecture decision. Do not claim a completed
   sandbox, native qualification, self-host run or Roadmap step 7. No child concern
   is implemented or accepted by this closure. Required CI and fresh independent
   exact-head/base review precede the named manager's protected merge and receipt.

## Risks

The main risk is wording that turns a completed decision into a claim of a working
security boundary. Review the added paragraphs against the complete accepted spec,
not just the word “blocked.” Preserve declaration-only status, the exact ceiling,
all unresolved enforcement/provenance blockers and every separate child gate.

Manifest linkage must include the subsequently accepted plan and use correct relative
links from two different directory levels. Do not change artifact bytes to make
links or hashes pass. The original evaluator and its 46 declaration checks stay
unchanged; green CI does not qualify a real execution environment.

A copied matrix or new decision.md would create a second source to maintain. A
README component row could imply a runtime exists. Neither is needed: README already
leads readers to component documentation, and the existing restore instructions
provide the right entry point. An empty PR would deliver no restoration improvement.

The program permits this bounded documentation completion, not installation,
selection, probes, runtime or candidate execution, acquisition, credentials or
activation. Those reserved boundaries and the four future concerns remain separate.

## Proof

Use the actual implementation base and final head in every report. Record these
read-only identity checks before edits and again on committed final bytes:

```sh
git rev-parse HEAD:work/real-sandbox-boundary/intent.md
git rev-parse HEAD:work/real-sandbox-boundary/spec.md
git rev-parse HEAD:work/real-sandbox-boundary/plan.md
git show HEAD:work/real-sandbox-boundary/spec.md | sed -n '1,5p'
git show HEAD:work/real-sandbox-boundary/plan.md | sed -n '1,4p'
```

Require the first two blobs above, the separately accepted plan blob, risk high
and both correct hash links. Against the recorded implementation base, inspect
`git diff --name-only BASE HEAD`, `git diff --stat BASE HEAD` and the full
`git diff BASE HEAD`; exactly the three allowed paths may differ. Replace BASE with
that recorded full OID. Run `git diff --check BASE HEAD` and require no output.

Check each of the three manifest paths exists as a tracked regular file and appears
exactly once among active manifest lines. Check every new relative Markdown link by
resolving it from the containing file; all targets are existing tracked files and
no heading fragments are added. Read the complete changed sections to confirm the
existing evaluator/test explanation and all other manifest entries remain intact.
These are one-time content checks, not a new matching-text test committed to the repo.

Run the focused suite without modifying it:

```sh
bash scripts/test/control-sandbox-policy.test.sh
```

Require all 46 existing focused checks to pass. This preserves declaration/identity
behavior only. Record the actual command, head, platform and complete output; no
real runtime probe or synthetic VM proof is part of this command.

On the exact final PR head/base, require all existing CI jobs: checks, test shards
1–6 and the ci aggregate. The checks job runs the complete required-file existence
and script-executable check, pinned ShellCheck 0.11.0, sharding proof and rename
gate. Each shard runs `bash scripts/test/run-all.sh --shard N/6` for its actual N;
this preserves the complete existing test set, including schema checks. Do not
substitute the focused suite for full required CI or rerun a failed suite until green.

A separate read-only reviewer applies Bugs, Security and Compliance passes to the
complete exact-head/base diff, hash links, manifest/link checks and CI evidence.
The manager reads the complete raw review and resolves every Important finding.
No new unit test, evaluator edit, artifact edit or safety/qualification claim is
needed for this documentation change.
