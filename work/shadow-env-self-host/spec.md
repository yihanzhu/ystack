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
itself. Reading a repository's root commit only means something if the repository
answers out of its own object store, so the driver first checks that the directory it
was handed is a plain repository with nothing pointing outside it — and, because those
checks are only as good as the shell they run in, the driver starts by scrubbing the
environment it was called with and re-execing itself clean, the way the materializer
already does. The test and docs that count the entries become true again. No run
happens here.

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
commit of the fixture bare repository that test builds (R12 shows why that sha is
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
itself, so writing its output is enough — and for the same reason R12's `cmp` of a
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

**R7.** Driver edit three, and the first thing the driver does: a clean entry, copied
from the materializer. A fixed `PATH` is not enough to make the copied predicates in R8
mean what they say. Bash resolves a command word by looking for a shell *function* of
that name before it ever looks at `PATH`, and a function can be handed to a child bash
through the environment (`find() { :; }; export -f find`). So a caller who cannot touch
`PATH` can still make the three bare `find` calls in the copy (`materialize.sh:327`,
`331`, `348`) run its own silent code, and the worktrees, promisor-pack and hook
predicates all report "nothing found" — the R8/R9 bypass again, one layer earlier. The
same door is open to `head`, `wc`, `tr`, `rm` and `grep` (every other command in the
copy is absolute), and an exported `IFS`, `BASH_ENV` or `SHELLOPTS` reaches the same
code by another route.

The materializer already closes this at its own entry, and the driver adopts that entry
rather than inventing one. It is `adapters/local-git-materializer/v1/materialize.sh:4-13`
— the scrub —

```
clean_path=/usr/bin:/bin
while IFS= builtin read -r inherited_function; do
  builtin unset -f "$inherited_function" 2>/dev/null || :
done < <(builtin compgen -A function)
while IFS= builtin read -r exported_name; do
  case "$exported_name" in PATH) ;; *) builtin unset "$exported_name" 2>/dev/null || : ;; esac
done < <(builtin compgen -e)
PATH=$clean_path
LC_ALL=C
export PATH LC_ALL
```

— and `materialize.sh:22-29` — the arity check and the re-exec:

```
[ "$#" -eq 8 ] || emit_error E_USAGE
script_path=${BASH_SOURCE[0]}
case "$script_path" in /*) ;; *) emit_error E_USAGE ;; esac
if [ "$1" = materialize ]; then
  exec /usr/bin/env -i PATH="${PATH:-/usr/bin:/bin}" LC_ALL=C \
    /bin/bash "$script_path" __materialize_clean "$2" "$3" "$4" "$5" "$6" "$7" "$8"
fi
[ "$1" = __materialize_clean ] || emit_error E_USAGE
```

Both blocks are **copied** into `shadow/v1/reproduce.sh`, under the same copy header R8
uses (the `shadow/v1/qualified-identity.jq:8-13` convention), naming
`materialize.sh:4-13` and `22-29` at the same commit as R8's spans. Copying rather than
paraphrasing is the point: the driver must scrub exactly what the producer scrubs, so
the two can never disagree about what a clean start is. Every deviation from the
materializer's bytes, and nothing beyond these:

- **the marker word and verb** — `reproduce` where it says `materialize`, and
  `__reproduce_clean` where it says `__materialize_clean`;
- **the argument count** — `13`, not `8`, and the exec forwards `"$2"` … `"${13}"`,
  twelve paths after the marker;
- **the shebang** — the driver's `#!/bin/bash` becomes `#!/bin/bash -p`
  (`materialize.sh:1`), which is part of this entry: started through its shebang, a
  privileged bash imports no function from the environment and ignores `BASH_ENV`,
  `ENV`, `SHELLOPTS`, `BASHOPTS` and `CDPATH`. `-p` alone is not the fix — it is
  bypassed entirely when the file is run as `bash reproduce.sh` — which is why the
  scrub and the re-exec are copied too, and why R15d tests both invocations;
- **the script path** — the materializer refuses a relative `${BASH_SOURCE[0]}` with
  `E_USAGE`; the driver instead normalizes it against `$(pwd -P)`, exactly as
  `reproduce.sh:94-95` already does, and then requires the result to be an existing
  non-symlink regular file or `E_RUNTIME` — the code `reproduce.sh:96` already uses for
  that condition. Reason: the driver accepts a relative invocation path today, and a
  failed `exec` would report bash's own message instead of the driver's error
  vocabulary. `reproduce.sh:94-101` stays exactly as it is and re-derives and re-checks
  the path in the clean process;
- **`set -euo pipefail`** — `materialize.sh:15` is *not* copied. The driver keeps its
  own `set -uo pipefail` (`reproduce.sh:3`); R9's status capture and R10's fall-through
  both depend on there being no `-e`, and adding one would change every existing branch
  in the file;
- **where the dispatch sits** — at the driver's existing arity check
  (`reproduce.sh:61`), which is after the helper-function definitions because
  `emit_error` must exist to say `E_USAGE`. Those definitions are the only thing above
  it and they run no command. The scrub block itself is at the very top of the file,
  above `set -uo pipefail` and `umask 077`. `reproduce.sh:4`'s `export LC_ALL=C` stays
  where it is, as `materialize.sh:30` keeps its own: the same value, said twice, costs
  nothing and keeps both files reading the same way.

**Ordering, which is the whole value.** The scrub is the first thing in the file and the
re-exec is the first thing after the arity check, both before any external command, before
R8's copied spans, before R9's root lookup, and before the sandbox evaluation at
`reproduce.sh:270-273`. Everything the driver does after it runs in a process with no
imported functions, no inherited exported variables, and `PATH=/usr/bin:/bin`
`LC_ALL=C` fixed. The scrub runs in both entries — the public one and the marker one —
so invoking the marker form directly gains a caller nothing.

**The 13-argument contract is unchanged from the caller's view.** Callers still write
`reproduce` plus twelve absolute paths, and `[ "$#" -eq 13 ]` stays exactly as written
and still runs *before* the dispatch, because the marker form is also thirteen words
(marker plus the same twelve). So `shadow-slice.test.sh:565-569` (two arguments →
`E_USAGE`) and `571-577` (thirteen words, one relative path → `E_USAGE`) both hold
unchanged: the relative path is forwarded and refused by the same loop
(`reproduce.sh:76-78`) in the clean process, and stderr survives `exec`. A wrong verb is
still `E_USAGE`, now from the marker check. No other test asserts the driver's first
lines, its shebang or its arity — checked while drafting; the only other text assertions
on the file are the digest check (computed from the file at run time, not a stored
constant) and R18's greps, which the entry does not trip.

**What the clean entry passes through: `PATH` and `LC_ALL`, exactly as the materializer
does, and nothing else.** The one inherited variable `reproduce.sh` reads today is
`TMPDIR`, at `reproduce.sh:120`
(`mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-reproduce.XXXXXX"`), and it is deliberately
not passed:

- it cannot be re-derived from an argument. `scratch_root` must still be an *empty*
  private directory when the materializer checks it (`materialize.sh:120`,
  `E_SCRATCH_ROOT`), and the driver creates its scratch (line 120) long before it calls
  the materializer (line 302); `candidate_root` and `state_dir` are outputs the driver
  itself requires empty (`reproduce.sh:84`). Putting the scratch in any of them breaks
  the run;
- it should not be passed through. It is a caller-chosen path that decides where the
  driver writes — today, with nothing checking it, that includes inside
  `$source_git_dir`. Dropping it removes a caller's influence over an authorization
  path and costs only the fallback `/tmp` that same line already declares. Every
  directory the driver actually needs is an argument.

`HOME` needs nothing: the driver reads it nowhere, and git sees the `HOME="$scratch"`
`git_env` sets explicitly (`reproduce.sh:338-341`, R9). Two consequences, both accepted:
the sandbox evaluator and the trace validator are invoked with only a `PATH` prefix
(`reproduce.sh:271`, `460`) and so inherit this environment — they take their scratch
from `${TMPDIR:-/tmp}` (`evaluate-sandbox.sh:59`) or `/tmp` outright
(`validate-trace-ledger.sh:102`), so they move with the driver and need no change, and
they keep `$scratch/bin` first on the `PATH` those invocations set, which is how they
find the pinned jq; and the materializer invocation at `reproduce.sh:302` already went
through its own `env -i`, so it is unaffected. No new error code, no new reason id, no
change to the record.

**R8.** Driver edit four: the source directory must be a plain repository *before*
the driver asks it who it is. R9's binding asks git to resolve object ids inside
`$source_git_dir`. Git will answer out of an object store that is not in that
directory if the directory tells it to: `objects/info/alternates` names extra object
directories, a `commondir` file points the whole repository at another one, and
`GIT_OBJECT_DIRECTORY` / `GIT_ALTERNATE_OBJECT_DIRECTORIES` do the same from the
environment. So a directory holding none of ystack's objects can still report ystack's
root and pass R9 — checked while drafting: a copy of the fixture bare repository with
its own objects removed and `objects/info/alternates` pointing at the real fixture
object store reports `866a40ce…`, and so does the same copy with a `commondir` file
instead. The materializer refuses such a source, but it only runs *after* the
environment gate, so the gate would already have been passed and the run would reach
sandbox evaluation and materialization instead of `environment.unlisted`. The driver
therefore runs the materializer's own source-purity predicates inside the R6 `if` and
**before** R9's lookup.

Those predicates are two contiguous spans of
`adapters/local-git-materializer/v1/materialize.sh`:

- **271-332** — the `git_dir` helper (271-275); the filesystem inventory (277-299):
  every entry under the directory is inside it, is not a symlink, and is a regular
  file or a directory, bounded at 8388608 bytes and 65536 entries
  (`E_SOURCE_GIT`, `E_SOURCE_LIMIT`); the bounded config snapshot and its name-only
  allow-list (301-323) — only
  `core.repositoryformatversion`, `core.filemode`, `core.bare`,
  `core.logallrefupdates`, `core.ignorecase`, `core.precomposeunicode`,
  `extensions.objectformat` (`E_SOURCE_CONFIG`); `rev-parse --is-bare-repository`
  equal to `true` (324-325, `E_SOURCE_WORKTREE`); and the structural absences
  (326-332) — no `commondir`, no `shallow`, no entry under `worktrees`, no
  `info/grafts`, no `objects/info/alternates`, no `refs/replace` directory, no
  `*.promisor` pack (`E_SOURCE_GIT`).
- **348-354** — no hook that is not a `*.sample` (348-351, `E_SOURCE_HOOK`); and
  `rev-parse --show-object-format` equal to the declared algorithm (352-354,
  `E_SOURCE_GIT` on the git failure, `E_SOURCE_IDENTITY` on a mismatch).

Both spans are **copied verbatim** into `shadow/v1/reproduce.sh` — byte for byte, not
re-implemented and not approximated — under the header this repo already uses for a
copied predicate (see `shadow/v1/qualified-identity.jq:8-13`): `# Copied verbatim from
adapters/local-git-materializer/v1/materialize.sh at <commit sha> (origin/main) — keep
in sync.`, followed by one sentence saying why it is a copy (the gate must refuse
exactly what the materializer refuses, so the two can never disagree about what a
plain source repository is). Keep the copy runnable without editing its body by
binding the names it uses just above it:

- `run_root` — a fresh `0700` directory the driver creates under its own `$scratch`
  (the copied lines write only `source-filesystem`, `source-config.snapshot` and
  `source-config` there, and delete the first themselves);
- `git_env` and the `git_dir` helper — the driver's own, hoisted per R9. The driver's
  `git_env` also gains the materializer's hook pin (`materialize.sh:268-269`:
  `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=core.hooksPath`,
  `GIT_CONFIG_VALUE_0="$scratch/no-hooks"`) so the copied predicates run under an
  environment at least as protective as the one they were written for;
