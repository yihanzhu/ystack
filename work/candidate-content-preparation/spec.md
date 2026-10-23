---
intent-blob: fd10d967e2c6ee1fea4a80b560e861856d3ed507
risk: high
drafted: 2026-09-15
---

# Spec: Prepare exact candidate file content for the fixed verifier

Tracks #327. The accepted intent was read at main
`ab26ca2a477afff6541220fde2107fd445904538`. This is one inactive local preparation
component. G2 and a separate accepted high-risk plan precede implementation.

## Requirements

1. Export every admitted regular file in one checked materializer candidate tree
   into a fresh preparation-owned content root. Preserve raw blob bytes and each
   Git mode's executable distinction. Emit a complete measured inventory and a
   preparation record bound to the exact approved input and actual response.
2. Accept those input bytes only through an explicit trusted-parent handoff.
   Recheck syntax, digests, complete materializer relations and actual Git object
   identities. Caller JSON, file ownership and matching hashes do not authenticate
   approval, the materializer, a supervisor or an execution environment.
3. Read Git objects only from a bounded private copy of admitted bare candidate
   storage. Execute no candidate content, hooks, filters, text conversion, archive
   attributes or submodules. The verifier-visible content root contains only
   admitted directories and regular files, with no Git administration storage.
4. Bound complete physical repository copying, expanded tree traversal, every blob,
   total exported bytes, paths, entries, records and subprocess output. Repeated
   references to one blob count once per exported path toward the content budget.
5. Bind all filesystem operations to held directory descriptors, refuse links and
   aliases, and require exclusive ownership of fresh output. Never replace an
   existing attempt, follow an input into unrelated storage or clean unrelated work.
6. Publish completion only after the actual files, inventory and record have been
   validated and the publication sequence succeeds. Interrupted or failed preparation
   cannot become successful merely because some files or matching JSON exist.
   A read-only check can recover a complete published bundle after an outward reply
   is lost. Incomplete output is preserved and explicitly refused.
7. Prove genuine changed/no-change exports, independent expected bytes and modes,
   full inventory, source preservation, real I/O failures and process interruptions
   before and after publication. Preserve all existing regression suites.
8. Keep local byte preparation distinct from enforced immutability, authenticated
   receipts and sandbox qualification. The separate supervisor still owns those
   boundaries and the parent's unchanged verifier invocation and resource ceilings.

## Design

### Component and trusted input

Add `preparation/v1/prepare-candidate.py`, using Python 3.11 or newer and its standard
library in the existing supported Linux x86_64 and Darwin arm64/x86_64 development
and CI environments. The trusted caller chooses the existing absolute interpreter
and starts it with `-I`; there is no executable discovery or installation. Actual
no-follow, directory-relative opens, descriptor-relative creation and advisory file
locks are required. An unavailable primitive refuses support, never becomes a zero
flag or a pathname-only fallback. No native helper or private hashing implementation
is copied from the resolver or materializer.

The fixed public operations are:

```text
PYTHON -I /absolute/preparation/v1/prepare-candidate.py prepare \
  --input INPUT --input-sha256 SHA256 \
  --response RESPONSE --response-sha256 SHA256 \
  --candidate-repository BARE_REPOSITORY \
  --output NEW_BUNDLE --scratch SCRATCH_PARENT --jq JQ

PYTHON -I /absolute/preparation/v1/prepare-candidate.py inspect \
  --input INPUT --input-sha256 SHA256 \
  --response RESPONSE --response-sha256 SHA256 \
  --candidate-repository BARE_REPOSITORY \
  --output EXISTING_BUNDLE --scratch SCRATCH_PARENT --jq JQ
```

All paths are absolute physical paths with no `.` or `..` component, no repeated
separator and no symlink in any component. SHA-256 arguments are exactly 64 lower
hexadecimal characters. Unknown, repeated or missing arguments fail before creating
output. `inspect` has the same identity inputs; it cannot create missing output or
its lock, repair files, re-export content or change a completion record.

The trusted parent must already have accepted the exact input bytes and obtained
the response bytes from the actual materializer's controlled completion channel for
this same attempt. It supplies their independently retained hashes through the
invocation, and supplies the corresponding owned bare candidate repository after
materialization has finished. It keeps the input/dependency closure and candidate
under exclusive preparation ownership until this invocation finishes. This is an
explicit external trust precondition, not an `approved:true` document field or a
capability granted by the CLI. A direct local fixture driver can satisfy it for
component tests; no production trusted-parent launcher is added here.

