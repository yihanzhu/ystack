---
spec-blob: 079be9befacd58f19203bf70c0751281668156a8
risk: high
drafted: 2026-09-21
---

# Plan: Prepare exact candidate content

Tracks #327. Implement one inactive local preparation component under the complete
accepted [spec](spec.md). Its requirements, closed schemas, limits, exit codes and
nine proof rows remain binding; the implementation steps below do not replace them.
The accepted intent blob is `fd10d967e2c6ee1fea4a80b560e861856d3ed507`.
The inspected main base is `dd854fc09d2db98f60e6fc6cc69dbbe08674a374`.

## Gate, scope and size

This plan lands alone on `ystack/plan/candidate-content-preparation`, after separate
read-only review and required CI. The named Roadmap manager records acceptance and
the merged plan-base before claiming implementation on
`ystack/impl/candidate-content-preparation`. Recheck the full artifact links and
dependencies before code; a moved base needs fresh independent acceptance under
AGENTS.md. Select **gpt-5.6-sol / medium** as implementation author, with a separate
**gpt-6-astra / high** reviewer. Record the requested and exposed actual model; do
not infer an identity the runtime does not expose. The implementation author cannot
edit accepted artifacts or accept their own work.

Only these seven implementation paths may change:

| Path | Work |
| --- | --- |
| `preparation/v1/prepare-candidate.py` | New standard-library Python component. |
| `scripts/test/candidate-content-preparation.test.sh` | New executable suite and real producer orchestration. |
| `scripts/test/candidate-content-preparation-fixtures.py` | Private expected-byte, malformed-input and process/fault fixtures. |
| `docs/candidate-content-preparation.md` | CLI, trust, support, recovery and restoration instructions. |
| `README.md` | Component entry and limits. |
| `docs/components.md` | Component boundary and consumer relationship. |
| `ci/required-files.txt` | Append the four new restore-critical paths above. |

`review_size: accepted-exception`: 5,450–6,000 added plus removed implementation
lines for this one concern. Use these allocations to check progress, not to remove
proof or compress readable code:

| Work within the allowed paths | Forecast lines |
| --- | ---: |
| Admission, descriptors, counters, bounded children and dependency/input checks | 997 |
| Storage observations, reverse-index validation and raw object/tree export | 638 |
| Bundle measurement, publication, inspect and failure handling | 653 |
| Shared real-fixture driver, independent byte/mode oracles and positive exports | 600–650 |
| Table-driven rejection, inclusive bounds, races, I/O and crash/recovery proof | 2,412–2,587 |
| Documentation and restore-manifest entries | 175 |
| Total forecast | 5,475–5,700 |

Measure the whole diff against its accepted base. Keep accounting and review-round
history in the PR, not this artifact. Stop and preserve the exact attempt for a
separate amendment if scope, meaning, paths or accepted size must change.

## Landed dependencies

The spec's missing-validator note describes its older source base. The real
`validate-response` operation landed in #345 at
`b873a171c550ca68f440b8c454b89ccd49304499` and is present at this plan's base.
Reuse it unchanged. Do not resume receiver work, copy its validators or call a
receipt/result generator to manufacture successful evidence.

Select core v2 through the exact measured `scripts/core-contract.sh` and registry
below. Require one consistent selected generation across selector, registry and
ingress. In the table, `G/` means its directory under `core/v2/generations/`.
The implementation uses that normal selection path, not a hardcoded generation
literal or a changed validator guard. These actual source SHA-256s bind the fixed
dependency list and must be rechecked before implementation:

| Dependency | SHA-256 |
| --- | --- |
| `adapters/local-git-materializer/v1/protocol.jq` | `232517c19455667cca795769ffc0d8edad7873a9d55be0c21166de5b436bf323` |
| `scripts/core-contract.sh` | `b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9` |
| `core/v2/generation-registry.json` | `3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94` |
| `G/core-ingress.sh` | `dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8` |
| `G/contracts.jq` | `65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a` |
| `G/modules/schema.jq` | `8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade` |
| `G/modules/profile_graph.jq` | `c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207` |
| `G/modules/stage_request.jq` | `6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e` |
| `G/modules/result_facts.jq` | `8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281` |
| `G/modules/result_truth.jq` | `ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46` |

