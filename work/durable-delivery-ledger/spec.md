---
intent-blob: 6374d3ff7535c816e72c7294c620c36cc169df6b
risk: high
drafted: 2026-09-14
---
# Spec: Durable delivery ledger

Tracks #297.

## Requirements

### R1. Persist one planner ledger, without dispatch authority

Provide an inactive local store for the existing reconciliation planner. Its public
verbs are `initialize`, `read` and `apply-update`. They never execute a delivery.
Keep the planner, scanner, core generation and existing schemas unchanged. Stored
facts are caller assertions, not authenticated effects or exactly-once execution.

Every call names an absolute store root, a logical store ID and an immutable ledger
ID. Initialization also names an initialization ID and recording time. An update
names a unique update ID, exact expected Git tip, delivery key, action, recording
time and delivery ordinal. No arbitrary snapshot replacement or delete API exists.

The implementation accepts one bounded canonical JSON request file and emits one
bounded canonical JSON response on stdout. It emits no success bytes before all
validation and any publication have completed. Refusals return nonzero, empty
stdout and one bounded diagnostic code on stderr. A broken response pipe after
publication is a lost reply, never permission to roll back committed state.

### R2. Preserve the exact planner shape and produce its real reference

Snapshots have the exact `orchestrator_delivery_ledger` shape accepted by
`orchestrator/v1/reconciliation-plan.jq:178–205`: schema_version 1, stable id,
body.entries, body.recorded_at and body.ledger_contract. The contract records
actual entry count, maximum_entry_count 128 and schema identity
`orchestrator.delivery-ledger.v1`. No storage fields enter the snapshot.

Each entry retains delivery_key, state, delivery_count and last_delivery_at.
The key contains the four stage-key IDs, request_sha256, operation and attempt_number.
Operations remain dispatch-stage, retry-stage and recover-stranded-attempt; attempts
remain 1–10. Sort by initiative, workflow, stage, task class, request digest,
operation and attempt, exactly as the planner does. Entries are unique, at most
128, with delivery counts 1–1000. Never evict acknowledged or pending entries.

Export the snapshot's exact canonical bytes and compute SHA-256 over those bytes,
including their final LF. The reference contains kind, schema_identity, matching
ledger id and this genuine digest. The existing planner checks reference shape and
ID equality; it does not recompute the digest or enforce raw canonical input.
Storage must independently verify both. A planner pass alone is not this proof.

### R3. One update records one transition

Delivery ordinal counts deliveries of one immutable key. It is not attempt_number.
Only the following new updates are permitted:

| Current entry | Action and ordinal | Result |
| --- | --- | --- |
| Absent | record-delivery, 1 | pending, count 1 |
| pending or failed | record-delivery, current count + 1, at most 1000 | pending, increment once |
| pending | record-failure, current count | failed, count unchanged |
| pending or failed | acknowledge, any recorded ordinal 1 through current count | acknowledged, count unchanged |

All other transitions refuse. In particular, failure of an older delivery cannot
fail a newer pending delivery. A late acknowledgment of an earlier delivery of the
same key settles the key, including a later redelivery. Acknowledged is terminal:
new acknowledgment IDs are not no-op updates, and no new action can reopen it.
Exact historical replay remains valid. Different key fields identify different
entries; an acknowledgment cannot cross a key boundary.

New updates require recorded_at >= the current recording time; equality is allowed.
This is caller-supplied recording time, not authenticated wall time or external
occurrence time. A delivery sets last_delivery_at to it. Failure and acknowledgment
preserve last_delivery_at. Each new snapshot uses the update's recording time.

At count 1000, another delivery refuses; valid failure/acknowledgment still work if
history space remains. Existing keys can be updated at 128 entries, but insertion
of a 129th refuses. Overall history limits can be reached earlier than either
schema maximum; those maxima do not promise space for 128,000 deliveries.

### R4. Identity, replay and concurrency

After checking store identity and complete bounded committed history, look for the
update ID before checking stale expected tip, new time, transition or free capacity.
Identical stored request bytes return the original receipt and original commit,
without new objects, another count or moving the tip. This applies after later
updates, acknowledgment and full capacity. The same ID with different bytes is a
conflict. Only an unseen update must name the captured current tip and pass R3.

All publication uses the private Git-compatible direct-ref compare-and-swap
protocol below against the exact old OID, never force replacement, merge or
automatic retry on a new tip. A competing writer cannot overwrite another committed update. A busy store may refuse without
publication; this is distinct from a stale expected tip. Neither is automatic replay.

