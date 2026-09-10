---
spec-blob: ab212e82359ba3132fa6127194b61fa484bb1a85
drafted: 2026-09-10
---

# Plan: shadow-input-assembler

The spec (`work/shadow-input-assembler/spec.md`, blob above) is the contract and states
requirements 1-18 in full. This plan says which files change, in what order, where in today's
files each piece comes from, what can break, and how each requirement group is proved. Where a
step names a requirement, that requirement's own wording is the detail to follow — this plan does
not restate it. Freshness: the spec's `intent-blob`
`61218c3c9b3554f4a86c58fd3a7311d9e818f3b6` equals `main`'s
`work/shadow-input-assembler/intent.md` at `986531a`, so the spec is current against the merged
intent.

## Files that change

Seven files, nothing else. Counts are net changed lines, honest estimates.

- **`shadow/v1/materialization-input.jq`** (~200, new). The eight digest pins and their header
  (~15); document construction mirroring the fixture builder — contract, six manifests, profile
  pair, resolved-profile pair, the four decision-record scope refs, stage request, then the input
  wrapper (~130); requirement 3's id and digest checks plus requirement 16's `config_source` walk
  (~40); the two `pair_ref` projections (~15).
- **`shadow/v1/assemble-materialization-input.sh`** (~248, new). The copied clean entry with its
  header and the assembler's own `set`/`emit_error`/`umask` lines (~30); step 2.2's seven ordered
  argument, workspace and pinned-jq checks, including the copied `physical_dir` helper that both
  that step and 2.4's source check call (~58); requirement 10's `time_ok` call with its split
  status handling (~15); reading and canonicalizing the five inputs (~25); the `run_root` path,
  the trap with its `committed` guard, the flag and destination-list initialization, the `mkdir`,
  the source `physical_dir` check, and the
  `git_env`/`git_dir`/`source_algorithm`/`source_commit` bindings (~24); `source_pure`
  with the three verbatim spans and the copy header (~95); the algorithm and root-tree reads, the
  size check, the stage step, and the commit step with its closing `committed=yes` (~33). Roughly
  136 of those are copied lines that must not be edited here.
- **`scripts/test/shadow-assembler.test.sh`** (~355, new). jq bootstrap and scaffolding (~40);
  the `sha1` and `sha256` fixture repositories (~30); the resolved profile built over the shipped
  documents (~45); the positive assertion groups including the driver run (~70); the negative
  sources and the one case per refusal class (~116); the copy, pin-liveness and source-order
  assertions (~55).
- **`docs/components.md`** (~35). One new "Inactive shadow materialization input assembler"
  section after the existing `## Inactive shadow reproduction slice` section (line 1175).
- **`README.md`** (1). One index row beside the shadow slice row at line 288.
- **`RESTORE.md`** (~20). One restore block in the shape of "Restore the inactive shadow
  reproduction slice" (lines 200-221), naming `scripts/test/shadow-assembler.test.sh`.
- **`ci/required-files.txt`** (~5). A blank line, a section comment, then the three new paths,
  appended at the **end** of the file after today's last line `docs/transition-kit.md`
  (requirement 14).

Estimate total: about 865 net lines.

**Implementation PR figure — `review_size: accepted-exception`**, as the spec records it. One
concern: one inactive component whose focused test must drive the real `reproduce.sh` end to end
over fixture ground it has to build first. Range **610-840 net lines** — about 430 of component
(jq plus shell), about 330 of test, and the documentation rows. **The estimate above no longer sits
inside that range.** This round's physical-source check and its one-case-per-refusal-class cases
add about 35 lines to the 830 an earlier draft estimated, so the honest figure is about 865 — just
past the top. The range is the **spec's**, so widening it is the operator's call and not the
coder's, and requirements 12 and 13 are what the added cases serve, so they are not the thing to
trim to fit. Take the count when the test lands rather than at the end, and if it is over 840, stop
there. Roughly 130 of the total is copied text this initiative did not write. The
exception waives only the soft line signal in `AGENTS.md:102-106`; readability, tests, CI, review,
the high-risk gate and operator merge are unchanged. **Above 840, stop and re-decide with the
operator** rather than splitting: the component and its focused test are one concern, and
requirement 17's entry is the first lines of the same script as requirement 15's predicates.

**Artifact PR figure — size exception for this plan PR itself, not the implementation.** This
file is 724 lines by `wc -l`, self-inclusive of this paragraph as committed, so this artifact
PR carries the same ~300-400 net-line soft budget as any other and would otherwise read as an
unexplained overrun under `AGENTS.md:102-106`. One concern: one high-risk plan whose copy and
proof instructions carry exact line ranges and commands for a 1600-line spec, and whose refusal
order and success-path guarantee are each spelled out step by step because both are one line's
position away from being wrong. Evidence-based
range **615-833 net lines** — the measured count above, plus or minus 15%. This exception waives
only the soft line signal for this artifact PR. Scope (still one concern), readability, review,
CI and operator merge are unchanged, and it grants nothing to the implementation PR, whose own
figure is the 610-840 range recorded above.

**What does not change.** `shadow/v1/reproduce.sh`, `adapters/local-git-materializer/v1/**`
(`materialize.sh` and `protocol.jq` both), `core/v2/**`, `profiles/default/v1/**`,
`scripts/test/local-git-materializer-fixtures.sh`, `scripts/test/shadow-slice.test.sh`,
`shadow/v1/shadow-environments.json`, `scope/v1/**`, and everything under `work/**` once this
plan's PR merges. The assembler adds a producer of an input those components already consume; it
adds no error id, no reason id and no record field. The eight profile documents are read as data
and their digests copied; their bytes are not touched.

## Order of work

### Step 0 — the test, before any behavior (requirement 13)

Write the whole of `scripts/test/shadow-assembler.test.sh` against the finished behavior. It does
not pass at the end of this step. Run it once and paste the single `FAIL:` line it prints; the
`fail` helper exits on the first failure, the way `scripts/test/shadow-slice.test.sh:19` does, so
one run names one case.

0.1 **Scaffolding.** Copy the pinned-jq bootstrap from `scripts/test/shadow-slice.test.sh:1-56` —
the platform case with the two release digests, the shared cache under
`${TMPDIR:-/tmp}/ystack-portable-core-jq16`, the `curl` fetch with a digest check, the copy into
`$tmp/bin/jq` at 0555, and the `jq-1.6` identity assertion. Take `git_clean` from lines 70-79 and
`fail`/`pass`/`sha_file` from lines 19-23 unchanged. Step 0.7's driver run also needs the
`object-closure` helper compiled the way lines 52-55 compile it.

