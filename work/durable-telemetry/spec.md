---
intent-blob: fb1dd4a9d66592149637c131f8732f6d6d0e4f7a
risk: high
drafted: 2026-09-27
---

# Spec: durable telemetry store for sealed trace bundles

Tracks #438 (subsumes #307). Step-8 child concern 8
(`work/step8-bounded-write-readiness/spec.md:298`), with no landing dependency and no
reserved decision beyond review. Concern 11, the real publisher and post-write check,
lands after this one and binds to it (`spec.md:301`). The accepted intent was read at
main `272ec0fd04b0acd83d0176616feb40a7da3254a7`.

This concern adds one inactive store and nothing that calls it. It keeps complete
sealed trace bundles, byte for byte, outside the scratch that made them, and proves
process-crash recovery for this contract only: not who made a bundle, power loss, a
hostile administrator or a session service.

## Requirements

### R1. What ships, and what stays unchanged

1. One new program, `telemetry/v1/trace-store.py` (Python 3 standard library, mode
   0755), and one new test, `scripts/test/telemetry-trace-store.test.sh` (mode 0755).
   `docs/components.md`, `RESTORE.md` and `ci/required-files.txt` gain their entries
   (R12). These five paths, plus `work/durable-telemetry/plan.md` in its own plan PR,
   are the whole scope.
2. `telemetry/v1/trace-ledger.jq`, `telemetry/v1/validate-trace-ledger.sh`,
   `scripts/test/telemetry-trace-ledger.test.sh`, `orchestrator/v1/delivery-ledger.py`,
   `delivery/v1/replay.py`, `shadow/**`, `maintenance/**`, `evals/**`, `core/**` and
   `config/**` stay byte-identical. The validator's receipt keeps
   `storage_effect: "none"` (`trace-ledger.jq:110`); it describes the validator, which
   still stores nothing.
3. No shipped component calls the store. Wiring the shadow driver, scanner, eval
   dashboard or publisher to it is later work (concern 11 for the publisher).
4. Every document the store writes or prints is a `telemetry/v1` package document,
   like the existing `telemetry_trace_ledger_validation` receipt, which no core file
   names (`git grep telemetry_trace_ledger core` is empty). No core kind, role,
   capability, generation, profile or registry changes.
5. Every document carries `activation_state: "inactive"` and `authority_effect: "none"`.
   The store grants nothing, qualifies nothing and copies no fact value; the facts in a
   stored bundle stay supplied and unqualified.

### R2. Invocation

1. The program runs only as
   `INTERPRETER -I -S -B SOURCE/telemetry/v1/trace-store.py VERB ARGS...` with the
   identified interpreter of `docs/delivery-ledger.md:10-17`: `/usr/bin/python3` on
   Linux, the Command Line Tools Python 3.9 path on Darwin. No PATH search or shebang
   selection. SOURCE is an absolute physical path.
2. The caller starts it with an empty environment holding only `PATH=/usr/bin:/bin`,
   `LANG=C`, `LC_ALL=C` and `HOME=/dev/null`, stdin `/dev/null`, as the delivery
   ledger does (`docs/delivery-ledger.md:19-23`). A variable named `GIT_*`, `XDG_*`,
   `PYTHON*`, `LD_*` or `DYLD_*` present at start refuses with `E_USAGE`. Children get
   only the R5.1 environment.
3. The verbs are exactly:
   - `initialize STORE_ROOT STORE_ID`
   - `append STORE_ROOT STORE_ID EXPECTED_TIP SCRATCH_ROOT JQ_BIN SESSION_ID ATTEMPT_ID LEDGER`
   - `read STORE_ROOT JQ_BIN STORAGE_RECEIPT OUTPUT`
   - `list STORE_ROOT STORE_ID`
   Ids match `\A[a-z0-9][a-z0-9._:-]{0,127}\z` (the validator's rule,
   `validate-trace-ledger.sh:84-85`). `EXPECTED_TIP` is 40 lowercase hex. Anything else
   is `E_USAGE`.
