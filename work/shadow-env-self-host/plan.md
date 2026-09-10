---
spec-blob: bb4993f44fd0d56e84d54dab33c5758bfa12bce7
drafted: 2026-09-10
---

# Plan: shadow-env-self-host

The spec (`work/shadow-env-self-host/spec.md`, blob above) is the contract and states every
requirement in full. This plan says what changes, in what order, where in today's files, what
can break, and how each requirement group is proved. Where a step names a requirement id, that
requirement's own wording is the detail to follow.

## Files that change

Six files, nothing else. Counts are net changed lines, honest estimates.

- **`shadow/v1/shadow-environments.json`** (~2). One canonical JSON line out, one in; written by
  step 1's jq transform, never hand-edited.
- **`shadow/v1/reproduce.sh`** (~120). Clean entry, shebang plus two copied blocks (~20); two
  string checks in the `E_RELATION` shape jq (~4); `git_env` hoist and its new pins (~8);
  `source_pure` with the two verbatim spans, copy header and name bindings (~75); the root-commit
  check with status capture (~15).
- **`scripts/test/shadow-slice.test.sh`** (~150). Full-registry byte pin replacing today's
  partial assertion (~25); `config_guard_ok` and its two calls (~35); seven new cases (~80); the
  `missing-revision` retarget (~10).
- **`docs/components.md`** (~14). Three edited passages plus one added passage.
- **`docs/transition.md`** (~6). Two edited passages.
- **`docs/transition-kit.md`** (~2). One edited passage.

**`ci/required-files.txt` does not change**: no file is added or removed and the registry path is
already listed (R19). **`scope/v1/**` does not change**: the gate adds no reason id and no record
field — a wrong repository, an impure source and a root mismatch all fall through to the existing
`environment.unlisted` outcome — so `slice_states` in `scope/v1/scope-gates.jq` (~536-558, first
row) is already right. Do not touch it, not even the indicative line range in the comment above
it (R11); a re-run is its proof.

**`review_size: standard`**, with the spec's estimate of about 300-320 changed lines across those
six files (R22). No exception claimed. Above 400, stop and re-decide with the operator rather
than splitting: the clean entry and the four driver edits are one concern.

## Order of work

### Step 0 — the clean entry, alone, before anything else (R7, R20)

Copy from the **working tree's** `adapters/local-git-materializer/v1/materialize.sh`, not from a
commit. Above each block put a copy header in the form `shadow/v1/qualified-identity.jq:8-13`
uses — `# Copied verbatim from adapters/local-git-materializer/v1/materialize.sh at
a637451d4b3fbef6b516a9c08f68c0dde46a7059 (origin/main) — keep in sync.` — plus one sentence: the
driver must scrub exactly what the producer scrubs, so the two can never disagree about what a
clean start is. Add an end marker after each block so step 5 can extract it.

1. `reproduce.sh:1` — `#!/bin/bash` becomes `#!/bin/bash -p`, byte for byte `materialize.sh:1`.
   Load-bearing: `BASH_ENV` is read before the script's first line, so nothing inside the file
   can get in front of it.
2. Insert `materialize.sh:4-13`, the scrub, **byte-identical**, between the existing
   `# shellcheck disable=SC2016` (line 2) and `set -uo pipefail` (line 3). Its last three lines
   are the driver-wide `PATH=/usr/bin:/bin; export PATH` the copied predicates need. Leave
   `export LC_ALL=C` (line 4) where it is, as `materialize.sh:30` keeps its own.