0.2 **Two fixture repositories.** Build the `sha1` bare repository the way
`scripts/test/shadow-slice.test.sh:81-98` does (`git_clean init -q --bare --object-format=sha1`,
`hash-object`, `mktree`, `commit-tree`) and a second one with `--object-format=sha256`, the shape
`scripts/test/local-git-materializer-adapter.test.sh:973-981` already builds. Keep each commit's
root tree id, since 0.4 asserts the widths follow the repository.

0.3 **A resolved profile over the shipped documents.** Follow
`scripts/test/local-git-materializer-fixtures.sh:103-117` — the `-L "$fixtures"` import of
`portable-core-profile-graph-fixtures`, `f::resolved_profile_doc`, the `v2` walk, and the
per-binding rewrite — but over `profiles/default/v1/profile.json` and the six manifests in
`profiles/default/v1/manifests/`, not the five synthetic manifests that builder invents. One
change the existing builders do not have: where line 114 writes `config_source={state:"absent"}`
for every binding, the producer binding here carries a present `config_source` whose
`value.source` is the binding's own `config_ref` and whose `value.value_sha256` is the real
SHA-256 of `profiles/default/v1/producer-config.json`
(`ea076206d7f721aa4796c2a0830e95b3c7006703addc717240447c64ad589b61`) — not the stand-in digest
`scripts/test/default-profile-assembly.test.sh:310-311` reuses, which requirement 16 refuses.
Pass the existing fixture claim — built the way `scripts/test/shadow-slice.test.sh:128-194` builds
`policy-set.json`, `duty.json` and `claim.json` — as the ninth argument.

0.4 **The positive assertion groups**, each from requirement 13: `validate-input` accepts the
output; a second run is byte-identical; the read-only shape holds in `.payloads` and
`.trust_context.verified_payloads` and `network_mode` is `deny`; `environment_ref.environment_id`
equals the claim's `.id` and `fingerprint_sha256` equals the SHA-256 of the claim file's bytes;
the two `pair_ref` documents equal what `shadow/v1/reproduce.sh:250-256` compares; and both
algorithms are covered — `target_revision.hash_algorithm` and the commit and tree id widths
follow the repository in each case, and a 40-hex commit id offered to the `sha256` repository is
`E_TARGET`. Then the success half of requirement 18's guarantee, which is the runtime proof of
2.7's flag: after the successful run the output directory holds **exactly** the seven documents
and no `run_root`. Assert the listing, not just that `input.json` exists — a trap that deletes
what it committed leaves a directory that is empty rather than wrong, and only a full listing
catches that.

0.5 **The negative cases**, one per refusal in requirement 12, plus the four negative source
repositories requirement 13 names, each otherwise a clean copy of the `sha1` fixture: a disallowed
config key (`remote.origin.url` set), a non-`*.sample` file under `hooks/`, a `packed-refs`
carrying a `refs/replace/<commit>` line, and a head commit whose message exceeds 1 MiB so its
commit object trips `materialize.sh:359-360`. All four are `E_TARGET`, the last pinned as
`E_TARGET` and not `E_LIMIT`. Beside them a fifth source case, which is not a bad repository but a
bad path: a **symlink** to the good `sha1` fixture, passed as `<source-git-dir>` — `E_TARGET`,
refused by 2.4's `physical_dir` check before `source_pure` runs, because git follows the link
without complaint and every copied guard then passes on the target. Then: the exported-function
cases (`find() { :; }; export -f find`,
and the same for `grep`) against the `hooks/` repository and against the good fixture, each run
through the shebang form **and** as `/bin/bash <script> assemble …`; the `BASH_ENV` alias case
through a supported form only; `2026-02-30T00:00:00Z` → `E_USAGE` and `2024-02-29T00:00:00Z` → a
normal run; the unreadable modules directory (`chmod 000`, restored afterwards, or a module path
with no `schema.jq` if the test runs as root) → `E_RUNTIME`; the claim of the wrong kind, the
out-of-charset claim id and the non-canonical claim; a `profile.json` whose id is not
`profile.default.v1`; the self-consistent look-alike profile set that reuses the id but differs in
bytes → `E_PROFILE`; and the resolved profile whose producer `config_source.value.value_sha256` is
swapped while `value.source` is left alone → `E_PROFILE`. Then the pair that pins 2.2's order,
written as a pair on purpose because either one alone passes under the wrong order: a **relative**
`<jq-binary>` path → `E_USAGE`, and a jq at an absolute path that looks right and whose SHA-256
does not match the platform pin → `E_RUNTIME`. Add the same pairing for the other cheap checks
whose argument is refused while some later `E_RUNTIME` condition is also true in the same run — a
bad repository id and a malformed commit id, each offered alongside an unreadable modules
directory, still `E_USAGE`. Also the refuse-then-retry pair: after
the `hooks/` refusal the output directory exists and holds nothing at all, and a rerun into it
with the good fixture assembles normally rather than failing `E_WORKSPACE`. Add no case that
invokes `__assemble_clean` directly, and write the negative-knowledge sentence requirement 13 asks
for beside the alias case.

**One case per refusal class, each asserted by id.** Requirement 12 names ten classes, and the
cases above leave four of them with no case at all. Write them beside the others, and keep the list
in the test in this order so a reader can check the coverage off against requirement 12 without
reading the whole file.
- `E_USAGE` — the relative `<jq-binary>`, the bad repository id, the malformed commit id and
  `2026-02-30T00:00:00Z`, all above.
- `E_TARGET` — the four negative sources, the symlinked source directory and the 40-hex commit
  offered to the `sha256` repository, all above.
- `E_WORKSPACE` — **new.** One file `touch`ed into the output directory before the run, so it is
  not empty. This is the class the refuse-then-retry pair asserts the *absence* of; it needs a case
  that produces it too, or nothing proves 2.2(6) can say it at all.
- `E_RUNTIME` — the unreadable modules directory and the wrong-digest absolute jq, both above.
- `E_LIMIT` — **new, two cases, one per half of the class.** (a) The caller's own file: a copy of
  the fixture claim padded past 1 MiB by a valid JSON string field of a million `x`, refused at the
  claim's `snapshot_bounded` bound before it is parsed, so its shape does not matter. (b) The
  finished output over the driver's 8 MiB cap: pad the supplied **resolved profile**, which is the
  one caller-supplied document whose entire content is embedded in `input.json`
  (`scripts/test/local-git-materializer-fixtures.sh:170`), by repeating shape-valid
  `skill_sources`/`tool_sources` entries under distinct ids with `config_source: {state:"absent"}`
  — absent, so requirement 16 has nothing to check and the refusal is the size check's and not
  its — until the finished document would cross 8388608 bytes. That is the only lever the test has
  on the output size: everything else in the seven documents is pinned bytes or fixed text.