4. Success prints exactly one canonical JSON line (jq 1.6 `-S -c` bytes plus one LF)
   on stdout, nothing on stderr, and exits 0. A refusal prints nothing on stdout,
   exactly one line on stderr — one code from R10 — and exits 1.
5. The program imports only these standard modules: `errno`, `fcntl`, `hashlib`,
   `json`, `os`, `re`, `select`, `signal`, `stat`, `subprocess`, `sys`, `zlib`. It
   opens no socket, runs no Git executable and contacts no network.

### R3. Where the store lives and how it is identified

1. `STORE_ROOT` is an existing directory chosen by the caller. The store checks, on
   every call, that it and every ancestor are physical (no symlink component), that it
   is owned by the current UID with mode 0700, and that no ancestor (excluding the root
   itself) contains an entry named `.git`, file or directory. This refuses a store
   inside any source or target checkout or worktree.
2. The root must not equal, contain or lie inside the source tree two directories
   above `trace-store.py`, nor, for `append`, `SCRATCH_ROOT`; and `LEDGER` must be a
   regular file inside `SCRATCH_ROOT`. So the caller names the scratch being disposed
   and the store refuses any overlap. Any failure is `E_BOUNDARY`.
3. No default location ships. Tests use disposable directories. Concern 11 names the
   operator's store location in its own gate.
4. Identity is the pair `STORE_ID` and the root commit id. `initialize` writes the root
   commit holding one `store.json` document (kind `telemetry_trace_store`, `id` =
   `STORE_ID`, body `layout_version: 1` and the R9 limits). Every later call
   recomputes the root commit from the chain and refuses with `E_IDENTITY` when its
   `store.json` id differs from the `STORE_ID` argument, or, for `read`, when the
   receipt's store id or root commit differs.

### R4. Record keys and same-attempt records

1. A record's key is the validator's replay key: `session_id`, `attempt_id` and
   `final_digest` (`trace-ledger.jq:114-115`). `record_key` is the SHA-256 of the
   canonical line `{"attempt_id":…,"final_digest":…,"session_id":…}` plus LF.
2. Several distinct sealed records for one session and attempt are allowed. They are
   told apart only by `final_digest`. Reason: the shadow driver seals every run of one
   incident with the same session (the incident id) and the fixed attempt
   `attempt.shadow-reproduce` (`shadow/v1/reproduce.sh:528`, `:559`, `:563`), so the
   repeat run the step-8 decision requires (`spec.md:83-85`) seals two bundles with one
   session and attempt, whose final digests differ when their event times differ.
3. One replay key maps to at most one record. The same key with different ledger bytes
   (for example a changed ledger `id`, which no event digest covers) is `E_CONFLICT`.
4. The store never merges two bundles, never adds events to a stored one, never
   reseals bytes, and never marks one record as newest, current or authoritative. A
   consumer that needs one bundle binds its storage receipt (R7), never "the record
   for this session".

### R5. Validation through the real validator

1. `append` snapshots `LEDGER` (no-follow open, at most 1,048,576 bytes, the
   validator's own limit at `validate-trace-ledger.sh:117`, `:123`) and `JQ_BIN` (at
   most 8,388,608 bytes) into one private 0700 directory under `/tmp`, outside the
   store. It runs the unchanged validator on the snapshot as
   `/bin/bash SOURCE/telemetry/v1/validate-trace-ledger.sh validate SESSION_ID ATTEMPT_ID SNAPSHOT`,
   with environment `PATH=<private>/bin:/usr/bin:/bin`, `LC_ALL=C`, `HOME=/dev/null`,
   where `<private>/bin/jq` is the jq snapshot. The validator itself refuses any jq
   that is not its pinned jq 1.6 (`validate-trace-ledger.sh:72-78`, `:111-113`).
2. Limits on the child: stdout at most 16,384 bytes, stderr at most 4,096 bytes, and a
   60-second deadline, then TERM, one second, KILL. A timeout, an oversize stream or an
   unexpected exit is `E_RUNTIME`.
3. A validator refusal is `E_INVALID:<code>`, where `<code>` is its single stderr line
   and one of its seven codes (`validate-trace-ledger.sh:9`). Anything else on stderr
   is `E_RUNTIME`.