- `source_algorithm` — the incident's `hash_algorithm` (`reproduce.sh:193`). That is
  the same value the materializer uses: `reproduce.sh:233-238` already requires the
  materialization input's `target_revision.hash_algorithm` to equal it, and
  `materialize.sh:252` reads `source_algorithm` from that field.

The copy runs inside a subshell function that shadows `emit_error` with an immediate
non-zero exit — `source_pure() ( emit_error() { exit 1; }; <verbatim span 271-332>;
<verbatim span 348-354>; exit 0 )` — so the predicates keep their exact text while an
impure source produces a failed return instead of a driver error (R10). No purity
failure is ever reported as an error code: the shadow driver's error codes are for
malformed inputs, and an impure source is a run the entry does not authorize.

**The copy must run under a fixed `PATH` and with no inherited function, which is what
R7's clean entry is for.** Inside the
materializer these spans always run under `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C`
— the re-exec at `materialize.sh:26-27`, which every `materialize` invocation goes
through. That is why the three bare command words in the copy are safe there: `find`
at `materialize.sh:327`, `331` and `348` (every other command in the two spans is
already written as an absolute path, and `git` is reached through `git_env`, which
starts with its own `/usr/bin/env -i PATH=/usr/bin:/bin`). `reproduce.sh` fixes no
`PATH` at all today — lines 3-5 are `set -uo pipefail`, `export LC_ALL=C`, `umask 077`
and nothing more — and it gets away with that because every external command it runs
is absolute (`/usr/bin/shasum`, `/usr/bin/stat`, `/usr/bin/find`, `/bin/dd`, `/bin/rm`,
…) and the four places that need a different `PATH` set it on the invocation
(`reproduce.sh:271` and `460`, `$scratch/bin:/usr/bin:/bin` for the sandbox evaluator
and the trace validator; `reproduce.sh:302`, `env -i PATH=/usr/bin:/bin` for the
materializer; `reproduce.sh:338` inside `git_env`). Pasted into the driver as written,
those three bare `find`s would be the first commands in the file to resolve against the
**caller's** `PATH` — and they run before R9's binding and before the sandbox
evaluation, at the one moment the gate is deciding whether to trust the directory. A
caller that puts its own `find` first on `PATH` (exit 0, print nothing) makes the
worktrees, promisor-pack and hook predicates all report "nothing found" and walks an
impure source through the gate.

