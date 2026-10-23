---
spec-blob: 883360cc9efe778669c55b9417c7eaa8de425b1c
drafted: 2026-09-14
---
# Plan: durable-delivery-ledger

Tracks #297.

Draft for independent review. Risk: high. Gate mode: artifact-high.
This proposes review_size: accepted-exception, 2400–3250 net implementation lines.
It does not accept that range or authorize code. The manager must first complete
independent plan review, required CI and the separate protected plan merge.

Source base: fcc0d1dc512ec562197d7073f72f223d3e0b398f.
Intent: 6374d3ff7535c816e72c7294c620c36cc169df6b.
Spec: 883360cc9efe778669c55b9417c7eaa8de425b1c, accepted by PR317.
This plan is new. The earlier blocked provisional plan supplies no accepted choices,
size allowance or proof. All539 lines of the accepted spec and the full intent were
read from main. Current AGENTS/REVIEW and plan-draft rules retain separate author,
reviewer and coder roles; this document grants no runtime activation or live use.

## Files that change

Exactly five implementation paths:

| Path | Change | Estimated net lines |
| --- | --- | --- |
| orchestrator/v1/delivery-ledger.py | New Python3 standard-library command, mode0644; fixed protocol, validator and single writer | 950–1250 |
| scripts/test/orchestrator-delivery-ledger.test.sh | New executable focused suite, with private Python fixtures/observer emitted from readable heredocs | 1350–1850 |
| docs/delivery-ledger.md | New invocation, state, limits, proof boundaries and restoration guide | 80–110 |
| docs/components.md | New inactive ledger section adjacent to reconciliation planner | 15–30 |
| ci/required-files.txt | Append the three new restore-critical paths, preserve existing entries | 3–5 |

The sum is2398–3245; proposed rounded allowance2400–3250. This is a planning
estimate, not a measured implementation. The code estimate includes roughly200
lines canonical/request/transition logic,200 path/inventory checks,250 object/chain
validation,200 write/accounting/locking logic and100–400 interface/error handling.
The test estimate includes roughly300 fixture/runner/tool lines,300 observer and
ownership lines,300 protocol/planner cases,250 corruption/resource cases and200–700
crash/interoperability/platform cases. No test matrix may be cut or code compressed
to fit. An observed overrun pauses for a separate size/plan review with measured
components, preserving the same attempt. No general storage library is introduced.

Do not edit intent/spec/plan in implementation. Do not change planner, schema,
core generation, existing tests, workflows, RESTORE.md or resolver WIP. Put the
restoration instructions in the new guide and link them from the component section.
The existing filename-discovering test runner includes the new focused suite without
a workflow change. Its addition changes shard distribution; reprove full coverage.

## Order of work

### 1. Preflight and test foundation

After the plan gate and manager claim, verify exact main/artifact/claim/branch tuple
and create only the authorized implementation worktree. No old blocked plan or
finite experiment substitutes for the accepted brief. Before first code, recheck
plan-base under current policy. Preserve the first test-first red result.

Write readable focused-test fixture and assertion helpers first. Use one shell
entry with a fixed private Python harness emitted outside all application stores.
Keep reusable fixture/assertion functions within that test; no extra committed helper
paths. A generated private file is test infrastructure, never a product dependency.
Record named test groups and actual case counts; no success path may skip a group.

Choose tools by the test host's existing /usr/bin/uname result. Production has no
platform selector or subprocess. Supported test hosts are Linux:x86_64 and Darwin
with the already installed compatible direct interpreter/jq binaries. An unsupported
host/tool fails explicitly; do not download an interpreter, install translation,
change developer selection, or substitute another executable to obtain proof.

Public command, with absolute physical source path, is exactly:

- Linux: /usr/bin/python3 -I -S -B SOURCE/orchestrator/v1/delivery-ledger.py VERB STORE_ROOT REQUEST_FILE
- Darwin: /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python -I -S -B SOURCE/orchestrator/v1/delivery-ledger.py VERB STORE_ROOT REQUEST_FILE