The unchanged real fixture builder is
`scripts/test/local-git-materializer-fixtures.sh`, blob
`6e68f390c532b54cdf775ab4065251698797f424`. Call its existing `build` operation with
actual source commit/tree IDs, then adjust only owned fixture data and recalculate
its affected links before real materialization. Use the existing materializer and
its compiled object-closure helper unchanged in fixture production, never as copied
preparation code. Preparation itself adds no native helper or generic library.

## Implementation sequence

1. **Establish one private operation context.** Implement exactly the two CLI
   operations and arguments in the spec, under a caller-selected absolute Python
   3.11+ interpreter with `-I`. Reject duplicate/unknown arguments and bad physical
   paths before output creation. Hold descriptor chains from admitted roots; use
   real `O_NOFOLLOW`, directory-relative operations and advisory locks. Refuse
   missing primitives, unowned/nonprivate roots, aliases, overlaps, hardlinks,
   nonregular files and device crossings. Recheck pathname-to-descriptor identity
   before completion. Treat ancestor ACL exclusion as the stated caller precondition.
   Keep these helpers private to this component, without borrowed nofollow code.

   Put the spec's entire inclusive limit table in one named constant table. One
   accounting context charges input, objects, retained scratch, bundle bytes and
   subprocess output before admission, including temporaries and failed writes.
   Subtract retained bytes only after successful owned deletion. One bounded child
   runner drains stdout/stderr concurrently, streams at most 64 KiB per chunk,
   checks framing/exit, and terminates/reaps children on the 300-second operation
   or 120-second child deadline. Do not buffer whole blobs or unbounded pipes.

2. **Validate real inputs using measured dependency copies.** Copy the fixed
   protocol/core closure and existing verified native jq 1.6 into owned scratch,
   preserving the core selector's relative layout. Measure source descriptors
   before/after copying and the actual copies; require the fixed file set, hashes,
   selector and unique registry relation. Record source, interpreter, fixed
   `/usr/bin/git`, jq and Unicode identities as the spec requires. No candidate
   import, shell expansion, dependency discovery or installation is allowed.

   Strictly parse bounded input/response and nested receipt/contract JSON. Reject
   duplicate members, BOM, bad UTF-8/surrogates, nonfinite numbers, excess depth,
   trailing documents and invalid numeric types. Check the exact retained hashes,
   jq 1.6 input canonical bytes, every document-pair digest and raw payload hash.
   Extract the original stage result with jq framing; hash its measured bytes.
   Feed the copied protocol's `validate-input` and `validate-response` fixed data
   files; the latter has exactly `input`, `response`, `verified_receipt`,
   `receipt_utf8`, `stage_result_sha256`. Validate documents, profile set and stage
   run with the copied core selector's existing `--accounted-validation` operation.
   Reserve its bounded scratch allowance and drain/verify its fd-3 written-byte
   receipt; retain the reservation on missing or invalid accounting evidence.
   Require all actual relations and the unchanged authority/qualification fields.

3. **Observe and copy the closed bare storage.** Enumerate held descriptors and
   admit only the spec's exact layout and config allowlist. Copy bounded regular
   files, measuring their actual bytes and complete metadata observations; reread
   every source file and re-enumerate after copying and before completion. Compare
   content even if inode, size and timestamps match. Never reopen the original
   source repository through a field in input/response. Read config as data using
   the fixed no-includes command; generate scrubbed private config and fixed refs.

   Keep optional same-basename `.rev` copies under `observed-sidecars/`, outside
   the object-reading repository and bundle. Include their bytes in every source
   observation, storage digest and scratch counter. A private `validate_reverse_index`
   boundary checks RIDX v1, hash ID, bounded matching pack/index counts, exact
   lengths, v2 index framing/checksums, ordinary/large offsets, position permutation,
   increasing in-body offsets, actual pack trailer/basename and reverse checksum.
   Run this before any object-reading Git. Preserve the source sidecar unchanged.
   Link this boundary to the spec's admitted observation policy: its invariant is
   optional reverse metadata never serving as object-reading input; a new format
   or consumer requires re-evaluation, not another copied workaround.