R7 gives the copy the environment it was written for: `PATH=/usr/bin:/bin` and
`LC_ALL=C`, exported before any external command runs, in a process that imported no
function and no other variable. Driver-wide, not a `PATH=/usr/bin:/bin source_pure`
prefix on the invocation: the driver's own commands are already absolute so a
driver-wide fix costs them nothing, the four sites above set `PATH` on their own
invocation and are untouched — in particular the evaluator and the trace validator
keep `$scratch/bin` first, which is how they find the pinned jq — and whether an
assignment prefix on a *function* call survives the call differs between bash's
default and POSIX modes, which is not something an authorization gate should rest on.
A prefix would also have done nothing about an exported `find` function, which is the
half of this that `PATH` cannot reach at all. Beyond the fixed environment, require
that every command word in the two copied spans resolves under `PATH=/usr/bin:/bin`:
check it when the copy lands. If a later span ever names a command that lives outside
`/usr/bin` and `/bin`, stop and re-decide — do not widen `PATH` to accommodate it.

`materialize.sh:333-347` (the `packed-refs` scan for `refs/replace/` lines) is
deliberately **not** copied. Replace refs cannot move the binding: R9's lookup runs
with `--no-replace-objects` and `GIT_NO_REPLACE_OBJECTS=1`, verified while drafting
(a copy carrying a `refs/replace/<incident commit>` line in `packed-refs` still
reports `866a40ce…`). It stays a materializer-only check, and R16 uses it.

**R9.** Driver edit five: the driver verifies the source repository's identity. R6's
two values are both caller-supplied text, so the entry must also be checked against
something the driver computes from the bytes of the repository the run will read.
After R8's purity check passes and **before** the sandbox evaluation at
`shadow/v1/reproduce.sh:270-273`:

- read that entry's `source_root_commit` out of the registry snapshot with the same two
  `--arg` values, into a shell variable;
- run, read-only, `git --no-replace-objects --git-dir="$source_git_dir" rev-list
  --max-parents=0 "$commit_id"`, where `$commit_id` is the incident revision the driver
  already parsed at `shadow/v1/reproduce.sh:195`; capture stdout bounded through
  `/usr/bin/head -c 4096`, discard stderr, and **capture the pipeline's exit status in
  the same breath** — `observed_root=$(…); root_status=$?` on the line after, or the
  `if observed_root=$(…); then … else …` shape; either is fine, silence is not.
  `reproduce.sh` runs under `set -uo pipefail` with no `-e`, so a failing git neither
  stops the driver nor shows up in the captured text by itself; `pipefail` is what makes
  the pipeline's status git's rather than `head`'s;
- require **all three** before the entry is treated as matching: `root_status` equal to
  `0`; the captured text exactly one line of forty lowercase hex characters
  (`[0-9a-f]{40}`, no second line and nothing else — the capture strips the trailing
  newline, so this is a whole-string check); and that line equal to the entry's
  `source_root_commit`.
- anything else is `environment.unlisted` (R10): a different root, more than one root
  line, output that is not a bare object id, an incident commit absent from that
  repository, an unreadable directory, and any nonzero status. Status is checked
  separately from text because the two can disagree in the direction that matters: git
  can print a root and *then* fail — a walk that runs into a missing object after
  reaching one, or a `head -c 4096` bound closing the pipe on a repository with very many
  roots — and a text-only comparison would read that partial answer as a clean one.
  Refusing on a status the driver does not understand is the safe direction; the entry
  is only for a repository that answers cleanly.

How the status check is proved. The nonzero branch is executed by the suite as it
stands: R14's foreign repository does not contain the incident commit, so `rev-list`
exits 128 and prints nothing, and R15a/R15b's impure copies reach the same branch by
another route. The one corner the test cannot reach is a nonzero status that has
*already* printed the pinned root: the incident commit is fixed by the incident
document, git prints a root only once the walk reaches one, and a store truncated
anywhere on the way therefore fails before printing — so no deterministic fixture in
this suite produces output-plus-failure. Do not build a hand-corrupted repository to
manufacture one; that corner is proved by review of the code shape, which is why this
requirement pins the shape (status captured, three conditions, all required) and not
just the outcome.

Run it with the protective environment `reproduce.sh` already uses for git
(`shadow/v1/reproduce.sh:338-341`), hoisted above the environment decision so the new
check and the existing candidate-blob reads at `shadow/v1/reproduce.sh:344-361` share
one definition and cannot drift, plus the hook pin from R8 and three additions. The
git process for the lookup sees exactly this environment and nothing else, because
`git_env` starts with `/usr/bin/env -i`:

`HOME=$scratch`, `TMPDIR=$scratch`, `PATH=/usr/bin:/bin`, `LC_ALL=C`,
`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_NO_REPLACE_OBJECTS=1`,
`GIT_NO_LAZY_FETCH=1`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`,
`GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=core.hooksPath`,
`GIT_CONFIG_VALUE_0=$scratch/no-hooks`, `GIT_GRAFT_FILE=$scratch/no-grafts`,
`GIT_ALTERNATE_OBJECT_DIRECTORIES=` (set, empty), `GIT_DIR=$source_git_dir`.

The last three are the ones this revision adds beyond the hoist. `GIT_GRAFT_FILE`
points at a path inside the driver's scratch that nothing creates: without it a source
repository carrying `info/grafts` rewrites the parent links git reports and the root
becomes whatever that file says — checked while drafting: with a graft the same commit
reports root `52022bc4…`, with `GIT_GRAFT_FILE` at a missing path it reports its true
`866a40ce…`. `GIT_ALTERNATE_OBJECT_DIRECTORIES=` and `GIT_DIR` are belt and braces
made visible: `env -i` already means `GIT_OBJECT_DIRECTORY`, `GIT_COMMON_DIR`,
`GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE` and every other caller variable
reach the git process unset (verified while drafting: the env-alternates bypass that
works with a plain `git` fails under `env -i`), and `--git-dir` on the command line
wins over `GIT_DIR` anyway — naming them puts the guarantee on the face of the code
next to the check it protects, and `$scratch/no-hooks` and `$scratch/no-grafts` are
paths the driver never creates. R8's copied `objects/info/alternates` and `commondir`
predicates cover the on-disk half, which the environment cannot.

Keep both R8 and this check inside the R6 `if`, so a run whose environment was never
listed still touches no git object and reads nothing under the source directory, as
today.

**R10.** No new outcome vocabulary. An entry bound to another repository, a source
directory that is not a plain repository, or a source repository whose root is not the
entry's, does not authorize the run, so it falls through to the **existing**
`environment.unlisted` branch already initialized at `shadow/v1/reproduce.sh:258-264`:
`outcome: inconclusive`, `reason_id: environment.unlisted`, and the environment,
materialization and check sections all `absent`. Impurity and a root mismatch share
that one outcome on purpose: on an impure source the binding cannot be verified at all,
so the environment is not listed for it. No new reason id, no new record field, no
change to the record shape, no new error code.

**R11.** Consumers untouched, and proven so. Because R10 adds no reason id and no record
field, the reason/state table copied out of the driver into `scope/v1/scope-gates.jq`
(`slice_states`, ~lines 536-558, first row `environment.unlisted` → `inconclusive`
with every section `absent`) needs no change. Do not edit it; the only drift is the
indicative line range in the comment above it, left as is. Re-run `bash
scripts/test/scope-qualification.test.sh` and require 0 failures as the proof.

**R12.** `scripts/test/shadow-slice.test.sh` (the `registry-contents` block, near lines
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

**R13.** One new negative case for the id binding, beside the existing
`unlisted-environment` case (near lines 436-443): the fixture incident
(`target_repository_id` `fixture.target`) run with a claim whose `.id` is mutated to
`env.local-macos-ystack-self` — a *listed* id, bound to `repo.ystack` — yields
`outcome: inconclusive`, `reason_id: environment.unlisted`, environment evaluation
`{state:"absent", reason_id:"environment.unlisted"}`, and materialization and check
execution `absent`. Use the existing `mutate` and `expect_outcome` helpers; add no new
helper.

**R14.** One new negative case for the source binding: the unmutated fixture claim and
the fixture incident — so *both* R6 values match the fixture entry — run against a
second bare repository whose history is not the fixture's, giving the same
`environment.unlisted` result and the same three absent sections. Build that repository
beside the existing one with `git_clean`, deterministically: `init -q --bare
--object-format=sha1`, then one root commit (`commit-tree` over the empty tree, no
parent). `run_case` already takes the source directory as its fifth argument (line
333), so no new helper is needed. This case fails before R9 and passes after: today the
run reaches the sandbox evaluator and materializes against whatever repository it was
handed.

**R15.** Five new cases for source purity and the environment it is judged in. The first
two are impure copies of the fixture repository that *would* satisfy R9's root check
through an object store outside themselves; (c) and (d) are the same first copy with the
caller's environment turned against the copied predicates; (e) is a positive run proving
the clean entry did not take anything the driver needs. (a) through (d) give
`outcome: inconclusive`, `reason_id: environment.unlisted` and the same three absent
sections, with the unmutated fixture claim and incident:

- (a) **alternates.** `/bin/cp -R "$tmp/source.git" "$tmp/alternates.git"`, remove the
  copy's own objects (`/bin/rm -rf "$tmp/alternates.git/objects"`, then recreate
  `objects/info` and `objects/pack` as `0700` directories), and write
  `"$tmp/source.git/objects"` into `$tmp/alternates.git/objects/info/alternates`.
- (b) **commondir.** `/bin/cp -R "$tmp/source.git" "$tmp/commondir.git"`, remove
  `"$tmp/commondir.git/objects"`, and write `"$tmp/source.git"` into
  `$tmp/commondir.git/commondir`.
- (c) **poisoned `PATH`.** The alternates copy from (a) again, this time run with a
  `PATH` whose first entry is a `0700` directory under `$tmp` holding one executable
  named `find` that touches `$tmp/poison-marker` and exits 0 printing nothing — the
  shape that would make every copied `find` predicate report "nothing found". Set it
  around the one call and put it back, rather than in a subshell (the suite's `pass`
  counter is a plain shell variable): `saved_path=$PATH`, `PATH="$tmp/poison:$PATH"`,
  the `expect_outcome` call, `PATH=$saved_path`. Then assert the second half:
  `[ ! -e "$tmp/poison-marker" ] || fail poisoned-find-executed` — the driver must
  never have run the planted `find` at all, not merely have survived it. The driver
  needs nothing from the inherited `PATH`: it takes the pinned jq and the closure
  helper as explicit arguments (`shadow-slice.test.sh:338-340`), copies that jq into
  `$scratch/bin` itself, and sets `PATH` on the invocation at each of the four sites
  that need one — so the test's own `$bin` entry, which sits behind the poison
  directory here and is exported at `shadow-slice.test.sh:56`, keeps working for the
  suite's own commands and is irrelevant to the run. This case fails before R7's
  clean entry, which is what fixes `PATH` — the marker appears, and with the hook and
  promisor predicates silenced the run gets further than `environment.unlisted` — and
  passes after.
- (d) **exported shell function.** The alternates copy from (a) once more, this time run
  with `find() { :; }` exported into the driver's environment — the attack `PATH` alone
  cannot stop, since bash resolves a function before it consults `PATH`. Set it around
  the calls and take it back the way (c) does with `PATH`: define the function,
  `export -f find`, make the calls, then `unset -f find` (the suite's own `find` uses are
  absolute, so nothing else in the file is affected). Three assertions:
  - through `run_case` as usual — the driver invoked as `"$reproducer"`, so its shebang
    is honoured — the impure copy is still refused with `environment.unlisted`;
  - the same exported function, and the *positive* inputs of the `reproduced` case
    against `$tmp/source.git`, still gives `reproduced` / `check.failed-at-revision`:
    the clean entry must not break a good run;
  - one more invocation of the impure copy written out directly as
    `/bin/bash "$reproducer" reproduce …` with the function still exported, shaped like
    the existing direct invocations at `shadow-slice.test.sh:565-577` (capture the
    status and stderr; no new helper), asserting the same `environment.unlisted` record.
    This third one is the assertion that earns its place: run that way the
    `#!/bin/bash -p` shebang is bypassed entirely, so only the scrub and the re-exec
    can be what refuses it.

  With R8's copy in place but without R7, the first and third fail: the exported `find`
  silences the same worktrees, promisor-pack and hook predicates R15c's planted binary
  does, and the impure copy walks the gate. The second is a guard rather than a
  discriminator — it must hold before and after, since a neutered `find` makes the
  inventory report nothing, which is also the answer a pure repository gives. Note the
  driver's own `/usr/bin/find` calls are untouched by any of this: a function named
  `find` shadows the bare word only.