The trusted caller supplies those arguments; no shebang/PATH entry or environment
variable selects an interpreter. Tests invoke via exec argument arrays, never a
shell-assembled command. Linux /usr/bin/python3 may be a distribution-owned symlink:
resolve its complete physical target, require root-owned non-writable ancestry and
record both link text and terminal executable digest. Darwin uses the explicit
non-symlink framework entry; no Versions/Current or CLT bin launcher fallback.
Record executable bytes, architecture, actual version, flags and imported native/
standard-library module origins before/after proof. A changed identity invalidates
affected evidence, rather than silently adopting the old result.

Known Darwin research identity is executable SHA256
295b2fd03b2b05f12b6f4887d70dbf43e5358173f8eec0909c121c9bdec2756f,
framework SHA2566d3f7badc96687779a34b0bb10b74800b69cd97f7cda4a39a41a35e5d7175d01,
Python3.9.6 on Darwin27 arm64. These identify prior finite research, not a product
release pin or future pass. Linux actual identity must be recorded on required CI.

The supported caller starts from an empty environment containing only
PATH=/usr/bin:/bin, LANG=C, LC_ALL=C, HOME=/dev/null, TMPDIR=validated STORE_ROOT.
Cwd is that physical store root; stdin is /dev/null. Only stdout/stderr pipes survive
in ordinary proof. Read/apply do not create a missing store; callers must provide
an existing owned root. This environment is a launch precondition, not an in-process
claim that Python can undo native startup injection after it happened. No caller
PYTHON*, DYLD*, LD*, Git config, hook or credential environment is inherited.
No outside-store application temporary directory is permitted.

Keep product imports closed to errno, fcntl, hashlib, json, os, re, stat, sys and
zlib; helpers may use builtins only. Do not import subprocess/threading/tempfile or
load caller files/modules. If an additional import becomes necessary, record and
review its startup/native effects before relying on old evidence. Bytecode is not
written under -B; trusted pre-existing bytecode reads are not falsely excluded.
Hash actual loaded native module files and Python source origins in supplementary
instrumented provenance, plus direct-entry source identity. This does not make that
instrumented loader ordinary startup proof.

Self-contained jq1.6 setup copies the existing planner test's fixed dependency
recipe, before any measured application root or entry. Select jq-linux64 on Linux
x86_64, SHA256af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44;
on Darwin select jq-osx-amd64,
SHA2565c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef.
Use only https://github.com/jqlang/jq/releases/download/jq-1.6/ASSET with that closed
asset mapping. Verify every cache hit; otherwise use an exclusive private download,
curl --proto '=https' --tlsv1.2 -fsSL with connect timeout10 and total timeout60,
verify digest before chmod0555 and copy to private test bin. Verify digest/version
again on the private copy. No reliance on prior test or shared shard order. Do not
repair an unverified cache in place; an owned new temporary is published only after
verification. Download failure fails the suite, not a skip or alternate version.

This is the already shipped development/CI tool prerequisite, explicitly separated
from the spec's no-network application and disposable ledger execution. It is not
runtime download, host installation, a new provider or target network permission.
The manager confirmed this scope interpretation and the separate complete
ledger-jq-provisioning-scope-review.md found it consistent with the existing setup
(source test11522aa24c48904d79f3ae91b6376a32af2d3fc3). Independent plan review must check
it against the accepted spec; R6 itself grants no downloads. A contrary review
returns this prerequisite for resolution before code. Existing planner tests remain unchanged and are run in full separately.

### 2. Fixed protocol and pure state transitions

In P1 and P4, run the already verified private jq1.6 executable with actual
`-S -c` on complete valid request, identity, receipt, ledger and response fixtures.
Compare exact bytes including the final LF with actual product responses and
canonical blobs from actual committed stores; obtain blob bytes independently from
validated copies using test-only Git. Compare the stored request as well as generated
identity/receipt/ledger. Keep nested key sorting, arrays and null response receipt in
the comparisons, not only individual scalar examples. Include restricted ID length
boundaries and characters, applicable integer/count/attempt bounds, and valid
Gregorian dates, including valid0000-02-29 and2000-02-29; keep invalid1900-02-29
in the separate actual public refusal cases. For the private restricted serializer's
larger integer limit2147483647, label its scalar boundary comparison separately from
public fields whose narrower limits must still refuse. The exact command is
`"$jq_bin" -S -c . "$fixture" > "$oracle"`, followed by an exact byte comparison;
this must run on both supported platforms inside the focused suite.

