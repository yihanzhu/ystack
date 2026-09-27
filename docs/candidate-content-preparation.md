# Candidate content preparation

`preparation/v1/prepare-candidate.py` is an inactive local component. It turns one
completed local Git materializer candidate into a measured file tree for the fixed
verifier. It does not run the verifier, make the files immutable, authenticate a
receipt, qualify a sandbox, or select a live profile.

## Commands

The trusted parent chooses an existing absolute Python 3.11 or newer interpreter
and invokes it in isolated mode. It also supplies the existing pinned jq 1.6 binary.

```text
PYTHON -I /absolute/preparation/v1/prepare-candidate.py prepare \
  --input /private/input.json --input-sha256 SHA256 \
  --response /private/response.json --response-sha256 SHA256 \
  --candidate-repository /private/candidate.git \
  --output /private/new-bundle --scratch /private/empty-scratch-parent \
  --jq /private/tools/jq

PYTHON -I /absolute/preparation/v1/prepare-candidate.py inspect \
  --input /private/input.json --input-sha256 SHA256 \
  --response /private/response.json --response-sha256 SHA256 \
  --candidate-repository /private/candidate.git \
  --output /private/existing-bundle --scratch /private/empty-scratch-parent \
  --jq /private/tools/jq
```

Every path must be absolute and physical. A path cannot contain a repeated
separator, `.` or `..`, or a symlink component. The input, response, candidate,
output, scratch and jq boundaries must not overlap. Their owned private parents
must already exclude other principals, including through ACLs. The component checks
ownership and mode bits; the caller remains responsible for the ancestor ACL
precondition.

The parent must already have accepted the exact input bytes and obtained the exact
response bytes from the materializer's controlled completion channel for this
attempt. Matching hashes and local ownership do not establish that provenance.
The parent keeps the input, candidate and dependency closure frozen for the whole
operation.

`prepare` requires an absent output path. It creates a 0700 bundle and a permanent
exclusive lock. It never replaces or adopts an earlier attempt. `inspect` requires
an existing completed bundle and lock. It rechecks the approved bytes, materializer
relations, source storage, Git objects, exported bytes, modes, manifest, producer
identities and record without changing or repairing the bundle.

## Bundle

A complete bundle has exactly six top-level entries:

- `candidate/` contains only exported directories and regular files;
- `input.json` and `response.json` preserve the exact accepted bytes;
- `manifest.json` inventories every exported file and non-root directory;
- `record.json` binds the input, response, materializer result, source observation,
  candidate identities, manifest and measured producer dependencies; and
- `preparation.lock` serializes a writer or inspector.

Regular files are 0400 or 0500 according to their Git executable mode. Directories
under `candidate/` are 0500. Those permissions reduce accidental changes but do not
freeze data from another process running as the same owner. The record therefore
says `authority:none`, `qualification:unavailable`, `immutable:false`, and
`authenticated_receipt:false`.

The component reads objects only from its private, scrubbed copy of the admitted
bare repository. It uses raw `cat-file` object bytes, recomputes every Git identity,
and never checks out content or applies attributes. Hooks, filters, conversions,
submodules and candidate commands do not run. Optional pack reverse indexes are
fully observed and validated in separate scratch; Git cannot discover them in the
object-reading copy and they never enter the bundle.

The core generation is not a component setting. Preparation measures the existing
core selector and registry, requires their one consistent selected generation, and
then checks the fixed hashes of that generation's ingress and modules. The copied
jq executable is checked before use and again before completion. A changed selector,
registry, module, jq binary, input or response causes refusal.

Repository and candidate walks enumerate each directory entry through held
descriptors. Linked directories, linked files, device crossings, duplicate inodes,
unsupported config, malformed refs and unlisted storage are refused instead of
being skipped. File bodies and Git blobs move in bounded chunks. Their SHA-256 and
Git object identities are computed from the bytes actually read or written.
Destination space is charged before a write begins, including a write that later
fails.

Publication applies final modes before flushing each file. It flushes completed
content directories from the leaves upward, writes and flushes a private temporary
record, renames that record within the held bundle directory, and then flushes the
bundle and its parent. The lock remains held while the final success or refusal is
written. A published record can therefore be recovered after an outward-pipe
failure without treating a pre-publication directory as complete.

The successful response is one canonical JSON line. It identifies the record and
manifest SHA-256 values and repeats the unavailable authority and qualification.
Exit zero means local preparation completed. It does not mean a supervisor or
verifier accepted the bundle.

## Refusal and recovery

Failures write one bounded token to standard error and no successful envelope.
Usage, identity and existing-output conflicts exit 2. Malformed input, unsupported
storage, object, path, limit and I/O failures exit 1. A handled signal or deadline
exits 75. Hostile paths, Git diagnostics and file content are never copied into the
diagnostic.

A failed output and its invocation scratch are retained. Do not restart into it,
replace it, or infer success from plausible files. Record its exact input, response,
candidate, output and scratch identities, then keep it untouched until its owner
records a disposition. Only scratch from a fully successful invocation is eligible
for cleanup by the caller.

A process can die after exporting content but before publishing `record.json`. A
fresh `inspect` refuses that bundle as incomplete and does not finish it. A process
can also publish successfully and lose its outward reply. In that case a fresh
trusted `inspect` can recover the same completion envelope after rechecking the
entire relation. A partial or broken envelope is never completion evidence.

## Restoration

Restore the whole six-entry bundle together. Keep the exact approved input and
response, the checked candidate repository, the pinned jq 1.6 binary, the matching
preparation source and the selected core dependency closure. Place each under new
owned private physical paths and invoke `inspect` with freshly retained input and
response hashes.

A copied `record.json` does not preserve trusted provenance. The restoring parent
must establish the input and materializer response channel again. Missing entries,
extra files, changed modes or bytes, stale dependencies, a different candidate, or
an altered local tool causes refusal. A same-owner process can chmod or rewrite the
candidate content; inspection detects an observed difference but local permission
bits are not containment.

Before handing the bundle to a verifier, the later supervisor must independently:

1. authenticate the accepted preparation producer and input/response channel;
2. remeasure the transferred manifest against the candidate files;
3. close source and preparation descriptors;
4. establish read-only candidate access for the full verifier interval;
5. deny source Git, host data, credentials and sibling access; and
6. authenticate its own protected attempt receipt.

That supervisor preserves the fixed invocation
`/sandbox/tools/verifier verify --candidate /sandbox/candidate --evidence
/sandbox/evidence`, its four parent environment variables, and the existing CPU,
wall, memory, output and task ceilings. Preparation neither raises those limits nor
claims the supervisor performed these duties.