- (e) **the clean entry takes nothing the driver needs.** The `reproduced` case's inputs
  once more, run with `TMPDIR` pointed at a directory that does not exist
  (`saved_tmpdir=${TMPDIR-}`, `TMPDIR="$tmp/no-such-tmpdir"`, the `expect_outcome` call,
  then restore — the same set-around-the-call shape as (c)), requiring the ordinary
  `reproduced` / `check.failed-at-revision` record. Before R7 this fails: `mktemp -d`
  under a missing directory returns `E_RUNTIME`. After it, the caller's `TMPDIR` reaches
  nothing, which is exactly the pass-through decision R7 makes, held in place by a test
  rather than by prose.

The first two were reproduced while drafting: each copy resolves the incident
commit and reports root `866a40ce…` — the fixture entry's pinned value — out of
the *other* repository's objects. So each fails before R8 (the run passes the
gate and goes on to sandbox evaluation) and passes after, exactly the regression
this revision closes.
No copy is written to by the run, and the fixture repository's own fingerprint
check (R17) still covers the store they read through.

**R16.** The `missing-revision` case (lines 476-480) changes, and must be retargeted,
not deleted. It runs the fixture incident against an empty bare repository and today
expects `materialization.refused`; under R9 the driver refuses one step earlier
(`environment.unlisted`), since a repository without the incident commit has no root to
report for it — that path is now R14's. `materialization.refused` is covered nowhere
else in the suite, so keep it covered with a source the driver's own checks accept and
the materializer's later ones do not. That must be a check the driver does not copy,
which rules out the `core.bare = false` copy an earlier draft of this spec proposed:
R8 now performs `--is-bare-repository` itself, so that copy would come back
`environment.unlisted` and stop proving anything. Use the un-copied `packed-refs` scan
instead: `/bin/cp -R` the fixture repository and write one line
`<some commit id> refs/replace/<failing_commit>` into the copy's `packed-refs`. Checked
while drafting, that copy passes every predicate R8 copies (bare, allow-listed config
keys only, no `refs/replace` *directory*, no symlink, matching object format) and R9's
root check (`866a40ce…`), and `materialize.sh:343-345` refuses it with `E_SOURCE_GIT`,
which the driver records as `inconclusive` / `materialization.refused`
(`reproduce.sh:306-308`) exactly as before. Rename the case and its `pass` message to
what it now proves; drop the now-unused empty repository. Every other case keeps its
current outcome: they all pass `$tmp/source.git`, which is pure and whose root matches
the pinned entry, and the read-only, identity and staleness guards all run before the
environment decision. Checked while drafting: `$tmp/gone.git` is the only source in the
suite other than `$tmp/source.git`, so no other existing case moves. Any *other*
changed outcome means the change is wrong.

**R17.** Nothing a run touches is written: the existing never-written checks must pass
unchanged — the registry re-digest (same test, near lines 604-610) and the source
repository fingerprint (near lines 100-102 and 601), which now covers a driver that
inventories and reads the source repository directly. Do not edit either; if the purity
inventory or `rev-list` left anything behind in `source.git`, that check is what says
so. The copied predicates write only inside the driver's own scratch (R8's `run_root`).

**R18.** The test's own purity guard on the driver's text is *tightened*, not dropped —
it is the one existing check this revision must edit.
`scripts/test/shadow-slice.test.sh:612-618` greps `reproduce.sh` and fails
`forge-or-network-command` if it finds a forge or network tool, a URL, or `git` followed
by any of `push|commit|apply|update-ref|fetch|clone|init|config` (line 614); line 620's
pass message reads 'the driver reads Git objects only and calls no forge, network, or
model tool'. What that `config` word is protecting against is a driver that *writes*
config — the way a run would quietly redirect `core.hooksPath` or any other setting and
stop being read-only. But it matches on the two words alone, so it also refuses a
*read*, and R8's copy contains exactly one, verbatim from `materialize.sh:314-315`:

```
"${git_env[@]}" /usr/bin/git config --file "$source_config_snapshot" \
  --name-only --list --no-includes > "$source_config" 2>/dev/null ||
```

That lists key *names* out of a bounded copy the driver made under its own `run_root`
(`materialize.sh:301-312`) — never out of the source repository, `$HOME`, or the
machine — and writes nothing. Checked while drafting by running the guard's three
greps over both copied spans: that line is the only hit, in that one clause, and no
other clause fires. So R21's shadow-slice all-pass cannot hold until the guard is made
precise.

Drop `config` from line 614's verb list and give it its own check, which refuses
strictly more than the old one did in every direction that matters:

- refuse `git config` carrying `--global`, `--system`, `--local` or `--worktree` —
  each of those reaches outside the snapshot, to read or to write;
- refuse `git config` with no `--file` at all — that is the repository's own config;
- refuse a `--file` argument that is anything other than `"$source_config_snapshot"`,
  the driver's own scratch copy;