A read captures exactly one tip, validates that commit's full retained chain and
returns its complete snapshot. It never rereads the tip to combine newer metadata
with older ledger bytes. A later concurrent commit belongs to a later read.

### R5. Process interruption and finite storage

Support local Linux and Darwin filesystems with atomic same-filesystem rename,
exclusive file creation, reliable advisory flock and Git ref locking. The caller
and cooperating writers run as one trusted UID. After supported process termination,
a previously valid initialized store must reopen to the complete readable old or
new committed view; unpublished objects never count as an update. Unexpected runtime
residue is failed platform support, not a newly permitted unreadable-store outcome.
Only partial initialization before its first committed ref may return E_INCOMPLETE.
This does not claim survival of power loss, disk failure, filesystem rollback,
root or hostile same-UID edits. Git hashes are not signatures.

A valid store has at most 1024 update commits plus its initialization commit,
8192 loose objects, 16384 filesystem entries and 128 MiB total regular-file bytes,
including unreachable objects, temporary files and lock files. Count regular-file
logical lengths, not allocated blocks. Count every entry
before allocating unbounded input or object data. No pack files or pruning exist.
Maximum request bytes are 8192, snapshot bytes 262144 and response bytes 524288.
Each complete object inflates to at most 270336 bytes including its Git header
(at most 32 bytes), leaving at most 270304 content bytes. The 128 MiB inflated-byte ceiling counts those headers and contents for every
loose object, reachable or not. Charge each permitted temporary object file the
full 270336 bytes even if partial or smaller; do not try to treat truncated compressed
data as zero. Reject excessive depth, data or object count during bounded traversal.

Serialize object creation/publication under the store lock. Before a new update,
require room simultaneously for eight additional object files, 32 filesystem entries,
1 MiB of regular-file bytes AND 1 MiB of inflated bytes. Count object temporary files
in the object-file ceiling too. Refuse before any object creation if any reserve
fails. The six new objects have these content caps: identity 1024, request 8192,
ledger 262144, receipt 1024, tree 1024 and commit 1024 bytes. Their sum is 274432;
six 32-byte headers bring the sum to 274624. The single Python writer creates
at most one additional object temporary file at a time. Even charging that
temporary file its full 270336 bytes gives 544960 inflated bytes, below the 1 MiB reserve. Shared
existing identity/object bytes may reduce growth but never reduce admission reserve.

For regular-file growth, budget each compressed complete object at content plus
header plus 1024 bytes of compression overhead. Doubling the six-object sum for
conservative temporary duplication gives 561536 bytes; another 16384 bytes covers
fixed metadata/ref files, below 1 MiB. Six possible fanout directories, six final
objects, one simultaneous temporary and fixed repository/ref/lock entries fit the
32-entry reserve, including initialization's minimal layout. Build each bounded
object's complete compressed bytes before its file is created; reject compressed
length greater than content plus header plus 1024. Write only these prevalidated
bytes in bounded chunks, retaining correct partial-write accounting. Require actual
application tests on supported platforms to confirm temporary count, size high-water
marks, modes and metadata bounds. Unexpected behavior refuses; never raise limits.
Validate the actual resulting inventory before ref publication as a backstop, not
a substitute for write admission. The writer cannot allocate huge output then check.
At any capacity boundary, committed read and exact replay remain available without
object creation. A malformed or over-limit store refuses instead of hiding debris.

Do not remove old objects, partial initialization, unexpected files or stale Git
locks. A stale internal lock makes writes refuse immediately, with a bounded error;
read/replay may proceed only if the captured committed closure and file limits are
valid and the lock is an allowed bounded regular file. A persistent advisory lock
file is not evidence that its former process is alive. No cleanup/recovery command
is introduced. An operator can preserve and investigate a blocked store separately.

### R6. Required proof

Before G2 selection, finite authorized disposable research may assess tool startup,
minimal Git layout and object/ref compatibility. Earlier external-Git lock-FD
observations remain historical evidence for that different writer mechanism. These observations
are tool feasibility evidence only, not public application, peak-allocation or
all-platform proof. G2 does not require writing the application before its plan.
After G2 and the separate high-risk plan gate, implementation acceptance requires
all actual public-entry proofs below on the supported platforms. Finite research
cannot replace or weaken any of them.

