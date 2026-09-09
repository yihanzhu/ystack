---
intent-blob: a606f5f2f67d247d4d7827684322e15ae10b4dc9
risk: high
drafted: 2026-09-09
---

# Spec: shadow-env-self-host

The shadow driver refuses any execution environment not listed in
`shadow/v1/shadow-environments.json`. That file lists one environment today and it is
fixture-only, so no self-host run is permitted at all. This change lists one more —
the operator's own macOS checkout against ystack's own scrubbed bare source
repository — and, because an entry today authorizes an environment id against *any*
repository, binds every entry to the repository it is for: by the document id the
incident carries, and by the root commit of the source repository the driver reads for
itself. The test and docs that count the entries become true again. No run happens
here.

## Requirements

**R1.** Registry schema: every entry carries exactly six keys — `description`,
`environment_id`, `evidence_scope`, `proof_state`, `source_root_commit`,
`target_repository_id` — and no others. `target_repository_id` is a string matching
`\A[a-z0-9][a-z0-9._:-]{0,127}\z`, the id charset `environment_id` already uses; it is
the document id the incident declares. `source_root_commit` is a string matching
`\A[0-9a-f]{40}\z`: the sha1 of the root commit of the source repository this entry
authorizes — the one commit in that history with no parent, which is the repository's
history identity and which the driver computes itself from the bytes it reads.
The existing `env.local-macos-fixture` entry gains `target_repository_id`
`fixture.target` (the repository id every fixture incident in the shadow test already
carries) and `source_root_commit` `866a40ce4a7fb6198fd489a0326f0cd1c2e2d791`, the root
commit of the fixture bare repository that test builds (R10 shows why that sha is
fixed and pins it). Its other four values are unchanged.

**R2.** The registry gains exactly one new entry, appended *after* the fixture entry
(order: fixture first, new one second): `environment_id`
`env.local-macos-ystack-self`; `description` `Operator's local macOS checkout,
ystack's own scrubbed bare source repository.`; `evidence_scope` `self-host`;
`proof_state` `unproven`; `target_repository_id` `repo.ystack`, the id this repo
already uses for its own repository across `profiles/` and `packaging/v1/`;
`source_root_commit` `7908b159c0a2d24ce6ccdde6ee0f501acc483e75`, ystack's own root
commit, read off the clone with `git rev-list --max-parents=0 origin/main` — exactly
one root, checked while drafting.

**R3.** `.body.activation_state` stays `inactive`, `.body.registry_version` stays
`v1`, and `.id` (`shadow.environments.v1`), `.kind` (`shadow_environment_registry`)
and `.schema_version` (`1`) are unchanged.

**R4.** The file stays exactly one canonical JSON text: `cmp` of the file against
`jq -S -c . <file>` succeeds. On main it is a single line whose last byte is `0a`
(verified) and that `cmp` passes; preserve both. `jq -S -c` emits the trailing newline
itself, so writing its output is enough — and for the same reason R10's `cmp` of a
`jq -S -c`-built expectation is exact. `reproduce.sh`'s `canonical_json` and the test's
`registry-canonical` check depend on this byte-exactly.

**R5.** Driver edit one, the shape check. The `E_RELATION` jq at
`shadow/v1/reproduce.sh:182-188` today requires `schema_version == 1`, the kind,
`activation_state == "inactive"`, and an `environments` array of length 1–64 whose
every `environment_id` is a string matching the id charset. It additionally requires,
of every entry, a `target_repository_id` string matching that same charset and a
`source_root_commit` string matching `\A[0-9a-f]{40}\z`, so a registry that omits
either binding is refused with `E_RELATION` instead of silently authorizing more than
it names.

**R6.** Driver edit two, the per-run lookup. The lookup at
`shadow/v1/reproduce.sh:267-268` is today `[.body.environments[] |
select(.environment_id == $id)] | length == 1`, where `$id` comes from the
caller-supplied claim. It selects on **both** `environment_id == $id` **and**
`target_repository_id ==` this incident's `.body.target_repository_id` — a value the
driver already parses into `repository_id` at `shadow/v1/reproduce.sh:191`; pass it as
a second `--arg`. Exactly one entry must match, as today.