3. Replace `reproduce.sh:61` (`[ "$#" -eq 13 ] && [ "$1" = reproduce ] || emit_error E_USAGE`)
   with `materialize.sh:22-29`, copied with R7's six deviations and no others: the count is `13`,
   so the first line is `[ "$#" -eq 13 ] || emit_error E_USAGE`; the verb is `reproduce` and the
   marker `__reproduce_clean`; the exec forwards `"$2"` … `"${13}"`, twelve paths after the
   marker; the `-p` shebang above; the script path is normalized instead of refused — where the
   materializer rejects a relative `${BASH_SOURCE[0]}` with `E_USAGE`, write the normalization
   `reproduce.sh:94-95` already uses (`*) script_path="$(pwd -P)/$script_path" ;;`) then
   `[ -f "$script_path" ] && [ ! -L "$script_path" ] || emit_error E_RUNTIME`, the condition and
   code `reproduce.sh:96` already uses; and `materialize.sh:15`'s `set -euo pipefail` is **not**
   copied, the driver keeping its own `set -uo pipefail`.

   Everything else is the materializer's bytes. The exec line stays `/bin/bash "$script_path"`
   with **no** `-p`: `env -i` has already emptied the environment, and `-p` there would be a
   seventh deviation. Keep `shift` (line 62) and the twelve assignments after it — in the marker
   process `$1` is `__reproduce_clean`, so `shift` leaves the same twelve paths.
   `reproduce.sh:94-101` stays as it is and re-derives the path in the clean process.

**Verify before writing anything else:** `bash scripts/test/shadow-slice.test.sh` passes in full
with no other change and shellcheck 0.11.0 is clean. That is what says the entry cost nothing.

### Step 1 — the registry (R1-R4)

Run this over the current file, to a temp file, then move it into place:

```
jq -S -c --arg d "Operator's local macOS checkout, ystack's own scrubbed bare source repository." \
  '.body.environments[0].target_repository_id = "fixture.target"
   | .body.environments[0].source_root_commit = "866a40ce4a7fb6198fd489a0326f0cd1c2e2d791"
   | .body.environments += [{environment_id:"env.local-macos-ystack-self", description:$d,
       evidence_scope:"self-host", proof_state:"unproven", target_repository_id:"repo.ystack",
       source_root_commit:"7908b159c0a2d24ce6ccdde6ee0f501acc483e75"}]' \
  shadow/v1/shadow-environments.json
```

`-S` sorts keys while arrays keep order, so the new entry lands second; `-c` plus jq's trailing
newline reproduce today's byte shape. Check R4's `cmp` before committing.
`.body.activation_state` stays `inactive`, `.body.registry_version` stays `v1`, and `.id`,
`.kind`, `.schema_version` are untouched.

### Step 2 — four driver edits on top of step 0 (R5, R6, R8, R9)

1. **Shape check (R5).** The `E_RELATION` jq at `reproduce.sh:182-188` requires of every entry an
   `environment_id` string on the id charset. Add two per-entry requirements: a
   `target_repository_id` string matching `\A[a-z0-9][a-z0-9._:-]{0,127}\z` and a
   `source_root_commit` string matching `\A[0-9a-f]{40}\z`. Today's `all(.[]; …)` pipes into
   `.environment_id`, so restructure the body to test three fields off the entry instead of
   extending that pipe. Key-exactness and the other three keys are not the driver's job — R12's
   byte pin covers those.
2. **`git_env` hoist (R9).** Move the array out of the `if [ "$reason" = check.completed ]` block
   (`reproduce.sh:338-341`) to just above the `outcome=inconclusive` initialization at line 258,
   so the new check and the candidate-blob reads at 344-361 share one definition. Add the
   materializer's hook pin (`materialize.sh:268-269`) — `GIT_CONFIG_COUNT=1`,
   `GIT_CONFIG_KEY_0=core.hooksPath`, `GIT_CONFIG_VALUE_0="$scratch/no-hooks"` — plus
   `GIT_GRAFT_FILE="$scratch/no-grafts"`. Nothing creates either path. Everything else in the
   array stays as written, `HOME` and `TMPDIR` included.
