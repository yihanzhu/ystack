---
spec-blob: e161301045491f5f41d2fb2df0c6ad0a6284f914
drafted: 2026-10-13
---

# Plan: harden scope qualification evidence core

Tracks #541. Risk is high. This is the nonterminal child-6 core. It authenticates
the existing child-5 evidence at one exact revision. Issue #544 remains mandatory
before child 6 completes or child 7 starts.

Implementation PR: `review_size: accepted-exception`, 2,600–3,800 net changed
lines. The private evidence reader, held-path and Git checks, closed evaluator
relations, and a real two-principal origin fixture form one security boundary.
Most of the range is proof: complete bundle and write-relation damage cases plus
the same-contract owner, group, ACL, descriptor and receipt lifecycle. The range
does not relax readability, tests, CI, review, or any acceptance standard.

## Files that change

The plan PR changes only this file. The implementation may change only these
paths:

- `scope/v1/read-shadow-evidence.py` — new private reader for completed bundles,
  controlled-store origin, fixed receipt checks and target Git facts.
- `scope/v1/evaluate-scope.sh` — extend the one existing evaluator entry point,
  run the private reader, and pass its measured result to jq.
- `scope/v1/scope-gates.jq` — validate the closed internal observation and apply
  authentic receipt, native identity, record-form, exact-revision and write gates.
- `scope/v1/scope-policy.json` — add only
  `scope.sandbox-receipt-missing` to the closed reason vocabulary.
- `shadow/v1/_consumer.py` — expose private reusable held-bundle and read-only Git
  primitives without adding a public command or trust input.
- `shadow/v1/write-shadow.py` — call the shared Git primitive with unchanged
  child-5 behavior, so scope does not carry a second implementation.
- `scripts/test/scope-qualification.test.sh` — complete core proof, including the
  real controlled-store fixture.
- `scripts/test/shadow-write.test.sh` — prove the shared Git primitive preserves
  the accepted writer behavior and fixed command set.
- `docs/components.md` and `RESTORE.md` — document the inactive inputs, refusal
  state, restore set and focused/full proof commands.
- `ci/required-files.txt` — add the new private reader exactly once.

No intent, spec, workflow, construction marker, accepted identity, registry,
host-supervisor, sandbox launcher, generic library, `scripts/test/run-all.sh`, or
other path changes. The new reader is restore-critical, so omitting the manifest
entry is not an option. Keep shell files executable. The implementation remains
one PR and uses `Closes #541`; closing it records only the nonterminal core while
#544 remains the required continuation.

## Fixed invocation and data flow

Keep `evaluate-scope.sh` as the only public evaluator. Its command is exactly:

```text
evaluate SCOPE SHADOW_SET DASHBOARD RISK KILL DUTY MARKER BUNDLE_ROOT SOURCE_GIT_DIR
```

The first seven document arguments keep their existing schemas, one-MiB bounds,
canonical snapshots and stale checks. `BUNDLE_ROOT` and `SOURCE_GIT_DIR` are
physical absolute directory locators. They are not evidence and grant no trust.
Reject symlinks, traversal, relative paths, aliases, overlap with scratch, wrong
kind and changes observed through held and named descriptors.

`BUNDLE_ROOT` has one closed layout. Each direct child is named by the lowercase
SHA-256 of one canonical record in `SHADOW_SET`. It is a completed child-5 output
directory. Direct children not named by a supplied record refuse. A legacy record
has no child directory. A claimed enforced record with no matching directory is
well-formed missing evidence. A legacy record with a directory, an unclaimed
directory, or two paths for one digest is malformed.

`SOURCE_GIT_DIR` is one held bare object database for the scope's target. All
records and the scope must name the same repository id, hash algorithm and exact
target commit before the reader uses it. The locator does not prove a repository
id. Git object hashes and the record/scope relations prove the exact bytes used by
this inactive evaluation.

The driver snapshots its own package files and the seven documents first. It then
runs the physical current Python as:

```text
P -I -S -B PACKAGE/scope/v1/read-shadow-evidence.py read \
  SNAPSHOT_SCOPE SNAPSHOT_SHADOW_SET BUNDLE_ROOT SOURCE_GIT_DIR OUTPUT
```

Use a clean fixed environment, closed descriptors, bounded stdout/stderr, a
bounded runtime, one foreground child, and exact reap. The reader writes one
canonical internal `scope_shadow_evidence_observation` to the exclusive `OUTPUT`.
It never writes the bundle, store, Git repository, package or target. It reports
measured refs and facts, not an authorization decision. The driver snapshots this
file, passes it to `scope-gates.jq` as one fixed slurp input, and rechecks package,
documents, both directory trees and the observation before emitting output.

Keep the existing driver error vocabulary. Bad invocation is `E_USAGE`; an input
or output bound is `E_LIMIT`; malformed JSON is `E_PARSE` or `E_CANONICAL` as it
is today; a closed contract mismatch is `E_RELATION`; a changed held object is
`E_STALE`; an OS, child or reap failure is `E_RUNTIME`. Missing authentic evidence
is not a driver error. The reader records a closed missing state so jq emits the
deterministic not-proposable reason `scope.sandbox-receipt-missing`.