**R7.** Driver edit three, and the substance of this revision: the driver verifies the
source repository itself. R6's two values are both caller-supplied text, so the entry
must also be checked against something the driver computes from the bytes of the
repository the run will read. After the R6 lookup matches exactly one entry and
**before** the sandbox evaluation at `shadow/v1/reproduce.sh:270-273`:
- read that entry's `source_root_commit` out of the registry snapshot with the same two
  `--arg` values, into a shell variable;
- run, read-only, `git --no-replace-objects --git-dir="$source_git_dir" rev-list
  --max-parents=0 "$commit_id"`, where `$commit_id` is the incident revision the driver
  already parsed at `shadow/v1/reproduce.sh:195`; capture stdout bounded through
  `/usr/bin/head -c 4096`, discard stderr;
- require the captured text to equal the entry's `source_root_commit` exactly. A
  different root, more than one root line, an incident commit absent from that
  repository, an unreadable directory, or any git failure all leave the run on the
  **existing** `environment.unlisted` branch (R8). The comparison is on captured text,
  so a nonzero git exit fails closed on its own: `reproduce.sh` runs under
  `set -uo pipefail` with no `-e`.

Run it with the protective environment `reproduce.sh` already uses for git
(`shadow/v1/reproduce.sh:338-341`: `env -i`, `HOME`/`TMPDIR` in the driver's scratch,
`PATH=/usr/bin:/bin`, `LC_ALL=C`, `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_NO_REPLACE_OBJECTS=1`, `GIT_NO_LAZY_FETCH=1`,
`GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`) plus one addition: `GIT_GRAFT_FILE`
pointing at a path inside that scratch which does not exist. Without it a source
repository carrying `info/grafts` rewrites the parent links git reports and the root
becomes whatever that file says — checked while drafting: with a graft the same commit
reports root `52022bc4…`, with `GIT_GRAFT_FILE` at a missing path it reports its true
`866a40ce…`. Hoist the existing `git_env=(…)` definition above the environment
decision, add `GIT_GRAFT_FILE` to it, and let both the new check and the existing
candidate-blob reads at `shadow/v1/reproduce.sh:344-361` use the one definition so they
cannot drift. Keep the new check inside the R6 `if`, so a run whose environment was
never listed still touches no git object, as today.

**R8.** No new outcome vocabulary. An entry bound to another repository, or a source
repository whose root is not the entry's, does not authorize the run, so it falls
through to the **existing** `environment.unlisted` branch already initialized at
`shadow/v1/reproduce.sh:258-264`: `outcome: inconclusive`, `reason_id:
environment.unlisted`, and the environment, materialization and check sections all
`absent`. No new reason id, no new record field, no change to the record shape, no new
error code.

**R9.** Consumers untouched, and proven so. Because R8 adds no reason id and no record
field, the reason/state table copied out of the driver into `scope/v1/scope-gates.jq`
(`slice_states`, ~lines 536-558, first row `environment.unlisted` → `inconclusive`
with every section `absent`) needs no change. Do not edit it; the only drift is the
indicative line range in the comment above it, left as is. Re-run `bash
scripts/test/scope-qualification.test.sh` and require 0 failures as the proof.