A deliberately changed key order, spacing, escaping or omitted LF must produce an
oracle comparison failure and, when supplied as a public request, actual E_INPUT.
Do not feed a forbidden product input through jq and then call its normalized result
proof that the original input was accepted. Valid canonical oracle fixtures and raw
refusal fixtures remain separate. Independent SHA256/reference and actual planner
checks stay required; they do not replace this byte oracle.

Implement exactly the accepted three verbs and closed request fields. Use bounded
raw reads, strict ASCII restricted values, duplicate-key rejection, exact integer
type checks (bool is not int), maximum2147483647 and per-field limits. Reject root
arrays/scalars before field access. Canonical bytes are recursively sorted compact
JSON plus exactly one LF; compare reserialization to original. Reject BOM, trailing
data, optional whitespace/escaping, negative zero, float/exponent, non-ASCII IDs and
unknown/missing fields. Use a bounded nesting pre-scan before JSON decoding so an
8192-byte nesting bomb does not become an uncaught recursion error.

Use exact nested stage_key fields initiative_id/workflow_id/stage_id/task_class_id,
request_sha256 lowercase64hex, the three accepted operations and attempt_number1–10.
IDs use the spec128-character pattern. Sort by the seven specified fields, with
attempt numeric. Validate Gregorian dates manually, including year0000 and century
leap rules, rather than datetime's narrower year range. Compare validated fixed-width
UTC timestamps lexically; reject offsets/fractions/second60.

Choose closed stderr codes with one LF, no caller data: E_USAGE, E_INPUT, E_STORE,
E_IDENTITY, E_CONFLICT, E_STALE, E_TRANSITION, E_LIMIT, E_BUSY, E_INCOMPLETE, E_IO.
Exit2 only for argument/verb misuse; other refusals exit1, stdout empty. Unexpected
ordinary OS errors map to E_IO without traceback. A bounded error write failure still
exits nonzero. Success returns0 only after the complete prepared response is written.
After partial stdout/broken pipe the operation may already be committed: report no
rollback, exit nonzero and resolve by fresh read/replay; never call that a prepublication
refusal with guaranteed empty stdout. Cap diagnostics at64 bytes and response at524288.

Prepare all R3 updates in memory from a fully validated state. Capture no wall clock.
Delivery ordinal is separate from attempt number. Preserve last_delivery_at for
failure/ack, record update time on snapshot, enforce acknowledged terminality and
all count/entry limits. Derive receipt as a closed object containing request_kind,
request_id, request_sha256 and ledger_sha256; request_kind distinguishes initialize
and apply-update, and request_id is the appropriate initialization/update ID. The
receipt contains no commit OID. Identity is the closed protocol/store_id/ledger_id/
initialization_id object. These private stored formats are fixed and fully validated.

### 3. Bounded store and complete history validator

Use physical absolute path checks, no-follow lstat/open/fstat and nonblocking input
open. Reject symlink components, nonregular files, foreign owner, group/other access,
external hardlinks, input inside store, source/root overlap, and any checkout .git
file/directory in store ancestry. Internal hardlinks are unnecessary: require regular
file nlink1 for newly created state and refuse other links unless the spec's existing
no-external-hardlink condition is proved without broadening allowed layout. The plan
chooses to validate complete internal inode membership when nlink>1, not silently
strengthen that accepted existing-store condition to nlink1-only.

Include an otherwise-valid internal-hardlink positive fixture: a complete loose
object and an allowed bounded temp alias share one inode, with all links within
the inventoried store. Actual read/replay must accept complete membership and count
each path's regular bytes; charge the temp path's full270336 inflated bytes as well
as the complete object's raw length. A separate alias outside the store must refuse.
This prevents an nlink1-only shortcut without adding a product hardlink writer.