4. On exit 0 the stdout must be one canonical `telemetry_trace_ledger_validation`
   whose session, attempt and `ledger_ref.sha256` equal the arguments and the
   snapshot's SHA-256. Those exact bytes are stored as `validation.json`. A receipt
   supplied by the caller is never read.
5. The validator identity bound into each record is: SHA-256 of
   `validate-trace-ledger.sh`, SHA-256 of `trace-ledger.jq`, SHA-256 of the jq
   snapshot, and `jq_version: "jq-1.6"`. The store hashes both validator files before
   and after the child runs; any change is `E_RUNTIME`.
6. No child process runs while the store lock (R8.2) is held. Validation finishes
   before `append` takes the lock; `read` releases it before re-validating.

### R6. Append, replay and compare-and-swap

After validation, `append` takes the lock, captures the tip once, validates the whole
chain (R8.4), then decides in this order:

1. **Identical replay.** The replay key exists and the stored ledger bytes are
   identical: print the storage receipt rebuilt from the stored record. No object,
   file or ref changes. This holds after later appends, at full capacity and while a
   stale ref lock (R11 K4) is present. `EXPECTED_TIP` is not compared.
2. **Conflict.** The replay key exists with different bytes: `E_CONFLICT`.
3. **Stale writer.** `EXPECTED_TIP` differs from the captured tip: `E_STALE`.
4. **Stale ref lock.** `refs/heads/records.lock` exists: `E_LOCKED`.
5. **Capacity.** The R9 admission reserve does not fit: `E_CAPACITY`.
6. **New record.** Write the objects, then publish with a compare-and-swap of
   `refs/heads/records` from the captured tip (R8.3). Print the storage receipt.

Steps 1-5 write nothing. There is no automatic retry against a newer tip.

The **storage receipt** (kind `telemetry_trace_storage_receipt`, `id`
`trace-record.<record_key>`) body holds exactly: `activation_state`,
`authority_effect`, `storage_effect: "append-only"`, `store` (`id`, `root_commit`),
`commit_id` (the commit that added the record), `record_key`, `replay_key`,
`record_sha256` (of the stored `record.json` bytes), `ledger_ref` (copied from the
validator receipt), `validation_sha256` and `validator` (R5.5). It is not stored as a
file, because it names its own commit. It is fully recomputable from the committed
record and chain, so an append and every identical replay print the same bytes.

### R7. Read and list: the consumer interface

1. `read` validates the receipt as a canonical storage receipt, then under the lock
   captures the tip, validates the chain, and requires: the store identity equals the
   receipt's; `commit_id` is on the chain and adds `record_key`; the receipt rebuilt
   from that record equals the supplied bytes exactly. A missing record is
   `E_NOT_FOUND`; any other mismatch is `E_IDENTITY` or `E_CORRUPT`. It copies the
   three record blobs into memory and releases the lock.
2. It then requires the running validator's script and program digests to equal the
   record's `validator` entry (`E_VALIDATOR` otherwise), re-runs the validator on the
   read bytes as in R5.1-R5.4, and requires its stdout to equal the stored
   `validation.json` bytes. The jq digest may differ from the record's only as one of
   the two platform digests the same validator script pins
   (`validate-trace-ledger.sh:74-75`), so a record appended on Darwin reads on Linux.
   A record made by another validator revision is never read as this one's; it stays
   intact for a checkout of the revision it names.
3. Only then it creates `OUTPUT` with no-follow, exclusive creation, mode 0400, writes
   the exact ledger bytes, checks size and digest through the open descriptor, and
   prints a `telemetry_trace_store_read` document: `storage_receipt_sha256`,
   `ledger_ref`, `validation_sha256` and the tip it read at. An existing, symlinked or
   in-store `OUTPUT` is `E_OUTPUT`. Ledger bytes never go to stdout.
4. `list` prints a `telemetry_trace_store_listing`: `store`, the captured `tip`,
   `record_count`, and one entry per record (`record_key`, `replay_key`,
   `event_count`, `commit_id`, `record_sha256`, `ledger_ref.sha256`), sorted by
   `session_id`, `attempt_id`, `final_digest` in byte order. It has no time order and
   no "latest" field. At most 1,024 entries and 1,048,576 output bytes.