**R10.** `scripts/test/shadow-slice.test.sh` (the `registry-contents` block, near lines
322-328) pins the *complete* registry document, not a subset of its fields: build the
whole expected registry with `"$jq_bin" -S -c` (the way that file already builds
canonical fixtures) and `cmp` it byte for byte against the committed
`shadow/v1/shadow-environments.json`, failing `registry-contents` on any difference.
The expectation spells out both entries in order (`env.local-macos-fixture` then
`env.local-macos-ystack-self`), each with all six keys and no others, plus the five
header fields. This *replaces* the partial id/scope/proof-state assertion, under which
a wrong `description`, a missing or wrong binding, or an extra key would still have
passed — unacceptable for an authorization file. Build the fixture entry's
`source_root_commit` from the fixture repository rather than typing the sha twice:
`fixture_root=$(git_clean --git-dir="$tmp/source.git" rev-list --max-parents=0
"$failing_commit")`, passed as an `--arg`, so the pin proves both that the committed
sha is that repository's real root and that the builder is deterministic here. It is
deterministic, and needs no change: `git_clean` (lines 69-77) fixes author and
committer name, email and date (`2000-01-01T00:00:00Z`), and the root is
`failing_commit` (lines 89-90), a `commit-tree` with no parent over trees built from
literal bytes (lines 81-88). Rebuilt from those lines while drafting:
`866a40ce4a7fb6198fd489a0326f0cd1c2e2d791`, also the root of `passing_commit`, so both
fixture incidents pin to the same root. The block's `pass` message stops saying
"exactly the one … fixture environment" and states something true of two entries:
neither proven, each bound to one repository by id and by root commit.

**R11.** One new negative case for the id binding, beside the existing
`unlisted-environment` case (near lines 436-443): the fixture incident
(`target_repository_id` `fixture.target`) run with a claim whose `.id` is mutated to
`env.local-macos-ystack-self` — a *listed* id, bound to `repo.ystack` — yields
`outcome: inconclusive`, `reason_id: environment.unlisted`, environment evaluation
`{state:"absent", reason_id:"environment.unlisted"}`, and materialization and check
execution `absent`. Use the existing `mutate` and `expect_outcome` helpers; add no new
helper.

**R12.** One new negative case for the source binding: the unmutated fixture claim and
the fixture incident — so *both* R6 values match the fixture entry — run against a
second bare repository whose history is not the fixture's, giving the same
`environment.unlisted` result and the same three absent sections. Build that repository
beside the existing one with `git_clean`, deterministically: `init -q --bare
--object-format=sha1`, then one root commit (`commit-tree` over the empty tree, no
parent). `run_case` already takes the source directory as its fifth argument (line
333), so no new helper is needed. This case fails before R7 and passes after: today the
run reaches the sandbox evaluator and materializes against whatever repository it was
handed.

**R13.** The `missing-revision` case (lines 476-480) changes, and must be retargeted,
not deleted. It runs the fixture incident against an empty bare repository and today
expects `materialization.refused`; under R7 the driver refuses one step earlier
(`environment.unlisted`), since a repository without the incident commit has no root to
report for it — that path is now R12's. `materialization.refused` is covered nowhere
else in the suite, so keep it covered: point the case at a `/bin/cp -R` copy of the
fixture repository with `core.bare` set to `false` — an *allowed* key in the
materializer's config allow-list
(`adapters/local-git-materializer/v1/materialize.sh:319`), so the copy passes R7's root
check (checked while drafting: `rev-list` still reports `866a40ce…`) and is refused by
the bare-repository guard (`materialize.sh:324-325`, `E_SOURCE_WORKTREE`), giving
`inconclusive` / `materialization.refused` exactly as before. Rename the case and its
`pass` message to what it now proves; drop the now-unused empty repository. Every other
case keeps its current outcome: they all pass `$tmp/source.git`, whose root matches the
pinned entry, and the read-only, identity and staleness guards all run before the
environment decision. Any *other* changed outcome means the change is wrong.

**R14.** Nothing a run touches is written: the existing never-written checks must pass
unchanged — the registry re-digest (same test, near lines 604-610) and the source
repository fingerprint (near lines 100-102 and 601), which now covers a driver that
reads the source repository directly. Do not edit either; if `rev-list` left anything
behind in `source.git`, that check is what says so.

**R15.** Nothing else under `shadow/v1/` changes — not the `.jq` programs, not
`validate-incident.sh` — and no adapter changes: `materialize.sh` is cited, never
edited. `ci/required-files.txt` is unchanged: the registry path is already listed and
no new file is added.