Keep the complete existing planner suite. In fresh processes, pass actual exports
to the unchanged planner for empty first dispatch, pending redelivery without an
extra slot, failed redelivery, acknowledgment suppression and pending keys absent
from the observation. Independently hash exported ledger bytes. Demonstrate that
an intentionally wrong reference can pass the planner's shape gate while storage's
own closure/reference validation refuses corruption; do not change planner claims.
Read, exact update/init replay and pre-admission refusal must validate the real
bounded inventory and complete committed closure without spawning Git, creating
objects or changing application file bytes/shape. This is not a claim about kernel
access-time bookkeeping. At capacity, these actual public paths remain available.

Cover every R3 allowed/refused edge, late acknowledgment, obsolete failure, all key
fields, counts 1/999/1000/1001, entries 0/128/129, equal/increasing/backdated times,
year 0000, Gregorian leap days in 1900/2000, second 60, fractions and offsets.
Cover canonical violations, duplicate keys, bad integers, bad IDs, wrong identity,
wrong tip, exact replay after newer updates/ack/full, and changed replay content.

Use two actual writer processes with distinct updates and the same expected tip.
Each first performs a real public read. A private barrier after those reads
releases their apply calls with that same captured expected tip; exactly one may
publish. A busy loser is retried once as a separate deliberate stale-tip test, not
as transaction recovery or retry-until-green, and must then refuse stale state.
Also exercise the real CAS failure branch after a test-only intervening ref update
that publishes a fully valid competing chain. Build that chain through the actual
application in a separate fixture, then perform a controlled test-only copy/ref
publication before the actual CAS boundary. This is deliberate fixture interference,
not support for production writers that ignore flock. Never replace CAS with a fake
result or run Git against the application store.

SIGKILL an actual writer after its real object writes and before real ref update,
and separately after real ref publication but before stdout response. Private test
wrappers call the real operation and acknowledge the reached boundary over pipes;
missing boundary acknowledgment fails. Reopen in fresh processes, assert exact
old/new tip, history, digest and counts, then replay the lost-response request.
Test lost initialization reply, partial initialization refusal, orphan accounting,
full read/replay, stale locks and invalid config/ref/object/path state. Independently
exercise reachable physical-byte, inflated-byte and object-count reserve
exhaustion. In particular, create a valid store with compressible unreachable objects
near the inflated ceiling but ample physical/object headroom. Require the actual
new update to refuse before adding any object or temporary file, then require read
and exact replay to succeed. Use that preservation proof for each reachable reserve.
At refusal, prove committed bytes remain usable whenever the state is otherwise valid.

The unchanged 16384-entry ceiling and 32-entry reserve are defensive but dominated
by the closed layout: at most 8192 object/temp files, 256 fanouts, five fixed
directories including root, and five fixed files including ledger.lock give 8458
entries. Require an actual otherwise-valid high-entry-count fixture with complete
enumeration/count checks and successful read/replay. Separately exercise the actual
private entry-counter threshold at 16384/16385 and admission arithmetic at
16352/16353 with explicitly synthetic counts; these are defensive-boundary tests,
not valid-store exhaustion. An actual oversized malformed directory fixture must
refuse without mutation. Do not add paths or alter any numeric ceiling to manufacture
independent entry exhaustion; never call the malformed fixture valid/readable.

The application creates no subprocess, fork, worker thread, external writer or
Git command. Its one Python process owns the permanent flock for every state
mutation. While it is held at a proved real mutation boundary, a second real public
caller must return E_BUSY without mutation. Kill the actual writer with SIGKILL,
observe its exit, then reopen in a fresh process and verify the old/new view,
permitted partial temporary/ref-lock residue, and replay. No surviving product
writer is permitted. This replaces the external-Git prepared-child case because
that child no longer exists; retain all ordinary before-ref/after-ref/init proofs.

Observe real object creation, each actual partial write, close and rename, and
ref-lock creation/write/close/rename. The implementation keeps these private bounded
primitive boundaries explicit. A private test loader may execute the exact unchanged
production source with its normal main entry and argv after wrapping those primitives.
The wrapper calls the saved real operation, records the actual FD/path/byte count,
and acknowledges the reached boundary over an outer-owned pipe before returning.
The outer supervisor inventories the held store or kills that actual writer. A
supplementary partial-write fixture limits the size passed to the real write; it
must report the real return value, never fake a completed write. Test empty/partial/
complete object temps and partial/complete ref locks, ordinary write/close/rename
errors, and lost responses. Missing acknowledgment fails; no guessed race sleeps.