3. **`source_pure` (R8).** Bind three names just above it so the copy runs unedited: `run_root`, a
   fresh `0700` directory under the driver's own `$scratch` (the copy writes only
   `source-filesystem`, `source-config.snapshot`, `source-config` there); `source_algorithm`, the
   incident's `hash_algorithm` (`reproduce.sh:193`, the value `materialize.sh:252` reads); and
   `git_env`, the hoisted array. `git_dir` needs no binding — it is the first five lines of the
   copied span. Then paste `materialize.sh:271-332` and `348-354` **byte for byte** into a
   subshell function shadowing `emit_error`:
   `source_pure() ( emit_error() { exit 1; }; <span 271-332>; <span 348-354>; exit 0 )`. Paste at
   column zero with **no re-indentation**; bash accepts that inside a subshell body and it keeps
   step 5's `cmp` byte-exact. Before pasting, check every command word in the two spans resolves
   under `PATH=/usr/bin:/bin`; if one ever does not, stop and re-decide rather than widen `PATH`.
   Do not copy `materialize.sh:333-347` (the `packed-refs` replace-ref scan) — it stays
   adapter-only and step 3 depends on that — nor `scan_tree` (`materialize.sh:386` on) or the
   identity checks after line 354.
4. **The gate (R6, R9, R10).** Replace the single `if` at `reproduce.sh:267-269` with a flag,
   leaving the sandbox block below it untouched and unindented:

   ```
   environment_listed=no
   if <lookup on both ids>; then
     if source_pure; then
       entry_root=$(<jq read of the matched entry's source_root_commit>)
       root_status=0
       observed_root=$("${git_env[@]}" GIT_ALTERNATE_OBJECT_DIRECTORIES= \
         GIT_DIR="$source_git_dir" /usr/bin/git --no-replace-objects \
         --git-dir="$source_git_dir" rev-list --max-parents=0 "$commit_id" \
         2>/dev/null | /usr/bin/head -c 4096) || root_status=$?
       case "$observed_root" in
         *[!0-9a-f]*|"") ;;
         *) [ "$root_status" -eq 0 ] && [ "${#observed_root}" -eq 40 ] &&
              [ -n "$entry_root" ] && [ "$observed_root" = "$entry_root" ] &&
              environment_listed=yes ;;
       esac
     fi
   fi
   if [ "$environment_listed" = yes ]; then
     … existing sandbox evaluation, unchanged …
   ```

   The lookup selects on **both** `.environment_id == $id` and `.target_repository_id == $repo`,
   `$repo` a second `--arg` carrying `$repository_id`, the value already parsed at
   `reproduce.sh:191`; exactly one entry must match, as today, and `entry_root` is read with the
   same two `--arg` values. The extra `VAR=value` words sit between `git_env`'s `/usr/bin/env -i`
   and the command, so they are that one command's environment and no other caller is affected.
   All three conditions are required: status `0`, exactly one line of forty lowercase hex
   characters, equality with the entry. Purity runs before the root check and both stay inside
   the lookup `if`, so an unlisted run still reads nothing under the source directory. Any
   failure changes nothing — the run keeps the `environment.unlisted` state initialized at
   `reproduce.sh:258-265`. No new reason id, error code or record field.

### Step 3 — the test, with step 2 and not after it (R12-R18)

R18's guard belongs here: the copied `git config` read trips the guard as it stands the moment
2.3 lands.

1. **Full-registry byte pin (R12).** Replace lines 322-328: build the whole expected document
   with `"$jq_bin" -S -c -n`, as that file already builds canonical fixtures, and `cmp` it
   against `$registry`, failing `registry-contents` on any difference — five header fields and
   both entries in order, each with all six keys and no others. Do not type the fixture sha
   twice: compute it as an `--arg`, `fixture_root=$(git_clean --git-dir="$tmp/source.git"
   rev-list --max-parents=0 "$failing_commit")`, after `failing_commit` exists (line 90). Keep
   the `registry-canonical` `cmp` at line 321 and rewrite the pass message (line 329) to
   something true of two entries.
2. **`config_guard_ok` (R18).** Drop `config` from the verb list on line 614 and add a helper
   beside the existing ones (near `mutate`, 274-279) that takes a path and returns nonzero on any
   of R18's four refusals, accepting exactly the two lines the copy brings in from
   `materialize.sh:314-315` and requiring them exactly once. Call it twice: on `$reproducer`,
   which must pass, and on a `/bin/cp` copy under `$tmp` with R18's one appended `--local` line,
   which must be refused (`fail config-guard-permissive`). Never edit `$reproducer` — the
   component digest check at 604-609 depends on that. Update line 620's pass message.