**R16.** The doc passages that count the entries, plus the two describing what the
driver enforces, are updated, with no other prose change. Confirm each by grepping
`shadow-environments`; line numbers are indicative.
- `docs/components.md` ~1194 — "starts with exactly one entry" becomes two, named with
  scope and proof state, and states both bindings: an entry authorizes an environment
  for one target repository id *and* one source repository, named by its root commit.
- `docs/components.md` ~1203 — "the claim's document id is listed in the environment
  file" becomes listed, bound to this incident's target repository id, *and* run
  against a source repository whose root commit is the entry's, matching R6 and R7.
- `docs/components.md` ~1247 — the fixture-proof-only paragraph must not read as if no
  self-host environment is listed: it is listed and unproven, its proof a later step.
- `docs/transition.md` ~65 — "lists exactly one execution environment" becomes two,
  both `unproven`, so "nothing has ever run against a real target" stays true.
- `docs/transition.md` ~183 — the "added by its own reviewed PR" sentence notes the
  self-host environment is now listed and the external-target one is not.
- `docs/transition-kit.md` ~247 — "must first be listed" becomes "is now listed", the
  run itself still gated.

**R17.** Proof: shellcheck 0.11.0 `-x -S style` clean on both edited shell files
(`shadow/v1/reproduce.sh`, `scripts/test/shadow-slice.test.sh`), `bash
scripts/test/shadow-slice.test.sh` all-pass, `bash
scripts/test/scope-qualification.test.sh` 0 failures, `bash
scripts/test/portable-core-schema.test.sh` 0 failures, `bash scripts/check-rename.sh`
clean, required CI green.

**R18.** Size: about 150 changed lines across the same six files
(`shadow/v1/shadow-environments.json`, `shadow/v1/reproduce.sh`,
`scripts/test/shadow-slice.test.sh`, `docs/components.md`, `docs/transition.md`,
`docs/transition-kit.md`). `review_size: standard`; no exception claimed.

## Design

In this order, because each step is checkable by the one after it.

1. **Registry.** Rewrite canonically in one step instead of hand-editing the line:
   `jq -S -c --arg d "Operator's local macOS checkout, ystack's own scrubbed bare
   source repository." '.body.environments[0].target_repository_id = "fixture.target"
   | .body.environments[0].source_root_commit =
   "866a40ce4a7fb6198fd489a0326f0cd1c2e2d791" | .body.environments += [{environment_id:
   "env.local-macos-ystack-self", description:$d, evidence_scope:"self-host",
   proof_state:"unproven", target_repository_id:"repo.ystack", source_root_commit:
   "7908b159c0a2d24ce6ccdde6ee0f501acc483e75"}]'` over the current file, to a temp
   file, then move it into place. `-S` sorts object keys while arrays keep their order
   (so the new entry lands second), and `-c` plus jq's trailing newline reproduce
   today's byte shape. Verify with R4's `cmp` before committing.
2. **Driver, three small edits, nothing else.** Extend the `E_RELATION` shape jq
   (`shadow/v1/reproduce.sh:182-188`) with R5's two string checks. Hoist the
   `git_env=(…)` array (today at `shadow/v1/reproduce.sh:338-341`) to just above the
   environment decision and add `GIT_GRAFT_FILE="$scratch/no-grafts"` — `$scratch` is
   the driver's own mktemp directory (lines 120-122) and nothing creates that path.
   Then replace the single `if` at `shadow/v1/reproduce.sh:267-269` with a gate that
   leaves the sandbox block below it untouched and unindented:

   ```
   environment_listed=no
   if <R6 lookup>; then
     entry_root=$(<jq read of the matched entry's source_root_commit>)
     observed_root=$("${git_env[@]}" /usr/bin/git --no-replace-objects \
       --git-dir="$source_git_dir" rev-list --max-parents=0 "$commit_id" 2>/dev/null |
       /usr/bin/head -c 4096)
     if [ -n "$entry_root" ] && [ "$observed_root" = "$entry_root" ]; then
       environment_listed=yes
     fi
   fi
   if [ "$environment_listed" = yes ]; then
     … existing sandbox evaluation, unchanged …
   ```

   The `-n` guard is belt and braces: R5 already makes `source_root_commit` 40 hex on
   every entry. The `head -c` bound keeps a repository with very many roots out of a
   shell variable; a truncated list is unequal anyway. The driver touches
   `$source_git_dir` before this point only for path checks (`physical_dir` line 83,
   `check_disjoint` lines 87-89) — no git command, no object read — so this is its
   first read of the source repository, and it happens before anything is evaluated,
   materialized or executed.
