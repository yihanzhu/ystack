---
spec-blob: f55ca9023b66b52fefed8571a2c8806656018578
drafted: 2026-09-27
---
# Plan: external-target-shadow-run

Tracks #426. Risk: high, matching the accepted spec frontmatter. Gate mode is
`artifact-high`: this plan-only PR needs independent review, green CI and operator
merge before any registry edit, run or code. This one plan covers two PRs, in order:
the registry PR, then the evidence PR. No second plan is needed unless a stop
condition below fires.

`work/external-target-shadow-run/spec.md` (blob above) is the contract. Where a step
names a requirement, that requirement's wording is the detail to follow. Where this
plan says "as the self-host plan", it means `work/shadow-self-host-run/plan.md` on
main, with every self-host value replaced by the value given here.

Before accepting this plan, and again before each PR's first commit, recheck the spec
blob above against main and the spec's own `intent-blob`
(`7659bfdbf0175d5f6a0ab363038ac21f7b4e0568`) against main's
`work/external-target-shadow-run/intent.md`. A mismatch stops work (`stale`).

Checked while drafting, against the operator's local clone
`/Users/yihanzhu/git/ystack-dummy-target` and main:

- `git log -1 --format='%H %P %T' e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e` gives
  single parent `413a2f02a46ababa987039be65089e95c1916765` and root tree
  `1c173494765089b1cce2dac6e061135e7fee5c77`.
- `git rev-list --max-parents=0 e7da8f7b` returns only
  `c1cacf5a1dbcc5030d66ecd300bf0b115c792e99`. Object format is `sha1`.
- `src/greet.sh` is blob `bbea64b7…` at the pre revision (SHA-256
  `c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c`) and blob
  `2abe3e52…` at the post revision (SHA-256
  `9a3eecedc5f314cbc921ac8768b7651c3324afa355d42c90686ee8efb803dd90`).
- `git diff --stat a73bd8c origin/main` over `shadow/v1`, `resolver/v1`,
  `scripts/lib/profile-resolution.sh`, `adapters/local-git-materializer/v1`,
  `control/v1`, `scope/v1`, `maintenance/v1`, `telemetry/v1`, `profiles/default/v1`,
  `core` and `scripts/core-contract.sh` is empty.
- The self-host `resolved-profile.json` names the registry bytes
  (`721e19bb…`, the SHA-256 of main's `shadow/v1/shadow-environments.json`) as its
  `repository_context_ref` decision record, and its shadow records carry the same
  digest in `body.environment.registry_ref`. The self-host environment declaration
  hashes the `jq -S -c` output of its one registry entry, newline included.
- `bash scripts/test/shadow-self-host-evidence.test.sh` on main prints ten `ok` lines
  and `shadow self-host evidence: 10 focused checks passed`, in about one minute.
- Enumerating every `repository_id` and `target_repository_id` path in the 45
  self-host files gives 114 file/path pairs, exactly requirement 15's two lists.

## Files that change

Nothing outside these lists. Counts are net changed lines.

### PR 1: the registry entry (requirements 1-3)

- `shadow/v1/shadow-environments.json` (1 line changed). Append the third entry of
  requirement 1 after the two existing ones. The file stays one canonical
  `jq -S -c` line with its trailing newline. With pinned jq 1.6 the expected bytes
  are exactly those of
  `jq -S -c '.body.environments += [<entry>]'` over main's file, where `<entry>` is
  requirement 1's six fields. Computed while drafting, the new file's SHA-256 is
  `37c9776205decf8aa37404ca1ddff941d13401f8b515a6e03e0e3f8e4102dd12` and the new
  entry's `jq -S -c` output (with newline) hashes to
  `2cad2eb4ed2381bcfa528fb3bf9d7314650cb5e5411b7f08f02825c1254c141a`. The PR
  recomputes both and states them; if they differ, stop and explain.
- `scripts/test/shadow-slice.test.sh` (+6, -1), at the `registry-contents` pin
  (lines 340-362): add
  `--arg dummy_description "Operator's local macOS checkout, a scrubbed bare copy of the external dummy target repository."`
  after `self_description`; append a third element to `environments` —
  `{description:$dummy_description,environment_id:"env.local-macos-dummy-target",
  evidence_scope:"external-target",proof_state:"unproven",
  source_root_commit:"c1cacf5a1dbcc5030d66ecd300bf0b115c792e99",
  target_repository_id:"repo.ystack-dummy-target"}`; change the pass message to
  `the environment registry lists three environments, each bound to a target repository and a source root commit`.
  Nothing else in the file changes. The component-digest block at lines 58-67 reads
  the registry at run time, so it needs no edit.
- `docs/components.md` (about +4, -3), the registry paragraph at lines 1365-1371:
  "It lists three entries today: `env.local-macos-fixture` (`fixtures-only`,
  `unproven`), `env.local-macos-ystack-self` (`self-host`, `unproven`) and
  `env.local-macos-dummy-target` (`external-target`, `unproven`), which binds the
  external dummy target `repo.ystack-dummy-target` by its root commit." No other
  paragraph changes.

No validator or enumeration for `evidence_scope` is added.
`shadow/v1/reproduce.sh`, `scripts/test/shadow-assembler.test.sh` and
`scripts/test/shadow-self-host-evidence.test.sh` must pass unchanged: the driver and
the assembler test select entries by id, and the self-host test does not read the
registry.

### PR 2: the evidence (requirements 13-17)

**New evidence under `shadow/evidence/external-dummy-target/v1/`**, the same 45-file
layout as `shadow/evidence/self-host-transition/v1/`:

| Path | What it is | Lines |
| --- | --- | ---: |
| `README.md` | Requirement 14's sections plus the portability result and requester provenance | 210-250 |
| `verification-instructions.md` | Requirement 13's hand-written file-digest procedure for `src/greet.sh` | 80-90 |
| `checksums.json` | Id `shadow.external-dummy-target.v1.checksums`; sorted relative paths and SHA-256 of the other 44 files | 1 |
| `resolved-profile.json`, `requester.json`, `environment-claim.json`, `control-policy-set.json`, `core-package-closure.json`, `duty-evaluation.json` | Shared documents, as the self-host bundle | 6 |
| `prerequisite/{environment-declaration,input,stage-request,resolved-profile-document,stage-result,materialization-receipt}.json` | The prerequisite stage run | 6 |
| `{pre,post}/{incident,qualified-identity,sandbox-evaluation,materialization-receipt}.json` | Per-case documents | 8 |
| `{pre,post}/assembled/*` | The assembler's seven outputs, native names | 20-40 |
| `{pre,post}/state/*` | The driver's four state files | 8 |

