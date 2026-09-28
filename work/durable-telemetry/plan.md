---
spec-blob: 160faa6b4f1a45c6e88524badb831a72f1046bfc
intent-blob: fb1dd4a9d66592149637c131f8732f6d6d0e4f7a
risk: high
drafted: 2026-09-28
---
# Plan: durable-telemetry

Tracks #438 (subsumes #307). Risk: high, as the accepted spec records. Gate mode is
`artifact-high`: this plan-only PR needs independent review, green CI and a protected
merge before any code. It covers one implementation PR.

The spec (blob above) is the contract; a named requirement (R-n) is the detail to
follow, and this plan adds only the "Implementation choices" the spec leaves open.
Before the first code commit and on the final head, recheck both blobs against main.
A mismatch stops work (`stale`).

## Dependencies

Merged artifacts only: the telemetry validator, the committed self-host ledgers
(`shadow/evidence/self-host-transition/v1/{pre,post}/state/trace-ledger.json`), the
delivery ledger's design and tests, and the step-8 decision
(`work/step8-bounded-write-readiness/spec.md:298`: no landing dependency). No sibling
concern is assumed; concern 11 lands after this one and binds to it.

## PR split

One implementation PR, `ystack/impl/durable-telemetry`, with `Closes #438`.

A split was rejected. The four verbs share one lock, chain validator, object writer
and refusal set. A PR shipping some verbs would put on main a program whose verbs
(R2.3) and refusals (R10) differ from the spec, and each fragment would still need the
full R12.1 matrix for its code, so none falls under the soft budget. The durable
delivery ledger (#323) landed the same way. Reviewability comes from the commit order:
each commit is one layer with its own cases.

## Files that change

Exactly the five paths of R1.1. Nothing else changes in the implementation PR.

| Path | Change | Estimated lines |
| --- | --- | ---: |
| `telemetry/v1/trace-store.py` | New, mode 0755, Python 3 standard library (R1-R11) | 950-1,250 |
| `scripts/test/telemetry-trace-store.test.sh` | New, mode 0755, shell entry plus a private Python harness from a quoted heredoc (R12.1-R12.2) | 1,400-1,950 |
| `docs/components.md` | New section after the validator section; closing sentence at `docs/components.md:519-521` replaced (R12.4) | 20-35 |
| `RESTORE.md` | New paragraph after the validator paragraph (`RESTORE.md:794-808`); two edits in that paragraph (R12.4) | 14-22 |
| `ci/required-files.txt` | Two lines appended to the telemetry block (`ci/required-files.txt:269-272`) | 2 |

Existing tests and pins, found by grep on main, none of which is edited:

- `scripts/test/telemetry-trace-ledger.test.sh` must pass unchanged (R12.3).
- `scripts/test/portable-core-schema.test.sh` fails if a core generation id appears in
  a tracked path outside its closed lists (`:900-960`). The new files must contain no
  core generation id and no core module import, so it passes unchanged.
- Manifest-prefix pins (`portable-core-schema.test.sh:537-548`,
  `portable-core-ingress.test.sh:1296-1303`, `portable-core-profile-graph.test.sh:1022`,
  `portable-core-result-facts.test.sh:642`, `portable-core-stage-request.test.sh:1016`)
  hash at most the first 112 lines; the edit is at line 273.
- `scripts/test/run-all.sh:66-69` finds the suite by name;
  `scripts/test/run-all-sharding.check.sh` checks shard partition generically.
- No test pins the telemetry manifest block, docs section or RESTORE paragraph.
  `maintenance/v1/scan.sh:82`, `shadow/v1/reproduce.sh:137`,
  `scripts/test/shadow-slice.test.sh:12` and
  `scripts/test/shadow-self-host-evidence.test.sh:480` call the unchanged validator.

## Implementation choices

Choices the spec leaves open, fixed here so review and tests have one target:

1. **Structure.** Top-level named step functions that the test wrapper may replace
   (R12.2): `snapshot_inputs`, `run_validator`, `acquire_lock`, `load_chain`,
   `create_object_temporary`, `install_object`, `create_ref_lock`, `write_ref_lock`,
   `install_ref_lock`, `emit`, and one limit constant per R9 row. Entry is
   `main(argv)` behind `if __name__ == "__main__"`. No environment variable, argument
   or file changes behaviour for tests.
2. **Python 3.9.** The Darwin interpreter is the Command Line Tools 3.9
   (`docs/delivery-ledger.md:16-17`), so no syntax newer than 3.9. At start the program
   requires `sys.flags.isolated`, `no_site` and `dont_write_bytecode`, else
   `E_RUNTIME`.
3. **Check order per call.** Usage and environment (R2), then placement (R3.1-R3.2),
   then the `read` receipt (choice 8) or the `append` snapshot and validation (R5), then
   `flock` (`E_BUSY`), then layout, identity and chain (`E_INCOMPLETE`, `E_IDENTITY`,
   `E_CORRUPT`), then the R6 or R7.1 checks; `read` re-validates after unlocking. The
   first failure is the one reported.
4. **Uninitialized roots.** `append`, `read` and `list` on an empty root, or a root
   without a published `refs/heads/records`, refuse `E_INCOMPLETE`. `initialize`
   creates `store.lock` first (exclusive, 0600) and takes the lock before any other
   write, so every K7 state holds `store.lock` plus a partial `repository.git`.
5. **Canonical output.** The emitter is `json.dumps(sort_keys=True,
   separators=(",", ":"))` plus LF, over integers and strings only, and refuses to emit
   (`E_RUNTIME`) any string byte outside 0x20-0x7E, where Python and jq 1.6 escaping
   would differ. Parsed documents (`store.json`, `record.json`, supplied receipts) are
   canonical only when re-emission equals their bytes. `validation.json` is kept as the
   validator's exact stdout and only parsed for the R5.4 field checks.
6. **Validator child.** `/bin/bash` started with `start_new_session=True`,
   `close_fds=True`, stdin `/dev/null`, the R5.1 environment and cwd the private
   directory. The jq snapshot is `<private>/bin/jq` at mode 0500, so the validator's
   `command -v jq` (`validate-trace-ledger.sh:97`) finds it. Streams are read with
   `select` against the R5.2 caps; at the deadline the whole process group gets TERM,
   then KILL after one second. The private directory is removed on every exit the
   program controls, success or refusal; only a kill leaves it (K1).
7. **jq across platforms at read.** The program holds the two digests of
   `validate-trace-ledger.sh:74-75` as a constant; R7.2 accepts a record's jq digest
   and the running jq digest only when each is in that set. A test pins the constant to
   the validator's lines, and R7.2's script-digest check already refuses any other
   validator revision.
8. **Receipt and output files.** `STORAGE_RECEIPT` is opened no-follow and read up to
   8,192 bytes: unreadable is `E_RUNTIME`; oversize, non-canonical or wrong shape is
   `E_USAGE`. `OUTPUT` whose parent is not an existing physical directory is
   `E_OUTPUT`, as are the R7.3 cases.
9. **Residue bounds.** Temporary object names are `tmp_obj_` plus 24 lowercase hex,
   at most 32 exclusive-create attempts, as the delivery ledger
   (`work/durable-delivery-ledger/spec.md:397-400`). A loose object or temporary file
   over 1,114,112 raw bytes is `E_CORRUPT`; each temporary counts 1,048,589 bytes
   (the largest permitted object, header included) against the inflated-bytes limit.
   `config` bytes equal the delivery ledger's `CONFIG_BYTES`
   (`orchestrator/v1/delivery-ledger.py:36`).
10. **Exit.** Every refusal exits 1, `E_USAGE` included (R2.4); a caught `OSError`,
    `ValueError`, `UnicodeError` or `RecursionError` is `E_RUNTIME`, never a traceback.

## Order of work

1. **Gate.** After independent review, green CI and protected merge of this plan, record
   the merged default OID as `plan-base` and the plan blob, and create
   `ystack/impl/durable-telemetry` from that OID. If main moves before the first code
   commit, follow the `work/README.md` base-move rule before any edit.
2. **Commit `test: trace-store harness foundation`.** The test shell entry: platform
   interpreter and Git selection as
   `scripts/test/orchestrator-delivery-ledger.test.sh:14-22`, jq 1.6 fetch and digest
   check as `scripts/test/telemetry-trace-ledger.test.sh:18-40`, then the harness
   heredoc with: a store-tree snapshot (path, type, mode, size, SHA-256 of every entry,
   `store.lock` included), a caller that runs the product with the exact R2.2
   environment, a wrapper builder that loads the product as
   `scripts/test/delivery-replay.test.sh:166-191` and `:292-320` do, and pipe-based
   barriers. First cases (usage, `initialize`, `list`) fail red; record that result.
3. **Commit `feat: trace-store invocation and placement`** (R2, R3.1-R3.3, R10 output
   shape, choices 2-3, 5, 10). Cases: every verb and argument-count error, id and tip
   shapes, each forbidden variable prefix, every R3 boundary, one-line stderr, empty
   stdout on refusal.
4. **Commit `feat: trace-store repository, initialize and list`** (R3.4, R7.4-R7.5,
   R8, R9, choices 4 and 9). Object writer and reader, chain loader, inventory and limit
   accounting, `initialize`, `list`. Cases: new store listing, exact R9 values in
   `store.json`, identity mismatch, `E_INCOMPLETE`, non-empty root.
5. **Commit `feat: trace-store validated append and replay`** (R4, R5, R6, choices 6-7).
   Snapshot, validator child, identity binding, record and receipt, the R6 decision
   order, compare-and-swap publication. Cases: first append, identical replay, conflict,
   stale writer, each validator refusal class, wrong session and attempt.
6. **Commit `feat: trace-store read`** (R7.1-R7.3, choice 8). Cases: byte-exact read of
   both committed self-host ledgers after deleting their scratch copies, `E_NOT_FOUND`,
   `E_IDENTITY`, `E_VALIDATOR`, `E_OUTPUT`.
7. **Commit `test: trace-store crash, concurrency and capacity`** (R9, R11): the crash
   and capacity cases below.
8. **Commit `test: trace-store corruption, isolation and interoperability`** (R2.5,
   R8, R12.1): the remaining cases below.
9. **Commit `docs: trace-store component, restore and manifest`** (R12.4): the text in
   "Documentation and manifest", verbatim up to wrapping.
10. Read the full diff, run the proof, open the PR with `Closes #438` and the review
    size line. Describe it as an inactive store with no caller. Record a green
    dispatched `ci` on the exact head and a native Darwin run of both telemetry tests
    (R12.3).

Tests land with the code they cover. A size overrun or needed spec change pauses the
attempt as `work/README.md` describes; no case is dropped and no code compressed.

## Test cases

Each bullet of R12.1 maps to cases in the harness; every refusal case also asserts the
full store tree is byte-identical before and after, except the named K-residue.

- **Recovery.** Copy each self-host ledger into a disposable scratch, append, delete
  the scratch, `read` to a new file: bytes and SHA-256 equal the committed file.
- **Same session and attempt.** Two fixture bundles sealed like
  `shadow/v1/reproduce.sh:557-564` with different event times: both stored, `list` in
  key order, no entry field names order or recency.
- **Replay.** Identical replay after two later appends, at full capacity, and with a
  K4 lock present: same receipt bytes, same tip, same tree snapshot.
- **Writers.** `E_CONFLICT` (same key, changed ledger `id`), `E_STALE` (old tip), and
  `E_BUSY`: writer A blocks at a barrier inside `load_chain`, writer B refuses, A is
  released and succeeds.
- **Crash states**, each by SIGKILL from the wrapper at the named step: K1 inside
  `run_validator`; K2 inside `create_object_temporary` after a partial write; K3 after
  the second `install_object`; K4 in `write_ref_lock` with zero, twenty and all
  41 bytes written; K5 in `emit` before writing; K6 killed while A holds the lock at a
  barrier, then a new call succeeds and `store.lock` remains; K7 in `initialize`'s
  `write_ref_lock`, then every verb is `E_INCOMPLETE`. Each asserts the R11 outcome
  and that residue is counted.
- **Invalid input.** Each validator code a bundle can trigger, plus wrong session and
  attempt: `E_INVALID:<code>`, tree unchanged.
- **Corruption**, each for `append`, `read` and `list`: a changed object byte, a
  changed `record.json` (rehashed and unrehashed), a missing object, an extra ref,
  `packed-refs`, a symbolic ref, a reflog, `objects/info/alternates`, an unknown config
  key, a second parent, a chain that drops a record, a chain that rewrites an earlier
  record, an over-limit object: all `E_CORRUPT`.
- **Capacity.** With wrapper-lowered constants (and a store initialized under them),
  each R9 counter and the admission reserve reach `E_CAPACITY` with nothing written,
  and `read`, `list` and identical replay still succeed. A store initialized by the
  shipped constants lists exactly the R9 values.
- **Boundaries.** Store with a symlinked ancestor, wrong mode, wrong owner (the
  wrapper replaces `os.getuid`), a `.git`
  file and a `.git` directory in an ancestor, inside the source tree, equal to or inside
  or containing `SCRATCH_ROOT`, `LEDGER` outside `SCRATCH_ROOT`: `E_BOUNDARY`.
  `E_OUTPUT` for existing, symlinked, in-store and parentless outputs. `E_VALIDATOR`
  with a copied source tree whose validator script differs by one byte.
- **Isolation.** A hostile `HOME` holding a Git config with a hooks path, a clean
  filter and a credential helper that each write a marker: output and store bytes equal
  a clean run and no marker exists. Each forbidden prefix of R2.2 (`GIT_DIR`,
  `XDG_CONFIG_HOME`, `PYTHONPATH`, `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`): `E_USAGE`.
- **Canonical and static.** Every printed document equals pinned jq 1.6 `-S -c` of
  itself. An `ast` scan of the program finds exactly the R2.5 imports, no
  `socket`, and `/bin/bash` as the only executable it names. The choice-7 constant
  equals `validate-trace-ledger.sh:74-75`.
- **Git interoperability.** On a copy of a closed store only, with `HOME` an empty
  directory and `GIT_CONFIG_NOSYSTEM=1`: `git fsck --strict`, `cat-file` of every
  blob, tree and commit, and `rev-list --parents` show the exact linear history; the
  original store tree is unchanged.

## Documentation and manifest

**`docs/components.md`.** Replace the sentence at `:519-521` ("A later unit must
provide durable append, retention, access, and recovery behavior before it can claim a
telemetry ledger runtime.") with:

> The [inactive telemetry trace store](#inactive-telemetry-trace-store) adds bounded
> durable append and read-back for sealed bundles; no shipped component calls it, and
> live collection, retention policy and caller wiring remain later work.

Then add, after the validator section and before `## Inactive hermetic eval-record
evaluator`:

> ## Inactive telemetry trace store
>
> `telemetry/v1/trace-store.py` keeps complete sealed trace bundles, byte for byte, in
> a local store outside the scratch that made them. It runs only under the identified
> interpreter and empty environment of the [delivery ledger](delivery-ledger.md), with
> `-I -S -B` and no `TMPDIR`:
>
> ```text
> initialize STORE_ROOT STORE_ID
> append STORE_ROOT STORE_ID EXPECTED_TIP SCRATCH_ROOT JQ_BIN SESSION_ID ATTEMPT_ID LEDGER
> read STORE_ROOT JQ_BIN STORAGE_RECEIPT OUTPUT
> list STORE_ROOT STORE_ID
> ```
>
> Append runs the unchanged validator above on a private snapshot and never reads a
> caller's receipt. A record keeps the exact bundle, the validator's exact receipt and
> the validator, program and jq digests, keyed by the receipt's session, attempt and
> final-digest replay key. One session and attempt may hold several records, told apart
> only by final digest; none is newest. Publication is one expected-tip
> compare-and-swap of a single ref in a bare SHA-1 repository the program writes
> itself, without running Git. An identical replay returns the same storage receipt and
> adds nothing. Read writes the exact bytes to a new 0400 file only after re-checking
> the storage receipt and re-running the same validator revision.
>
> A store holds at most 1,024 records of up to 1 MiB each and 256 MiB of files. A full
> store refuses; there is no eviction, pruning, garbage collection, repair or history
> rewrite, and a stale ref lock or partial initialization waits for the operator. The
> proof covers process-crash recovery for this contract only, not producer
> authenticity, power loss, same-UID or administrator rollback, or a session service.
> The store is inactive, grants no authority, qualifies no fact, uses no network or
> credential and ships no default location. No shipped component calls it; a later
> publisher binds to it by storage receipt in its own gate.

**`RESTORE.md`.** In the validator paragraph, change "Restore the three paths" to
"Restore the first three paths" (`:794`) and replace the last sentence ("Durable
append, retention, access, and recovery behavior is later work.", `:807-808`) with
"The validator itself stores nothing." Then add after that paragraph:

> Restore the last two paths of the same manifest block,
> `telemetry/v1/trace-store.py` and `scripts/test/telemetry-trace-store.test.sh`,
> together with the validator paths above, then run:
>
> ```sh
> bash scripts/test/telemetry-trace-store.test.sh
> ```
>
> This proves byte-exact read-back after the source scratch is deleted, identical and
> conflicting replay, stale and concurrent writers, every crash state around the ref
> update, unchanged state after invalid input, corrupt stored data, capacity refusal
> and the store and environment boundaries, on disposable local stores. It restores no
> store contents, creates no store location, wires no caller, uses no credential or
> network beyond the digest-checked jq 1.6 download, and activates nothing.

**`ci/required-files.txt`.** Append, directly after
`scripts/test/telemetry-trace-ledger.test.sh` (`:272`) and inside the same block:

```text
telemetry/v1/trace-store.py
scripts/test/telemetry-trace-store.test.sh
```

No `README.md` row is added: R1.1 closes the scope at five paths, and the README
validator row (`README.md:272`, "Not a durable ledger.") stays true of the validator.

## What does not change

- Byte-identical (R1.2): `telemetry/v1/trace-ledger.jq`,
  `telemetry/v1/validate-trace-ledger.sh`, `scripts/test/telemetry-trace-ledger.test.sh`,
  `orchestrator/v1/delivery-ledger.py`, `delivery/v1/replay.py`, `shadow/**`,
  `maintenance/**`, `evals/**`, `core/**`, `config/**`, `README.md` and every other path
  outside the five above.
- No caller: nothing in the repository invokes `trace-store.py` except its test (R1.3).
- No core kind, role, capability, generation, profile or registry (R1.4); every
  document is `inactive` with `authority_effect: "none"` (R1.5).
- No network, credential, model or provider call in the shipped program; the test's
  only network use is the digest-checked jq 1.6 download, as the validator's test.

**Reserved and excluded.** Not part of this concern: a real store location (concern
11's gate), caller wiring, the real publisher, any credential, network scope,
installation or first write-scope activation, and any change to `ROADMAP.md`,
`AGENTS.md`, `REVIEW.md`, `NORTH_STAR.md`, `.github/**`, `config/**`,
`scripts/merge-pr.sh`, `scripts/codex-review.sh`, `scripts/test/run-all.sh` or
`scripts/lib/*.sh`. Per step-8 row 8, nothing beyond review is reserved.

## Follow-up intakes

Concern 11 (#304) binds the publisher to the storage receipt and names the store
location. Caller wiring, a retention policy and a README row each need their own
intake; this plan opens none.

## Review size

Implementation PR: `review_size: accepted-exception`, 2,400-3,300 added plus removed
lines, one concern (the inactive trace store with its focused proof). Evidence: the
durable delivery ledger, the closest design, landed as #323 at 2,903 added lines
(807 program, 1,973 test, 123 docs and manifest). This store adds a validator child,
read re-validation and a boundary set and drops the delivery protocol and planner,
giving the per-file estimates in "Files that change". An overrun pauses for a size
review; it never trims cases. This plan-only PR is within the soft budget.

## Risks

- **Test seams.** A replaceable step function is a test control only because the
  shipped entry never reads an override. Review must confirm no environment, argument,
  file or import hook changes behaviour.
- **Canonical drift.** Python and jq 1.6 escape some bytes differently; choice 5 and
  the self-comparison case keep printed bytes identical.
- **Lock held across a child.** A hung validator under the lock would block every
  caller; R5.6 and choice 3 forbid it.
- **Destructive cleanup.** Only the private `/tmp` directory is ever deleted; review
  each `unlink`, `rmdir` and `rename` against R8.5.
- **Overclaiming.** Docs and the PR must not call this a telemetry runtime, a session
  service, signed evidence or power-loss durable.

## Proof

Record BASE (full OID) and the final head. Identity, before the first edit and on the
final head:

```sh
git rev-parse HEAD:work/durable-telemetry/intent.md   # fb1dd4a9d66592149637c131f8732f6d6d0e4f7a
git rev-parse HEAD:work/durable-telemetry/spec.md     # 160faa6b4f1a45c6e88524badb831a72f1046bfc
git rev-parse HEAD:work/durable-telemetry/plan.md     # the merged plan blob
git show HEAD:work/durable-telemetry/spec.md | sed -n '1,5p'
git show HEAD:work/durable-telemetry/plan.md | sed -n '1,6p'
```

Scope and modes:

```sh
git diff --name-only BASE HEAD
git diff --stat BASE HEAD
git diff --check BASE HEAD
git ls-files -s telemetry/v1/trace-store.py scripts/test/telemetry-trace-store.test.sh
git diff --quiet BASE HEAD -- telemetry/v1/trace-ledger.jq telemetry/v1/validate-trace-ledger.sh \
  scripts/test/telemetry-trace-ledger.test.sh orchestrator/v1/delivery-ledger.py \
  delivery/v1/replay.py shadow maintenance evals core config README.md
```

Exactly the five paths differ, both new files are `100755`, `--check` is silent and
the `--quiet` diff exits 0.

Required files and guards:

```sh
grep -v -e '^$' -e '^#' ci/required-files.txt | while IFS= read -r f; do
  [ -f "$f" ] || echo "missing required file: $f"
done
grep -Fxc telemetry/v1/trace-store.py ci/required-files.txt
grep -Fxc scripts/test/telemetry-trace-store.test.sh ci/required-files.txt
git grep -n 'trace-store' -- ':!work/**' ':!docs/components.md' ':!RESTORE.md' \
  ':!ci/required-files.txt' ':!telemetry/v1/trace-store.py' \
  ':!scripts/test/telemetry-trace-store.test.sh'
bash scripts/check-rename.sh
shellcheck -x -S style scripts/test/telemetry-trace-store.test.sh   # shellcheck 0.11.0
```

The loop prints nothing, each count is `1`, the caller grep prints nothing (R1.3),
`check-rename.sh` exits 0 and pinned shellcheck is clean.

Tests, on Linux and natively on Darwin:

```sh
bash scripts/test/telemetry-trace-store.test.sh
bash scripts/test/telemetry-trace-ledger.test.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/v2-pending-stage.test.sh
bash scripts/test/run-all-sharding.check.sh
```

All pass; record command, head, platform and full output. On the exact final head and
base require the automatic `ci` and one green dispatched `ci` with all six shards
(R12.3); never rerun a failure until green. A separate read-only reviewer applies the
Bugs, Security and Compliance passes to the diff, hash links and this evidence; every
Important finding is resolved before merge.