The component has no argument for the original source checkout or source Git
repository. The materializer's candidate repository already contains the referenced
source commit/tree. Verify the source relation using those copied objects. Never
reopen an original source path extracted from input or response data. No incident,
expected file digest or verifier instruction is selected here; those arrive through
the verifier's separate trusted instruction channel.

Source and candidate names, JSON strings, Git names and file bytes remain hostile
data. The trusted parent, installed tools, interpreter/runtime and OS are trusted;
candidate code never runs. Another process controlled by the same account can
modify owned directories or forge a bundle. This component does not isolate that
adversary. Reject observed changes, but do not claim metadata checks or two reads
exclude every transient same-owner mutation. A real supervisor must enforce its
separate ownership/freeze interval before verification.

### Existing validation dependency

Reuse the pure `validate-response` operation accepted in
`work/replay-materialization-result/spec.md`, with its existing input, receipt and
core result predicates. That operation is not implemented on this spec's source
base. Its separately accepted #324 implementation must land and supply the checked
operation before candidate-preparation implementation is accepted or used. The
implementation plan must bind its actual accepted protocol/core source identities.
A missing operation or stale dependency refuses; do not generate a substitute result,
duplicate the materializer's private validators or edit its package in this concern.
This dependency does not resume or adopt the paused receiver implementation.

Strictly decode the supplied input and response, rejecting duplicate JSON members,
BOM, invalid UTF-8 or escaped lone surrogates, non-finite numbers, booleans in integer
slots, depth above 32, trailing data, extra documents and malformed nested shapes.
Compare input with frozen jq 1.6 sorted compact bytes plus one final newline, then
verify its exact SHA-256, every core document pair's canonical digest, raw payload
hash and profile/request/manifest/contract relation. Verify the original response
SHA-256, its sole raw receipt payload hash and strictly parsed receipt. Extract the
actual stage result with the same jq framing and hash it; never reconstruct it.
Pass only fixed data files to the accepted response validator and core validators.

Require the actual supported completed materialization response, including all
source/candidate/request/profile/attempt relations and its unchanged `authority:none`
and unavailable qualification. Accept changed and no-change outcomes. The checked
candidate commit is either the changed commit with exactly its one source parent,
or the source commit itself for no-change. For a no-change source root commit, the
receipt's source-as-parent convention is a relation, not a demand for a real parent
that the source commit does not have. Check actual commit/tree bytes and algorithm.

Trusted code and fixed modules come from the component's own repository closure,
never the candidate. Copy the required protocol/core module files and jq executable
into private scratch, verify their measured bytes before and after copying, and run
only those copies. Jq must be native jq 1.6 from an existing verified dependency;
record its SHA-256. Record the preparation source SHA-256, interpreter executable
SHA-256 and version, fixed Git executable SHA-256/version, protocol SHA-256 and
selected core generation with each used module SHA-256. These are measured component
identities, not proof of an authenticated or complete qualified runtime closure.
The later supervisor must bind the interpreter, libraries and OS/runtime closure
before any qualified use. No caller dependency path is used as a shell command.

### Repository copy and raw object reads

Hold no-follow descriptors for the candidate repository and each directory traversed.
Require an owned private bare repository, with regular single-link files and owned
directories; reject symlinks, devices, FIFOs, sockets, hard-linked files, mount/device
crossings and filesystem aliases. Input files, trusted tool sources, output and
scratch must be outside that repository and mutually nonoverlapping where writable.
Their ancestors cannot be writable by an untrusted account; sticky temporary roots
are allowed only above the caller's owned private directory. Trusted root admission
also excludes ACL entries granting another principal access; this is a caller
ownership precondition, not a claim that mode bits inspect every platform's ACLs. Resolve paths through
held descriptors and verify pathname-to-descriptor identity on admission and before
completion, rather than relying only on normalized strings.