- refuse any writing form on a `git config` line: `--add`, `--replace-all`, `--unset`,
  `--unset-all`, `--edit`, `--rename-section`, `--remove-section`, or a bare
  key-and-value pair;
- allow exactly the two lines quoted above, and require them exactly once — `git
  config` occurs once in `reproduce.sh`, and that occurrence is the copied read-only
  listing. Pinning the allowed form to the copy's exact text is deliberate: it is a
  verbatim copy (R8), so a reflow or an edit of those lines should trip the guard and
  be looked at.

Assertion form, since the file has no mutation harness for shell text (`mutate`, lines
274-279, is jq over JSON): factor the check into a helper beside the existing ones —
`config_guard_ok <path>`, returning nonzero on any refusal above — and call it twice.
Once on `$reproducer`, which must pass. Once on a mutated copy under `$tmp`, made with
`/bin/cp` plus one appended line `git config --local core.hooksPath "$scratch/hooks"`,
which must be refused; `fail config-guard-permissive` if it is not. `reproduce.sh`
itself is never edited, so R17's component digests still hold. The pass message
becomes: the reproducer reads git config only from its own bounded snapshot copy and
never writes.

**R19.** Nothing else under `shadow/v1/` changes — not the `.jq` programs, not
`validate-incident.sh` — and no adapter changes: `materialize.sh` is cited and copied
from, never edited; its own checks stay exactly where they are, as the second line of
defense behind the driver's copy. `ci/required-files.txt` is unchanged: the registry
path is already listed and no new file is added.

**R20.** The doc passages that count the entries, plus the two describing what the
driver enforces, are updated, with no other prose change. Confirm each by grepping
`shadow-environments`; line numbers are indicative.
- `docs/components.md` ~1194 — "starts with exactly one entry" becomes two, named with
  scope and proof state, and states both bindings: an entry authorizes an environment
  for one target repository id *and* one source repository, named by its root commit.
- `docs/components.md` ~1203 — "the claim's document id is listed in the environment
  file" becomes listed, bound to this incident's target repository id, *and* run
  against a plain source repository — no alternates, no `commondir`, nothing pointing
  outside it — whose root commit is the entry's, matching R6, R8 and R9.
- `docs/components.md` ~1247 — the fixture-proof-only paragraph must not read as if no
  self-host environment is listed: it is listed and unproven, its proof a later step.
- `docs/transition.md` ~65 — "lists exactly one execution environment" becomes two,
  both `unproven`, so "nothing has ever run against a real target" stays true.
- `docs/transition.md` ~183 — the "added by its own reviewed PR" sentence notes the
  self-host environment is now listed and the external-target one is not.
- `docs/transition-kit.md` ~247 — "must first be listed" becomes "is now listed", the
  run itself still gated.

**R21.** Proof: shellcheck 0.11.0 `-x -S style` clean on both edited shell files
(`shadow/v1/reproduce.sh`, `scripts/test/shadow-slice.test.sh`), `bash
scripts/test/shadow-slice.test.sh` all-pass, `bash
scripts/test/scope-qualification.test.sh` 0 failures, `bash
scripts/test/portable-core-schema.test.sh` 0 failures, `bash scripts/check-rename.sh`
clean, required CI green — shellcheck included on the new shebang and the clean-entry
block, with no new `shellcheck disable` directive added to the file. Additionally, the
copies are proven to be copies. For R8's
two predicate spans, that is byte equality: extracted from `reproduce.sh` between the
copy header and its end marker, they compare equal to `materialize.sh:271-332` and
`348-354` at the cited commit. For R7's clean entry, which is adapted rather than
byte-identical, show a diff against `materialize.sh:4-13` and `22-29` at the same commit
and check that every hunk in it is one of the six deviations R7 names — the marker word
and verb, the argument count, the `-p` shebang, the script-path normalization, the
omitted `set -euo pipefail`, and where the dispatch sits — and nothing else. Show both
comparisons in the PR body. The all-pass includes R18's two calls — the tightened guard
accepts `reproduce.sh` as shipped and refuses the `--local` mutation of it — R15c's
second assertion, that the planted `find` was never executed, and R15d's three
assertions, of which the `/bin/bash "$reproducer"` one is the only proof that the scrub
and re-exec work where the `-p` shebang does not apply.

**R22.** Size: about 300–320 changed lines across the same six files
(`shadow/v1/shadow-environments.json`, `shadow/v1/reproduce.sh`,
`scripts/test/shadow-slice.test.sh`, `docs/components.md`, `docs/transition.md`,
`docs/transition-kit.md`). The earlier estimate was ~150, then 275–295; R8's copy and
its name bindings add about 75 lines to the driver, R15's five cases plus R16's rewrite
about 60 to the test, R18's tightened config guard with its mutation call about 10 more,
R7's clean entry about 20 to the driver (the two copied blocks, the copy header, and the
script-path normalization), and R9's status capture about 5. That is inside the
~300–400 net-line soft budget in `AGENTS.md:103`, at the low end of it, so
`review_size: standard` still stands and no exception is claimed. Two of the three
biggest blocks — R7's entry and R8's spans — are copies of reviewed code a reviewer
checks by diffing against the original rather than by reading them as new logic, which
is faster than the line count suggests. If the implementation lands above 400 lines,
stop and re-decide the size with the operator rather than splitting the gate across
PRs — the clean entry and the four driver edits are one concern and must not ship
apart.

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
2. **Clean entry, before any other driver edit (R7).** Copy `materialize.sh:4-13` into
   `shadow/v1/reproduce.sh` above its `set -uo pipefail`, change the shebang to
   `#!/bin/bash -p`, and copy `materialize.sh:22-29` over the existing arity line
   (`reproduce.sh:61`), with the marker `__reproduce_clean`, thirteen arguments, the
   relative-path normalization from `reproduce.sh:94-95` in place of the materializer's
   `E_USAGE`, and without `materialize.sh:15`'s `set -euo pipefail`. Put the copy header
   on it, naming both line ranges at the cited commit. Do this on its own and run the
   suite: everything must still pass with no other change, which is what says the entry
   cost the driver nothing. Only then paste into the file anything that depends on it.