## Private reader and trust closure

Move the read-only bare-Git inventory logic from `write-shadow.py` into
`_consumer.py`. Keep the writer's exact `/usr/bin/git --no-replace-objects`
commands, clean environment, config allowlist, bare/object-format checks, and
rejection of shallow state, alternates, grafts, replace refs, worktrees and
promisor packs. Hold and recheck repository ancestors, config and object database
around every command. Accept only fixed `config`, `rev-parse`, `ls-tree` and
`cat-file` forms. Hooks, filters, prompts, global/system config, arbitrary refs and
caller-selected Git commands remain impossible. `write-shadow.py` must use this
same primitive after the refactor.

Add a private bundle reader to `_consumer.py`. It opens a bundle directory and
every listed file descriptor-relative with no-follow rules, one link, regular-file
kind, bounded size and stable before/after metadata. Require canonical
`bundle.json`, exact sorted names, exact sizes and SHA-256 values, and no extra
entry. The only inventories are the accepted enforced-reproduction and
withheld-write inventories. The completion marker is present before the directory
is considered complete. Keep descriptors through all relation checks and perform
a final name/descriptor recheck before success.

The scope reader loads `_consumer.py` only from its measured physical sibling in
the fixed package. It uses `load_anchor` and `read_store_attempt`; it does not add
an anchor argument or environment override. On Darwin it uses the existing fixed
UUID and supplementary-group child roles with the same physical Python, clean
environment, saved mask, closed descriptors, timeout, output limits and unique
reap. Refactor only the concrete runner needed to share those roles; do not add a
generic child dispatcher, callback, registry or caller-supplied command.

For each completed bundle, perform these checks in this order:

1. Match the raw `shadow-record.json` to the record selected by its directory
   digest. Dispatch only legacy, `enforced-reproduction.v1`, and
   `withheld-write.v1` exactly as the spec defines.
2. Match bundle copies of registry, accepted set, control policy, decision,
   policy set and evaluator files byte for byte with the root-owned package held
   by `load_anchor`. Match their complete references in the record and retained
   documents. Package drift refuses.
3. Reconstruct the launch expectation and its relation to the retained request,
   preparation/materialization records, claim, environment, candidate, incident,
   store and payload. Do not add a field to the existing checker.
4. Call `read_store_attempt(anchor, attempt_id)`. Require its fresh raw receipt,
   stdout, stderr, evidence manifest and evidence file to equal the retained
   bundle bytes. Require the fresh canonical origin observation to equal the
   retained authenticated observation and its digest. Recheck the anchor and held
   store after the comparison.
5. Invoke the existing checker exactly as
   `check-bound RECEIPT EXPECTATION EVALUATION VERIFIER_OBSERVATION`. The verifier
   observation is freshly derived from the fixed anchor and target repository id.
   Require the returned canonical check bytes to equal `sandbox-check.json`, with
   valid check and satisfied enforcement verdicts.
6. Select exactly one registry row and one accepted-set row for the environment.
   Require `proof_state: native-qualified` and field-for-field identity agreement
   with the receipt. Duplicate, absent, foreign, unproven or caller-labelled rows
   refuse qualification. The shipped empty/unproven state therefore stays
   not-proposable.
7. Validate every remaining child-5 ref and relation, including provenance,
   qualified identity, trace, result, materializer response and the exact record
   form. Produce only canonical measured refs and the minimum derived facts jq
   needs. Never forward a caller `trusted`, `checked` or `native-qualified` value
   as a decision.

The controlled store establishes the origin of receipt and payload bytes. The
caller-owned bundle remains only a held transport until all raw bytes match that
store and the fixed package. A copied observation, matching digest, supplied JSON
or successful checker invocation alone cannot satisfy origin.

## Record, Git and write relations

For enforced no-change, require the exact 29 evidence files plus marker, outcome
`no-change`, no `write` field, and all accepted child-5 relations. For withheld
write, require the complete outer inventory, changed materialization and the exact
write object. A missing, extra or cross-form field is malformed; it never falls
back to another form.

Derive source and candidate facts from `SOURCE_GIT_DIR`. Read the source commit,
candidate commit and trees with the shared fixed Git primitive. Require the
candidate's sole parent to be the source commit. Compare repository, algorithm,
commit and tree ids with the incident, qualified identity, materializer response,
preparation records, publisher request and post-write verification.

For a withheld write, reconstruct the exact 32 files from held bundle bytes plus
the deterministic seed and README rules already used by child 5. Recompute each
raw SHA-256 and Git blob oid, the sorted add-only mode-`100644` write set and the
bounded text patch. Compare them to the write section, actual candidate tree and
materializer request/response. Require every leaf absent from source, every row to
match an allowed scope glob and the existing protected-path predicate, and no
changed existing leaf, unrelated sibling or subtree. Permit only ancestor tree
object changes necessary for the new leaves. Keep publication withheld, admission
effect none and every request/body/post-check digest exact.