4. **Check objects and export the whole candidate.** Use fixed Git `cat-file`
   commands only against the scrubbed private copy, in the cleared environment and
   descriptor boundary from the spec. Check every declared/actual type and length,
   exact protocol framing, successful child exit and independently recomputed Git
   object ID. Parse bounded raw commits and ordered raw trees; check source and
   candidate trees, changed-path digest/count, allowed-path contract and parents.
   Preserve the no-change source-root parent convention without inventing ancestry.

   A single traversal validates names/modes, NFC-casefold component aliases,
   prefixes, visits and expanded budgets. Count repeated blobs per exported path
   and repeated trees per visit. Reject unsupported modes and non-root empty trees.
   Exclusively create files through destination descriptors; stream raw bytes,
   apply 0400/0500 file modes and 0500 directories, then reread actual files for
   SHA-256, size and Git identity. Enumerate exact actual spelling, permissions,
   single links and unique inodes; reject a filesystem's rewriting or aliasing.
   Attributes, fake instructions and executable content stay ordinary bytes.

5. **Publish once and inspect without repair.** Share the input, storage, object
   and bundle measurement functions between operations. `prepare` alone creates
   the absent 0700 bundle and permanent exclusive lock. `inspect` opens the existing
   lock without creating anything in the bundle and serializes with the writer.
   Build exactly the six top-level entries and closed manifest/record schemas in
   the spec; measure actual files rather than trusting saved inventory declarations.
   Record all required hashes, complete sorted source observation, checked refs,
   identities and explicitly mutable, unauthenticated local ownership state.

   After final rechecks and file/content-directory fsyncs, write/fsync the private
   completion temporary, rename to absent `record.json` under the held lock, then
   fsync bundle and parent. Only the complete successful sequence may reply with
   the bounded canonical envelope. Close writable candidate descriptors before
   handoff. Map refusals, handled interrupts, deadline and outward-pipe failures to
   the spec's exact codes/tokens; never leak hostile diagnostics or absolute paths.
   Preserve failed output and scratch, including post-rename failures. Only owned
   successful-invocation scratch is eligible for automatic cleanup. `inspect`
   revalidates identities, source objects/observations and the complete bundle;
   leftovers, absent/extra entries, altered tools/bytes/modes and partial records
   refuse unchanged. It cannot finish an interrupted writer or export again.

## Proof built alongside those steps

Use one private fixture driver and table-driven cases, not a new testing framework.
Success fixtures always run the unchanged real materializer and preparation in
separate processes. Expected bytes/modes come from fixture construction, never the
emitted manifest. The helper may import production functions for narrow injected
faults and synchronization; it cannot expose a product test flag, callback, fake
validator success or alternate protocol. Keep clean CLI successes and real OS
failures alongside those injected cases. Each group below covers its full numbered
spec proof row, including that row's detailed negatives.