Admit the materializer's closed bare layout: `HEAD`, `config`, the fixed
`refs/heads/candidate` ref, directories `objects`, `objects/info`, `objects/pack`,
`refs`, `refs/heads` and optional empty `refs/tags`, plus ordinary loose objects and
pack/index files and their explicitly admitted optional reverse indexes. Loose
object names must match the selected algorithm's lower-hex fanout and suffix lengths.
Pack and index names are `pack-<oid>.pack` and matching `pack-<oid>.idx`; require
matching pairs. For each pair, admit at most its same-basename `pack-<oid>.rev`.
The basename uses exactly 40 lower-hex digits for SHA-1 or 64 for SHA-256. A reverse
index without both matching files, a mismatched basename or any other sidecar is
refused. This admits ordinary unchanged materializer output on Git versions that
write reverse indexes; it does not admit arbitrary Git auxiliary files. No other
file or nonempty administrative directory is admitted. Reject worktree/commondir
metadata, alternates, grafts,
replace refs, shallow state, promisor files, hooks, remote configuration, index
extensions, commit graphs and multi-pack indexes. An unsupported otherwise valid
Git layout is refused explicitly; it is not silently pruned or repaired. The candidate
ref is exactly its lower-hex commit ID and one newline. HEAD is one bounded symbolic
`ref: refs/heads/<name>` line and one newline, with name matching
`[A-Za-z0-9][A-Za-z0-9._-]{0,127}`; an unborn symbolic HEAD is
allowed because object reads never use it. Both are inventoried but the private copy
uses newly written fixed HEAD/ref bytes, not an input-selected ref lookup.

The optional `.rev` is observation-only metadata. Apply the same owned regular,
single-link, no-follow, same-device and alias checks as every other admitted file.
Charge its full bytes, entry and name to the complete source-storage limits, every
source observation and `storage_observation_sha256`, including rereads on `inspect`.
Copy it into a separate private `observed-sidecars/` directory in this invocation's
scratch, charge those bytes to retained scratch, and keep it outside the private
Git repository and output bundle. Git cannot discover or use it there. Do not
remove, rewrite or regenerate the source sidecar, alter the materializer or change
Git defaults. Its omission from object-reading storage is an explicit admitted
observation policy, not silent removal of unsupported input.

