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