Test-only instrumentation stays outside the shipped source: no product pause
switch, environment selector or alternate public command. It may observe actual
primitive calls, not replace transitions, CAS comparison, bytes, admission, lock
results or publication with fake success. First run the identical instrumented
entry without a pause/fault and compare its outcome, committed bytes and layout
with the ordinary direct public invocation. Then exercise the real production
entry logic at the acknowledged boundaries. These are instrumented application
crash/peak tests, not evidence that an instrumented loader is the ordinary executable
invocation. All ordinary success/refusal/startup cases also use the unmodified
absolute public command below, without a loader or added observation descriptors.

Prove the complete write-path inventory through source review plus actual operation
observations, including real per-write byte high-water marks and simultaneous named
files. All allocations are made by the one code-owned writer; no native Git child
can create an unobserved temporary. Test-only audit hooks may reject/record process
creation while executing ordinary code, but are supplementary to the closed source
and actual lifecycle checks. Neither source review alone nor final snapshots alone
are crash/concurrency/peak proof. Unexpected allocation, spawn, trace loss or missing
mechanism fails. No auxiliary cache, extra root entry, undeclared application scratch
or writer outside the permanent flock is supported.

Use real disposable repositories and independently test Git interoperability as
specified below, never execute Git against the application store under test. Check
complete application roots in fresh and reused cases. Record executable/platform
identities and invalidate affected evidence when they change. No network, real
target, privileged observer, tracing-permission change or installation follows.