3. **Test.** Turn `registry-contents` into a full-document byte comparison with the
   fixture root computed from the fixture repository (R10), update its pass message,
   add the two negative cases (R11, R12), and retarget `missing-revision` (R13). The
   pin must fail before step 1 and pass after; R11's case must fail before the lookup
   edit and R12's before the source check, and both pass after. That ordering shows
   each edit does what it claims.
4. **Docs.** The six passages, nothing else.

**High-risk path, before any of the above.** Draft `work/shadow-env-self-host/plan.md`
on `ystack/plan/shadow-env-self-host` as a plan-only PR (`Tracks #263`), get
independent review and green CI, and let the operator merge it; record the merged
default OID as `plan-base`. Only then create `ystack/impl/shadow-env-self-host` from
updated main and write code there. That PR is the one using `Closes #263`.

## Out of scope

- Any shadow run. Listing an environment only permits one.
- Any driver change beyond the three edits in R5, R6 and R7: no new reason id, no new
  record field, no registry field beyond `source_root_commit`, no reordering of the
  driver's stages, no change to the read-only guards or the error codes.
- Proving *provenance* of the source repository — that it is a clone of the ystack
  remote rather than a repository built on top of ystack's root commit. See Areas of
  concern: no check the driver can make on a local bare directory establishes that, and
  the run stays read-only and inconclusive either way. Carried forward with the
  self-host-run initiative, where the operator supplies the path.
- A validator or enumerated values for `evidence_scope` / `proof_state`. None exists
  today; adding one changes the registry's contract and every consumer, so it is a
  second concern with its own risk decision. Carried forward as its own initiative.
- A Linux self-host environment. `reproduce.sh` pins jq only for `Darwin:*` and
  `Linux:x86_64` and the operator has no Linux runner, so a listed Linux environment
  could not be exercised. Carried forward.
- Deciding what proves an environment. `proof_state` leaves `unproven` only by a later
  reviewed change to this file citing recorded run evidence; that belongs to the
  self-host-run initiative.
- Any other environment including the external-target one; `activation_state`,
  real-target use, credentials, and every other gate.

## Areas of concern

- **The registry alone was an id allowlist, and that was the first P1.** The lookup at
  `shadow/v1/reproduce.sh:267-268` matched on `environment_id` only, and that id comes
  from the caller-supplied claim, so listing `env.local-macos-ystack-self` as data
  alone would have let any caller name that id and run the driver against *any* bare
  source repository handed to it. A registry-only edit cannot close that: the driver
  has to compare the entry against something the caller does not choose freely.
- **Binding to the incident's repository id was not that something — the second P1.**
  `.body.target_repository_id` is text in a caller-supplied document: `reproduce.sh`
  reads it at line 191 and passes it to the materializer at line 303, so a caller can
  write `repo.ystack` in the incident while pointing `source_git_dir` at an unrelated
  bare repository. Two caller-written fields agreeing with each other prove nothing.
  The id binding is kept because it ties an entry to the documents a run is about; the
  root commit is what ties it to the repository the run actually reads.
- **Why the root commit is a verified identity.** The driver computes it with git from
  the object bytes in the directory it was handed, starting from the incident's own
  commit — not from any field a caller wrote. Commit ids are content-addressed, so a
  repository cannot present the incident's commit id without holding that exact object
  with that exact history, and cannot report ystack's root without holding ystack's
  root commit object with the incident commit descended from it. That is why R7 runs
  before the sandbox evaluation: it decides whether this run is the one the entry
  authorizes at all.