- `E_PARSE` — **new, two cases**, the two conditions the canonicalizer names: a
  `<resolved-profile-file>` holding two JSON values rather than one (`printf '{}{}'`), and a claim
  file that is the good claim's bytes with a UTF-8 BOM prepended.
- `E_CANONICAL` — the non-canonical claim, above.
- `E_SHAPE` — the claim of the wrong kind and the out-of-charset claim id, above.
- `E_PROFILE` — the look-alike profile set, the wrong `profile.json` id and the swapped
  producer-config digest, all above.
- `E_RELATION` — **new.** A profile set that is internally inconsistent while every document in it
  is individually well-shaped and correctly pinned: rewrite one binding's `manifest_source` digest
  in the resolved profile to another supplied manifest's real SHA-256, so each document passes its
  own checks and the set does not hold together. The class's **second** half — the finished input
  failing the staged `validate-input` — gets no case, on purpose: no input that passes 2.2-2.6 can
  reach a failing `validate-input`, and the only way to force one is the test-only hook the
  Alternatives reject. It is covered by review instead — the `|| emit_error E_RELATION` on 2.7's
  staged call, read once, plus 0.4's positive assertion that a good run's staged check exits 0.
  Say that in the test beside this case, the way requirement 13's negative-knowledge sentence is
  said beside the alias case, so the gap is recorded rather than merely absent.

0.6 **The three source-derived assertions**, which read files rather than run the assembler.
(a) **The pins are live**: recompute the SHA-256 of each of the eight files under
`profiles/default/v1/` in the working tree and require it to equal the pin the jq program carries.
(b) **The copies are copies**, by the commands the Proof section spells out: anchor each span on
its own first line (exactly one match, at 76, 271, 333, 348, 4 and 22), bound its end by the
extracted block's own length (81, 332, 347, 360, 13 and 29), `cmp` the three spans, the
`physical_dir` helper and the scrub, and diff the
entry so every hunk is one of the four named deviations and nothing else. Never anchor on a span's
last line — `emit_error E_SOURCE_GIT`, `fi` and `emit_error E_SOURCE_LIMIT` each appear several
times — and never read a past commit: a default-depth `actions/checkout`
(`.github/workflows/ci.yml:15`) has no ancestor objects.
(c) **The orders**: in `shadow/v1/assemble-materialization-input.sh`, the `physical_dir` call on
`$source_git_dir` appears exactly once and on an earlier line than the `source_pure` call, so a
symlinked source cannot reach the copy; the `trap` lines naming
`run_root` are on earlier lines than the `mkdir` that creates it; every `mv` whose destination is
the output directory is on a later line than the last check including the staged `validate-input`;
the `mv` of `input.json` is the last of those; each destination's list-append is on an
**earlier** line than its own `mv`; and the `committed=yes` assignment appears exactly once, on a
**later** line than the `mv` of `input.json`, with the trap body's removal of listed destinations
guarded by that flag while its `rm -rf` of `run_root` is not.

0.7 **The driver run.** Feed the assembled `sha1` input to `shadow/v1/reproduce.sh` with the
fixture environment, policy set, duty and the same claim file, using the thirteen-argument
invocation `scripts/test/shadow-slice.test.sh:338-340` uses, and assert the outcome is not
`inconclusive`.

### Step 1 — `shadow/v1/materialization-input.jq` (requirements 3, 4, 5, 6, 8, 9, 16)

1.1 The eight pins as constants at the top, under the header
`# pinned from profiles/default/v1 at 4965175d0edeeec8ba746609e585b053be03e075` — the commit the
spec's table is taken at, replaced with the current commit if the profile moves before this lands.
Copy the digest strings from the spec's table verbatim; do not retype them from a fresh
`shasum` run. Requirement 3's check: the supplied `profile.json` carries top-level `id`
`"profile.default.v1"` first, then each supplied document's digest equals its pin, and the refusal
names the file that differed.

1.2 Requirement 16's rule beside them, because it compares against the same `producer-config.json`
pin and the resolved profile is already parsed here: walk every `config_source` in the resolved
profile that is `state: "present"` — the six bindings' own and every `tool_sources[].config_source`
— and refuse unless the document it names has a pin and its `value.value_sha256` equals that pin.
`config_source` is a present-or-absent wrapper (`schema.jq:155-159`) whose `value` is a
`source_value_ref` (`:368-373`), so the digest is two levels down.

1.3 Document construction, mirroring `scripts/test/local-git-materializer-fixtures.sh` in its own
order — contract (~31-38), manifests (~49-72), profile pair (~83-99), resolved-profile pair
(~103-118), stage request (~119-153), then the input wrapper with `payloads` and `trust_context`
(~155-188). Six manifests, not five. Anything lifted from a producer sits verbatim under a
`copied from <path> at <commit>` header, the convention `loop/v1/review-fix-planner.jq:1-3` uses.