Validate the copied sidecar before any object-reading Git runs. Admit only reverse
index version 1: `RIDX`, version 1, the matching hash-function ID (1 for SHA-1,
2 for SHA-256), exactly one 32-bit network-order index position per packed object,
and the two algorithm-sized checksums. Require exact length `12 + 4*N + 2*H`,
where `H` is 20 or 32 and `N` agrees with both the matching pack header and index.
Require `N <= 65,536`, no trailing bytes, and a permutation of `0..N-1` whose
corresponding index offsets are strictly increasing and inside the pack body.
Check the pack checksum against the actual copied pack, its trailer and basename;
check the reverse-index final checksum over its preceding bytes. A pair carrying
`.rev` must have a version-2 `.idx` with valid framing/counts/checksums and bounded
offset tables; check its pack checksum matches too. Resolve its ordinary or large
offset entries with checked bounds; never allocate from an unchecked count. Use
only standard-library parsing and hashes on these bounded copies, not a generic
pack parser or sidecar execution path. Unknown versions, invalid positions or
ordering, malformed/truncated bodies and mismatched checksums refuse. The format
reference is the pinned [Git v2.55.0 pack-format document](https://github.com/git/git/blob/v2.55.0/Documentation/gitformat-pack.adoc#pack-rev-files-have-the-format).

Read bounded config as data with the fixed Git `config --file ... --no-includes`
interface only after copying that file. Allow only the materializer's plain bare
keys: `core.repositoryformatversion`, `core.filemode`, `core.bare`,
`core.logallrefupdates`, `core.ignorecase`, `core.precomposeunicode`, and
`extensions.objectformat`. Refuse duplicate keys, sections outside this set,
includes, unsupported values or an algorithm inconsistent with the trusted input.
Never pass the supplied config to object-reading Git. Generate a minimal private
bare config for the checked object format, with replacement and optional acceleration
metadata disabled; write fixed HEAD/ref bytes bound to the checked candidate commit.
Copy only admitted loose objects and pack/index pairs into that scratch repository;
keep admitted `.rev` files in the separate observation directory described above.
Do not run Git against the caller's repository and do not link its objects into scratch.

For each copied file, retain length and SHA-256 over the bytes actually read through
its descriptor; compare pre/post descriptor and directory-entry identity, including
device, inode, type/mode, owner, link count, size and nanosecond modification/change
times where provided. Content comparison remains required when metadata matches. Re-enumerate
the complete source storage and reread/hash every admitted file after copying, then
again before completion. Require exact path/type/mode/size/content equality with the
first inventory. Same-length same-inode changes must be caught by content comparison
when observed; stable metadata alone is insufficient. Missing/new/replaced entries
refuse completion. The component performs no write to input candidate storage.
Its record proves the compared observations and exported content relation, not that
an external actor never wrote and restored bytes between observations.

Use fixed Git object-reading commands against the private scrubbed copy, with a
cleared environment, a private HOME/TMPDIR, no system/global config, no lazy fetch,
no replacement objects, no credentials/prompts, optional locks disabled and a fixed
empty hooks directory. Use `/usr/bin/git`, matching the materializer's supported
object-reading path; record its real bytes. No remote/fetch/checkout/archive/apply,
textconv or candidate-selected command is permitted. Close inherited descriptors
except the intended standard streams and explicitly passed data pipes. No source
path or object name becomes shell text; invoke fixed argument arrays without a shell.

Read bounded raw commit/tree/blob objects through a fixed `cat-file` protocol.
Check declared type/length and actual streamed length, detect overflow with an extra
byte, require exact message boundaries and successful child completion. Independently
recompute each object's Git identity from `type + SP + decimal length + NUL + raw
content`, using Python's standard hashlib SHA-1 or SHA-256 as declared. Require its
OID to equal the requested OID before admitting those bytes. This check covers
commits and trees as well as blobs; a corrupt object database cannot supply trusted
content merely by returning a header with the requested ID.

Traverse source and candidate trees as bounded raw objects, not a recursive checkout
or textual pathname split. Verify tree entry framing, unique names, strict ordering,
mode/type relations and the complete path rules below. Compare the actual source and
candidate inventory to the receipt's sorted changed-path count/digest and the input's
allowed-path contract. The exporter performs no new materialization or patch replay.
History outside the named commits/trees is not exported or represented as verified.

### Admitted content and complete limits

Paths are strict UTF-8, at most 4,096 bytes and 64 components, with each component
at most 255 UTF-8 bytes. Preserve their exact bytes; do not normalize names. Reject
absolute/empty paths, empty components, `.`/`..`, backslash, U+0000–U+001F,
U+007F–U+009F, case-insensitive `.git`, and components ending in dot or space.
These retain the materializer exclusions and add explicit filesystem representability.
Reject duplicate paths, file/directory prefix collisions and component aliases under
Unicode NFC plus casefold. Record the Python Unicode data version used for that
check. Also enumerate the actual output names and verify exact UTF-8 byte spelling
and distinct inode identities: a filesystem that rewrites a name, aliases it or
cannot represent it refuses this export. Do not claim universal filesystem support.

Only `040000:tree`, `100644:blob` and `100755:blob` are admitted. Reject symlinks,
submodules, other modes/types and non-root empty subtrees. An empty root tree is
valid. Empty files, NUL/binary bytes, CRLF, final-newline differences, attribute
files and names resembling commands are ordinary raw data. Export full candidate
content, including unchanged files, without applying attributes. The Git modes
are recorded verbatim. Final regular-file permissions are 0400 for 100644 and 0500
for 100755; content directories are 0500. This preserves the executable distinction
and restricts incidental writes, but an owner can chmod them again. It is not freezing.
No source or output hardlinks are used, and no source ACLs or xattrs are copied.
Output privacy relies on the admitted parent's ownership/ACL precondition plus
exclusive creation and explicit modes; no stronger ACL isolation is claimed.

All limits below are inclusive; overflow, unsupported types and arithmetic errors
fail before publication. Lengths refer to bytes, never character counts.

| Data or operation | Maximum |
| --- | ---: |
| Input / response / raw receipt / canonical stage result | 8 MiB / 1 MiB / 64 KiB / 256 KiB |
| Input/response JSON depth | 32 |
| Complete copied bare storage, including admitted metadata | 256 MiB |
| One physical repository file / optional reverse-index sidecar | 64 MiB / 1 MiB |
| Indexed objects in a pack carrying a reverse index | 65,536 |
| Physical repository entries / summed relative-name bytes | 65,536 / 8 MiB |
| One config / HEAD or candidate ref | 1 MiB / 4 KiB |
| One raw commit / one raw tree | 1 MiB / 16 MiB |
| Tree-object bytes visited, per source or candidate traversal | 16 MiB |
| Tree visits / directory entries, per traversal | 1,024 / 65,536 |
| Candidate regular-file paths / non-root directories | 4,096 / 1,023 |
| Summed exported file and directory path bytes | 1 MiB |
| One expanded blob / total exported file bytes | 8 MiB / 64 MiB |
| Manifest / completion record | 2 MiB / 16 KiB |
| Trusted dependency copies in scratch | 32 MiB |
| Total retained scratch / output-bundle bytes | 384 MiB / 80 MiB |
| Buffered subprocess diagnostic bytes per child / per invocation | 64 KiB / 256 KiB |
| Outward result / diagnostic bytes | 16 KiB / 4 KiB |

Repeated trees count per visit and repeated blob OIDs count per destination path.
Validate announced sizes before requesting bodies and bound actual reads/writes.
Stream file content in chunks no larger than 64 KiB; drain stdout/stderr concurrently
and reap every child. Include temporary files and failed-attempt retained data in
the disk counters; do not subtract a file until its owned deletion succeeds. Bound
in-memory metadata by the explicit entry/name/manifest limits rather than retaining
whole blob content. No unbounded `subprocess.run(..., PIPE)` or recursive expansion.

Use one parent-controlled monotonic 300-second operation deadline and at most
120 seconds for an individual Git/validator subprocess. On expiry, stop admission,
terminate and reap owned children and report failure; never publish success while
children remain. This is local process lifecycle protection, not a strict kernel CPU,
memory, task or wall-time isolation claim. Kernel-blocked I/O and hostile same-owner
processes remain outside that guarantee. These preparation limits do not replace or
raise the parent's fixed verifier limits: CPU 30,000 ms, wall 60,000 ms, memory
536,870,912 bytes, combined output 10,485,760 bytes and 32 tasks.

### Bundle, record and publication

`prepare` exclusively creates the previously absent output directory, mode 0700,
under its checked private parent. Any existing file, directory or link at that path
is refused unchanged. It creates a permanent `preparation.lock` exclusively and
holds its exclusive lock through export, publication and final reply. Output is
never placed in the candidate or scratch repository. Scratch uses one newly created
private subdirectory of the caller's scratch parent; only that owned subtree can
be removed. Preserve failed output and scratch for explicit recovery, with no
automatic restart, adoption, replacement or cleanup of an earlier attempt.

A complete bundle has exactly these top-level entries:

- `candidate/`: only the exported tree, with the file and directory inventory above;
- `input.json`: the exact accepted materialization input bytes;
- `response.json`: the exact actual materializer response bytes;
- `manifest.json`: the canonical complete measured content inventory;
- `record.json`: the canonical preparation completion record;
- `preparation.lock`: the permanent regular lock file.

The lock and metadata are outside `candidate/`; a later supervisor passes only
candidate content to the verifier. No repository copy, private tool, original
source path, scratch directory or instruction file appears under `candidate/`.

`manifest.json` has exactly `schema_version:1`,
`kind:candidate_content_manifest`, `hash_algorithm:sha256`, `entries`,
`file_count`, `directory_count` and `total_file_bytes`. Entries are ordered by raw
UTF-8 path bytes and include every file and non-root directory exactly once.
A directory entry is `{path,kind:"directory",git_mode:"040000",mode:"0500"}`.
A file entry is `{path,kind:"file",git_mode,mode,blob_oid,size_bytes,sha256}`.
Hashes and sizes come from bytes reread from each actual exported regular file;
recompute its Git blob identity and compare with the admitted tree entry. Verify
permissions, single link, unique inode, spelling and complete inventory; no extra
file or directory is ignored. Do not hash a JSON promise in place of reading files.

`record.json` has exactly `schema_version:1`,
`kind:candidate_content_preparation`, `status:completed`, `authority:none`,
`qualification:unavailable`, `input_sha256`, `response_sha256`,
`stage_result_sha256`, `receipt_sha256`, `request_ref`, `resolved_profile_ref`,
`attempt`, `source`, `candidate`, `manifest_sha256`, `storage_observation_sha256`,
`producer` and `ownership`. Request/profile refs come from validated input/result relations. `attempt` is
exactly `{attempt_id,attempt_number}`. `source` is exactly
`{repository_id,hash_algorithm,commit_id,tree_id}`. `candidate` is exactly
`{hash_algorithm,commit_id,tree_id,parent_commit_id,outcome}`; the parent field uses
the checked materializer convention and outcome is `changed` or `no-change`.
The stored record copies only these checked fields; no caller-provided status or
producer declaration is accepted.

`storage_observation_sha256` hashes a canonical sorted inventory of every admitted
input repository entry from the matching source observations. Directory entries
are exactly `{path,type:"directory",mode}`; file entries are exactly
`{path,type:"file",mode,size_bytes,sha256}`. Modes are four-digit octal strings,
paths are relative UTF-8 and entries are ordered by path bytes. Directory allocation
sizes are not portable content facts and are excluded. Device/inode checks are local checks, not
portable content identity and are not included in that digest. `producer` is exactly `{component_id,source_sha256,python,git,jq,protocol_sha256,
core,unicode_version}`. The component ID is `candidate-content-preparation.v1`.
`python`, `git` and `jq` each contain exactly `{executable_sha256,version}`; versions
are single-line ASCII strings of at most 128 bytes, with jq exactly `jq-1.6`.
`core` is exactly `{generation_id,files}`; files are the fixed used core dependency
paths and SHA-256 pairs, sorted by path, including the selector/registry, ingress,
contracts and used modules. Unknown, duplicate or missing dependency entries fail.
All digests are measured as described above; `unicode_version` is the actual
standard-library Unicode data version used for alias checks.
`ownership` is exactly `{state:"local-preparation-complete",immutable:false,
authenticated_receipt:false,supervisor_handoff:"required"}`. The record is created
by this local component; arbitrary copies of it do not authenticate that origin.
No actor name, caller-supplied issuer or matching hash upgrades its authority.

Canonical preparation JSON uses frozen jq 1.6 `-S -c` with one newline. Check final
encoded limits before publication. Write input, response, content and inventory
through exclusive no-follow files; flush/fsync files and content directories after
final modes. Re-enumerate/recheck the complete output and source observations.
Write a private temporary completion record, flush/fsync it, then atomically rename
it to previously absent `record.json` while holding the owned bundle lock; fsync
the bundle directory and its parent. The exclusive-ownership precondition excludes
another writer creating a destination between checks. Never overwrite an existing
record or treat a lock as protection from a hostile same-owner writer.

The successful completion boundary is this entire sequence returning successfully.
Only then emit one bounded canonical JSON envelope containing
`schema_version:1`, `kind:candidate_content_preparation_result`, `status:completed`,
`record_sha256`, `manifest_sha256`, `authority:none` and `qualification:unavailable`.
Exit 0 means this local preparation completed, not that verification ran or a
supervisor accepted it. Do not include machine-specific absolute paths in records
or echo hostile paths, Git messages or file contents into diagnostics.

`inspect` holds the existing lock, revalidates the supplied trusted identity inputs,
actual candidate object relation and complete bundle byte/mode/inventory relation,
and returns that same completion envelope without modifying the bundle. It uses
fresh private scratch only for bounded validation. An existing `record.json` after
a crash is accepted only through these full checks. No record, partial JSON, leftover
publication temporary file, missing/extra output, changed mode/bytes, mismatched
identity or unknown version is a completed preparation. Do not reconstruct a missing
record from a tree or finish someone else's interrupted export.

On refusal, malformed/unsupported data, observed mutation, limit or I/O failure,
return nonzero with one bounded reason code and no completion envelope. Use exit 2
for usage, identity or existing-output conflicts; exit 1 for malformed, unsupported,
limit, missing/incomplete evidence or I/O failure; exit 75 for handled interruption
or timeout. A verifier digest mismatch is not an outcome of this component. Git,
validation, fsync or directory-fsync failure never becomes completed. If a failure
occurs after rename, preserve the actual bundle: a later `inspect` may establish a
complete state, but the failed writer does not claim a successful publication.
SIGKILL has no promised outward receipt; retained state is the recovery evidence.
Diagnostics are exactly one ASCII reason token and newline: `E_USAGE`, `E_IDENTITY`,
`E_EXISTS`, `E_INPUT`, `E_DEPENDENCY`, `E_STORAGE`, `E_OBJECT`, `E_PATH`, `E_LIMIT`,
`E_IO`, `E_INCOMPLETE`, `E_INTERRUPTED` or `E_TIMEOUT`. A broken outward pipe can
leave partial output after publication; consumers require the complete framed
envelope and successful exit or a fresh trusted `inspect`, never a truncated prefix.

### Ownership handoff and restoration

After successful publication, preparation closes all writable candidate descriptors
and performs no further bundle writes. The trusted parent owns the returned bundle
and controlled completion channel. The record binds the exact local content; it
contains no token transferring privilege. `inspect` on an arbitrary caller-supplied
bundle proves only present consistency. Restoring a bundle under another owner or
path requires the same checks and fresh trusted provenance; do not inherit caller
identity or supervisor acceptance from a copied record.

The later supervisor must separately verify the accepted preparation producer and
input/response channel, remeasure the manifest against transferred files, close
source/preparation descriptors, establish read-only candidate access for the full
verifier interval and authenticate its own protected attempt receipt. It must deny
source Git, host data, credentials and sibling access. It preserves exactly
`/sandbox/tools/verifier verify --candidate /sandbox/candidate --evidence /sandbox/evidence`
and the four parent environment variables. This spec does not implement that launch,
a frozen image, mount, ownership-changing privilege or authenticated receipt ingress.
A failed or missing supervisor handoff leaves qualification unavailable.

Restoration documentation covers the whole bundle, exact approved input/response,
checked candidate source needed for `inspect`, trusted dependency identities and
ownership preconditions. A partial copy, missing publication record, altered tools
or unexplained producer channel must remain incomplete/untrusted. Keep failed
attempts identifiable and untouched until the owner records their disposition;
only successfully created scratch from this invocation may be automatically cleaned.

## Proof, exact paths and review size

The G2 PR changes only `work/candidate-content-preparation/spec.md`. The subsequent
high-risk plan PR changes only `work/candidate-content-preparation/plan.md`.
Implementation may change only:

- `preparation/v1/prepare-candidate.py` (new);
- `scripts/test/candidate-content-preparation.test.sh` (new executable suite);
- `scripts/test/candidate-content-preparation-fixtures.py` (new private test helper);
- `docs/candidate-content-preparation.md` (new);
- `README.md` and `docs/components.md`, adding the component and its limits;
- `ci/required-files.txt`, appending those four new restore-critical paths.

Do not change materializer/protocol/closure helper, resolver/nofollow code, replay,
scanner, verifier, core schemas/generations, profiles, policy, workflows or accepted
artifacts in implementation. The existing test runner discovers the new suite.
Reuse the real materializer fixture builder unchanged. The Python fixture helper
supplies independent expected bytes, malformed-object construction and narrowly
scoped synchronization/fault injection; it is not a second exporter or public API.

Required evidence includes:

1. Real materialization and raw export in separate processes, for changed and
   no-change, source root and ancestor commits, SHA-1 and SHA-256 repositories,
   empty root/file, executable files, binary/NUL/CRLF/no-final-newline content,
   repeated blob references, nested UTF-8 paths and unchanged files. Independently
   calculate expected bytes, modes, sizes and hashes without reading expected
   values from the emitted manifest. Enumerate the actual complete result.
   Include genuine unchanged materializer output from the existing supported Git
   with matching `.rev` files actually present; assert presence rather than skipping
   this case or deleting sidecars. Keep success proof for valid input without them,
   using a separate owned fixture created without optional sidecars from the start.
   Prove sidecars are included in source observations and scratch budgets, remain
   byte-identical in the source, and are absent from object-reading Git storage and
   the published bundle. Use actual exported byte checks in both cases.
2. Attribute/filter traps with positive controls: committed `.gitattributes`
   containing export-ignore, export-subst, encoding and conversion directives
   must not omit or transform bytes; executable or fake instruction/expected-answer
   content must not run or influence preparation. Hostile Git config/hooks/alternates
   and inherited Git/Python/shell variables cannot select executables or reach
   unrelated sentinel roots. Use only synthetic sentinels, never real secrets.
3. Reject wrong approved-input/response hashes, rehashed relation mutations, every
   request/profile/attempt/source/candidate/parent/outcome mismatch, fake receipt,
   malformed canonical JSON, duplicate fields, Unicode/depth/type problems and
   altered dependencies. Test the real response validator and actual object checks;
   no fake positive result or regenerated receipt supplies success evidence.
4. Raw malformed trees, duplicate/order/type/mode errors, missing/corrupt/truncated
   objects, unsafe names, case/normalization/prefix aliases, excessive components,
   Git metadata paths, symlink/submodule modes, intermediate/final filesystem links,
   hardlinks and nonregular nodes. Cover representable Unicode success and explicit
   platform refusal where the filesystem rewrites or aliases names.
   Reject reverse indexes with malformed names, headers, versions/hash IDs, counts,
   permutations/offset order, lengths or checksums; rehash structural mutations so
   checksum failure is not the only oracle. Reject unpaired, linked/nonregular,
   over-1-MiB and over-count sidecars and arbitrary other pack auxiliaries. Cover
   both hash algorithms, source sidecar mutation and whole-storage/scratch overflow
   including admitted sidecar bytes. Negative fixtures are separate owned copies;
   do not mutate or delete producer output to make a positive case pass.
5. Every inclusive byte/count bound and its overflow; multiply referenced blobs
   must overflow the expanded budget even when stored once. Exercise actual bounded
   source-copy/object-read/export paths. Where a fixed schema cannot fill a numeric
   limit validly, separately prove the primitive bound and semantic rejection.
   Assert maximum retained buffers and subprocess draining without deadlock.
6. Snapshot input/candidate/source/old-output bytes and inventory before each
   refusal, then prove unchanged afterward. Synchronize actual input-file and
   repository replacement, addition/removal and same-inode same-length mutation
   during copy and before final recheck. Restore timestamps in mutation fixtures
   where possible so content verification, not metadata alone, supplies rejection.
   Include positive controls proving the intended race window was reached. Tests
   cannot claim detection of an unobserved change-and-restore between all reads.
7. Real file read/write, directory creation and output collision failures, plus
   narrow deterministic write/fsync/rename/directory-fsync/pipe failure injection
   around the same production functions. Preserve prior usable state. No product
   testmode, arbitrary execution callback or alternate protocol is exposed.
8. Explicit ready/release synchronization, watchdogs and SIGKILL before record
   publication after exported files exist, and after successful publication before
   any outward reply. Prove the former remains incomplete and untouched; the latter
   is recovered by a fresh `inspect` with byte-identical result. Prove zero outward
   completion bytes at the latter pause, handled interruption, deadline child
   cleanup, failed outward write, corrupt/extra-file refusal and concurrent prepare
   collision/read serialization. No automatic repair or second export occurs.
9. Copy a complete bundle for restoration and validate against its real approved
   input/response and candidate objects under new owned temporary paths. Tampered,
   partial and stale-dependency copies fail. Demonstrate that a same-owner process
   can chmod/change local content and that `inspect` rejects the changed bytes;
   do not present local read-only permission bits as containment proof.

Run the new suite, the unchanged materializer protocol and adapter suites, legacy
40-check replay suite, receiver-result suite once its dependency lands, both profile
assembly suites, unchanged target-packaging suite and the complete existing runner.
Run structure validation, `git diff --check` and repository-wide Shellcheck 0.11.0.
Retain complete output tied to actual head/base, test discovery and all required CI;
a missing native capability is a refusal with a recorded support limitation, not
a skipped passing test. Linux and Darwin component results remain separate from
native VM, fixed-root verifier or qualified workflow proof.

`review_size: accepted-exception`. The amended envelope is 5,450–6,000 added
plus removed implementation lines across the same seven allowed paths. This changes
only the size estimate; all requirements, proof and safety boundaries stay intact.
The earlier 1,200–2,200 estimate did not leave enough room for the complete source
observation, reverse-index, resource-limit, race and publication proof.

The design forecast is 5,475–5,700 lines:

| Area | Forecast |
| --- | ---: |
| Bounded preparation/export/inspection component | 2,288 |
| Real fixtures and complete adversarial/process proof in the two new test files | 3,012–3,237 |
| Documentation and restore-manifest entries | 175 |
| Total | 5,475–5,700 |

The component allocation covers descriptor admission and counters, measured dependency
copies and validation, closed bare storage and reverse-index checks, bounded child
I/O and raw object export, then full remeasurement, publication and inspection.
The proof allocation covers every existing proof row with independent byte oracles,
inclusive limits, source-mutation controls and real crash/recovery assertions.
Shared setup is counted once; no proof is deferred to fit the range. The 6,000 ceiling
leaves 300 lines above the upper forecast for implementation uncertainty.

At sizing base `b873a171c550ca68f440b8c454b89ccd49304499`, the replay is 1,412
lines, its receiver-result suite is 2,660 and the source snapshot helper is 2,732.
These are evidence of the boundary and proof costs, not code to copy. This narrower
bare-only Python component avoids general repository-layout resolution,
materialization, arbitrary execution and a generic storage layer. Its exact byte
checks, ownership and crash proof remain one complete preparation concern.

The separate plan must refine this allocation from the actual design; later review
must measure the complete diff against the accepted base. Any overrun, additional
path or changed dependency returns through the appropriate amendment. Never reduce
tests or compress code to fit the estimate.

## Out of scope and remaining gates

No VM/runtime acquisition, installation, activation, privileged setup, credential or
network expansion, real target, model invocation, generic dispatcher, patch producer,
materializer change, verifier implementation, shadow integration, release or deploy.
No stronger policy, looser parent resource ceiling, sandbox qualification, authenticated
receipt or immutability claim. The original materializer and nofollow contracts stay
unchanged; no private exception is made into a generic library.

Preserved #271, frozen #183, the old delivery-loop plan and unresolved dirty work
remain excluded. The paused receiver attempt is a separately gated dependency, not
work adopted by this spec. The fixed verifier intent is consumer context only and
is not present as a merged artifact at this source base; its eventual accepted design
cannot be invented here. A parent conflict or new privileged prerequisite stops the
affected integration for a separate decision. The current named manager's Roadmap
program supplies in-scope artifact acceptance only after independent review; this
author does not self-accept or grant runtime authority.