Exercise the actual chosen Python public invocation, not only imported functions or
a toy Git parent. It must use an explicitly identified existing trusted interpreter
with isolated startup, disabled site customization and disabled import bytecode
writes (Python's -I -S -B modes), and no caller-controlled import/search path. The
plan records the supported absolute invocation and interpreter identity. Verify
startup/imports do not write the source checkout, target or undeclared application
locations. Git-free paths alone are not proof that Python startup is write-free.
No install, startup-write exception or new interpreter-selection authority follows.

Run boundary proofs on supported Linux and Darwin; source reading alone is not
crash or concurrency evidence. Existing CI, shellcheck 0.11.0, schema and rename
checks remain required. Tests must report uncertainty or fail, never skip a required
supported-platform case because its boundary was missed.

## Design

### Private files and command contract

Implement `orchestrator/v1/delivery-ledger.py` using Python 3 standard library
and the private Git-compatible object/ref writer below. Add
`scripts/test/orchestrator-delivery-ledger.test.sh` and
`docs/delivery-ledger.md`; update `docs/components.md` and `ci/required-files.txt`.
These five paths are the implementation scope. No shared storage framework or
change to `delivery/v1/replay.py` is needed. Its bounded file reads and private flock
patterns are references, not authority for this different consumer.

The command takes exactly `VERB STORE_ROOT REQUEST_FILE`. Each request is a closed
object with protocol `ystack.delivery-ledger.v1`, store_id and ledger_id.
Initialize adds initialization_id and recorded_at; read adds no fields; apply-update
adds update_id, expected_tip, delivery_key, action, recorded_at and delivery_ordinal.
IDs match `[a-z0-9][a-z0-9._:-]{0,127}`; expected_tip is a lowercase SHA-1 Git
OID of 40 hex characters. Ledger/request digests remain SHA-256, not Git object IDs.

Use ASCII-only value shapes already required for IDs, times and fixed strings.
Numbers are unsigned ordinary decimal integers at most 2147483647, with stricter
field limits above, and no Boolean-as-integer, float,
exponent or negative zero. Recursively sort object keys, compact separators, no
optional escaping, and exactly one final LF. Reject duplicate keys, BOM, extra
JSON documents, whitespace variants and noncanonical raw bytes by bounded parsing
and exact reserialization comparison. Validate Gregorian dates explicitly, including
year 0000; do not inherit a narrower datetime library range. Use Python serialization
for these restricted values and prove byte equality against actual pinned jq 1.6
`-S -c` on complete fixtures and boundary values. jq is a test dependency only.

Successful responses have protocol, store_id, ledger_id, current_tip, result_tip,
receipt, ledger and ledger_ref. The ledger is embedded as a JSON object; extraction
with the specified canonical encoding recreates the exact stored ledger file,
including LF. For read, receipt is null and result_tip=current_tip. For initialize
and update, receipt contains the committed request identity, its SHA-256 and the
result ledger SHA-256; result_tip is the commit that recorded it. Replay returns
that original ledger/receipt/result_tip, with the separately captured current_tip.
The protocol does not claim a replay's historical snapshot is today's view.

### Dedicated Git layout and closure

The root is a caller-owned 0700 real directory outside every checkout ancestor,
including ystack's source checkout; reject .git files/directories in its ancestors.
Reject symlink components, root overlap with the source installation, group/other
access, non-regular inputs and input paths inside the store. Open the request with
no-follow/nonblocking checks and bound its bytes. Require a physically resolved
path; Git discovery, caller cwd and environment cannot choose another repository.
The caller remains responsible for naming a dedicated location outside any target
that has no detectable checkout marker. No hostile same-UID path-swap proof is made.

The root contains only a permanent 0600 `store.lock` and `repository.git`. Use a
single immediate nonblocking exclusive flock for all calls, including read; busy
returns E_BUSY. Capture the tip only once after locking in ordinary calls. The
concurrency test's private pre-lock observation barrier supplies the two requests'
common expected tip without weakening production lock coverage.

The one Python process owns all application writes and the permanent flock. Keep
its descriptor close-on-exec; never fork, exec, spawn a subprocess or delegate writes
to threads/helpers. No Git probe runs on any application path. Never call LOCK_UN;
close the owned descriptor at the end, and never unlink the permanent lock file.
SIGKILL ends that sole writer and closes its descriptors; no finally handler or
child cleanup is needed to prevent later application writes. A busy reader/writer
refuses immediately. Normal errors stop issuing writes, close owned descriptors and
preserve permitted residue. An uncertain publication is resolved by reopening, not
rollback, retry on another tip or cleanup. No new public wall-time guarantee is
claimed for a blocked local filesystem syscall. The former external-Git command
and child-reap deadlines apply only to isolated test-only Git commands below.

Create a bare SHA-1 repository directly with the minimal required directories,
fixed HEAD bytes `ref: refs/heads/ledger\n`, and fixed config containing only
core.repositoryformatversion=0, core.filemode=true and core.bare=true. No `git init`
template copying or caller repository config is needed. Only the direct ref
`refs/heads/ledger` is permitted. No other ref, reflog, packed-refs, worktree, index,
hooks, alternates, replacements, shallow/promisor state, object packs or extensions.
Directories are owner-only; ordinary metadata files are 0600, immutable object files
are 0400 or 0600, all caller-owned regular files with no symlinks or external hardlinks.
The only tolerated interrupted-write names are the ledger ref
`refs/heads/ledger.lock` and Git loose-object `objects/HH/tmp_obj_*` files, each
bounded by the object limit and inventory. They are not valid object identities.
The application uses umask 077 and explicit creation modes; unsupported observed
modes refuse before publication. Define exact fixed metadata bytes and reject
unknown configuration rather than overriding it. Git never interprets application
configuration during a public operation.

Create fixed directories only with exclusive mkdir and mode 0700, charging each
entry first; validate an existing permitted directory rather than replacing it.
Empty valid fanouts left by an interrupted update remain counted and readable.
During initialization only, create HEAD/config with exclusive no-follow regular
0600 files, bounded precomputed bytes and the same actual short-write/close handling
below. Charge their complete planned sizes before writing. Never rewrite existing
metadata, even if partial. A death/error during initial metadata creation before
the first committed ref leaves E_INCOMPLETE as already specified; this exception
does not apply to an initialized store. Include these mkdir/open/write/close paths
in actual boundary and peak tests, not only object/ref paths.

### Bounded private object and ref writer

Encode a Git object as its ASCII type, space, canonical decimal content length,
NUL and exact content bytes. Its OID is SHA-1 of these complete raw bytes. The only
written types are blob, tree and commit. Tree entries are the four fixed ASCII
names in byte order identity.json, ledger.json, receipt.json, request.json. Each
entry is ASCII `100644`, one space, name, NUL and its raw 20-byte OID, with no
separator after the OID. No caller revision expression,
pathspec, shell, filter or command is interpreted. Validate every content/header/
compressed-size cap before creating its object file. Stream bounded source chunks
into zlib, accumulate at most the permitted compressed length, and reject an excess
rather than allocate an unbounded output buffer. Retain only the capped current
object and bounded metadata; decoding and chain traversal keep the existing bounds.
Charge the reserved growth before each create/write, including old residue, the
current fully charged object temp, fanout and ref-lock allocation. The validated
reserve cannot be spent twice; retain actual deltas until the operation ends.

Under the permanent flock, reuse an existing OID only after validating its exact
raw content against the proposed object. A collision or malformed object refuses;
never overwrite it. For an absent OID, create one permitted tmp_obj name in its
fanout with exclusive no-follow creation and mode 0600. New names have prefix
`tmp_obj_` plus 24 lowercase hex digits; try at most 32 exclusive names and refuse
on exhaustion. Older permitted bounded tmp_obj names remain residue, not identity.
Existing temp names are neither overwritten nor removed. Write only the prevalidated
compressed bytes in chunks of at most 65536 bytes; advance only by the positive
actual return count. Retry an interrupted write only when no bytes were reported;
zero/invalid counts and ordinary errors refuse. Verify size/mode through the owned
descriptor, close successfully, then atomically rename that complete temp to the absent final OID. No
partial bytes ever receive a final object name. Only the current bounded file is
in flight. Recheck final-path absence before rename; all cooperating writers hold
the same flock throughout. This absence-check/rename contract relies on the stated
cooperating-writer model, not hostile same-UID exclusion. No link-based publication
or overwrite of an existing object is permitted. An error leaves a bounded permitted
temp or complete unreachable object; there is no automatic residue cleanup. If a
close fails or ownership is uncertain, stop publication and exit after bounded
owned-descriptor handling; never retry a potentially closed/reused descriptor or
continue writing on a guessed handle. Keep flock until all state descriptors are
closed or the sole process exits.

After all objects and the complete next closure are validated and the actual store
inventory is rechecked, exclusively create refs/heads/ledger.lock. Never remove or
reuse an existing lock. While holding it, read the real direct ref again solely for
the CAS comparison against the request's exact old OID (absence for zero init OID).
This check does not replace the single captured tip used for history/read results.
A mismatch preserves the competing committed view and refuses publication. Write
exactly the new 40-hex OID plus LF to that regular 0600 lock with bounded short-write
handling, close it, then atomically rename it over the direct ledger ref. This one
rename is the only visibility point. The caller cannot select another ref; symbolic
or packed refs are invalid. Success consumes the lock by rename; failure preserves
it. Empty or partial bounded ref-lock bytes are allowed interrupted-write residue;
read/replay validate the original committed ref/closure without parsing that lock
as the current tip. Never truncate the final ref or object on an error path. An
uncertain rename/response is settled by fresh public read/replay. No reflog, repair,
pruning, background writer or force-update API exists.

All supported product writers obey the permanent flock, including object creation.
Compatibility with Git's ref-lock convention does not authorize concurrent arbitrary
Git writers: their loose-object allocations would escape this store's accounting.

### Test-only Git interoperability

The application needs no Git executable or Git environment. Independent tests use
only already installed `/usr/bin/git` on Linux and
`/Library/Developer/CommandLineTools/usr/bin/git` on Darwin, with exact byte/platform
identity recorded. No fallback, xcrun/xcode-select, DEVELOPER_DIR override, download
or tool installation. Git runs only in a fresh private interoperability repository,
never the active application store or a source/target checkout. With the application
exited, copy only its validated object/ref/HEAD/config bytes into that separate
fixture; log/inventory both fixtures separately. Git-created cache, ref locks or
metadata cannot be attributed to or repair the application store.

Build the test Git environment from empty: PATH=/usr/bin:/bin, LANG=C, LC_ALL=C,
HOME=/dev/null, TMPDIR=that interoperability root, GIT_CONFIG_NOSYSTEM=1,
GIT_CONFIG_SYSTEM=/dev/null, GIT_CONFIG_GLOBAL=/dev/null, GIT_NO_REPLACE_OBJECTS=1,
GIT_NO_LAZY_FETCH=1, GIT_TERMINAL_PROMPT=0 and GIT_ATTR_NOSYSTEM=1. Supply explicit
repository and `-c core.hooksPath=/dev/null`. Only test commit creation additionally
supplies the exact fixed author/committer values below. Fixed object/tree/commit/ref
plumbing only, no checkout, arbitrary command, source access or network.

Require actual Git to read exact blob bytes, tree entries, commit metadata and
parent history from application-produced fixtures and resolve the expected tip.
Compare the application's encoded object OIDs against actual Git for complete and
boundary fixtures. Independently create a valid chain through real Git, then use
only a validated separate copy to test the real application reader. Also test actual
Git refusal with a held conventional ref lock and wrong old OID in the private
interoperability fixture. Those tests establish compatibility, not application CAS
or recovery; real application cases remain mandatory. Git tests have bounded stdout/
stderr, a ten-second command deadline, exact-child TERM/one-second reap then KILL/
one-second reap, and fail on unconfirmed cleanup. No test child touches the application
store or supplies its lock-lifetime proof.

Python performs bounded direct-tip, loose-object and full-chain validation on every
public path. Read, exact replay and pre-admission refusal create no objects and
change no application bytes/shape. Do not replace OID, canonical-byte, digest,
identity or transition checks with unchecked output or a general storage API.

Each commit tree has exactly `identity.json`, `request.json`, `ledger.json` and
`receipt.json`, regular blobs with Git mode 100644. Identity binds protocol,
store_id, ledger_id and initialization_id and never changes. The root commit holds
the initialize request and empty ledger. Each later commit has exactly one parent
and one R3 update. Receipt excludes its own commit OID, avoiding a hash cycle.
Encode author and committer as `ystack ledger <ledger@invalid> 946684800 +0000`,
in this exact commit content order: `tree <40hex>\n`, then for an update only
`parent <40hex>\n`, then `author ` plus that fixed value and LF, `committer ` plus
that fixed value and LF, one empty line, and `ystack delivery ledger\n`.
There are no extra headers or signature. Only tree and parent determine changing
commit content. Interoperability tests supply equivalent Git author/committer names,
emails and `2000-01-01T00:00:00Z` dates and compare actual serialization under the
unchanged commit cap.
Recompute object OIDs, raw canonical bytes, genuine digests, identity, every
transition and each receipt through the entire captured chain on each call.
Unreachable objects count toward limits but never supply replay or current state.

### Initialization, publication and recovery

Initialize accepts an existing empty owned root or an existing valid store with
exactly matching initialization request. Exclusive creation establishes the one
persistent store.lock before any repository files are made; actual flock ownership,
not creator identity,
selects the initializer allowed to proceed. A lock-only root with no repository
bytes may initialize after acquiring flock. If repository bytes already exist,
validate them; never reset an incomplete repository. A competing initializer may
return E_BUSY and be explicitly called again with its original request.
A crash before the first ref leaves no usable ledger and may leave partial layout;
report E_INCOMPLETE, preserve it and require explicit external disposition. This is
not successful initialization or automatic recovery. A crash after ref publication
supports exact initialization replay even after subsequent updates. A changed
initialization request conflicts. Ordinary read/apply never initialize implicitly.

Build and validate all next bytes first. Write the four blobs, tree and commit with
the bounded private object writer, then publish the one direct ref with the exact
old-OID ref-lock/rename protocol (all-zero OID for initialization). The ref is the
sole visibility point. Recheck
actual inventory before publication. CAS failure leaves only bounded unreachable
objects and permitted ref-lock residue; no response claims an update occurred.
No unpublished candidate is automatically adopted on reopening. Replaying a request
whose earlier process stopped before publication is a new attempted update against
its original expected tip; it may succeed only if that tip still matches.

## Out of scope

Dispatch, workers, scheduling, listeners, retry execution, external acknowledgments,
forge projections, remote Git, credentials, models, installation, activation,
qualification, target/source branch writes, source assembly, session/trace/result
storage, a general database API, migrations, pruning and automatic cleanup.
No change to planner semantics, core schemas, generation or capability boundaries.

## Areas of concern

Risk is high because durable identity, state transitions, concurrency and repository
isolation are security-sensitive boundaries. G2 acceptance must precede a separately
authored and independently reviewed high-risk plan and implementation. The plan must
estimate all parsing, closure validation, limits and real boundary tests honestly;
no measured implementation size exists yet. Propose a justified one-concern size
range there if the standard budget cannot hold complete readable implementation.

This resolves the intent's transition/replay questions through R3/R4 and its recovery
questions through R5/R6. Partial initialization and stale internal locks deliberately
fail closed without automatic repair. Supported process-crash recovery requires a
valid committed closure and the stated filesystem semantics; power-loss durability
and adversarial same-UID forgery remain unproved. No known north-star conflict is
introduced. Further dispatch authority is a separate dependency, not supplied here.