3. **Driver, four small edits on top of the clean entry, nothing else.** Extend the
   `E_RELATION` shape jq (`shadow/v1/reproduce.sh:182-188`) with R5's two string
   checks. Hoist the `git_env=(…)` array (today at
   `shadow/v1/reproduce.sh:338-341`) to just above the environment decision and add
   the hook pin and `GIT_GRAFT_FILE="$scratch/no-grafts"` — `$scratch` is the
   driver's own mktemp directory (lines 120-122) and nothing
   creates `$scratch/no-grafts` or `$scratch/no-hooks`. Paste the two verbatim spans
   into `source_pure()` with its copy header and its name bindings (R8). Then replace
   the single `if` at `shadow/v1/reproduce.sh:267-269` with a gate that leaves the
   sandbox block below it untouched and unindented — purity first, then identity, then
   the existing evaluation:

   ```
   environment_listed=no
   if <R6 lookup>; then
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

   The extra `VAR=value` words sit between `git_env`'s `/usr/bin/env -i` and the
   command, so they are that one command's environment and no other caller of
   `git_env` is affected. The exact shape of the three conditions is R9's; what the
   sketch shows is that the status is captured on the same statement as the output and
   checked beside it, and that the text must be one 40-character run of `[0-9a-f]` — a
   second root puts a newline in the variable and the `case` pattern refuses it. The
   `-n` guard on `entry_root` is belt and braces: R5 already makes `source_root_commit`
   40 hex on every entry. The `head -c` bound keeps a repository with very many roots
   out of a shell variable; a truncated list fails the shape check, and the `SIGPIPE`
   that bound can cause fails the status check.
   The driver touches `$source_git_dir` before this point only for path checks
   (`physical_dir` line 83, `check_disjoint` lines 87-89) — no git command, no read of
   its contents — so `source_pure` is its first look at the source repository, and it
   happens before anything is evaluated, materialized or executed.
4. **Test.** Turn `registry-contents` into a full-document byte comparison with the
   fixture root computed from the fixture repository (R12), update its pass message,
   add the seven new cases (R13, R14, R15a, R15b, R15c, R15d, R15e), and retarget
   `missing-revision` (R16). The pin must fail before step 1 and pass after; R13's case
   must fail before the lookup edit, R14's before the root check, R15a and R15b before
   the purity copy, and R15c, R15d and R15e before the clean entry that fixes `PATH`
   and scrubs the environment — and all of them pass after. That ordering shows each
   edit does what it claims. In the same step, tighten the `git config` guard into
   `config_guard_ok` and add its two calls (R18) — do this *with* step 3's copy, not
   after it, since the guard as it stands fails the suite the moment the copied read
   lands.
5. **Docs.** The six passages, nothing else.

**High-risk path, before any of the above.** Draft `work/shadow-env-self-host/plan.md`
on `ystack/plan/shadow-env-self-host` as a plan-only PR (`Tracks #263`), get
independent review and green CI, and let the operator merge it; record the merged
default OID as `plan-base`. Only then create `ystack/impl/shadow-env-self-host` from
updated main and write code there. That PR is the one using `Closes #263`.

## Out of scope

- Any shadow run. Listing an environment only permits one.
- Any driver change beyond R7's clean entry and the four edits in R5, R6, R8 and R9:
  no new reason id, no new record field, no reordering of the driver's stages, no
  change to the read-only guards or the error codes, and no change to the materializer.
  In particular the clean entry is copied as it stands and not improved on: no `-e`
  added to the driver's `set`, no new argument to carry `TMPDIR` or anything else in,
  and no second marker verb.
- Any registry field other than the two this change adds. R1, R2, R5 and R6 add
  exactly `target_repository_id` and `source_root_commit` to each entry, and nothing
  else: no third new key on an entry, and no new field in the registry header, which
  R3 leaves as it is.
- Strengthening or relaxing the copied predicates. They are copied, not authored here;
  changing what counts as a plain source repository is a materializer concern with its
  own review. If the copy reveals a gap in them, file it, do not fix it in the copy.
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
- **The root commit alone was still bypassable — the third P1.** The check reads the
  root "from the repository", but which object store the repository answers from is
  itself something the directory decides. An `objects/info/alternates` file, or a
  `commondir` file, makes git resolve both the
  incident commit and the authorized root out of a store that is not in the supplied
  directory; `GIT_OBJECT_DIRECTORY` and `GIT_ALTERNATE_OBJECT_DIRECTORIES` do it from
  the environment. Reproduced while drafting: a copy of the fixture repository holding
  none of its objects reports the fixture's exact root through either file. Such a
  source would have passed the gate and gone on to sandbox evaluation and
  materialization instead of stopping at `environment.unlisted`. The environment half
  of that was already closed — `git_env` begins with `/usr/bin/env -i`, and the
  env-based bypass that works with a plain `git` fails under it — but the on-disk half
  was open, and it is the half a caller controls by handing over a directory. R8 closes
  it by checking the directory is plain *before* asking it anything, and R9 names the
  environment variables explicitly so the closed half stays visibly closed.
- **A copied check carries its environment with it — the fourth P1.** The two spans
  are safe in the materializer partly because of what surrounds them: every
  `materialize` invocation re-execs through `/usr/bin/env -i PATH=/usr/bin:/bin
  LC_ALL=C` (`materialize.sh:26-27`), so the three bare `find`s at
  `materialize.sh:327`, `331` and `348` are `/usr/bin/find` and can be nothing else.
  `reproduce.sh` had no such wrapper and no `PATH` of its own, so the copy would have
  run those three under the caller's `PATH`, before the binding and before the sandbox
  evaluation — a planted `find` that exits 0 silently turns three refusals into three
  passes. That is the same failure as the third P1 in a different coat: a check
  reading something the caller controls. R15c plants a `find` on `PATH` and asserts it
  is never executed, and the rule "every command word in the copy must resolve under
  `PATH=/usr/bin:/bin`" is written down so the next span copied in is checked against
  it. The general lesson for future copies: copy the predicate and the environment it
  assumed, or prove the destination already provides it.
- **Functions are looked up before `PATH`, which is why the fix is the producer's whole
  entry and not a `PATH` line — the fifth P1.** An earlier revision of this spec fixed
  `PATH` at the top of the driver and stopped there. That closes only the outer door.
  Bash resolves a command word by looking for a shell function first, and a function
  arrives from the caller for free: `find() { :; }; export -f find` and the copied
  `find` predicates are silent again, with `PATH` untouched and looking correct. The
  same trick fits `head`, `wc`, `tr`, `rm` and `grep`, and `IFS`, `BASH_ENV` and
  `SHELLOPTS` are the same idea aimed at the shell rather than at a command. `unset -f
  find` before the copy would have been the small local fix, and it is the wrong one
  twice over: it is a list of names someone has to keep in step with the copy, and it
  leaves the driver differing from the producer at exactly the point where the copy's
  safety comes from the producer's surroundings. So R7 takes the materializer's entry
  instead — scrub every function and every exported variable, then re-exec the script
  through `/usr/bin/env -i` — which is a property (nothing is inherited), not an
  enumeration (these names are not inherited). It also puts the driver and the adapter
  on the same entry convention, so a reviewer reads one pattern in two files and a
  future copy between them stays honest. The cost is a re-exec per run and one
  inherited variable given up (`TMPDIR`, see R7); both are cheap for a gate.