5. `initialize` needs an empty root and prints the listing of the new store (zero
   records, tip = root commit). It never replays: a root holding only a partial store
   refuses with `E_INCOMPLETE`, any other non-empty root with `E_BOUNDARY`, and a
   caller whose reply was lost calls `list`.
6. This is the interface concern 11 binds to: it keeps each storage receipt and later
   reads by it. That wiring is concern 11's work.

### R8. Physical layout and the private writer

The store reuses the delivery ledger's proven Git-safety design as its own private
code, not as a shared module or schema (`work/durable-delivery-ledger/spec.md:322-516`,
`docs/delivery-ledger.md:65-87`):

1. The root holds only a permanent 0600 `store.lock` and `repository.git`, a bare
   SHA-1 repository written directly: fixed `HEAD` bytes `ref: refs/heads/records\n`,
   fixed `config` holding only `core.repositoryformatversion=0`, `core.filemode=true`
   and `core.bare=true`, and the one direct ref `refs/heads/records`. No other ref,
   packed refs, reflog, index, hooks, info, alternates, replacements, shallow state,
   worktrees, packs or extensions. The only tolerated interrupted-write names are
   `refs/heads/records.lock` and `objects/HH/tmp_obj_*`. Anything else is `E_CORRUPT`.
2. Every call takes one immediate non-blocking exclusive `flock` on `store.lock`
   (close-on-exec) and holds it until its last store read or write. A held lock is
   `E_BUSY`. The lock file is never removed.
3. Objects are written by the program itself: bounded zlib, exclusive temporary file,
   size and mode checked through the descriptor, atomic rename to an absent object
   name. An existing object is reused only after its exact content is checked.
   Publication exclusively creates `refs/heads/records.lock`, re-reads the ref for the
   compare-and-swap against the captured tip, writes the new id plus LF, and renames
   the lock over the ref. That rename is the only visibility point. Because Git never
   runs, ambient Git configuration, hooks, attributes, filters and credential helpers
   cannot apply.
4. Each non-root commit's tree has exactly `ledger.json`, `record.json`, `store.json`
   and `validation.json`, mode 100644, in that byte order; `store.json` is the root's
   blob. The root tree has only `store.json`. Commit content is fixed: `tree`, `parent`
   (non-root only), author and committer `ystack trace store <trace-store@invalid>
   946684800 +0000`, one blank line, message `ystack trace store\n`. Every call walks
   the single-parent chain from the captured tip to the root and checks every object
   id, every tree, every `record.json` (canonical, its digests and sizes equal the
   sibling blobs, its key recomputes), unique keys, and every loose object's content
   against its name. The `telemetry_trace_store_record` body holds exactly:
   `activation_state`, `authority_effect`, `store_id`, `record_key`, `replay_key`,
   `event_count`, `ledger_ref`, `ledger_bytes`, `validation_sha256`, `validator` and
   `store_package_sha256` (the program's own digest, recorded for audit, not enforced
   on read).
5. There is no garbage collection, pruning, repacking, repair, history rewrite or
   cleanup command. Unreachable objects and residue stay and count against R9.

### R9. Limits

Fixed in `store.json` at initialization, which must equal the program's own values,
and checked on every call. Every file counts, reachable or not, including residue and
`store.lock`:

| Limit | Value |
| --- | --- |
| Records per store (commits = records + 1) | 1,024 |
| Ledger input bytes | 1,048,576 |
| Validator stdout / stderr bytes | 16,384 / 4,096 |
| `record.json`, `store.json`, tree, commit content bytes | 4,096, 4,096, 1,024, 1,024 |
| Loose object files (temporaries included) | 8,192 |
| Filesystem entries under the root | 16,384 |
| Regular-file bytes under the root | 268,435,456 |
| Inflated object bytes (headers included) | 268,435,456 |
| Listing output bytes | 1,048,576 |
| Append admission reserve | 6 object files, 32 entries, 3,145,728 bytes in each byte counter |