Classify from the scope's fixed workflow and task fields. Only
`workflow.shadow-evidence-commit` plus `task.commit-shadow-evidence` may consume a
withheld-write form. A partial or mixed pair is malformed. A scope matching
neither field keeps all existing read-only exact-revision, full-identity and
no-change checks, with the new authentic receipt requirement. No record field or
caller boolean selects the class.

`scope-gates.jq` consumes only the reader's closed observation. It keeps every
unchanged risk, path, eval, kill, duty, mode, identity and proposal predicate.
Add the new reason only when a required environment has no one complete authentic
bundle. Structural ambiguity or a failed fixed relation stays a closed error.
Output remains inactive, observation-only, authority none, enabled false and
qualification unavailable. Do not add coverage, freshness, enablement, provider
or publication fields reserved for #544.

## Same-contract controlled-origin fixture

The positive origin case must exercise the production consumer checks. It may not
patch metadata functions, replace `ANCHOR`, copy an origin document or run writer
and reader as one uid.

On a disposable Linux CI runner, and on the required disposable Mac evidence
host, the scope test uses passwordless `/usr/bin/sudo -n` to create one unique
writer account, one distinct consumer account and one consumer group. It first
refuses if the fixed anchor already exists. Root creates the physical fixed anchor
and root-owned package/config/identity files with their production modes. The
config names the writer uid, consumer gid, unique store/work roots and the
reviewed package bytes. The disposable registry and accepted-set fixture bytes are
installed through that root-owned package; they do not alter tracked production
files.

Run the existing fixed host-supervisor store writer as the writer account to
create the exact bounded attempt. Run the real scope evaluator as the consumer
account, whose only access is the read-only group. The bundle and source Git
snapshot live outside the controlled store. Assert actual uid/gid, mode, platform
ACL, link, no-follow, held-descriptor, fresh-origin and `check-bound` success.
Then prove the consumer cannot create, replace, rename, chmod, link or remove a
store object. Root cleanup removes only the uniquely named fixture after every
case; cleanup failure fails the suite. No production anchor may be overwritten.

Use the same setup for paired negatives: caller-created store copy, same bytes
under the wrong owner or store id, writer/consumer uid collapse, missing group,
extra ACL grant, symlink/hardlink, metadata swap, changed receipt/payload and
anchor/package drift. On macOS include a supplementary-group-only positive and
the existing UUID-qualified ACL checks. Record actual `id`, filesystem metadata
and ACL command output with the test evidence. Fixture native-qualified entries
prove only this closed consumer path; they never claim CPU/wall proof, VM
qualification or a production identity.

If either platform cannot provide distinct principals, real ACLs or noninteractive
root setup, stop G3 as blocked. Do not replace this case with mocks, same-uid files,
permanent refusal or a skipped positive.

## Proof and completion

Add focused cases for every spec R6 item. Besides the real fixture above, cover:

- all three forms; exact inventories; missing/extra/early marker; swapped bundle
  directories; copied origin; fixed-package drift; stale descriptors; wrong
  attempt, candidate, environment, policy, payload, store and checker bytes;
- every required environment; absent, duplicate, foreign, unproven and forged
  registry/accepted rows; recomputed JSON digests do not create trust;
- the legal fixed write pair with no-change and withheld-write; both partial and
  mixed pairs; neither-field read-only exact-revision positive and cross-revision
  refusal; record fields cannot select class;
- the exact 32-file write, deterministic repeat, legal ancestor-tree changes and
  every damaged source, parent, tree, path, mode, blob, patch, body, request,
  publication and post-check relation from spec R6.6;
- fixed Git command rejection, config/replace/alternate/shallow/promisor drift,
  bundle/Git races, child timeout/signal/nonzero/malformed output and exact reap;
  no target write, network, credential, producer or publisher call.

Preserve existing byte-for-byte outputs where the new authenticity requirement
does not intentionally change the result. Update docs with the exact nine-argument
input contract after `evaluate`, the digest-directory layout, deterministic missing
reason, inactive status and #544 boundary. Restore instructions list the new reader
and do not describe fixture setup as installation or activation.

On the final implementation head, run and retain complete output for:

```sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/shadow-enforced.test.sh
bash scripts/test/shadow-write.test.sh
bash scripts/test/sandbox-receipt.test.sh
bash scripts/test/local-git-materializer.test.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/integration.test.sh
bash scripts/test/run-all.sh
```

Run the focused real-principal proof on Linux and macOS. Record OS/version,
filesystem, uid/gid/group and ACL observations and exact head. Then dispatch the
six-shard full matrix from the exact PR head with
`gh workflow run ci.yml --ref BRANCH`, bind its run id and head SHA, and require
all six `test` shards, `checks`, aggregate `ci`, and repository-required external
checks green. Automatic quick CI is additional evidence, not the full matrix.

Before publication, compare the implementation diff to the exact allowed-path
list, run `git diff --check`, verify intent/spec/plan blobs and risk, require the
new manifest entry exactly once, and confirm no tracked production registry or
accepted-set fixture changed. A separate read-only reviewer reads the complete
exact-head/base diff and raw test evidence. Resolve every Important finding. The
named manager alone performs the protected merge and records the receipt. No
merge, test, fixture or document may claim that #544, native qualification,
enablement or child 6 is complete.