That is 15 shared files and 15 per case. The 42 files other than `README.md`,
`verification-instructions.md` and `checksums.json` are kept exactly as produced or
constructed, never edited.

**Changed test:** `scripts/test/shadow-self-host-evidence.test.sh` (net +550-800).
It keeps its name, because the manifest, docs and RESTORE already name it. It becomes
the one table-driven harness for both bundles (see "The shared harness" below).

**Existing files:**

- `ci/required-files.txt` (+47): a block `# First external-target shadow evidence`
  directly after the self-host block's last line
  (`scripts/test/shadow-self-host-evidence.test.sh`), listing the 45 evidence paths
  in `LC_ALL=C sort` order, then a blank line.
- `scripts/test/portable-core-schema.test.sh` (+3): exactly three lines added to
  `schema_v2_corrective_expected_hits`, in `git ls-files` order, which puts them
  after `scripts/test/portable-core-v2-evidence-identity.test.sh` and before
  `shadow/evidence/self-host-transition/v1/control-policy-set.json`:
  `shadow/evidence/external-dummy-target/v1/control-policy-set.json`,
  `.../core-package-closure.json`, `.../duty-evaluation.json`. These three retained
  documents carry the corrective v2 generation id as emitted (the policy set copy,
  the closure the policy set names, and the evaluator's `core_contract`), exactly as
  #374 did for the self-host bundle. Nothing else in that file changes.
- `docs/components.md` (+60-75): `## First external-target shadow evidence` after
  `## First self-host shadow evidence`, before `## Inactive maintenance loop`,
  following the self-host section's structure, plus the portability result.
- `README.md` (+1): one index row after the "First self-host shadow evidence" row.
- `RESTORE.md` (+25-35): `### Restore the first external-target shadow evidence`
  after the self-host restore block. It restores evidence only; it runs nothing and
  registers, activates or qualifies nothing.

### What does not change

`shadow/v1/*` (including the registry after PR 1), `resolver/v1/*`,
`scripts/lib/profile-resolution.sh`, `adapters/local-git-materializer/v1/*`,
`control/v1/*`, `scope/v1/*`, `maintenance/v1/*`, `telemetry/v1/*`,
`profiles/default/v1/*`, `core/*`, `evals/v1/*`, every self-host evidence file, and
every accepted intent, spec or plan. A component that refuses the run is right; the
run stops (requirement 7).

### Review size

- Registry PR: `review_size: standard` — about 12 net lines, one concern.
- Evidence PR: `review_size: accepted-exception` — 1,000-1,400 net lines, one concern
  (the first external-target evidence pair and its shared offline verification), the
  range the accepted spec records. Evidence: #373 was +1,706/−1 over 51 paths. Here
  the README and instructions are 290-340 lines, canonical JSON and assembler text
  45-60, manifest and allowlist 50, docs 85-110, and the harness 550-800 instead of a
  1,200-line copy. An unexplained overrun returns to this plan gate.
- This plan PR: `review_size: accepted-exception` — 860-880 lines, measured, one
  concern (the plan for both PRs). It is over the soft budget because it carries the
  exact run recipes and the harness design the spec asks for, so the implementer
  has nothing left to decide. It waives the soft line signal only.

## Order of work

1. This plan merges (independent review, CI, operator merge). Record the merged main
   OID as `plan-base`. If main moves before PR 1's first commit, follow
   `work/README.md`: fresh non-author review with one `Plan-verdict:` and operator
   reaffirmation on #426.
2. **PR 1**, branch `ystack/impl/external-target-shadow-run` from `plan-base`:
   the registry entry. `Tracks #426`. Independent review, CI, operator merge.
3. The operator confirms the registry entry on #426 or in chat (requirement 16a).
4. The precondition gate below.
5. Provisioning, before the boundary.
6. The observation of the two frozen inputs, and the operator's confirmation of
   them with their `observed_at` times (requirement 16b).
7. The evidence session: source, resolution, construction order, both runs, capture
   of receipts and evaluations, repeatability, source comparison.
8. **PR 2**, same branch after an exact merge of fetched main (no reset, rebase or
   force). `Closes #426`. Independent review, CI, operator merge. Two commits, in
   order:
   1. the harness refactor on the self-host bundle alone ("Commit 1" below);
   2. everything else together, because CI needs it together: the 45 evidence
      files unchanged from capture, the three `schema_v2_corrective_expected_hits`
      lines (requirement 17; without them the schema test fails as soon as the
      evidence lands), the new bundle's table arm and new checks ("Commit 2"
      below), the manifest block, and the docs, index row and restore block.

## PR 1: the registry entry

Make the three edits under "Files that change". Proof for PR 1:

```sh
jq -S -c . shadow/v1/shadow-environments.json | cmp - shadow/v1/shadow-environments.json
shasum -a 256 shadow/v1/shadow-environments.json
jq -S -c '.body.environments[] | select(.environment_id == "env.local-macos-dummy-target")' \
  shadow/v1/shadow-environments.json | shasum -a 256
bash scripts/test/shadow-slice.test.sh
bash scripts/test/shadow-assembler.test.sh
bash scripts/test/shadow-self-host-evidence.test.sh
```

Use the pinned jq 1.6 (`$JQ` below) for the first three lines. The slice test
prints the three-environment pass line. The self-host evidence test still prints
`shadow self-host evidence: 10 focused checks passed`. CI green on the head. The PR
body states the two digests.

## The precondition gate (requirement 4)

No evidence-session step runs until all of these hold. The README records each.

1. PR 1 is merged. Pick `RUN_COMMIT`, a main commit that contains PR 1 and this
   plan. Check both:
   `git merge-base --is-ancestor <PR 1 merge commit> "$RUN_COMMIT"` and
   `git rev-parse "$RUN_COMMIT:work/external-target-shadow-run/plan.md"` equals the
   operator-merged plan blob.
2. The #373 components are unchanged:
   `git diff --quiet a73bd8c77214224a7ccbefae9fcd2ac22a50f895 "$RUN_COMMIT" -- shadow/v1 resolver/v1 scripts/lib/profile-resolution.sh adapters/local-git-materializer/v1 control/v1 scope/v1 maintenance/v1 telemetry/v1 profiles/default/v1 ':!shadow/v1/shadow-environments.json'`.
   Any difference stops the run.