1.4 The read-only facts of requirement 4: `input.producer-patch` data is `""` in `.payloads` and
in `.trust_context.verified_payloads`, and the empty-content digest
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` goes wherever the fixture
builder puts the patch digest — the verified payload's `sha256` and the stage request's
`input.producer-patch` content ref. `network_mode: deny`. Those are the three facts
`shadow/v1/reproduce.sh:241-246` reads.

1.5 The protocol minimum of requirement 5: `allowed_paths: [".ystack/never-written"]`,
`max_patch_bytes: 1`, `max_changed_paths: 1`.

1.6 Requirement 6's four decision-record texts as outputs, each with its real SHA-256 and
`scope_sha256` equal to `decision_record_ref.sha256` — the convention `evals/v1/framework.jq:36`
uses. `finish_condition` and `verification_instruction` are `delivered_scope_ok`
(`schema.jq:375-380`), so each carries a `ref` plus an `input_id`; the output contract is
`operation.arguments.materialization_contract.ref`; the policy ref sits in the risk claim, the
shape `scripts/test/portable-core-stage-request-fixtures.jq:210` shows. `selection_ref` and
`repository_context_ref` are copied unchanged from the resolved profile, and `requested_by` is
projected from the resolved forge binding.

1.7 `environment_ref` from the claim (requirement 7): `environment_id` from the claim's `.id`,
`fingerprint_sha256` from the SHA-256 of the claim's canonical bytes, both arriving as arguments.
The two-field shape is `environment_ref_ok`, `schema.jq:345-348`.

1.8 The two `pair_ref` outputs of requirement 9, `{schema_version, kind, id, sha256}` for
`stage_request` and `resolved_profile`, projected exactly as
`shadow/v1/reproduce.sh:251-254` projects them.

1.9 `stage_request.sha256` is re-digested after the request is finished. The hash algorithm, the
commit id and the tree id arrive as arguments; the program never reads a file and never writes
`sha1` as a literal in the revision it builds (`git_revision_ref_ok`, `schema.jq:266-273`).

### Step 2 — `shadow/v1/assemble-materialization-input.sh` (requirements 1, 2, 10, 11, 12, 15, 17, 18)

Land 2.1 as its own commit before anything that depends on it, the way PR #278 landed the
driver's entry alone: it rewrites the front door while the arity check has to keep meaning what
it means in both entries, and a commit of its own is what makes it bisectable.

2.1 **The clean entry, and nothing before it.** `#!/bin/bash -p` (`materialize.sh:1`), then the
copied scrub `materialize.sh:4-13` at the top of the file under the copy header, then the
assembler's own `set -euo pipefail`, `emit_error` and `umask 077` in the places
`materialize.sh:15`, `:17-20` and `:31` put them — `emit_error` before the arity check, so
`E_USAGE` can be said at all — then the copied `materialize.sh:22-29` with exactly four
deviations: the marker word and verb (`assemble`, `__assemble_clean`); `[ "$#" -eq 10 ]` with the
exec forwarding `"$2"` … `"${10}"`; the script path normalized against `$(pwd -P)` and then
required to be an existing non-symlink regular file or `E_RUNTIME`, the way
`shadow/v1/reproduce.sh:94-96` does; and `builtin unalias -a` plus `builtin shopt -u expand_aliases`
as the first two lines of the marker branch, above every other line in it, because bash expands
aliases as it reads each command and the reset has to run before `source_pure` is parsed.
**Inherit PR #278's bytes for the shared lines.** That PR carries the same scrub and the same
entry in `shadow/v1/reproduce.sh` under `# copy-begin materialize.sh:4-13` / `:22-29` markers;
if it has merged, take the scrub bytes from there rather than retaking the copy, so the two
components hold one text and not two. Use the same `# copy-begin`/`# copy-end` marker convention,
since step 0.6(b) extracts by it.

2.2 **Argument and workspace checks first, then the pinned jq, then `time_ok`.** Nine positional
arguments per requirement 1, checked in seven steps in this order — the order the spec gives at
lines 1217-1219. The order is the point, not a preference: every cheap check below decides
`E_USAGE`, and each has to answer before the component does anything that can only fail as
`E_RUNTIME` or `E_WORKSPACE`. A relative `<jq-binary>`, a bad repository id, a malformed commit id
or a misshapen timestamp is `E_USAGE` under requirement 12, and it cannot be if a digest check has
already refused the same run as `E_RUNTIME`.

(1) **Arity and verb**, decided by 2.1's copied entry before anything else runs.

(2) **Every path argument absolute.** `<source-git-dir>`, `<profile-dir>`,
`<resolved-profile-file>`, `<jq-binary>`, `<output-dir>` and `<environment-claim-file>`, each
matched against `/*` in the shell — a `case` or `[[ ]]` pattern, no external command, nothing
opened, stat'ed or executed. A relative `<jq-binary>` is `E_USAGE` here and never reaches step
(7). Existence and non-symlinkness of those paths are **not** checked here: requirement 12 files a
missing or symlinked required file under `E_RUNTIME`, so those tests sit with step (7).

(3) **The repository id** against `\A[a-z0-9][a-z0-9._:-]{0,127}\z`.

(4) **The commit id** as lowercase hex of 40 or 64 characters. Width against algorithm is not
decided here, because the repository has not been asked yet; the later mismatch against
`git rev-parse --show-object-format` inside requirement 15's copy is `E_TARGET`, not this.

(5) **The timestamp's shape only** — `YYYY-MM-DDTHH:MM:SSZ`, a pure-shell pattern match, no jq —
`E_USAGE`. This is a gate ahead of the rule, not the rule: requirement 10 says the shape alone is
not enough, and step (7)'s `time_ok` still decides whether a well-shaped timestamp is a real
instant. The gate earns its place by making a mistyped timestamp `E_USAGE` even on a run where jq
is the thing that is wrong.

(6) **The output directory**, as an existing, empty, physical `0700` directory disjoint from the
source repository and the profile directory — `E_WORKSPACE`, requirement 1's own shape.

(7) **Only now the pinned-jq checks** — the platform digest table and the `jq-1.6` identity check
`shadow/v1/reproduce.sh:113-118` and `:141-142` use — plus the existence and non-symlink checks of
the remaining supplied paths and of the component's own required files, all `E_RUNTIME`. **Nothing
above this step hashes or executes `$jq_bin`.** Steps (1)-(6) are shell pattern matches and, in
(6), file tests on the output directory alone, so the jq binary is read for the first time here.

Then requirement 10's `time_ok` on the timestamp argument, immediately after the pinned-jq check
and before any input file is opened: resolve the modules directory the way
`materialize.sh:60-69` does (read `PORTABLE_CORE_GENERATION` out of `scripts/core-contract.sh:207`
with `sed`, check the shape, check the generation is in `core/v2/generation-registry.json`, then
`core/v2/generations/$generation/modules`), from a repository root resolved from the script's own
normalized path the way `shadow/v1/reproduce.sh:100` resolves it, and call
`"$jq_bin" -L "$modules" … 'import "schema" as schema; … schema::time_ok'` on that one string —
the load shape `evals/v1/evals-driver.sh:58` and `:161` already use. Capture the exit status and
stdout **separately**, on the command's own failure branch (`|| status=$?`) so `set -e` does not
end the run: status 0 with stdout exactly `true` proceeds, status 0 with stdout exactly `false`
is `E_USAGE`, and everything else — non-zero exit, jq that would not start, modules that would
not load, stdout that is neither word — is `E_RUNTIME`. A timestamp that got past step (5) and
fails here is `E_USAGE` for the calendar reason, `2026-02-30T00:00:00Z` included.

Only after all of that: the profile, resolved-profile and claim document checks in 2.3, and only
after those the source repository in 2.4-2.6.

2.3 **Read and canonicalize the five inputs.** Follow `shadow/v1/reproduce.sh:144-153`'s
`canonical_json` shape — BOM check, one JSON value, `jq -S -c` compared with `cmp` — and its
`snapshot_bounded` bounds, the claim at the driver's own 1 MiB (`:156`). Then the profile-id check
and the eight digest comparisons, requirement 16's producer-config check, and the claim checks:
`kind` exactly `execution_environment_claim`, `id` in the core id charset (`:222-228`), and the
two derived values — the claim's `id` and the SHA-256 of its bytes, the digest `:168` takes as
`claim_sha`.