- **What the root commit does not prove, stated plainly.** It proves the incident's
  commit descends from ystack's root; it does not prove the directory is a clone of the
  ystack remote. ystack is public, so someone could build a repository holding its real
  root commit and hang a fabricated commit off it, and that repository would pass R7.
  The limit is accepted here because it is strictly narrower than today (an unrelated
  repository — the actual P1 — is now refused), because nothing available to the driver
  on a local bare directory does better (every ref, config value and object outside the
  content-addressed chain is equally caller-supplied), and because the run this
  authorizes is read-only, network-denied and non-authoritative: one revision
  materialized, one blob digested, an inconclusive-by-default record. Anything stronger
  belongs to the run initiative, where the operator names the path.
- **Grafts, and why `GIT_GRAFT_FILE` is in R7.** `info/grafts` rewrites the parent
  links git reports, so without neutralizing it the root a source repository reports is
  a value that repository chooses. Reproduced while drafting: the same commit reports
  `52022bc4…` with a graft in place and `866a40ce…` with `GIT_GRAFT_FILE` set to a path
  that does not exist. Replace refs are already neutralized by `--no-replace-objects`
  and `GIT_NO_REPLACE_OBJECTS=1` in the driver's `git_env`. The materializer separately
  refuses a source repository with grafts, alternates, replace refs, a `shallow` file or
  promisor packs (`materialize.sh:326-332`), so such a repository could never have
  produced a materialization — but it could have passed the environment gate on a
  fabricated basis, and a gate should not be satisfiable by the thing it gates.
- **One existing fixture case changes, and it is accounted for.** Every fixture
  incident already carries `target_repository_id: "fixture.target"` and every case but
  `missing-revision` already passes `$tmp/source.git`, whose root is the pinned
  `866a40ce…`. R13 says what happens to that one and how `materialization.refused`
  stays covered.
- **A pinned sha in an authorization file can go stale.** R10 answers that for the
  fixture entry: the test computes the root and byte-compares the whole registry, so
  the pin cannot drift from the builder without a red test. The self-host sha cannot
  drift at all — a root commit is fixed for the life of a history, and were ystack's
  ever rewritten the entry would stop matching and self-host runs would go
  `environment.unlisted`: refusing, not running.
- **High risk, and not because of size.** The registry is an authorization list:
  `reproduce.sh` refuses to run in an unlisted environment, so this file is the control
  deciding where the driver may execute — and this change edits that driver's
  enforcement and adds the first git command it runs against a caller-supplied
  directory. `work/README.md` classes security controls as high risk, so widening that
  list is high risk however small the diff — hence the plan-only PR, independent
  review, and operator merge. Do not re-argue it as routine on size grounds. What it
  widens: a read-only shadow run against ystack's own source, the intended step-7
  unblock, but a real widening of the driver's allowed execution surface and the first
  entry that is not fixture-only. The two bindings hold that widening to the documents
  the entry names and to a repository carrying ystack's own history.
- **Truthfulness rail (AGENTS.md).** Nothing may claim proof it does not have.
  `proof_state: unproven` and the doc edits exist for that: after the change no file may
  imply this environment has been exercised.
- **Construction mode is retired.** PR #261 set `config/construction-mode.json` to
  `status: retired`, and the `AGENTS.md` construction overlay applies only while that
  record says `active` — so it does not apply here, and the normal rules govern this
  initiative in full: the intake record, G1, this G2 spec with its accepted risk, the
  high-risk plan-only PR, and operator merge. The registry stays
  `activation_state: inactive`, and this change authorizes no real target, credential, or
  production action.
- **Constitution paths.** Nothing here touches `.github/**`, `.claude/**`, `AGENTS.md`,
  `CLAUDE.md`, `REVIEW.md`, or `ROADMAP.md`. If the work seems to need one, stop — that
  is a different initiative.
- **Prose counting a data file drifts.** The test pin is the durable check; the doc
  passages move in the same PR so nothing is left saying "one environment" or
  describing the gate as an id lookup.