3. **Seven new cases**, after the existing `unlisted-environment` case (436-443), built exactly as
   their requirements name them, using only the existing `mutate`, `run_case` and
   `expect_outcome` helpers: `run_case` already takes the source directory as its fifth argument,
   so no new helper is needed. (a)-(f) all expect `outcome: inconclusive`,
   `reason_id: environment.unlisted`, environment evaluation
   `{state:"absent", reason_id:"environment.unlisted"}`, and materialization and check execution
   `absent`.
   - **(a)** wrong id binding — a listed id bound to the other repository (R13).
   - **(b)** foreign repository — a second deterministic bare repository beside the fixture one
     (R14).
   - **(c)** alternates and **(d)** commondir — two copies of `$tmp/source.git` holding none of
     its objects that reach them from outside themselves (R15a, R15b).
   - **(e)** poisoned `PATH` — the (c) copy with a planted silent `find` first on `PATH`, plus the
     second assertion that `$tmp/poison-marker` never appeared (R15c). Set `PATH` around the one
     call and restore it, not in a subshell: the suite's `pass` counter is a plain shell variable.
   - **(f)** exported `find` function — the (c) copy again under `export -f find`, with R15d's
     three assertions, the third written out as `/bin/bash -p "$reproducer" reproduce …` and
     shaped like the direct invocations at 565-577 (capture status and stderr, no new helper). Add
     no `bash "$reproducer"` case under a hostile `BASH_ENV`, and claim nothing about it.
   - **(g)** `TMPDIR` missing — a *positive* case: the `reproduced` inputs with `TMPDIR` set
     around the call to a directory that does not exist, still giving `reproduced` /
     `check.failed-at-revision` (R15e).
4. **Retarget `missing-revision` (R16).** Lines 476-480 run the fixture incident against an empty
   bare repository for `materialization.refused`; under R9 that source is refused a step earlier,
   which is (b)'s job now. Keep `materialization.refused` covered with the one source check the
   driver does not copy — a `/bin/cp -R` of the fixture repository carrying one
   `refs/replace/<failing_commit>` line in `packed-refs`, which passes every copied predicate and
   the root check and is refused by `materialize.sh:343-345` with `E_SOURCE_GIT`, recorded as
   `inconclusive` / `materialization.refused` (`reproduce.sh:306-308`). Rename the case and its
   pass message to what it now proves and drop the unused `$tmp/gone.git` (476-477). Do not touch
   the never-written checks at 100-102, 601 and 604-609. No other existing case changes outcome;
   any other change means the work is wrong.

### Step 4 — the docs (R20)

Seven passages, six edits and one addition, worded as R20 words them. No other prose change;
confirm each by grepping `shadow-environments`, since the line numbers are indicative.

- `docs/components.md:1194` — one entry becomes two, with scope and proof state, stating both
  bindings (one target repository id **and** one source repository named by its root commit).
- `docs/components.md:1203` — the id-lookup sentence becomes listed, bound to this incident's
  target repository id, and run against a plain source repository whose root commit is the
  entry's.
- `docs/components.md:1247-1250` — the self-host environment is listed and unproven, its proof a
  later step.
- `docs/transition.md:65` — one execution environment becomes two, both `unproven`.
- `docs/transition.md:183` — the self-host environment is now listed, the external-target one is
  not.
- `docs/transition-kit.md:247` — "must first be listed" becomes "is now listed", the run still
  gated.
- `docs/components.md`, shadow-driver section (after the description ending near line 1209) — the
  one **addition**, two or three sentences: the supported invocations are executing the file (its
  `#!/bin/bash -p` shebang) and `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p
  <driver> reproduce …`; `bash <driver>` is not supported, because bash processes `$BASH_ENV`
  before the driver's first line and the scrub cannot get in front of that. Claim nothing more —
  the unsupported form is neither detected nor refused.

### Step 5 — run the Proof section on the final commit and paste it in the PR body.

## Risks