Inventory incrementally with scandir and bounded no-follow metadata. Count every
entry including root, every regular st_size, each object or permitted temp exactly
once, and object inflation by physical path. Reject unknown names/types/config,
excess depth, packed refs/objects, hooks, alternate/replacement/shallow/promisor state.
Validate exactly five fixed directories (root,repository.git,objects,refs,heads)
plus00–ff object fanouts. Empty valid fanouts remain counted and valid. HEAD bytes
are ref: refs/heads/ledger plus LF. Fix config bytes to:
[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n
No alternative formatting/config is accepted. Metadata0600, dirs0700, objects0400
or0600; temp/ref-lock regular bounded permitted residue. New ref-lock writes are
0–41 bytes; existing allowed regular ref-lock residue retains the spec's object-limit bound270336, charged as regular-file bytes. The
16384 metadata growth budget is not a smaller existing-ref-lock acceptance ceiling.
The lock is not interpreted as committed ref, even if partial.

Use chunked os.read at most65536 bytes. A complete object parser uses
zlib.decompressobj with strictly positive max_length, capped output and explicit
progress. At the exact raw limit use a one-byte excess detector, never max_length0
or unbounded flush. Reject zlib errors, missing eof, unused/trailing streams,
incorrect type/decimal header/NUL/header>32, declared-vs-actual length, raw>270336,
content>270304 and OID mismatch. Do not inflate partial tmp_obj files; charge270336.
Count global inflation≤128MiB before retaining decoded values; process unreachable
objects too. Do not retain all decoded object bodies at once: keep bounded metadata
and reload capped bodies as necessary. Names/classes/depth and input work are finite.

Read the direct40hex+LF tip exactly once under flock for normal view. Traverse at
most1025 commits, detecting cycles and illegal/multiple parents. Require exact fixed
Git commit serialization, four-entry100644 tree, fixed names/order and blob types;
validate canonical identity/request/ledger/receipt raw bytes. Walk root-to-tip and
recompute each transition, each digest and each receipt, rejecting duplicate update
IDs, wrong expected parent tip, altered identity, forged counts/time/state and
unreachable-object replay. Capture the current response from that one tip only.

For initialize replay compare exact root request even after later commits; changed
request conflicts. For update replay search validated history before stale tip,
transition/time or capacity. Return original ledger/receipt/result_tip plus captured
current_tip without writes. Ordinary read and all pre-admission refusals also run the
complete validator; invalid state never gains a successful stale/replay shortcut.

### 4. One private writer and exact allocation ledger

Set product umask077 before any file/directory creation; explicit modes and
postcreation checks remain. Create store.lock exclusively only for initialize on an
empty root, then obtain
immediate nonblocking exclusive flock before repository creation. Existing lock-only
root may initialize; existing repository bytes without committed closure refuse
E_INCOMPLETE without repair. Other calls never initialize implicitly. All paths,
including reads/replays, acquire the same permanent lock. Never unlink it or call
LOCK_UN. No production fork/exec/subprocess/thread/background helper exists.

Keep explicit ownership for each descriptor. Each close first removes its ownership
record so finally cannot retry a potentially reused number. A state-descriptor close
error stops publication; preserve flock and terminate via the top-level bounded
E_IO/os._exit path after attempting a bounded diagnostic. Do not allocate new state
or explicitly close flock after uncertain state close; process exit retires all
remaining descriptors. If only a normal response close fails after publication,
report uncertain delivery and preserve the committed ref. No filesystem fsync or
power-loss guarantee is invented. Ordinary successful closures release flock last.

Precompute each next canonical content and response bounds before creating objects.
Encode exact Git type/space/decimal-length/NUL and content, SHA1 over all raw bytes.
Tree bytes are fixed ASCII100644/name/NUL/raw20-byteOID in the specified order;
commit metadata is exactly the accepted fixed946684800 +0000 author/committer,
optional one parent and fixed message. Use zlib.compressobj with fixed standard
zlib stream settings; feed chunks≤65536, check each returned chunk and final flush
before appending. Raw input≤270336 and fixed zlib state bound returned buffers;
reject accumulated compressed size above raw_length+1024 before any file creation.
No arbitrary input can force uncapped compression input or retained output.

Admission requires all four original reserves simultaneously:8 objects,32 entries,
1MiB regular bytes and1MiB inflated bytes. Keep initial inventory, reservation and
actual deltas separate. Charge each prospective mkdir/open/write and every old
residue; reserve cannot be spent twice. Current temp is one object/entry and full
270336 inflated bytes from open, with its full compressed length charged before write.
Object rename transfers that charge to the final raw length only after success;
no unrelated bytes are refunded. New fixed metadata/fanout/ref lock also count.
Retain the accepted544960 inflated and561536+16384 physical conservative arithmetic.
Recheck actual complete inventory before ref publication as an additional check.

Reuse an OID only after complete raw-byte equality validation. Conflicting content
refuses without overwriting. New tmp_obj_ plus24 lowercase hex names use os.urandom
and at most32 exclusive no-follow open attempts, no reuse/unlink of old residue.
Create mode0600; use a single write_all helper with actual positive short counts,
no-byte InterruptedError retry, zero/invalid result or OS error refusal. fstat
confirms final size/mode; close successfully then recheck absent final and os.rename
within fanout. Keep final0600; no chmod/hardlink/unlink publication path exists.
This no-overwrite interval relies on all supported writers holding flock, not
hostile same-UID exclusion. Count empty fanout/crash temp/unreachable final as retained.

After all complete objects and closure/inventory validate, create ledger.lock
exclusively; pre-existing lock refuses new writes immediately. Reread the actual
ref solely for exact-oldOID CAS (absence for initialization). This does not replace
the earlier captured history view. Write exact41-byte newOID+LF, close successfully,
then os.replace ledger.lock→ledger. This is the sole visibility point. No stale-tip
retry, rollback, cleanup, orphan adoption, final truncation or lock removal follows
an error. A rename error/uncertainty stops all writes and fresh read determines state.
Build and emit success only after publication; broken response is recovered by replay.

### 5. Complete proof matrix and documentation

Use the groups below as the executable test ledger. Each group runs on Linux CI
and native Darwin; all ordinary operation cases call the exact direct public argv.
Table-generated cases must have readable names and independent expected results;
do not merely round-trip the same encoder as its own oracle. Run the full existing
planner suite unchanged in addition to the new focused suite.

| Group | Mandatory cases and real evidence |
| --- | --- |
| P1 protocol | Actual jq1.6 -S -c exact-byte oracle from step2 on complete product requests/stored blobs/responses and restricted boundary fixtures, including LF and nested ordering; deliberate byte-difference detection plus raw request refusal. All verbs, missing/excess args/unknown verb; rootarray/scalar; missing/extra keys; all invalid integer/ID/raw canonical forms; duplicate nested keys; byte limits8192/8193; timestamps year0000/1900/2000, invalid dates, second60/fractions/offsets; equal/new/backdated times. |
| P2 transitions | Every allowed/refused R3 state/action pair; ordinals0/1/current/older/next/beyond; late acknowledgment after redelivery, obsolete failure refusal, terminal ack no-op/new-ID refusal; each of seven key fields changes identity; attempts1/10/0/11; counts1/999/1000/1001; entries0/128/129 and existing-key update at128. |
| P3 replay/history | Exact init/update replay after newer update, acknowledgment and exhausted capacity; changed ID content conflict; original result_tip vs current_tip; wrong store/ledger/init identity; stale unseen expected tip;1024updates allowed and1025th refusal; no objects or byte/shape changes on read/replay/pre-admission refusal. |
| P4 planner | Export real app empty/pending/failed/ack snapshots to unchanged planner; first dispatch, redelivery without extra slot, acknowledged suppression and pending key absent from observation. Independently SHA256 exact LF bytes/reference. Wrong digest passes planner's shape check but a genuinely inconsistent stored digest/receipt or ledger closure is refused by app. |
| P5 invalid store | Symlink root/component/input/object/ref, FIFO/directory/device input, checkout ancestor/source overlap, mode/owner/link violations with nonprivileged fixtures or explicitly labelled private stat fault; wrong config/HEAD, symbolic/packed/extra refs, unknown names, packs/hooks/alternates, malformed/truncated/trailing zlib, bad headers/lengths/OID/type/tree order/mode/name/parents, forged identity/receipt/transition/digest and actual corrupted/overlong history; explicitly synthetic defensive cycle detection. |
| P6 resource | Independent actual reachable object/regular/inflated reserve exhaustion, each preserving valid read/replay and zero new objects/temp. Exact raw/header/content/output caps; compressed overhead before allocation; partial temp full inflation charge. Actual valid high-entry store, labelled synthetic16384/16385 and16352/16353 private counter checks, actual malformed oversized-directory refusal. |
| P7 concurrency/CAS | Two actual public readers obtain same tip; private outer barrier releases distinct direct-public updates. Exactly one publishes. If loser E_BUSY, one deliberate later stale call must refuse. Separate real CAS mismatch after controlled fully valid competing-chain copy/ref, no fake result or Git against app store. |
| P8 crash/write faults | Empty/partial/full object temps; after close/before rename and after each object rename; empty/partial/full ref lock; pre/postref rename; postpublication/preresponse and lost init reply; partial initialization mkdir/metadata; real short writes plus released continuation; actual write/close/rename failure paths and no continued publication. Fresh direct read/replay after every kill. |
| P9 peaks/sole writer | Complete source mutation inventory plus held observations after every real mkdir/open/write/close/rename on maximum-growth fixtures. Actual st_size/entry/temp/object/inflated highwater≤caps/reserves; second public caller E_BUSY during held writes after flock acquisition; actual SIGKILL and confirmed death before lock release/reopen. No source-only/final-snapshot replacement. |
| P10 interoperability | Fixed real Git reads separate copies of app-created raw blobs/tree/commit/history/OIDs, boundary contents and tip. Reverse real Git-created valid chain copied into separate app fixture then actual public reader. Real Git held-ref-lock/wrong-oldOID negatives are interoperability only, not product CAS/crash proof. |
| P11 startup/isolation | Fresh and reused direct public initialize/read/update/replay/refusal; actual isolated/no-site/no-bytecode interpreter flags and identities, declared imports/native origins, no added loader FDs. Entire store/source/test scratch/undeclared temp observations with setup excluded; no xcrun_db/pycache/new auxiliary entry. Poison caller env/search-path values are excluded by the exact empty-start launch. No runtime Git/network/process creation. |

Construct counts999/1000 and maximum history using one retained actual-public update
sequence with distinct IDs and deterministic times, sharing its independently saved
valid checkpoints between isolated fixtures. This is fixture reuse, not skipping
execution of the boundary calls or reusing stale test outcomes. Account for history
space so count1000 failure/ack cases use still-admissible snapshots. Reopen every
checkpoint through the real full validator before using it. Large unreachable-object
fixtures may use independent test encoding; they are inputs, not proof the app writer
works. Validate their exact physical/raw/object totals independently and through the
actual public reader before calling them otherwise-valid capacity cases.

Exercise defensive cycle detection with an explicitly synthetic private traversal
fixture/counter, never call it a real valid cyclic SHA1 history. Actual public
corrupt-object/OID and overlong-chain refusals remain mandatory and separate.

Some representation byte ceilings are also dominated by the closed field/count
limits. Do not label an8192-byte invalid request or oversized synthetic snapshot a
valid positive simply to reach a byte cap. Exercise maximum structurally valid
requests/snapshots/responses through actual public calls; exercise unreachable exact
serializer/length thresholds through explicitly private synthetic boundary cases
and real oversized-input refusal. Keep all existing ceilings unchanged. Header and
content overrun cases distinguish invalid encoding from genuinely valid boundary
loose objects, verified by the independent oracle.

For inflated reserve, add bounded compressible unique unreachable blobs leaving
physical/object headroom. For physical reserve use bounded incompressible blobs
whose actual compressed overhead makes physical usage cross127MiB while inflated
usage remains below127MiB; tune the final real blob using measured serialized sizes,
with finite construction bounds and fail if required separation is not achieved.
For object reserve add small unique valid loose blobs to8185 objects with other
headroom;8184 is the admission boundary. At cap-exceeding malformed cases assert
refusal/no writes, never read success. For valid high-entry coverage include all256
fanouts and up to8192 object/temp paths while keeping byte ceilings; derive actual
entry count rather than asserting8458 if some fixed files are absent. Never create
extra invalid names and call them a valid entry-reserve witness.

Private instrumentation executes exact unchanged product source via
runpy.run_path(absolute_file, run_name='__main__') with normal argv in a fresh
identified -I -S -B interpreter. It wraps saved real os.mkdir/open/write/close/rename/
replace and tracks only actual owned store FD+device+inode identities, retiring maps
on close. It never substitutes parser, validator, transition, CAS, lock or success.
Emit bounded acknowledgment metadata over outer-owned pipes, then block before
returning to the product. No store-file signal, guessed sleep or PID reuse.

At each chosen boundary outer supervisor verifies exact owned live child/event,
inventories store, optionally runs the direct E_BUSY contender, sends SIGKILL and
reaps that exact child. EOF/wrong/missing acknowledgment fails. Before-publication
kill expects old committed closure plus allowed residue; afterref kill expects new
closure. Replay an already committed request when a stale write lock remains;
unpublished request replay does not bypass that lock. No cleanup makes recovery pass.

For the partial41-byte ref case, private wrapper calls saved os.write on a strict
prefix of the real buffer and returns its actual positive count. Kill after that
actual prefix acknowledgment. A separate release control must finish the unchanged
write loop and produce identical output/committed bytes to ordinary direct entry.
Also run identical instrumented no-pause/no-fault controls for each fixture family.
Distinguish before-call OS-error injection from actual-success-then-uncertainty cases,
particularly close/rename. Never claim a mocked success is real publication.

Test permanent-lock bootstrap separately: an exclusive store.lock creator paused
before flock is not yet its owner. A competing initializer may acquire that lock;
only the actual flock owner may create repository bytes. Do not expect E_BUSY before
acquisition or call lock-file existence ownership. After acquisition every held
repository mutation requires the E_BUSY contender check.

Use a test-only audit hook/process-call guard as supplementary no-spawn evidence,
not as a product policy or replacement for full source mutation inspection. Ordinary
direct entry has no hook/loader/extra FDs. After every instrumented crash reopen only
through the direct public command. No application proof is inferred from former toy
Git FD experiments or the finite Python import script.

Outer harness drains stdout/stderr concurrently using selectors, enforces524288
and64-byte app caps while reading (plus one-byte overflow detection), and bounds
acknowledgments to2048 bytes. Each ordinary child gets120seconds, acknowledgment30,
whole focused suite1800seconds. These are test failure deadlines, not new public
wall-time guarantees. On failure close owned control pipes, TERM exact unreaped child,
wait1second, KILL if still owned/live and wait1second; unconfirmed cleanup fails and
is reported, never marked pass. No broad kill or retry-until-green. Bound fixture
construction loops: at most8192 added object candidates per capacity fixture,
32768 candidate hashes to obtain all256 fanouts, and32 exclusive temp-name attempts
in the product. Fail instead of extending a search/deadline silently. Preserve
first red/fault logs and exact statuses; do not erase failures on a later pass.

Real Git runs only after app exit and only in fresh private interoperability copies.
Use /usr/bin/git on Linux, /Library/Developer/CommandLineTools/usr/bin/git on Darwin;
record bytes/platform. Exact empty-start environment and fixed -c core.hooksPath
are those in spec449–455, TMPDIR=interop root, plus only fixed author/committer
values for commit creation. Git command deadline10seconds with TERM1/KILL1 reap;
stream captures capped to the specific expected object bound270336 plus framing,
and stderr4096. Large history comparisons use bounded per-object commands, not an
unbounded all-history dump. Never run Git on the application store to validate,
repair or produce its CAS/lifetime proof. No external network or candidate runs.

Document the exact invocation/environment, closed request/response/private metadata
shapes, deterministic transitions, genuine exported references, complete validation,
resource ceilings/reserves, replay ordering, old/new crash model and stale residue.
Explain dedicated-store trusted-UID/filesystem assumptions, Git interoperability
without arbitrary concurrent Git writers, and no cleanup/dispatch/authentication/
activation/power-loss guarantee. Restoration needs the three new files and existing
planner/schema dependencies; no installed daemon, binary, profile or credential.

## Risks

Serialization and history validation are as important as atomic ref publication.
Independent actual Git and planner checks must catch a self-consistent but wrong
encoder. The raw-byte digest includes LF; Boolean integers and year0000 need explicit
handling. Do not reuse delivery/v1/replay.py's different JSON or storage contract.

All product mutations must remain inside one owned locked path. Python buffered
I/O, helper subprocesses, imports, close retries and hidden cleanup would invalidate
its proof surface. A syscall blocked in the supported filesystem keeps the process
alive and flock held; test timeout is not evidence of death. Source plus actual
held-operation inventories are necessary; neither final snapshots nor an audit hook
alone proves peaks or every native startup effect.

Native provenance observations require a quiet measurement window coordinated with
the manager on Darwin. Complete fixture/tool setup first; record per-user temp and
all declared source/scratch roots before/after actual direct entry, without deleting
or prewarming shared cache. Attribute other active processes honestly. Unexpected
or unattributable changes fail that proof; no new cache allowance or claimed global
host-write absence follows. Linux CI supplies its own actual entry/crash evidence,
not an inferred cross-platform pass from Darwin. Missing installed dependency,
unobservable required boundary or exceeded suite budget is a reported blocker.

Retained finite research justifies investigating the selected existing direct Python
entry and interoperability tools. It does not prove this app, exact imports, Linux,
peak allocation or crash recovery. Full gates remain. The previous external-Git
writer was rejected because observing every external transient writer was unresolved;
this accepted design removes it instead of weakening allocation/lifetime proof.

## Proof

Run from the exact implementation root, with the currently identified tool bytes.
Record HEAD, main/base, three artifact hashes, full five-path diff and every actual
command/status/log. Syntax/source inspection is not functional proof.

1. bash scripts/test/orchestrator-delivery-ledger.test.sh — all P1–P11 cases,
   including actual jq1.6 -S -c byte comparisons and deliberate mismatch controls,
   exact direct/instrumented distinctions and actual bounds on native Darwin and
   Linux required CI. First red, fault-control and final complete logs retained.
2. bash scripts/test/orchestrator-reconciliation-plan.test.sh — unchanged full
   existing planner suite, additional to actual app-export planner cases above.
3. bash scripts/test/portable-core-schema.test.sh — stage the new intended paths
   first so indexed inventory checks see them; record the indexed tree identity.
4. bash scripts/check-rename.sh and bash scripts/test/run-all-sharding.check.sh.
   Verify new tracked focused suite appears exactly once in the six-shard union.
5. Verified shellcheck0.11.0: find . -name '*.sh' -not -path './.git/*' -print0 |
   xargs -0 "$shellcheck_bin" -x -S style. Verify version/digest before use.
6. Mirror ci.yml's full required-files structure/executable check without editing
   it; verify three appended paths exist, no original manifest entry changed.
7. Complete independent source review of every write/import/process primitive and
   all admission/closure/error paths, paired with actual P8/P9 event inventories.
8. Required remote CI checks plus all six actual test shards on the final head/base;
   no skipped/canceled/stale run supplies acceptance. Preserve complete logs and
   prove current tracked script coverage. Remote Linux CI does not replace Darwin.

Do not run a second local full run-all solely to duplicate final remote CI unless a
new issue warrants it. Necessary focused/planner/schema/lint and exact-head checks
remain required; a later change invalidates affected proof. Python source syntax
can be checked by compile() on read bytes without py_compile/cache writes, but it
never substitutes for the full functional suite. Manager reads the complete raw
independent review and exact CI before any protected merge. Implementation handoff
must name unresolved failures; opening a PR is not permission to merge or activate.