3. DR-6 is accepted on #426: the
   [decision request](https://github.com/yihanzhu/ystack/issues/426#issuecomment-5858098260)
   and the [acceptance record](https://github.com/yihanzhu/ystack/issues/426#issuecomment-5858272787)
   ("approve IN-5 DR-6"). It covers this intake only.
4. The operator has confirmed the registry entry and the frozen inputs (steps 3 and
   6 of the order).
5. Pinned jq 1.6 and the closure helper are provisioned, as below.

## Before the evidence session: provisioning

This is not part of the run and produces no evidence document.

- `$GIT_HOME` is a fresh, empty 0700 directory. `GIT_ISO` is the self-host plan's
  isolated Git prefix, exactly (cleared environment, disposable `HOME`, no system or
  global config, six pinned keys). Every `git` command in this plan uses it.
- `$REPO` is the frozen runtime: a fresh non-shared clone of the operator's local
  ystack checkout, detached at `RUN_COMMIT`, with its remote removed:

  ```sh
  "${GIT_ISO[@]}" /usr/bin/git clone --no-hardlinks --no-checkout -- \
    /Users/yihanzhu/git/ystack "$REPO"
  "${GIT_ISO[@]}" /usr/bin/git -C "$REPO" checkout --detach "$RUN_COMMIT"
  "${GIT_ISO[@]}" /usr/bin/git -C "$REPO" remote remove origin
  ```

  Record `git -C "$REPO" rev-parse HEAD`, empty `git status --porcelain`, and the
  SHA-256 of `$REPO/.git/index`, before capture and after. They must not change.
  Repo-relative commands below run with `$REPO` as the working directory.
- jq 1.6: `bash scripts/test/shadow-slice.test.sh` once fills
  `${TMPDIR:-/tmp}/ystack-portable-core-jq16/jq-osx-amd64` (Darwin SHA-256
  `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`). This is the
  only network action in this initiative. Copy the verified, non-symlink asset into
  a fresh 0700 `$JQ_DIR` as `jq`, mode `0555`; `$JQ=$JQ_DIR/jq`. If it is absent or
  does not match, stop with `pinned jq 1.6 asset not provisioned` and end the
  session; never download inside it.
- Closure helper: compile `$REPO/adapters/local-git-materializer/v1/object-closure.c`
  as `scripts/test/shadow-slice.test.sh:52-55` does, to `$CLOSURE`.
- `$EVIDENCE` is the capture directory, with `prerequisite/`, `pre/` and `post/`
  inside; `$PRE_REQ=$EVIDENCE/prerequisite`. Every other directory named below is a
  fresh, empty, private 0700 directory outside `$REPO` and `$SRC`, disjoint from all
  others.

The README records the asset, URL, verified digest, cache path and date as a
precondition line, not an evidence document.

## The frozen inputs and their confirmation (requirements 5, 11, 16b)

Read-only, on the operator's local clone, under `GIT_ISO`:

```sh
T=/Users/yihanzhu/git/ystack-dummy-target
"${GIT_ISO[@]}" /usr/bin/git -C "$T" log -1 --format='%H %P %T' e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e
"${GIT_ISO[@]}" /usr/bin/git -C "$T" rev-list --max-parents=0 e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e
"${GIT_ISO[@]}" /usr/bin/git -C "$T" rev-parse 413a2f02a46ababa987039be65089e95c1916765:src/greet.sh e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e:src/greet.sh
"${GIT_ISO[@]}" /usr/bin/git -C "$T" cat-file -s 413a2f02a46ababa987039be65089e95c1916765:src/greet.sh
"${GIT_ISO[@]}" /usr/bin/git -C "$T" cat-file -s e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e:src/greet.sh
"${GIT_ISO[@]}" /usr/bin/git -C "$T" cat-file blob 413a2f02a46ababa987039be65089e95c1916765:src/greet.sh | shasum -a 256
"${GIT_ISO[@]}" /usr/bin/git -C "$T" cat-file blob e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e:src/greet.sh | shasum -a 256
/bin/date -u +%Y-%m-%dT%H:%M:%SZ
```

Expected: parent `413a2f02…`, tree `1c173494…`, root `c1cacf5a…`, blobs
`bbea64b7…`/`2abe3e52…` of 121 and 330 bytes, digests
`c5ddea82…274a41c`/`9a3eeced…803dd90`. The `date` output is `observed_at`, one time
for both records. The manager posts these values on #426; the operator confirms
them there or in chat. Only then are they frozen. If the clone lacks an object, the
operator fetches it into their own clone before the boundary; nothing inside fetches.

## Prepare the disposable source (requirement 6)

Exactly as the self-host plan's "Prepare the disposable source", with the source
path changed:

```sh
"${GIT_ISO[@]}" /usr/bin/git clone --bare --no-hardlinks -- \
  /Users/yihanzhu/git/ystack-dummy-target "$SRC"
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" remote remove origin
rm -rf -- "$SRC/logs" "$SRC/info/grafts" "$SRC/objects/info/alternates"
find "$SRC/hooks" -type f ! -name '*.sample' -delete
printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n' \
  > "$SRC/config"
```

Then confirm no `shallow` file, no `objects/info/alternates`, no `refs/replace/`,
and no non-sample hook. Record the two inventory digests
(`show-ref | shasum -a 256` and
`cat-file --batch-all-objects --batch-check='%(objectname)' | shasum -a 256`), and
recompute inside `$SRC` every value of the section above (parent, root, tree, both
blob ids, sizes and raw digests). A mismatch stops the run. Never `gc`, `repack` or
`fsck --lost-found` `$SRC`. The operator's clone is never scrubbed or written.

## Resolve the real profile (requirement 9)

Build `$REQUEST` and `$MAP` in the scratch directory with `$JQ -S -c -n`. Every
object id comes from `git -C "$REPO" rev-parse` or `git --git-dir="$SRC" rev-parse`,
never typed. `L(p)` below means the locator
`{repository_id:"repo.ystack",hash_algorithm:"sha1",commit_id:$RUN_COMMIT,path:p,
object_id:<rev-parse $RUN_COMMIT:p>}`.

- `$REQUEST`: `{version:1, profile_source:L("profiles/default/v1/profile.json"),
  manifest_sources:[L(each of the six profiles/default/v1/manifests/*.json, sorted)],
  selection_ref:S, repository_context_ref:C}`.
- `S` (selection): `{purpose:"selection", decision_record_ref:{content_id:
  "plan.external-target-shadow-run", media_type:"text/markdown", sha256:P},
  scope_sha256:P, subject_ref:{type:"artifact", value:{type:"git-object",
  value:{revision:{repository_id:"repo.ystack", hash_algorithm:"sha1",
  commit_id:$RUN_COMMIT}, location:{kind:"path",
  value:"work/external-target-shadow-run/plan.md"}, object_type:"blob",
  mode:"100644", object_id:<rev-parse $RUN_COMMIT:work/external-target-shadow-run/plan.md>}}}}`,
  where `P` is the SHA-256 of that blob's raw bytes.
- `C` (repository context): `{purpose:"repository-context",
  decision_record_ref:{content_id:"shadow-environment-registry",
  media_type:"application/json", sha256:R}, scope_sha256:R,
  subject_ref:{type:"artifact", value:{type:"git-object",
  value:{revision:{repository_id:"repo.ystack-dummy-target", hash_algorithm:"sha1",
  commit_id:"e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e"}, location:{kind:"root"},
  object_type:"tree", mode:"040000", object_id:<rev-parse e7da8f7b^{tree} in $SRC>}}}}`,
  where `R` is the SHA-256 of `$REPO/shadow/v1/shadow-environments.json`
  (expected `37c97762…`). The tree id must equal `1c173494…`.
- `$MAP`: `{version:1, repositories:[{repository_id:"repo.ystack", root:$REPO},
  {repository_id:"repo.ystack-dummy-target", root:$SRC}]}`.

Run:

```sh
"$REPO/resolver/v1/resolve-profile.sh" "$JQ" "$RESOLVE_OUT" "$REQUEST" "$MAP" \
  > "$EVIDENCE/resolved-profile.json"
```

Expected: exit 0, `$RESOLVE_OUT` holds exactly `home`, `tmp`, `child.stdout`,
`child.stderr`, and stdout equals `child.stdout`. `$RESOLVED_PROFILE` is that file.
A refusal (for example `map-extra`, `locator-map-missing` or a repository-layout
error on `$SRC`) stops under requirement 7; never fall back to naming ystack's tree.
The README records the request and map digests and the map's two repository ids,
not the roots. `$REQUEST` and `$MAP` are not committed. The producer settings are
recorded configuration, never evidence that a model ran.

## Construction order (requirements 8, 10, 11)

Fixed and acyclic: no entry names bytes made after it. The reasons for each rule are
the self-host plan's "Construct the duty evaluation and the claim"; they are not
repeated here.

1. **`requester.json`** (`$REQUESTER`):

   ```sh
   "$JQ" -S -c -n --arg run_commit "$RUN_COMMIT" '{role:"operator",
     implementation_id:"ystack-operator-cli", implementation_version:$run_commit,
     adapter_instance_id:"instance.operator.local-macos",
     principal_id:"principal.operator.yihanzhu",
     execution_boundary_id:"boundary.operator.local-macos"}' > "$EVIDENCE/requester.json"
   ```

   Its digest is recorded in the README and pinned in the harness table.
2. **`control-policy-set.json`** (`$POLICY_SET`): `$REPO/control/v1/control-policy-set.json`
   copied byte for byte. Check with
   `PATH="$JQ_DIR:/usr/bin:/bin" control/v1/validate.sh validate "$POLICY_SET"`.
3. **`core-package-closure.json`**: the self-host plan's recipe exactly — read the
   generation id at run time from `$REPO/scripts/core-contract.sh`, hash the nine
   members, build with `$JQ -Rn -S -c`, write with no trailing newline. Its SHA-256
   must equal the policy set's `body.core_contract.package_ref.sha256` (at a73bd8c,
   `eff044bd…`); a mismatch stops the run. The README names the generation only by
   its `g-c83c940a` prefix and the closure's `selected_generation_id_sha256`, never
   the full id (the closed allowlist forbids it outside its listed paths).
4. **`resolved-profile.json`**: from the resolution above.
5. **`prerequisite/environment-declaration.json`**: `$JQ -S -c -n --slurpfile policy
   control/v1/sandbox-policy.json --arg entry_sha "$E"` building
   `{schema_version:1, kind:"execution_environment_claim",
   id:"env.local-macos-dummy-target", body:(the policy body's environment,
   filesystem, isolation, limits, network, resources, sensitive_material and tools
   sections) + {registry_entry_sha256:$entry_sha}}`. `$E` is the SHA-256 of
   `$JQ -S -c '.body.environments[] | select(.environment_id == "env.local-macos-dummy-target" and .target_repository_id == "repo.ystack-dummy-target")' shadow/v1/shadow-environments.json`
   (with newline, expected `2cad2eb4…`), after checking exactly one entry matches.
6. **`prerequisite/input.json`, `stage-request.json`, `resolved-profile-document.json`**:

   ```sh
   shadow/v1/assemble-materialization-input.sh assemble \
     repo.ystack-dummy-target "$SRC" 413a2f02a46ababa987039be65089e95c1916765 \
     "$REQUESTED_AT_0" "$REPO/profiles/default/v1" "$RESOLVED_PROFILE" "$JQ" \
     "$OUT_DIR_0" "$PRE_REQ/environment-declaration.json" "$REQUESTER"
   cp "$OUT_DIR_0/input.json" "$PRE_REQ/input.json"
   "$JQ" -S -c '.stage_request.content' "$OUT_DIR_0/input.json" > "$PRE_REQ/stage-request.json"
   "$JQ" -S -c '.resolved_profile.content' "$OUT_DIR_0/input.json" > "$PRE_REQ/resolved-profile-document.json"
   ```

   `$REQUESTED_AT_0` is the real UTC time of this step, different from
   `observed_at`. The two extracts' digests must equal the `sha256` of
   `$OUT_DIR_0/stage-request-ref.json` and `resolved-profile-ref.json`.
7. **`prerequisite/stage-result.json`, `materialization-receipt.json`**:

   ```sh
   /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash \
     "$REPO/adapters/local-git-materializer/v1/materialize.sh" materialize \
     "$PRE_REQ/input.json" repo.ystack-dummy-target "$SRC" "$CAND0" "$SCRATCH0" \
     "$CLOSURE" "$JQ" > "$SCRATCH_E/materialize.json"
   "$JQ" -S -c '.stage_result' "$SCRATCH_E/materialize.json" > "$PRE_REQ/stage-result.json"
   "$JQ" -j '.payloads[0].data' "$SCRATCH_E/materialize.json" > "$PRE_REQ/materialization-receipt.json"
   ```

   The receipt's SHA-256 must equal `payloads[0].sha256` and the stage result's
   `body.evidence[0].proof_ref.sha256` and
   `body.execution.metadata.tools.source_ref.sha256`. The envelope is scratch; the
   README records its stdout digest.
8. **`duty-evaluation.json`** (`$DUTY`):

   ```sh
   PATH="$JQ_DIR:/usr/bin:/bin" control/v1/evaluate-duty.sh evaluate \
     "$POLICY_SET" "$PRE_REQ/stage-request.json" \
     "$PRE_REQ/resolved-profile-document.json" "$PRE_REQ/stage-result.json" > "$DUTY"
   ```

   Expected `satisfied` with exactly `["duty.satisfied"]`. Anything else stops.
9. **`environment-claim.json`** (`$CLAIM`): `$JQ -S -c -n --slurpfile` over
   `control/v1/sandbox-policy.json`, `$DUTY`, `$POLICY_SET`, `$RESOLVED_PROFILE`,
   with exactly the self-host claim's fields: the eight policy sections verbatim
   (keeping the shipped all-ones verifier digest); `execution_identity` = role
   `verifier` plus the verifier binding's `adapter_instance_id`,
   `execution_boundary_id` and `principal_id` read from `$RESOLVED_PROFILE`;
   `declaration_status:"complete"`; `effects:{external_writes:false,
   target_writes:false}`; `policy_set_ref:{schema_version:1,
   kind:"control_policy_set", id:<set id>, sha256:<sha of $POLICY_SET>}`;
   `duty_evaluation_ref:{schema_version:1, kind:"duty_separation_evaluation",
   id:<duty id>, sha256:<sha of $DUTY>}`; `stage_result_ref` = `$DUTY`'s
   `body.stage.result_ref`; top-level `id:"env.local-macos-dummy-target"`. The README
   quotes the program.
10. **`verification-instructions.md`**: written by hand before either identity, in
    the self-host file's structure: the check (`file-digest` at `src/greet.sh`), both
    revisions with subjects, the expected digest, the two `git cat-file blob … |
    shasum -a 256` commands for any clone of `yihanzhu/ystack-dummy-target`, the three
    outcomes, and which reference serves which role. Frozen from here; any later
    edit changes both identities and forces a new capture.
11. **`{pre,post}/incident.json`**, then assembly, identity, validation, run and
    captures per case (next section).

## The two runs (requirements 11, 12)

For each case, `$CASE=$EVIDENCE/<case>`, with:

| | post | pre |
| --- | --- | --- |
| `$REV` | `e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e` | `413a2f02a46ababa987039be65089e95c1916765` |
| incident / identity id | `incident.dummy-target-greet.post` / `identity.dummy-target-greet.post` | `….pre` / `….pre` |
| `observed_symptom` | `Post-change src/greet.sh bytes differ from the recorded pre-change digest.` | `Control observation, not a second incident: pre-change src/greet.sh bytes match the recorded digest.` |
| outcome / reason | `reproduced` / `check.failed-at-revision`, observed `9a3eeced…` | `no-change` / `check.passed-at-revision`, observed `c5ddea82…` |

1. Incident: `$JQ -S -c -n` building `{schema_version:1,
   kind:"shadow_incident_record", id:<id>, body:{deploy_authority:"none",
   failing_check:{kind:"file-digest", path:"src/greet.sh",
   expected_sha256:"c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c"},
   git_revision_ref:{repository_id:"repo.ystack-dummy-target", hash_algorithm:"sha1",
   commit_id:$REV}, observed_at:<confirmed time>, observed_symptom:<above>,
   reporter_actor_ref:"actor.operator",
   target_repository_id:"repo.ystack-dummy-target"}}` into `$CASE/incident.json`.
   Validate: `PATH="$JQ_DIR:/usr/bin:/bin" shadow/v1/validate-incident.sh validate "$CASE/incident.json"`.
2. Assemble into a fresh `$OUT_DIR`, then copy all seven outputs to
   `$CASE/assembled/`:

   ```sh
   shadow/v1/assemble-materialization-input.sh assemble \
     repo.ystack-dummy-target "$SRC" "$REV" "$REQUESTED_AT" \
     "$REPO/profiles/default/v1" "$RESOLVED_PROFILE" "$JQ" "$OUT_DIR" "$CLAIM" "$REQUESTER"
   ```

   `$REQUESTED_AT` equals the incident's `observed_at`.
3. Identity: `$JQ -S -c -n` into `$CASE/qualified-identity.json`:
   `{schema_version:1, kind:"qualified_identity", id:<identity id>, body:{
   stage_request_ref:<$OUT_DIR/stage-request-ref.json>,
   resolved_profile_ref:<$OUT_DIR/resolved-profile-ref.json>,
   target_revision:<incident body.git_revision_ref>,
   model_request, prompt_refs:[prompt_ref], skill_refs` (all from the one
   `binding.role == "producer"` element of `$RESOLVED_PROFILE`),
   `adapter_config_refs:[{content_id:"producer-config",
   media_type:"application/vnd.ystack.adapter-config+json",
   sha256:<that binding's config_source.value.value_sha256>}],
   verification_instructions_ref:{content_id:"verification-instructions",
   media_type:"application/vnd.ystack.verification-instructions+json",
   sha256:<sha of verification-instructions.md>}}}`. The config digest must equal
   the SHA-256 of `$REPO/profiles/default/v1/producer-config.json`.
4. Run, with a scratch directory created empty immediately before:

   ```sh
   shadow/v1/reproduce.sh reproduce \
     "$CASE/incident.json" "$CLAIM" "$POLICY_SET" "$DUTY" \
     "$CASE/assembled/input.json" "$CASE/qualified-identity.json" \
     "$SRC" "$CANDIDATE" "$SCRATCH_D" "$STATE" "$CLOSURE" "$JQ"
   ```

   Expected outcome and reason as in the table; copy the four state files to
   `$CASE/state/`. `materialization-result.json` must be a completed `no-change`.
   An `inconclusive` or refused attempt is kept outside the bundle for diagnosis,
   listed in the README, and closes nothing.
5. Receipt: re-invoke the materializer with the driver's exact inputs
   (`"$CASE/assembled/input.json" repo.ystack-dummy-target "$SRC"`, fresh `$CAND_R`
   and `$SCRATCH_R`, `$CLOSURE`, `$JQ`), as in step 7 of the construction order.
   Require the self-host plan's three gates: receipt digest equals
   `payloads[0].sha256`; it equals both receipt references in
   `$CASE/state/materialization-result.json`; and the re-extracted `stage_result`
   is byte-identical to that file (`cmp`). Then copy the receipt to
   `$CASE/materialization-receipt.json`.
6. Sandbox evaluation:
   `PATH="$JQ_DIR:/usr/bin:/bin" control/v1/evaluate-sandbox.sh evaluate "$POLICY_SET" "$DUTY" "$CLAIM" > "$CASE/sandbox-evaluation.json"`.
   Its SHA-256 must equal the record's
   `body.environment.evaluation.value.evaluation_ref.sha256`; it must carry the
   declaration-only markers and `["sandbox.declaration-satisfied"]`.

Before retaining anything, recompute every reference field the self-host plan's
precondition gate lists against the bytes it names; a mismatch or repeated-character
placeholder stops the run.

## Repeatability (requirement 12)

Run each case's steps 2, 4, 5 and 6 a second time in fresh directories, with the
same `$SRC`, `$JQ`, `$CLOSURE`, `$REQUESTER`, `$CLAIM` and timestamps. Require:

```sh
diff -r "$OUT_DIR_1" "$OUT_DIR_2"
diff -r "$STATE_1" "$STATE_2"
cmp <first receipt> <second receipt>
cmp <first sandbox evaluation> <second sandbox evaluation>
```

all empty or equal, for both cases. Rebuild each identity from the second assembly
and `cmp` it with the first. Then record the source inventory digests again; both
must equal the first reading. This proves repeatability for these inputs on this
machine only; the README says so.

## Capture, recoverability, inventory (requirement 13)

- `shadow/evidence/external-dummy-target/v1/` holds exactly the 45 files of the
  table: 15 shared (including `prerequisite/`) and 15 in each of `pre/` and `post/`
  (4 documents, 7 under `assembled/`, 4 under `state/`). Copy the 42 producer and
  input files unchanged; write `README.md` and `checksums.json` last.
- `checksums.json`: `{schema_version:1, kind:"shadow_evidence_checksum_manifest",
  id:"shadow.external-dummy-target.v1.checksums", body:{files:[{path, sha256}]}}`,
  44 entries in `LC_ALL=C sort` path order, canonical `jq -S -c`.
- Recoverability: every digest in the bundle names a file in it or a Git object the
  README names. The README names, at `RUN_COMMIT`: the registry
  (`shadow/v1/shadow-environments.json`), the plan blob, the six manifests and
  profile, `control/v1/*` policies and decisions, the nine closure members, and
  `profiles/default/v1/producer-config.json`; and, in the dummy target, the root tree
  `1c173494…` and both `src/greet.sh` blobs.
- Never commit `$SRC`, `$REPO`, candidates, scratch, `$REQUEST`, `$MAP`, binaries,
  credentials or absolute paths. If a hashed document cannot be committed as emitted,
  stop; never redact or re-serialize.

The README follows the self-host README's sections (requirement 14) and adds:

- **Portability result.** No component generalisation was needed. Target-facing
  fields name `repo.ystack-dummy-target`; the control-plane fields name
  `repo.ystack` because they point at the ystack default profile, its packages and
  manifests, the producer prompt and this plan. It lists both sets as requirement 15
  does.
- **Requester provenance.** Executor, machine, account, session id and the delegation
  basis (the #375 rule extended by DR-6, with both #426 links). `requester.json`
  stays the operator identity.
- **Confirmations.** The operator's two confirmations, word for word, each with its
  comment URL or session reference.
- **Registry.** The frozen runtime's registry digest, with the note that the
  self-host bundle keeps the older registry digest `721e19bb…`, recoverable at its own
  frozen runtime commit.

## The shared harness (requirement 15)

`scripts/test/shadow-self-host-evidence.test.sh` becomes one harness over a bundle
table. It stays Bash-3.2-compatible (no associative arrays), because it runs on
macOS and Linux.

### Commit 1: refactor on the self-host bundle alone

- **The table.** A function `load_bundle <name>` sets plain `b_*` variables in one
  `case` arm per bundle. Fields: `b_rel` (evidence path), `b_plan`, `b_prefix` (pass
  message prefix), `b_summary`, `b_target_repo`, `b_control_repo`, `b_env_id`,
  `b_root_commit`, `b_incident_prefix`, `b_identity_prefix`, `b_check_path`,
  `b_expected_sha`, `b_post_observed_sha`, `b_pre_rev`, `b_post_rev`,
  `b_producer_config_pin`, `b_closure_sha`, `b_closure_nl_sha`, `b_requester_sha`,
  `b_run_commit`, `b_registry_sha`, `b_registry_entry_sha`, `b_checksums_id`,
  `b_scope_slug`, `b_harness`, `b_allowed_paths`. The self-host arm holds today's
  literals: `b_prefix=''`, `b_summary='shadow self-host evidence'`,
  `b_scope_slug=self-host-transition`, `b_harness=self-host-harness`,
  `b_allowed_paths='["docs/guides/setup.md","docs/notes-?.md"]'`, and the digests,
  revisions and commits now inline (`b913cf62…`, `5b3e0baf…`, `ea076206…`,
  `eff044bd…`, `06dbd5ec…`, `26206e64…`, `8b3e3f55…`, `721e19bb…`, `cc259fc1…`).
- **Parametrised functions.**
  - `require_bundle_present`: today's missing-file block, per bundle, naming
    `b_rel` and `b_plan`.
  - `check_evidence <dir> <label>`: unchanged steps, with every literal replaced by
    its `b_*` field: the outcomes step (path, expected and observed digests, both
    revisions), identity provenance (`b_producer_config_pin`), check 10's README grep
    and overclaim file list (`$root/$b_rel/README.md`,
    `$root/$b_rel/verification-instructions.md`, `RESTORE.md`,
    `docs/components.md`), check 11 (`b_closure_sha`, `b_closure_nl_sha`), check 12
    (`b_requester_sha`, `b_run_commit`).
  - `fresh_mutant_copy` and negative cases (a)-(c): unchanged, over `$root/$b_rel`.
  - `run_scope_harness`: today's harness, with the ids built from the table — shadow
    set `scope.evidence.$b_scope_slug.v1`, scope `scope.$b_scope_slug.v1`,
    `workflow.$b_scope_slug`, `task.$b_scope_slug`, every `*.self-host-harness` id as
    `*.$b_harness`, `target_repository_id:$b_target_repo`,
    `required_shadow_environments:[$b_env_id]`, `allowed_paths:$b_allowed_paths`.
    The dashboard fixture and `config/construction-mode.json` marker are shared.
  - `run_maintenance`: today's conversions and cross-pairings, generic.
- **Output.** `pass` prints `ok <global n> - $b_prefix<message>` and counts per
  bundle. Each bundle ends with `$b_summary: <n> focused checks passed`.
- **Proof of the refactor.** Before and after output of the test on the self-host
  bundle are identical: the same ten `ok` lines, byte for byte, and
  `shadow self-host evidence: 10 focused checks passed`. The PR shows both.

### Commit 2: new checks and the new bundle

New steps inside `check_evidence`, so they run for both bundles and the negative
copies:

- `bundle-ids`: incident ids are `$b_incident_prefix.{pre,post}`, identity ids
  `$b_identity_prefix.{pre,post}`, each record's `id` equals its incident's, the
  claim and prerequisite declaration ids and each record's
  `body.environment.environment_id` equal `b_env_id`, and `checksums.json`'s id is
  `b_checksums_id`.
- `registry-binding`: in the live registry exactly one entry has
  `environment_id == b_env_id`, and its `target_repository_id` and
  `source_root_commit` equal `b_target_repo` and `b_root_commit`. The bundle's own
  registry references equal the pinned `b_registry_sha`: each record's
  `body.environment.registry_ref.sha256` and every resolved profile's
  `repository_context_ref.decision_record_ref.sha256`; the declaration's
  `registry_entry_sha256` equals `b_registry_entry_sha`. The pins keep the check true
  after a later registry change.
- `repository-ids` (portability): a jq walker lists, for each retained `.json`
  except `checksums.json`, every path whose last key is `repository_id` or
  `target_repository_id`, normalised by writing array indexes as `[]` (for example
  `body.bindings[].binding.package_ref.revision.repository_id`). Two shared tables,
  `target_paths` and `control_paths`, hold requirement 15's lists as
  `file<TAB>path` lines, with `{case}` expanded to `pre` and `post` and `{input}` to
  `prerequisite/input.json`, `pre/assembled/input.json` and
  `post/assembled/input.json`. The check requires: the two expanded tables do not
  overlap and together hold 114 pairs; every walked pair is in one table; every
  table pair occurs at least once; every value on a target pair equals
  `b_target_repo` and on a control pair `b_control_repo`. For the self-host bundle
  both values are `repo.ystack`, so only coverage is tested there.

`target_paths` (requirement 15, target-facing):

- `{case}/incident.json`: `body.target_repository_id`,
  `body.git_revision_ref.repository_id`;
- `prerequisite/stage-request.json` under `body.`, and each `{input}` under
  `stage_request.content.body.`: `target_repository_id`,
  `target_revision.value.repository_id`, `base.value.repository_id`,
  `source.value.value.revision.repository_id`,
  `inputs[].value.value.value.revision.repository_id`,
  `repository_context_ref.subject_ref.value.value.revision.repository_id`;
- `resolved-profile.json` and `prerequisite/resolved-profile-document.json` under
  `body.`, and each `{input}` under `resolved_profile.content.body.`:
  `repository_context_ref.subject_ref.value.value.revision.repository_id`;
- `prerequisite/materialization-receipt.json`, `{case}/materialization-receipt.json`:
  `source.repository_id`;
- `{case}/qualified-identity.json`: `body.target_revision.repository_id`;
- `{case}/state/shadow-record.json`: `body.target_repository_id`,
  `body.git_revision_ref.repository_id`,
  `body.materialization.value.source.repository_id`,
  `body.qualified_identity.target_revision.repository_id`.

`control_paths` (requirement 15, control-plane):

- `resolved-profile.json` and `prerequisite/resolved-profile-document.json` under
  `body.`, and each `{input}` under `resolved_profile.content.body.`:
  `profile_source.source.revision.repository_id`,
  `selection_ref.subject_ref.value.value.revision.repository_id`,
  `bindings[].binding.{package_ref,config_ref,prompt_ref}.revision.repository_id`,
  `bindings[].package_source.source.revision.repository_id`,
  `bindings[].manifest_source.source.revision.repository_id`,
  `bindings[].config_source.value.source.revision.repository_id`,
  `bindings[].prompt_source.value.source.revision.repository_id`;
- each `{input}`:
  `profile.content.body.bindings[].{package_ref,config_ref,prompt_ref}.revision.repository_id`,
  `manifests[].content.body.package_ref.revision.repository_id`,
  `stage_request.content.body.selection_ref.subject_ref.value.value.revision.repository_id`;
- `prerequisite/stage-request.json`:
  `body.selection_ref.subject_ref.value.value.revision.repository_id`;
- `{case}/qualified-identity.json`: `body.prompt_refs[].revision.repository_id`;
  `{case}/state/shadow-record.json`:
  `body.qualified_identity.prompt_refs[].revision.repository_id`;
- `prerequisite/stage-result.json`, `{case}/state/materialization-result.json`:
  `body.execution.actual_binding.package_ref.revision.repository_id`.

The `{a,b,c}` braces are written out as separate lines in the table.

**New negative cases**, run for each bundle after its existing ten checks, so the
self-host lines 1-10 stay first and unchanged. Each starts from a fresh copy that is
`diff -r`-identical to a tree that has just passed `check_evidence`; the three
existing cases keep their full-check baseline. `refresh_checksums <dir>` rebuilds
`checksums.json` in the retained schema, so a case reaches the check it targets.
Each must make `check_evidence` fail; the test requires refusal, not a particular
message:

- (d) one file removed (`post/materialization-receipt.json`);
- (e) one changed byte, in each of the 45 files in turn (the 44 inventoried and
  `checksums.json` itself), restored after each; one pass line per bundle;
- (f) a JSON document re-serialized (`jq .` of `pre/qualified-identity.json`),
  checksums refreshed;
- (g) `pre/state/shadow-record.json` and `post/state/shadow-record.json` swapped,
  checksums refreshed;
- (h) only where `b_target_repo != b_control_repo`: `post/qualified-identity.json`
  with `body.target_revision.repository_id` set to `repo.ystack`, checksums refreshed;
- (i) only where they differ: `post/incident.json` with `body.target_repository_id`
  and `body.git_revision_ref.repository_id` set to `repo.ystack`, checksums
  refreshed.

The existing case (b) is the checksum-mismatch case.

**The new bundle's arm**: `b_rel=shadow/evidence/external-dummy-target/v1`,
`b_plan=work/external-target-shadow-run/plan.md`,
`b_prefix='external-dummy-target: '`,
`b_summary='shadow external-dummy-target evidence'`,
`b_target_repo=repo.ystack-dummy-target`, `b_control_repo=repo.ystack`,
`b_env_id=env.local-macos-dummy-target`, `b_root_commit=c1cacf5a…`,
`b_incident_prefix=incident.dummy-target-greet`,
`b_identity_prefix=identity.dummy-target-greet`, `b_check_path=src/greet.sh`,
`b_expected_sha=c5ddea82…`, `b_post_observed_sha=9a3eeced…`, `b_pre_rev=413a2f02…`,
`b_post_rev=e7da8f7b…`, `b_checksums_id=shadow.external-dummy-target.v1.checksums`,
`b_scope_slug=external-dummy-target`, `b_harness=external-dummy-target-harness`,
`b_allowed_paths='["src/greet.sh","test/greet.test.sh"]'`, and the captured values
of `b_run_commit`, `b_requester_sha`, `b_producer_config_pin`, `b_closure_sha`,
`b_closure_nl_sha`, `b_registry_sha` and `b_registry_entry_sha`, each equal to the
README's value (all full 64-hex or 40-hex literals in the file).

**Consumers for the new bundle** (requirement 15): the scope harness with scope
`repo.ystack-dummy-target` requiring `env.local-macos-dummy-target` must accept both
records and report `not-proposable`, `["scope.eval-failing"]`, qualification
`unavailable`/`scope.enablement-requires-operator-pr`, no authority; the maintenance
converter must give `stale-moved-artifacts`, post `{accepted, stale}`, pre
`{accepted, completed}`, qualification `maintenance.no-adapter-exists`, and refuse
both cross-pairings.

**Final output**: the self-host block (its original ten lines, then its new lines
and its summary line), the new bundle's block and summary, then one total line. A
separate sibling test file is not allowed.

## Documentation and manifest

Written after capture, to pass check 10's overclaim scan (never patch the test to
fit the prose):

- `docs/components.md`: what the pair is, the two tuples, that the evaluation is
  declaration-only and enforcement stays `unproven`
  (`work/real-sandbox-boundary/spec.md`), that `env.local-macos-dummy-target` stays
  `unproven`, the portability result in two sentences, the consumer results in the
  evaluators' own words, and the test command.
- `README.md` row: `| First external-target shadow evidence | \`shadow/evidence/external-dummy-target/v1/\` | The first real read-only shadow run pair on an external target (\`yihanzhu/ystack-dummy-target\`, one file-digest incident, reproduced/no-change), with a declaration-only sandbox evaluation and no real execution boundary. | [read](docs/components.md#first-external-target-shadow-evidence) |`.
- `RESTORE.md`: restore the listed paths with the harness and the components it
  checks against, run `bash scripts/test/shadow-self-host-evidence.test.sh`; it
  performs no reproduction, credential use or model call and changes no
  `proof_state`.
- `ci/required-files.txt` and the schema allowlist as under "Files that change".

## Operator steps and delegation (requirement 16)

The evidence session runs natively on the operator's macOS machine, under the
operator's account. The operator may run it by hand, or delegate it to the manager
session on that machine. The basis is the #375 rule in
`work/shadow-self-host-run/plan.md` ("Operator steps"): delegation only to the
manager session running on that machine, "never to CI, never to a remote or cloud
session, and never to a coder subagent". That rule excluded external-target
execution. DR-6 on #426 extends it to this intake only; its approved text is: "a
read-only reproduction against a disposable scrubbed bare copy of
`yihanzhu/ystack-dummy-target` on your Mac, run by the manager session under the #375
delegation rule". If the operator reads DR-6 as not covering delegation, the
operator runs the session by hand.

The delegation grants nothing else: no credential, network inside the boundary,
model call, target or forge write, installation, activation or deployment. The
operator or manager hands back the evidence files; they are committed unchanged.

Two confirmations must come from the operator, in chat or on #426, and the README
quotes each word for word with its reference: (a) the registry entry, after PR 1
merges and before source preparation; (b) the frozen inputs of requirement 5 with the
`observed_at` time, before assembly. A manager note, audit read or silence supplies
neither.

## Risks

**The target never touched is the point, and the easiest thing to break.** The
operator's clone has an HTTPS remote. A bare clone keeps `remote.origin.*` until it
is removed, and ambient Git config can rewrite a local path into a network URL. The
`GIT_ISO` prefix, remote removal and config rewrite are the defence, and the driver
refuses a source config with extra keys. Nothing writes to the operator's clone;
the before/after inventory proves the copy was untouched.

**A silent fallback on the resolver.** Naming the dummy tree in
`repository_context_ref` is the only part of this run that tests the resolver's side
of portability. If the resolver refuses `$SRC` as a map root, the tempting fix is to
name ystack's tree instead, which passes and proves nothing. That is a stop under
requirement 7, and review should check the retained resolved profile names
`1c173494…` in `repo.ystack-dummy-target`.

**Mixing the two repository ids.** The same bundle must name two repositories, each
in the right place. The portability walker checks every occurrence both ways, and
the new negative cases (h) and (i) prove it catches a target that names ystack. The
alternative I rejected was checking only the target-facing list: an unknown new
field would then pass unclassified.

**The harness refactor weakening the self-host proof.** This is the riskiest code
step. Commit 1 changes structure only, and the proof is byte-identical output on the
self-host bundle before and after. The alternative, a sibling copy of the test, is
forbidden by the spec and would let the two copies drift. Portable Bash 3.2 is kept
because the harness runs on the operator's Mac too.

**Runtime.** The harness now runs two bundles and more negative cases; expect about
three minutes. The new cases use `diff -r` baselines rather than a full check each,
and a changed byte fails at the inventory step, so the 44-file loop is cheap.

**The generation-id allowlist.** The three evidence files that must carry the
corrective v2 generation id need the three allowlist lines; any other file that
carries it (for example a README that prints the full id) fails
`portable-core-schema.test.sh`. The README uses the `g-c83c940a` prefix only.

**Registry drift.** A later registry edit (for example a `proof_state` change) must
not break either bundle. The harness pins each bundle's registry and entry digests
instead of hashing the live file; it reads the live file only for the entry's target
id and root commit.

**Overclaiming.** As the self-host plan: the sandbox evaluation is
declaration-only, the all-ones verifier digest is the shipped demonstration value,
and no document may call the run enforced, qualified or proposable. Check 10 scans
the new README, instructions, docs and RESTORE.

**A refusal mid-session.** Any component refusal, a digest mismatch, a moved
revision, or a runtime change stops the session. A runtime change also changes the
requester bytes and needs a fresh capture. None of these is fixed by a local patch,
an edited expectation or a hand-written document.

**History rewrite on the forge.** The dummy target is public and small; its history
could change later. The evidence binds object ids and raw bytes and the offline test
never needs the forge.

## Proof

**PR 1** (registry): the commands under "PR 1", their output in the PR body, and CI
green with independent review on the final head.

**PR 2** (evidence), bound to the final head in the PR body:

1. `bash scripts/test/shadow-self-host-evidence.test.sh`, full output: both bundles'
   blocks, including the self-host ten original lines unchanged, and the total line.
2. The same test's output at the harness-refactor commit and on main, showing the
   self-host lines byte-identical.
3. `bash scripts/test/portable-core-schema.test.sh` and CI shard logs showing the
   whole `scripts/test/run-all.sh` suite green, including `shadow-slice.test.sh` and
   `shadow-assembler.test.sh`.
4. The session transcript: `RUN_COMMIT`, the precondition checks, the provisioning
   line, the resolver, assembler (prerequisite and both cases), materializer (three
   captures), duty, sandbox, incident-validation and both `reproduce.sh` command lines
   with outcomes and reason ids, and the receipt gates.
5. The repeatability comparisons and the before/after source inventory digests.
6. `git show <head>:shadow/evidence/external-dummy-target/v1/checksums.json` beside
   a fresh `shasum -a 256` walk of the directory.
7. Independent non-author review and operator merge.

The records keep `authority: none`, `deploy_authority: none`, `shadow: true`,
`activation_state: inactive` and unavailable qualification as emitted. Nothing here
changes a `proof_state`, grants a write, or closes Roadmap step 7.