**What breaks first: the clean entry against the test's own invocations.** Two cases assert the
driver's arity and the re-exec sits on top of them. Lines 565-569 pass two words for `E_USAGE`:
that now comes from `[ "$#" -eq 13 ] || emit_error E_USAGE`, before the dispatch — the same check
from the same line. Lines 571-577 pass thirteen words with one relative path from a `cd "$tmp"`
subshell: that re-execs, and the relative path is refused by the unchanged loop at
`reproduce.sh:76-78` in the clean process. Three things this rests on: the marker form is also
thirteen words (marker plus the same twelve); `exec` preserves the working directory, so `pwd -P`
normalization agrees on both sides; stderr survives `exec`, so the driver's error vocabulary
still reaches the test.

**The `TMPDIR` drop is a real behavior change.** After the scrub the driver always takes `/tmp`
from `${TMPDIR:-/tmp}` (`reproduce.sh:120`). Case (g) holds that in place — it fails before the
clean entry, because `mktemp -d` under a missing directory returns `E_RUNTIME`. Do not add an
argument to carry `TMPDIR` back in.

**The copied predicates' `emit_error` shadowing.** It is shadowed so an impure source returns
nonzero instead of raising `E_SOURCE_*`, which `reproduce.sh:7`'s `case` would turn into
`E_RUNTIME`. That shadow must not escape: `source_pure` is a `( )` subshell function, or every
later error in the run becomes a silent `exit 1`. Related — the spans were written under
`set -euo pipefail` and the driver has no `-e`. Every refusal in them is an explicit
`|| emit_error` or `if …; then emit_error`; the only bare command is `materialize.sh:299`'s
`/bin/rm -f` of the inventory, which is cleanup. Re-check that line by line when the copy lands,
and do not add `set -e`: R9's status capture and R10's fall-through depend on there being none.

**`scan_tree` and everything past `materialize.sh:354` stay uncopied, on purpose.** The gate
decides whether the entry applies; it does not become the materializer. The tree scan, the
commit-object checks and the `packed-refs` replace-ref scan stay the adapter's second line of
defense, and step 3.4 depends on the last of those being adapter-only.

**Riskiest step: 0.3.** The re-exec is the one edit that can break a contract nothing else in the
suite re-states: it rewrites the driver's front door while `[ "$#" -eq 13 ]` must keep meaning
exactly what it meant, in both entries. Land it alone, run the full suite, and only then paste in
anything that depends on it.

**Alternatives rejected.**
- `unset -f find`, or any name list, instead of the producer's whole entry: a list someone must
  keep in step with the copy, silent about `head`, `wc`, `tr`, `rm`, `grep`, `IFS` and
  `SHELLOPTS`, and it leaves the driver differing from the producer at the one point where the
  copy's safety comes from the producer's surroundings. The entry is a property (nothing is
  inherited); a list is an enumeration.
- A new reason id such as `environment.source-impure`: it would add a row to `slice_states` in
  `scope/v1/scope-gates.jq` and change every consumer, turning a six-file change into a
  cross-component one. On an impure source the binding cannot be verified at all, so the
  environment genuinely is not listed for it.
- A `PATH=/usr/bin:/bin source_pure` prefix instead of a driver-wide `PATH`: whether an
  assignment prefix on a *function* call survives the call differs between bash's default and
  POSIX modes, and it does nothing about an exported function.
- Re-implementing the predicates instead of copying: that is how the gate and the adapter drift
  into two ideas of a plain repository, which is how the bypass comes back.
- Adding `-p` to the re-exec's `/bin/bash`, or `-e` to the driver's `set`: deviations the spec
  does not list.
- For step 3.4, a `core.bare = false` copy: the driver now runs `--is-bare-repository` itself, so
  that source would come back `environment.unlisted` and prove nothing.

## Proof

Run all of this on the final implementation commit and say which commit; old proof on a new
commit is stale. `$t` is any scratch directory.

- `bash scripts/test/shadow-slice.test.sh` — all pass; last line
  `shadow slice: <N> focused checks passed` and nothing else printed. That includes R18's two
  `config_guard_ok` calls (the tightened guard accepts `reproduce.sh` as shipped and refuses the
  `--local` mutation), case (e)'s assertion that the planted `find` never ran, and (f)'s three.