- **Reading only stdout is half a check.** The root lookup asks git a question and
  compares the answer, and an earlier revision of R9 compared the text alone. Under
  `set -uo pipefail` with no `-e`, a git that fails says so only in its exit status, and
  the usual case — it fails and prints nothing — happens to compare unequal, which is
  what made the gap easy to miss. The case that does not is a git that prints a root and
  then dies, and a gate that accepted that would be authorizing on a partial answer. So
  R9 requires the status, the shape and the value together. The general form of this
  one: when a check's evidence comes from a command, the command's success is part of
  the evidence.
- **Order is the whole point.** Purity, then identity, then evaluation. A check that
  runs after the gate does not protect the gate: the materializer already refuses
  alternates, `commondir`, grafts, replace refs, `shallow` and promisor packs
  (`materialize.sh:326-332`), but it runs only once the run is authorized, so its
  refusal would have been a refusal *after* an unauthorized source had been accepted as
  the authorized one. Those checks stay exactly where they are — nothing is removed
  from the materializer — and now run twice: once by the driver deciding whether the
  entry applies, once by the adapter deciding whether to materialize. Defense in depth,
  with the copy keeping the two from ever disagreeing.
- **A copy can rot, so it is a copy and says so.** Re-implementing the predicates would
  have let the gate and the adapter drift into two different ideas of a plain
  repository, which is how a bypass comes back. The verbatim copy with the
  `qualified-identity.jq` header, and R21's requirement to prove the bytes match the
  cited commit in the PR, make drift visible instead of silent. It is still a real
  maintenance cost, accepted for the same reason `qualified-identity.jq` accepted it.
- **Why the root commit is a verified identity, once the source is plain.** The driver
  computes it with git from the object bytes in the directory it was handed, starting
  from the incident's own commit — not from any field a caller wrote. Commit ids are
  content-addressed, so a repository cannot present the incident's commit id without
  holding that exact object with that exact history, and cannot report ystack's root
  without holding ystack's root commit object with the incident commit descended from
  it. "Holding" is exactly what R8 establishes: with no alternates, no `commondir` and
  no graft file, the objects git reads are the ones in that directory.
- **What the root commit does not prove, stated plainly.** It proves the incident's
  commit descends from ystack's root; it does not prove the directory is a clone of the
  ystack remote. ystack is public, so someone could build a repository holding its real
  root commit and hang a fabricated commit off it, and that repository would pass R8
  and R9. The limit is accepted here because it is strictly narrower than today (an
  unrelated repository — the actual P1 — is now refused), because nothing available to
  the driver on a local bare directory does better (every ref, config value and object
  outside the content-addressed chain is equally caller-supplied), and because the run
  this authorizes is read-only, network-denied and non-authoritative: one revision
  materialized, one blob digested, an inconclusive-by-default record. Anything stronger
  belongs to the run initiative, where the operator names the path.
- **Grafts, and why `GIT_GRAFT_FILE` is in R9.** `info/grafts` rewrites the parent
  links git reports, so without neutralizing it the root a source repository reports is
  a value that repository chooses. Reproduced while drafting: the same commit reports
  `52022bc4…` with a graft in place and `866a40ce…` with `GIT_GRAFT_FILE` set to a path
  that does not exist. R8 also refuses an `info/grafts` file outright; both stay,
  because the env variable protects the lookup even if the copy is ever narrowed, and
  a gate should not be satisfiable by the thing it gates. Replace refs are already
  neutralized by `--no-replace-objects` and `GIT_NO_REPLACE_OBJECTS=1`.
- **The one existing case that moves, and the coverage it was holding.**
  `missing-revision` is the only case in the suite that does not use `$tmp/source.git`,
  and it is the only holder of `materialization.refused`. R16 keeps that coverage using
  the one source check the driver deliberately does not copy — the `packed-refs`
  replace-ref scan — and explains why the `core.bare = false` copy an earlier draft
  proposed no longer works now that the driver runs `--is-bare-repository` itself. That
  is the cost of purity-first, paid once and visibly: the set of sources the driver
  admits and the materializer then refuses is smaller, so a test for the materializer's
  refusal has to reach for a narrower one.
- **A pinned sha in an authorization file can go stale.** R12 answers that for the
  fixture entry: the test computes the root and byte-compares the whole registry, so
  the pin cannot drift from the builder without a red test. The self-host sha cannot
  drift at all — a root commit is fixed for the life of a history, and were ystack's
  ever rewritten the entry would stop matching and self-host runs would go
  `environment.unlisted`: refusing, not running.
- **The gate now does real work on a caller-supplied directory.** R8 inventories every
  entry under `$source_git_dir` and reads its config before the run is authorized. The
  copied predicates carry their own bounds (8388608 bytes, 65536 entries, a 1 MiB
  config) and treat any excess as a refusal, and everything they write goes to the
  driver's own scratch, so the cost is bounded and nothing under the source directory
  changes — R17's fingerprint is what proves the last part. This is more work before
  authorization than the driver did before, and it is the price of deciding
  authorization from the bytes rather than from the caller's word.
- **High risk, and not because of size.** The registry is an authorization list:
  `reproduce.sh` refuses to run in an unlisted environment, so this file is the control
  deciding where the driver may execute — and this change edits that driver's
  enforcement and adds the first commands it runs against a caller-supplied directory.
  `work/README.md` classes security controls as high risk, so widening that list is
  high risk however small the diff — hence the plan-only PR, independent review, and
  operator merge. Do not re-argue it as routine on size grounds. What it widens: a
  read-only shadow run against ystack's own source, the intended step-7 unblock, but a
  real widening of the driver's allowed execution surface and the first entry that is
  not fixture-only. The three bindings — the documents' repository id, the source's
  purity, and the source's root commit — hold that widening to the documents the entry
  names and to a repository that is plain and carries ystack's own history.
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