2.4 **`run_root`, trap first.** Compute `run_root`'s path inside the caller's output directory,
**install the trap**, and only then `mkdir -m 0700` it — that order, because `trap` and `mkdir`
are two commands and a signal between them leaves a directory nothing is watching. The trap body
is guarded with `[ -n "${run_root:-}" ] && [ -d "$run_root" ]` ahead of its `rm -rf`. `INT`, `TERM`
and `HUP` are trapped beside `EXIT`, and the body consults a flag: it removes every recorded
commit destination that exists **only when `committed` is not `yes`**, and it removes `run_root`
in **every** case; the three signal traps then reset their own trap and re-raise, the shape
`shadow/v1/reproduce.sh:124-127` uses. Initialize `committed=no` and an empty destination list
beside the trap, above the `mkdir`, so the guard reads the same on every path out.

The flag is what stops the trap from deleting the outputs the run just committed. Without it the
normal `EXIT` fires after the last `mv` on a **successful** run and removes all seven documents,
which contradicts the spec's guarantee at lines 1159-1164: a run that reaches the end of the
commit step leaves exactly the documents requirements 6, 8 and 9 name and nothing else. 2.7 says
where the flag is set and why that spot is the only correct one.

Then bind the four names the copy needs, just above it:
`git_env` copied from `materialize.sh:265-269` including the `core.hooksPath` pin and the explicit
`HOME`/`TMPDIR`; `git_dir` comes with span 271-332; `source_algorithm` from the caller's commit-id
width, `sha1` for 40 and `sha256` for 64 — bound from the argument, not the repository, which is
what keeps the copied `:352-354` a real check; and `source_commit` from the caller's commit id.

**Then the source directory's own physical check, which the copy does not carry.** The materializer
refuses a symlinked or otherwise non-physical `<source-git-dir>` at `materialize.sh:118`
(`physical_dir "$source_git_dir" || emit_error E_SOURCE_GIT`), and line 118 is **outside** the three
spans, which start at 271 — so it is not among the copied bytes and nothing in the copy replaces
it. `git --git-dir=` follows a symlink without complaint, and every copied guard would then pass on
the link's target rather than on the path the caller named. The spec requires a **physical bare
repository** (lines 111-112) and files a source that is not one under `E_TARGET` (line 380), so
state the check explicitly, on the line just above the `source_pure` call:
`physical_dir "$source_git_dir" || emit_error E_TARGET`. Two notes on the helper. It is the
materializer's own, `materialize.sh:76-81`, taken under its own
`# copy-begin materialize.sh:76-81` marker so step 0.6(b) proves it byte-for-byte the way it proves
the other spans — the same file at the same commit as the rest of the copy, so there is one text
here and not two. And it is the same predicate the driver applies to its own `source_git_dir` with
its own `physical_dir`, which differs only by an absolute-path guard that 2.2(2) has already decided
by the time this line runs; the assembler's id is `E_TARGET` where the driver's is `E_WORKSPACE`,
because requirement 12 puts a bad source under the target and not the workspace. One helper serves
both callers: 2.2(6)'s physical check on the output directory calls the same function, the way
`empty_private_dir` calls it in the materializer at `:97-98`.

2.5 **`source_pure`, the verbatim copy.** `source_pure() ( emit_error() { exit 1; }; <271-332>;
<333-347>; <348-360>; exit 0 )`, the three spans in materializer order, all under one copy header
naming `adapters/local-git-materializer/v1/materialize.sh` at
`a637451d4b3fbef6b516a9c08f68c0dde46a7059 (origin/main)` plus one sentence saying why it is a
copy — the header shape `shadow/v1/qualified-identity.jq:8-13` uses. Take 271-332 from PR #278's
`reproduce.sh` copy if that has merged, and 333-347 and 355-360 from `materialize.sh`. Any
non-zero return is `E_TARGET`, whichever `E_SOURCE_*` id the copied line names. Do not edit a
byte inside the markers; if the anchors in step 0.6(b) do not land on 271, 333 and 348, that is
drift in `materialize.sh` to resolve with the operator before merging, not a number to adjust.

2.6 **After `source_pure` returns clean**, in the parent shell: `rev-parse --show-object-format`
for the algorithm written into the output, and the commit's root tree id. Nothing re-reads the
commit's tree content — that boundary is requirement 15's. There is no separate commit-existence,
type or size check: `:355-360` inside the copy decides all three.

2.7 **Size check, then stage, then commit** (requirement 18). Refuse `E_LIMIT` rather than emit
something over the driver's 8 MiB cap (`shadow/v1/reproduce.sh:158`). **Stage:** `mkdir` a
`stage/` under `run_root` and write `input.json`, `stage-request-ref.json`,
`resolved-profile-ref.json` and the four decision-record texts there, each as
`> <name>.tmp && mv <name>.tmp <name>` inside that directory; then run
`"$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol"` on the staged
`input.json`, the call `materialize.sh:167-168` makes, with `$protocol` being
`<repo>/adapters/local-git-materializer/v1/protocol.jq` checked for existence and non-symlinkness
alongside the other required files the way `shadow/v1/reproduce.sh:103-111` checks its own.
Nothing has touched the output directory yet.

**Commit:** for each staged file, append its destination path to the trap's list on the line
**above** its own `mv`, then `mv` it into the output directory, with `input.json` last. Then,
**after that last `mv` returns and before the script reaches its normal exit**, set
`committed=yes` and empty the destination list. The whole order in one line: append destination →
`mv`, repeated, `input.json` last → `committed=yes`, list cleared → `exit 0`. No removal step at
the end — the trap owns `run_root` on every path, flag or no flag.

That spot is the only correct one. Set the flag earlier and a failure inside the commit step
leaves a partial set behind that the trap will not clean; set it after the exit path has begun and
the `EXIT` trap has already run with `committed=no` and taken the seven documents with it. What
the two together buy is the spec's guarantee at lines 1159-1164, stated as a check anyone can run:
**after a successful run the output directory holds exactly the seven documents and no
`run_root`; after any refusal, and after any trapped signal, it is empty.** The one remaining
window is between the last `mv` and `committed=yes`, and it is the safe one — a signal there
removes the committed outputs and leaves the directory empty, which is a refusal-shaped result the
caller can retry into, not a partial set. Only a `KILL` or a power loss can leave a partial set,
the limit the spec names and no trap covers.