| Spec proof | Shared scenarios and required oracle |
| --- | --- |
| 1 — actual exports | A compact SHA-1/SHA-256 × changed/no-change matrix with root/ancestor sources, empty roots/files, executable and binary/NUL/CRLF/no-final-newline bytes, repeated blobs, unchanged files and nested UTF-8 paths. Compare independently expected bytes, modes, counts, sizes, hashes and complete actual inventory. Assert real producer `.rev` presence in its positive case; separately create a no-sidecar fixture from the start. Check source sidecars unchanged, observed and charged, absent from Git-reading copy/bundle. |
| 2 — inert content | Add attribute/filter/encoding and fake-instruction traps to those fixtures, with positive controls showing the traps work in an ordinary fixture consumer. Confirm raw export remains exact. Hostile config/hooks/alternates and inherited Git/Python/shell variables cannot execute or reach synthetic sentinel roots. |
| 3 — identity | Table-drive every input/response/request/profile/attempt/source/candidate/parent/outcome relation, fake receipt, strict JSON shape and altered dependency rejection. Rehash enclosing links to reach the targeted relation; retain separate raw digest failures. Use the real response validator and real object checks. |
| 4 — storage/trees | Construct separate owned malformed raw-object/storage fixtures for every spec framing, order, mode, name, alias, link and node refusal. Check representable Unicode success or honest platform refusal. Cover both algorithms' `.rev` name/header/version/hash-ID/count/length/permutation/offset/checksum errors, with rehashed structural mutations, unpaired/nonregular/linked/oversize sidecars and other auxiliaries. Never prune producer output to create a positive. |
| 5 — bounds | A ledger in the private helper maps every spec limit to inclusive and +1 cases through actual copy/read/export paths. Include repeated-blob expansion and sidecar storage/scratch totals. For structurally unreachable valid maxima, pair the production primitive bound with semantic rejection. Observe retained buffer high-water marks and concurrent pipe draining; no deadlock or uncharged temporary bytes. |
| 6 — preservation/races | Snapshot input, candidate, original fixture source and prior output before each refusal. Synchronize replacement, addition/removal and same-inode/same-length mutation during copy and final recheck, restoring timestamps where possible. Require ready/release positive controls and unchanged prior usable state; do not claim unobserved change-and-restore detection. |
| 7 — I/O | Real read/write/mkdir/collision failures plus narrowly injected write/fsync/rename/directory-fsync/pipe errors in the production functions. Assert nonzero, no success envelope and preserved state, including after record rename. |
| 8 — lifecycle | Watchdog-controlled SIGKILL after export before publication, and after successful publication before any reply; prove zero outward bytes at the latter pause. Fresh `inspect` leaves the former incomplete and recovers the latter identically. Add handled signals, deadline child reaping, broken reply, extra/corrupt content, prepare collision and lock serialization. No second export or repair. |
| 9 — restoration | Copy a complete bundle into new private owned paths and inspect with its real input/response/candidate. Reject partial, tampered and stale-dependency copies. Demonstrate same-owner chmod/change succeeds locally and inspection then refuses; permissions never prove containment. |

## Validation and delivery

Use the full configured Linux CI shard union of the unchanged
`scripts/test/run-all.sh` for complete-runner and named regression proof on the
final candidate. Discovery must include the new suite,
`local-git-materializer-protocol`, `local-git-materializer-adapter`, the legacy
40-check `delivery-replay`, `replay-materialization-result`, both
`default-profile-assembly` and `alternative-profile-assembly`, and `target-packaging`.
Run the new component's complete focused suite once natively for Darwin evidence.
No extra native serial full-suite run is required. Rerun only affected checks or
checks needed to resolve new failures; keep valid evidence without duplicate runs.

Run the existing structure-manifest check, `git diff --check`, repository-wide
Shellcheck 0.11.0, runner discovery/sharding proof and rename gate. Retain full logs
bound to actual head/base. Required CI remains unchanged. Record Linux and Darwin
component evidence separately with actual interpreter/Git/jq/platform identities;
unsupported primitives or a missing existing runtime are a recorded refusal, never
a skipped passing case. Do not install a runtime or claim unrun platform proof.

Document the exact bundle restoration inputs, dependency/ownership preconditions,
failed-attempt disposition and the supervisor's separate provenance, remeasurement,
descriptor closure and read-only isolation duties. Preserve the parent's fixed
verifier invocation, environment and resource ceilings. This component runs no
verifier and proves no sandbox qualification or authenticated receipt. No live
installation, activation, target execution, credentials, network expansion, frozen
or dirty-attempt adoption is included. The manager reads the complete independent
review, resolves Important findings and checks exact head/base and required CI
before protected merge; the terminal implementation PR alone closes #327.