- `bash scripts/test/scope-qualification.test.sh` — 0 failures: prints
  `scope qualification: <N> focused checks passed` and exits 0 (its `fail` aborts, so that line
  *is* the zero-failures proof). R11's evidence that the consumer is untouched.
- `bash scripts/test/portable-core-schema.test.sh` — final line `failures: 0`, exit 0.
- `bash scripts/check-rename.sh` — `check-rename: clean — no old names in tracked files.`
- `shellcheck -x -S style shadow/v1/reproduce.sh scripts/test/shadow-slice.test.sh` under
  **0.11.0** (paste `shellcheck --version`) — no findings, exit 0; and
  `grep -c 'shellcheck disable' shadow/v1/reproduce.sh` still `1`, so no new directive.
- **Ordering.** Run the suite after each step and paste which cases fail. Expected: 3.1's pin
  fails before step 1; (a) before 2.4's lookup edit; (b) before 2.4's root check; (c) and (d)
  before 2.3's purity copy; (e), (f) and (g) before step 0 — all passing at the end.
- **Registry.** `jq -S -c . shadow/v1/shadow-environments.json | cmp -
  shadow/v1/shadow-environments.json` — no output, exit 0 (R4); still one line ending `0a`.
- **The copy's environment.** `env -i PATH=/usr/bin:/bin command -v find head wc tr rm grep git`
  resolves every one under `/usr/bin` or `/bin`.
- **Scope.** `git diff --stat main` lists exactly the six files above and nothing else, net total
  in the 300-320 range. At 400, stop and ask the operator.

**The copies are copies.** Every comparison reads the **working tree's** `materialize.sh`, never a
commit: CI checks out at the default depth, so `git show <commit>:…` cannot resolve there. First
anchor the four ranges by content, not line number — `sed -n '4p;13p;22p;29p;271p;332p;348p;354p'`
on `materialize.sh` must still print those eight lines as this plan's ranges assume (`4p` is
`clean_path=/usr/bin:/bin`, `13p` `export PATH LC_ALL`, `22p` the `-eq 8` usage check, `29p` the
`__materialize_clean` marker check, `271p` `git_dir() {`, `332p` `  emit_error E_SOURCE_GIT`,
`348p` the `hooks` `find`, `354p` the `source_algorithm` comparison). A moved line is drift to
resolve before merge. Then extract each copy from `reproduce.sh` between its copy header and end
marker (`awk '/^# copy-begin materialize.sh:271-332$/{f=1;next} /^# copy-end
materialize.sh:271-332$/{f=0} f' shadow/v1/reproduce.sh > "$t/copy-a"`, likewise `348-354`,
`4-13`, `22-29`) and compare:

```
m=adapters/local-git-materializer/v1/materialize.sh
sed -n '271,332p' "$m" > "$t/orig-a"; sed -n '348,354p' "$m" > "$t/orig-b"
sed -n '4,13p'    "$m" > "$t/orig-scrub"; sed -n '22,29p' "$m" > "$t/orig-entry"
cmp "$t/orig-a" "$t/copy-a"            # R8 span 271-332: byte-equal
cmp "$t/orig-b" "$t/copy-b"            # R8 span 348-354: byte-equal
cmp "$t/orig-scrub" "$t/copy-scrub"    # R7 scrub 4-13: byte-equal, no deviation
diff -u "$t/orig-entry" "$t/copy-entry"     # R7 entry 22-29: only the named deviations
cmp <(sed -n 1p "$m") <(sed -n 1p shadow/v1/reproduce.sh)   # the -p shebang
```

That `diff -u` must show only: `-eq 8` → `-eq 13`; the `case … E_USAGE` line replaced by the
normalization plus the `-f`/`-L` check; `materialize` → `reproduce`; `__materialize_clean` →
`__reproduce_clean`; and the exec forwarding `"$2"` … `"${13}"`. Nothing else. With the shebang
`cmp`, the omitted `set -euo pipefail` (`grep -c 'set -euo pipefail' shadow/v1/reproduce.sh` is
`0`, `set -uo pipefail` still exactly once) and the block sitting at the driver's own arity check,
that is all six deviations R7 names and no seventh. Paste both comparisons in the PR body, naming
the ranges read.