2.8 **Refusal ids** exactly as requirement 12 lists them, and no new id. Three that are easy to
get wrong: everything the copy refuses about the source repository is `E_TARGET`, the oversized
commit object included even though the copied line says `E_SOURCE_LIMIT`; `E_LIMIT` is for the
caller's own files and the finished output; and a `time_ok` that ran and answered `false` is
`E_USAGE` while one that could not run is `E_RUNTIME`. A fourth, which is an ordering fault rather
than a mapping one: an id that is correct in the table and reported second is still the wrong id,
so every `E_USAGE` condition in 2.2 steps (1)-(5) has to be decided before the `E_WORKSPACE` and
`E_RUNTIME` conditions that could refuse the same run first. That is why 2.2 is written as a
numbered order rather than a list of checks.

2.9 **No `shellcheck disable` directive in either new file, and how the jq calls earn that.** The
spec allows none — lines 654-656 for both files and 1052-1056 for the assembler — and the one
directive `materialize.sh` carries, the file-level `disable=SC2016` at `:2`, is for its own inline
jq program text and not for anything copied here. That is checkable, and it checks out: with `:2`
removed, shellcheck 0.11.0 reports SC2016 at `materialize.sh` lines 63, 221, 258, 498, 578, 621 and
633, every one an inline jq program, and **none inside 4-13, 22-29, 76-81, 271-332, 333-347 or
348-360**. So the copies bring no finding with them and nothing has to replace the directive.