An append to a store with 1,024 records, or one that does not fit the reserve, refuses
with `E_CAPACITY` before any write.
A store found over any limit, or with an over-limit object, is `E_CORRUPT`. At full
capacity, `read`, `list` and identical replay still work. There is no eviction.

### R10. Refusals

The complete stderr set, each with no store change beyond R11's residue:

| Code | Meaning |
| --- | --- |
| `E_USAGE` | Wrong verb, argument count, id or tip shape, or environment |
| `E_RUNTIME` | Interpreter, file, child or snapshot failure |
| `E_BOUNDARY` | R3.1-R3.2 placement failure, or a non-empty root at `initialize` |
| `E_INCOMPLETE` | A partial initialization with no published ref |
| `E_IDENTITY` | Store id, root commit or receipt identity mismatch |
| `E_BUSY` | `store.lock` held by another call |
| `E_LOCKED` | A stale `refs/heads/records.lock` blocks a new append |
| `E_INVALID:<code>` | The validator refused the bundle |
| `E_CONFLICT` | Same replay key, different bytes |
| `E_STALE` | `EXPECTED_TIP` is not the current tip |
| `E_CAPACITY` | The admission reserve does not fit |
| `E_VALIDATOR` | Read with a different validator script or program |
| `E_NOT_FOUND` | The receipt's record is not on the chain |
| `E_OUTPUT` | `OUTPUT` exists, is a symlink, or is inside the store |
| `E_CORRUPT` | Any R8 layout, chain, object or limit check failed |

### R11. Crash states

The closed list of states a killed process can leave, and what follows:

- **K1.** Killed before the first store write (validation, lock, checks): no store
  change. The private `/tmp` directory may remain; it is never read back.
- **K2.** Killed while writing an object temporary: a bounded `tmp_obj_*` file. The
  tip is unchanged; the next append against the same tip proceeds; the residue stays
  counted.
- **K3.** Killed after some complete objects, before the ref lock: unreachable
  objects. The tip is unchanged; a retry reuses them after checking their content.
- **K4.** Killed after creating `refs/heads/records.lock`, before the rename (empty,
  partial or complete lock bytes): the old tip stays valid. `read`, `list` and
  identical replay work; a new append is `E_LOCKED`. The store never removes the lock;
  the operator preserves and investigates, then removes it by hand outside this tool.
- **K5.** Killed after the rename, before stdout: the record is committed. An identical
  replay prints the same receipt and adds nothing.
- **K6.** Killed while holding `flock`: the kernel releases it; the lock file is not
  evidence of a live process.
- **K7.** Killed during `initialize` before its ref is published: every call is
  `E_INCOMPLETE`; nothing repairs or reuses it.

### R12. Proof, discoverability and restore

1. `scripts/test/telemetry-trace-store.test.sh` proves each item below with real
   public calls on disposable stores, the pinned jq 1.6 fetched and digest-checked as
   `scripts/test/telemetry-trace-ledger.test.sh:18-40` does, and no credential, model,
   provider or target:
   - byte-exact read-back of both committed real sealed ledgers
     (`shadow/evidence/self-host-transition/v1/{pre,post}/state/trace-ledger.json`)
     after their scratch copy is deleted;
   - two fixture bundles with one session and attempt and different final digests
     both stored, listed in key order, neither marked newest;
   - identical replay after later appends, at full capacity and with a K4 lock:
     same receipt bytes, same tip, same file inventory and bytes;
   - conflicting replay (`E_CONFLICT`), stale writer (`E_STALE`) and a second writer
     refused while the first is held inside the lock (`E_BUSY`);
   - each crash state K2-K7, made by killing the process at the named step;
   - every validator refusal class, plus wrong session and attempt, returning
     `E_INVALID:<code>` with the store's full file tree byte-identical;
   - corrupt data: a changed object byte, a changed `record.json`, a missing object,
     an extra ref, packed refs, a symbolic ref, a reflog, alternates, an unknown
     config key, a second parent, and a chain that drops or rewrites an earlier
     record, each `E_CORRUPT` for every verb;
   - capacity exhaustion at each R9 counter (`E_CAPACITY`, nothing written) with
     read, list and replay still working;
   - every R3 boundary (`E_BOUNDARY`), `E_OUTPUT` and `E_VALIDATOR` case;
   - a hostile `HOME`, global Git config, hook, filter and credential helper, and each
     forbidden variable of R2.2: output and store bytes are unchanged, no marker file
     appears;
   - every printed document equals pinned jq 1.6 `-S -c` of itself;
   - the R2.5 import set, checked statically;
   - real Git, test-only and only in a separate copy of a closed store, reads the exact
     blobs, trees, commits and linear history, as in
     `work/durable-delivery-ledger/spec.md:437-490`.
