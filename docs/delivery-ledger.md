# Inactive durable delivery ledger

`orchestrator/v1/delivery-ledger.py` stores the reconciliation planner's delivery
history. It does not dispatch work, contact a provider, authenticate evidence or
activate a profile. The caller owns a dedicated local store and supplies requests.
No installed service, credential or generated binary is needed.

## Invocation

Invoke the absolute physical source path with an existing identified interpreter:

```text
/usr/bin/python3 -I -S -B SOURCE/orchestrator/v1/delivery-ledger.py VERB STORE_ROOT REQUEST_FILE
```

That is the Linux entry. On Darwin the interpreter is
`/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python`.
No PATH search, shebang selection or interpreter download is supported.

The trusted caller starts with an empty environment containing only
`PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C`, `HOME=/dev/null` and
`TMPDIR=STORE_ROOT`. Cwd is the physical store root; stdin is `/dev/null`.
Only stdout and stderr pipes are inherited. These are startup preconditions,
not something Python can repair after a hostile loader has already executed.

The root must already exist, be owned by the current UID, mode0700 and outside
source checkouts and execution roots. Every path component must be physical.
The request is a separate owned regular mode0400 or0600 file outside the store.
Symlinks, special files, unsafe modes and external state hard links are refused.
Use a trusted UID and local filesystem with working flock and atomic rename.
The command does not exclude a hostile same-UID writer or filesystem administrator.

## Requests and results

The verbs are `initialize`, `read` and `apply-update`. All requests have exactly
`protocol: "ystack.delivery-ledger.v1"`, `store_id` and `ledger_id` plus their
verb's fields. Initialize adds `initialization_id` and `recorded_at`.
Read adds nothing. Update adds `update_id`, `expected_tip`, `delivery_key`,
`action`, `recorded_at` and `delivery_ordinal`.

A key contains `stage_key`, `request_sha256`, `operation` and `attempt_number`.
The stage key has `initiative_id`, `workflow_id`, `stage_id` and `task_class_id`.
Operations are `dispatch-stage`, `retry-stage` and `recover-stranded-attempt`.
Attempts range1–10. IDs use lowercase ASCII letters, digits and `._:-`, start
with a letter or digit and contain at most128 characters. Digests are lowercase
hexadecimal. Timestamps use exact `YYYY-MM-DDTHH:MM:SSZ` Gregorian dates,
including year0000; no fractions, offsets or leap seconds are accepted.

JSON is recursively sorted, compact ASCII with exactly one final LF. Duplicate
keys, floats, Boolean integers, noncanonical bytes and extra fields are refused.
The accepted full contract is in `work/durable-delivery-ledger/spec.md`.

Success returns protocol and identities, captured `current_tip`, `result_tip`,
`ledger`, `receipt` and `ledger_ref`. Read has a null receipt. The exported
reference is SHA256 of the exact canonical ledger bytes including LF. The
unchanged planner checks reference shape and ID, but does not authenticate that
digest. Storage recomputes its own history, transitions, digests and receipts.

A first delivery creates pending count1. Redelivery increments the count and
updates its delivery time. Failure requires the latest delivered ordinal.
Acknowledgment may arrive late for any delivered positive ordinal. An acknowledged
key is terminal; a new update ID cannot reopen it. Update time cannot precede
the ledger time. Acknowledgment and failure retain the original delivery time.

## Replay and publication

Every call holds the same permanent `store.lock` through validation and response.
Contenders fail immediately. A single process validates every reachable commit,
all loose objects and retained residue; it never runs Git or another child.
An exact update ID replay returns its original ledger, receipt and result tip,
with the current tip, before stale-tip, time or capacity checks. Changed content
under that ID conflicts. Exact initialization can replay after later updates.

The private SHA1 Git repository has fixed config and HEAD, a direct ledger ref,
four named blobs per tree and fixed commit metadata. New objects use exclusive
owned temporary files. A closed41-byte ref lock is atomically renamed to publish.
An error before that rename leaves the old view; an error after it may lose the
reply while preserving the new view. A fresh read and exact replay resolve that
uncertainty. There is no rollback, garbage collection or automatic stale-lock repair.

Maximums are128 entries,1000 deliveries per key,1024 updates,8192 object/temp
paths,16384 total entries and128MiB each of regular and inflated bytes. Admission
reserves8 objects,32 entries and1MiB in each byte counter. Partial object temps
cost270336 inflated bytes. Unreachable objects and crash residue always count.
Requests cap8192 bytes, ledger262144, response524288 and loose raw objects270336.
A quota refusal does not invalidate an otherwise valid read or exact replay.

## Proof and restoration

Run `bash scripts/test/orchestrator-delivery-ledger.test.sh` and the existing
`orchestrator-reconciliation-plan.test.sh`. The focused suite uses actual public
calls, jq1.6 byte oracles and private held-operation crash observations. Real Git
interoperability runs only in separate copies, never as the application's writer.
Native Darwin evidence and required Linux CI are separate. Process-crash proof
is not power-loss durability or proof against administrators and hostile filesystems.

Restore this source, focused test and guide with `docs/components.md` and
`ci/required-files.txt`, plus the existing planner and portable schema dependencies.
Restoring these inactive files grants no live execution, target or credential use.