What would bring one is the assembler's own jq calls, and the rule is narrower than it looks:
SC2016 fires on a single-quoted argument containing `$` only when shellcheck cannot see that the
command is jq. It special-cases the literal word `jq`, and every call here is `"$jq_bin"`, so it
cannot see it — which is why the producers carry the directive at all. Two of this component's
three calls are already clear: the document build and the staged `validate-input` pass their
programs with `-f` (`shadow/v1/materialization-input.jq` and the materializer's `protocol.jq`), and
a `-f` path is not program text. The third is requirement 10's `time_ok` call, and it is the one to
write deliberately: pass the timestamp on **stdin** as a raw string instead of through `--arg`, so
the program text carries no `$` at all — `printf '%s' "$requested_at" | "$jq_bin" -L "$modules" -R
'import "schema" as schema; schema::time_ok'`. That is the shape `time_ok` wants anyway, since it
tests `.` (`schema.jq:186-188`). No `-e` on it: 2.2 reads the answer from stdout and the status
separately, and `-e` would turn `false` into exit 1 and destroy that distinction.

The same rule governs the test file, where it costs more. Every sibling test in the repository
carries the file-level `SC2016` instead of avoiding it — `scripts/test/shadow-slice.test.sh:2`,
and 19 findings appear under it if that line is removed — so copying a sibling's jq call style is
exactly what breaks this rule. Write the fixture programs that need `$name` bindings into
`$tmp/*.jq` with a quoted heredoc (`<<'EOF'`) and pass them with `-f`: shellcheck does not read `$`
inside a heredoc as a shell expansion, so no directive is needed. This is a real path and not a
hope — a mock assembler holding all the copied spans plus the stdin `time_ok` call and the `-f`
`validate-input` call passes `shellcheck -x -S style` at 0.11.0 with zero directives.

If a site still cannot be written without a directive, then the spec's rule and the code it asks
for are in conflict. **Stop and re-decide with the operator.** Do not add the directive, and do not
weaken the lint to get past it.

### Step 3 — documentation, index, restore and manifest (requirement 14)

3.1 `docs/components.md`: a new `## Inactive shadow materialization input assembler` section
after the shadow slice section (line 1175 onward). It says plainly that the resolved profile is an
input and where resolved profiles come from today — matching the wording of the resolver
trusted-parent note at lines 33-37, not editing it — and names the **two supported invocations**:
executing the file so its `#!/bin/bash -p` shebang starts bash, or
`env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p <script> assemble …`. It says invoking
`__assemble_clean` directly is not one of them and carries no safety claim, and that tree content
is the materializer's check, so a source that trips the tree scan comes back
`materialization.refused` from the driver.

3.2 `README.md`: one row beside line 288's shadow slice row, same three columns, linking
`docs/components.md#inactive-shadow-materialization-input-assembler`.

3.3 `RESTORE.md`: one block in the shape of lines 200-221, naming the three paths, the command
`bash scripts/test/shadow-assembler.test.sh`, what the proof shows, and the sentence that
restoring the records materializes nothing on its own.

3.4 `ci/required-files.txt`: append the section comment and
`shadow/v1/assemble-materialization-input.sh`, `shadow/v1/materialization-input.jq`,
`scripts/test/shadow-assembler.test.sh` at the end. The structure check also requires a listed
`scripts/*.sh` to be executable (`AGENTS.md:96-99`), so give both new shell files mode 0755.

### Step 4 — run the Proof section on the final commit and paste it into the PR body.

## Risks

**The verbatim copies are the riskiest thing here, and 2.5 is the riskiest step.** About 95 lines
of predicate, the six-line `physical_dir` helper 2.4 adds, and 18 of entry must be placed
byte-exactly and not improved. Three things go wrong
in practice: a line reflowed by an editor; an anchor that has stopped being unique in
`materialize.sh`; and the shared lines diverging from PR #278's copy. Step 0.6(b) catches the
first two, which is why it is written before the copy exists. The third no test catches — both
copies can be byte-equal to the materializer and still have been taken twice — so 2.1 and 2.5
inherit #278's bytes for 271-332 and the 348-354 prefix rather than retaking them. If #278 has
not merged when this starts, take them from `materialize.sh` and re-`cmp` against `reproduce.sh`
once it does.

**`emit_error` shadowing, and which `set` the assembler runs under.** The shadow
(`emit_error() { exit 1; }`) must stay inside the `( )` subshell, or every later refusal in the
run becomes a silent `exit 1`. On the `set` question the answer is favorable and worth stating,
because the driver's answer is different: `materialize.sh:15` is `set -euo pipefail`, and
requirement 17 gives the assembler the same line in the same place, so the copied spans run under
the errexit semantics they were written under. PR #278's driver is the odd one — `set -uo
pipefail`, no `-e` — so do not copy the driver's reasoning about bare commands along with its
bytes. The one place a non-zero exit is deliberately caught rather than left to `set -e` is
requirement 10's `time_ok` call in 2.2; every other refusal in the copy is an explicit
`|| emit_error` or `if …; then emit_error`. Read the copy line by line once it lands and confirm
the only bare command is `materialize.sh:299`'s `/bin/rm -f` of the inventory, which is cleanup.

**The driver's line numbers moved under this plan, and under the spec.** Every
`shadow/v1/reproduce.sh` citation here was taken before PR #278 merged, and the spec's own were
too (`spec` lines 319 and 965, and its references to `156` and `222-228`), so they now read low —
about 31 lines in the first half of that file and 36 in the second. Three, made concrete against
`main` at `1b46de0`: the `canonical_json` 2.3 cites as `:144-153` is at `175-184`; the claim's
1 MiB bound cited as `:156` is at `187`; the two `pair_ref` projections cited as `:250-256` and
`:251-254` are at `286-292` and `287-290`. The numbers are the spec's, the contract, so correcting
them is the operator's call rather than this plan's. Until that happens, **resolve every
`reproduce.sh` citation by reading the working tree, not by trusting the number** — the way step
0.6(b) resolves the materializer's anchors — and treat a citation that does not land as drift to
raise, not a number to guess. `adapters/local-git-materializer/v1/materialize.sh` has not moved, so
its numbers still land: every copied span, the `76-81` helper, and `:118`.

**`time_ok` module-path resolution.** The one new dependency on the core layout, and it fails in
two directions: point it at the wrong directory and every good timestamp comes back `E_RUNTIME`;
skip the generation-registry check and a stale `PORTABLE_CORE_GENERATION` loads a module set
nothing verified. Follow `materialize.sh:60-69` whole rather than shortening it, and resolve the
repository root from the script's own normalized path — not from `$PWD`, which the clean entry has
not fixed. Do not hard-code a generation id the way `evals/v1/evals-driver.sh:57` does: there are
two generation directories under `core/v2/generations/` today and the wrapper says which is
selected. Step 0.5's unreadable-modules case proves the `E_RUNTIME` half.

**The stage/commit ordering regresses by edit, not by accident.** Nothing at runtime can inject a
failure between the staging step and the commit step, so most of requirement 18's orders are only
ever proved in the source (step 0.6(c)) — exactly the kind of thing a later well-meaning edit
undoes by moving the `mkdir` above the `trap`, or the list-append below its `mv`. Keep all five
clauses of 0.6(c), and keep them named as source-order assertions so a reader does not mistake
them for runtime proofs. The `committed` flag is the exception that also fails loudly at runtime: drop it
as apparently dead code and the very next successful run comes back with an empty output
directory, which step 0.4's full listing catches. Every other order in that list fails silently,
which is why they are asserted at all.

**The `EXIT` trap fires on success too, and that is the fault to design against.** The trap's
whole purpose is cleaning up after a refusal, so it is natural to write its body as if only
refusals reach it — and then the seven documents a good run just committed are deleted by the
normal exit, with no error id and an empty directory as the only evidence. The `committed` flag in
2.4 and its placement in 2.7 are the answer, and the reason both steps spell out the ordering
rather than leaving it to the implementer: the correct code and the broken code differ by one
line's position.

**What the clean entry breaks first is the test's own invocations.** Arity is `[ "$#" -eq 10 ]`
before the dispatch, and the marker form is also ten words. A relative path is refused in the
re-exec'd process, not the caller's; `exec` preserves the working directory so the `pwd -P`
normalization agrees on both sides, and stderr survives `exec` so the error vocabulary still
reaches the test. Write 0.5's cases with that in mind.

**`run_root` inside the caller's output directory** is right for requirement 15's reason — the
clean entry passes through `PATH` and `LC_ALL` only, so there is no `TMPDIR` to read — but it
makes the assembler's scratch and the caller's workspace one directory. Do not add an argument or
an environment read to move it; the trap plus the staging step is the answer.

**Alternatives rejected.**
- Re-implementing the source guards, or mirroring only the subset an earlier draft listed: a
  paraphrase drifts silently while a copy drifts loudly in CI, and the subset is what left the
  config, hooks, `packed-refs` and commit-size checks out.
- Copying `scan_tree` too: it needs the object-closure walk, which is most of the materializer,
  and no tree-content condition can make this run write anything — empty patch, network denied.
- A shape-only timestamp check in shell **instead of** `time_ok`: it takes `2026-02-30T00:00:00Z`
  and returns `E_RELATION` from the self-check at the very end, blaming the component for the
  caller's typo. Step 2.2(5)'s shape gate is not that alternative — it runs before jq and
  `time_ok` still runs after it, so the calendar answer is still the core's and
  `2026-02-30T00:00:00Z` is still refused by the core's rule rather than by a pattern written
  here. What the gate adds is only that a misshapen timestamp is `E_USAGE` on a run where jq
  itself is broken.
- Mapping every failure of the `time_ok` jq call to `E_USAGE`: it blames an argument that may be
  perfectly good and leaves a missing modules directory unnamed.
- Resolving the profile here, or calling `scripts/test/`'s launcher: DR-1 option 2 on issue #262
  settles both — the resolved profile is an input, and the trusted parent is its own initiative.
- A test-only hook to fail between staging and commit: a second entry into the script, which
  requirement 17 spends its whole length narrowing.
- `unset -f find` or any name list instead of the producer's whole entry: a list someone must keep
  in step with the copy, silent about `head`, `wc`, `tr`, `rm`, `grep`, `IFS` and `BASH_ENV`.
- `set +o posix` or any further marker-branch state reset: nothing has been shown to need one, and
  a reset that guards nothing reads as a guarantee and is not one.
- Writing outputs straight into the output directory: a signal mid-write or a full disk leaves a
  truncated `input.json` the trap does not clean and the caller's retry cannot get past.

## Proof

Run all of this on the final implementation commit and say which commit; old proof on a new
commit is stale. `$t` is any scratch directory, `$m` is
`adapters/local-git-materializer/v1/materialize.sh`.

- `bash scripts/test/shadow-assembler.test.sh` — all pass, last line
  `shadow assembler: <N> focused checks passed` and nothing else printed. That one line covers
  every group in step 0: both algorithms, the four negative sources, the symlinked source, the
  exported-function and
  `BASH_ENV` cases in both invocation forms, the two timestamp cases, the unreadable-modules case,
  the look-alike profile set, the swapped producer-config digest, the relative-jq and
  wrong-digest-jq pair, the refuse-then-retry pair, the ten refusal classes, the success-path
  directory listing, and the copy, pin-liveness and source-order assertions.
- **One case per refusal class.** Paste the id each case produced, one line per class in
  requirement 12: `E_USAGE`, `E_TARGET`, `E_WORKSPACE`, `E_RUNTIME`, `E_LIMIT` twice (the padded
  claim, and the resolved profile padded until the output would cross 8 MiB), `E_PARSE` twice (two
  JSON values, and the BOM), `E_CANONICAL`, `E_SHAPE`, `E_PROFILE`, `E_RELATION`. Then say the one
  half with no runtime case — the finished input failing `validate-input` — and name the review
  that covers it, so the gap is on the record rather than read as an omission.
- **The source directory is checked physical.**
  `grep -n 'physical_dir "$source_git_dir"' shadow/v1/assemble-materialization-input.sh` matches
  exactly once, on an **earlier** line than the `source_pure` call; paste both numbers. Then the
  run: a symlink to the good `sha1` fixture passed as `<source-git-dir>` prints `E_TARGET`.
- **The driver accepts the input.** Inside that run: `shadow/v1/reproduce.sh` on the assembled
  `sha1` input with the fixture environment, policy set, duty and the same claim file produces a
  `shadow_reproduction_record` whose `.body.outcome` is **not** `inconclusive`. Paste the outcome
  and reason id.
- **Protocol.** `jq -L "$modules" -e --arg command validate-input -f
  adapters/local-git-materializer/v1/protocol.jq "$out/input.json"` — exit 0.
- **Determinism and canonical form.** Two runs into two empty directories:
  `cmp "$a/input.json" "$b/input.json"` exit 0 for every one of the seven outputs; and
  `jq -S -c . "$out/input.json" | cmp - "$out/input.json"` — no output, exit 0.
- **The pins are live.** `shasum -a 256 profiles/default/v1/profile.json
  profiles/default/v1/producer-config.json profiles/default/v1/manifests/*.json` — all eight
  digests appear in `shadow/v1/materialization-input.jq`, `grep -c` for each pin is 1. Expected
  values are the spec's table; today's working tree already matches it.
- **The copies are copies**, read against the **working tree**, never a commit. First anchor:
  `grep -n -x -F '<first line>' "$m"` for each of the six first lines matches exactly once, at
  76, 271, 333, 348, 4 and 22. Then extract each block from the assembler between its markers
  (`awk '/^# copy-begin materialize.sh:271-332$/{f=1;next} /^# copy-end
  materialize.sh:271-332$/{f=0} f' shadow/v1/assemble-materialization-input.sh > "$t/copy-a"`, and
  likewise `76-81`, `333-347`, `348-360`, `4-13`, `22-29`), confirm each block's line count puts its
  last line at 81, 332, 347, 360, 13 and 29, and compare:
  ```
  sed -n '76,81p'   "$m" > "$t/orig-phys"; cmp "$t/orig-phys" "$t/copy-phys"
  sed -n '271,332p' "$m" > "$t/orig-a"; cmp "$t/orig-a" "$t/copy-a"
  sed -n '333,347p' "$m" > "$t/orig-b"; cmp "$t/orig-b" "$t/copy-b"
  sed -n '348,360p' "$m" > "$t/orig-c"; cmp "$t/orig-c" "$t/copy-c"
  sed -n '4,13p'    "$m" > "$t/orig-scrub"; cmp "$t/orig-scrub" "$t/copy-scrub"
  sed -n '22,29p'   "$m" > "$t/orig-entry"; diff -u "$t/orig-entry" "$t/copy-entry"
  cmp <(sed -n 1p "$m") <(sed -n 1p shadow/v1/assemble-materialization-input.sh)
  ```
  The four `cmp`s and the scrub `cmp` are byte-equal, exit 0. The shebang `cmp` confirms
  `#!/bin/bash -p`. The `diff -u` shows only the four named deviations — `-eq 8` → `-eq 10`; the
  `case … E_USAGE` line replaced by the `pwd -P` normalization plus the `-f`/`-L` check;
  `materialize` → `assemble` and `__materialize_clean` → `__assemble_clean`; and the exec
  forwarding `"$2"` … `"${10}"` — and no fifth hunk. The alias reset is outside the markers, so it
  is not in that diff; show it separately with
  `grep -n -A2 '__assemble_clean' shadow/v1/assemble-materialization-input.sh`.
- **The shared lines match the driver.** `cmp "$t/copy-a" <(awk '…271-332…'
  shadow/v1/reproduce.sh)` and the same for the 348-354 prefix and the scrub — byte-equal, exit 0.
  Run this once PR #278 has merged; if it has not, say so and say which bytes were taken from
  `materialize.sh` instead.
- **Source order.** Paste the line numbers: the `trap` lines naming `run_root` before the `mkdir`;
  every output-directory `mv` after the staged `validate-input`; `input.json`'s `mv` last; each
  list-append above its own `mv`; and the single `committed=yes` assignment after `input.json`'s
  `mv`, with the trap's destination removal guarded by that flag and its `run_root` removal not.
- **Usage checks before jq.** Paste the line numbers showing 2.2 steps (1)-(6) — the `/*` pattern
  match on each path argument, the repository-id charset, the commit-id width, the timestamp shape
  and the output-directory checks — all on **earlier** lines than the first line that reads
  `$jq_bin` (its digest computation and its first execution). Then the two runs:
  `assemble … ../relative/jq …` prints `E_USAGE`, and the same call with an absolute jq whose
  digest is wrong prints `E_RUNTIME`.
- **Shellcheck, and no directive at all.** Under **0.11.0** (paste `shellcheck --version`):
  `shellcheck -x -S style shadow/v1/assemble-materialization-input.sh
  scripts/test/shadow-assembler.test.sh` — no findings, exit 0. Then
  `grep -c 'shellcheck disable' shadow/v1/assemble-materialization-input.sh` and the same on
  `scripts/test/shadow-assembler.test.sh` — **`0` for both.** Not `1`, and not a file-level
  `SC2016`: the spec allows no new directive in either file (lines 654-656 and 1052-1056), and 2.9
  says how the jq calls are written to earn that. A `1` here is a finding, not a pass.
- `bash scripts/test/portable-core-schema.test.sh` — final line `failures: 0`, exit 0.
- `bash scripts/check-rename.sh` — `check-rename: clean — no old names in tracked files.`
- **Scope and size.** `git diff --stat main` lists exactly the seven files this plan names and
  nothing else. Paste the net total, against the **610-840** range the spec records. Expect to
  reach that line: the estimate in this plan is now about 865. Above 840, stop and re-decide with
  the operator — do not trim the refusal-class cases to fit.
- **Output directory contract**, which is the spec's guarantee at lines 1159-1164 read back as
  two commands. After a successful run, `ls -a "$out"` shows exactly the seven documents and no
  `run_root` — the trap fired on that run's normal `EXIT` and spared them. After the `hooks/`
  refusal, `ls -a "$out"` shows nothing at all, and the retry into that same directory with the
  good fixture assembles normally. Paste both listings; an empty listing on the successful run is
  the `committed` flag missing or set in the wrong place.
- **The copy's environment.** `env -i PATH=/usr/bin:/bin command -v find head wc tr rm grep git`
  resolves every one under `/usr/bin` or `/bin`.
