# Stored materialization results

The inactive delivery replay can retain the real response of one local Git
materialization. This is a narrow recovery boundary for the existing offline
simulation. It does not send or acknowledge a delivery, resume a workflow, qualify
an actor, or grant publication authority.

## Delivery key

Pass `--delivery-key FILE` to create or reopen a keyed journal. The file is one
canonical JSON object:

```json
{
  "attempt_number": 1,
  "operation": "dispatch-stage",
  "request_sha256": "<64 lowercase hexadecimal characters>",
  "stage_key": {
    "initiative_id": "<request initiative_id>",
    "stage_id": "<request stage_id>",
    "task_class_id": "<request task_class_id>",
    "workflow_id": "<request workflow_id>"
  }
}
```

Every value must equal the supplied materialization input. Extra fields, including
a delivery ordinal, are rejected. The complete key becomes part of the run identity.
One state directory therefore represents one key and one attempt. There is no lookup
or deduplication across state directories.

Use the normal replay arguments and add the key:

```sh
python3 delivery/v1/replay.py \
  --input materialization-input.json \
  --delivery-key delivery-key.json \
  --source-repository-id fixture.target \
  --source-git-dir source.git \
  --candidate-root candidate \
  --scratch-root scratch \
  --state-dir state \
  --closure-helper object-closure \
  --jq-bin jq-1.6 \
  --verify-path source.txt \
  --expected-sha256 '<expected digest>'
```

The keyed call writes journal schema version 2. Before materialization it records a
pending receiver result. After bounded capture and complete validation it atomically
replaces that journal with the response bytes, response digest, canonical extracted
stage-result digest, receipt digest, and candidate identity. Later replay phases keep
those fields byte-for-byte.

Calls without a key keep journal schema version 1 and its established replay and
reconciliation behavior. A key cannot attach to version 1, and version 2 cannot be
opened without its matching key. There is no migration between the formats.

## Read-only retrieval

Add `--read-materialization-result` with the same normal identity arguments and the
same key:

```sh
python3 delivery/v1/replay.py \
  --read-materialization-result \
  --input materialization-input.json \
  --delivery-key delivery-key.json \
  --source-repository-id fixture.target \
  --source-git-dir source.git \
  --candidate-root candidate \
  --scratch-root scratch \
  --state-dir state \
  --closure-helper object-closure \
  --jq-bin jq-1.6 \
  --verify-path source.txt \
  --expected-sha256 '<expected digest>'
```

Read mode requires the existing state, execution snapshot, frozen input, and regular
permanent `replay.lock`. It creates none of them. It rejects review and publisher
observations. It validates the current tools and source plus the stored response,
receipt, stage result, changed paths, and read-only candidate Git identity. It does
not materialize, reconcile, verify candidate content, write a phase, consume an
observation, or acknowledge a delivery.

A stored result exits 0 and returns a
`delivery_replay_materialization_result` envelope. Its `response_utf8` is the exact
captured response, including the final newline. Its `stage_result` pair contains the
actual result object extracted from that response and canonicalized with the frozen
jq 1.6. Its receipt is the response's actual payload.

A valid pending journal exits 3 with
`replay.materialization-result-missing`. A valid version 1 journal read without a key
exits 3 with `replay.legacy-result-unavailable`. Neither unavailable response contains
a result or receipt. Identity conflicts exit 2. Malformed, missing, oversized, or
unavailable evidence exits 1. Interruption keeps exit 75.

## Limits and recovery

The inclusive limits are 8 MiB for supplied and frozen input, 4 KiB for the key,
1 MiB for captured response stdout, 256 KiB for the canonical stage result, 64 KiB
for receipt UTF-8, 64 KiB for retained materializer stderr, and 8 MiB for a version 2
journal. Version 1 journals and each workflow observation remain limited to 64 KiB.
Changed-path inventory remains limited to 2 MiB. JSON must be strict UTF-8 with one
document, unique members, finite numbers, valid Unicode, and depth no greater than 32.

If the process dies after candidate materialization but before journal publication,
the pending record and any nonempty candidate or scratch boundary produce explicit
missing-result evidence. Reopen preserves those bytes and never reconstructs the
result, reconciles the candidate, or starts another attempt. An empty pending
pre-effect state may perform the same attempt's first materialization.

If the process dies after the stored journal replacement but before its outward
reply, a fresh read returns the original stored response. This process-crash boundary
does not prove power-loss durability or exactly-once effects outside the local journal.
Digest agreement proves internal consistency, not provenance, permission, freshness,
qualification, or authority.

Restore the complete private state directory, including `run.json`,
`materialization-input.json`, `execution/`, and the existing `replay.lock`. Restore the
same source, candidate, and scratch boundaries and supply byte-identical replay driver,
materializer package, core generation, jq, object-closure helper, input, key, verifier,
and source identity. The four directories must remain caller-owned, private, and
disjoint. Partial copies, changed tools, or a matching digest alone cannot be promoted
to original-result evidence.

## Containing source commits

Restoration also needs the published commits named by the package and profile
bindings. The materializer source commit is
`8fc0675eb4e34acbebe9c8ab0310e64328a6114e`; its
`adapters/local-git-materializer/v1` path is tree
`07dc1fa6a1084be8a316384634d521b618991897`, mode `040000`. Profile commit
`4a576d9181d5e8c01c04f027432ad8b143400cee` contains the four bound documents:

| Document | SHA-256 of canonical jq 1.6 bytes with one final newline |
| --- | --- |
| Default profile | `81da07a8390b2ec6e00413cce6fad4bd07badbd17a512295da8e5292ace53574` |
| Alternative profile | `a2f3e69aa2d93afabfa852b6313de69fd44a0ee0d60a6c6ab693d0d3e8f91567` |
| Both local Git materializer manifests | `f2ace723bf3b604d756169f2cc12c89a02c08026984975e6bd476af4a6d6c3c8` |

Keep both commits reachable on the existing published
`ystack/impl/replay-materialization-result` branch after any squash merge. Do not
delete or rewrite that history while these bindings reference it. A squash commit,
a local object, or a temporarily dangling server object does not retain the original
containing commits. Omitting a CLI deletion option does not prevent server deletion.
The manager must obtain the separate approval and verify the retention procedure
recorded in [the accepted plan](../work/replay-materialization-result/plan.md)
before merging; this source record is not a completed merge or retention receipt.

Before relying on these bindings, fetch each exact containing commit into its own
fresh isolated history repository using the assembly tests' `history_fetch` boundary
and unchanged source/auth handling. Require `--depth=1 --no-tags`, the exact fetched
commit, ancestry from the retaining branch, one reachable commit and no tags. Check
the source package path, mode, type and tree object above. At the profile commit,
require all four files to be regular `100644` blobs, with complete bytes matching
the checkout and the hashes above. Compare their structures against the accepted
base, allowing only the materializer package tree/revision and its binding's
manifest digest. Repeat these fresh source/content checks before PR publication
and protected merge, and record them with the final receipt. Changed package or
profile bytes require new observed source commits and all dependent pins; a digest
agreement alone cannot replace the retained history or the complete state backup.