2. Private test controls load the program into a test wrapper and replace named step
   functions or limit constants, as `scripts/test/delivery-replay.test.sh:166-191` and
   `:292-320` do. The shipped program has no environment, argument or file test seam.
   Barriers are pipe handshakes and kills at named steps, never guessed sleeps or
   retry-until-green.
3. `scripts/test/run-all.sh` finds the new test by name (`run-all.sh:66-69`), so it runs
   in the dispatched full `ci` matrix (`.github/workflows/ci.yml:117`, `:126`) with no
   workflow change. The implementation PR records a green dispatched `ci` on its exact
   head, plus a native Darwin run of both telemetry tests.
   `scripts/test/telemetry-trace-ledger.test.sh` must pass unchanged.
4. `docs/components.md` gets a store paragraph after the validator section
   (`docs/components.md:498-521`), and its closing sentence on later durable append
   (`:519-521`) is updated to name the store and its limits. `RESTORE.md` gets a restore
   step beside the validator's (`RESTORE.md:794-806`). `ci/required-files.txt` lists
   the two new files in the telemetry block (`ci/required-files.txt:269-272`).

## Design

The store is a write-once chain: one root commit naming the store, then one commit per
sealed bundle holding the exact bundle, the validator's exact receipt, a record
document and the store identity. The chain is bounded, so every call re-checks all of
it; no index can drift from the objects. Append is validate, lock, check, decide,
write, publish. The only visibility point is one ref-lock rename, so a crash leaves the
old view plus counted leftovers, or the new view with a lost reply that an identical
replay answers.

Python, as in the delivery ledger, writes Git objects without running Git and lets
tests stop or kill the program at a named step without a shipped hook. That ledger is
807 program lines (`orchestrator/v1/delivery-ledger.py`); this store is expected to be
of that order, so the plan states an evidence-based one-concern `review_size` range for
the implementation PR or splits it. This spec PR is `review_size: standard`.

## Out of scope

Live telemetry collection, incremental event editing, wiring any caller (shadow
driver, scanner, eval dashboard, publisher), retention or deletion beyond refusal at
capacity, signing, remote replication, a shared storage framework, changes to the
validator or its accepted evidence, and any credential, network, provider, scheduling,
activation, installation or target write.

## Areas of concern

- **Risk is high.** Durable identity, concurrency and repository isolation are
  security-sensitive. G2 acceptance is followed by an operator-merged plan-only PR
  before any code.
- **Duplicated writer code.** The object and ref writer repeats the delivery ledger's
  design in a second private program. The intent forbids a shared framework, so the
  duplication is deliberate and kept private to `trace-store.py`. Any further reuse
  returns to its own gate for a shared design.
- **Trust limits.** One trusted UID and a local filesystem with working `flock`,
  exclusive create and atomic rename are assumed. A hostile same-UID process,
  administrator rollback, power loss or disk failure is not covered. SHA-1 object ids
  are not signatures; record integrity rests on the SHA-256 digests the store checks.
- **Stale locks need a person.** K4 and K7 block writes until the operator acts, by
  design.
- **Read depends on the validator revision.** Changing the validator makes older
  records refuse `E_VALIDATOR` in the new checkout. They stay intact and readable with
  the revision they name.

Intent open questions, answered: record keys and same-attempt records, R4; store
location, identity and placement proof, R3; validator and jq binding, R5.5 and R7.2;
limits and refusals, R9 and R10; receipts, R6 and R7, all `telemetry/v1` package
documents (R1.4); crash states, R11; read and export safety, R7.3.
