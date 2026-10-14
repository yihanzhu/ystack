---
spec-blob: e161301045491f5f41d2fb2df0c6ad0a6284f914
drafted: 2026-10-13
---

# Plan: harden scope qualification evidence core

Tracks #541. Risk is high. This is the nonterminal child-6 core. It authenticates
the existing child-5 evidence at one exact revision. Issue #544 remains mandatory
before child 6 completes or child 7 starts.

Implementation PR: `review_size: accepted-exception`, 2,600–5,000 net changed
lines. The private evidence reader, held-path and Git checks, closed evaluator
relations, and a real two-principal origin fixture form one security boundary.
Most of the range is proof: complete classification, bundle, Git, terminal and
authenticated-set controls, plus the same-contract owner, group, ACL, descriptor
and receipt lifecycle. The range preserves readable controls and does not relax
tests, CI, review, or any acceptance standard.

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
- `shadow/v1/enforced-reproduction.py` — wire its existing fixed Darwin UUID and
  group roles to the shared private owner with unchanged argv, ledger and lifecycle.
- `shadow/v1/write-shadow.py` — call the shared Git primitive with unchanged
  child-5 behavior, so scope does not carry a second implementation.
- `scripts/test/scope-qualification.test.sh` — complete core proof, including the
  real controlled-store fixture.
- `scripts/test/shadow-enforced.test.sh` — keep the original native-owner proof
  on the real private adapter after moving its obsolete test injection point.
- `scripts/test/shadow-write.test.sh` — prove the shared Git primitive preserves
  the accepted writer behavior and fixed command set.
- `scripts/test/shadow-self-host-evidence.test.sh` — move its real evaluator
  compatibility call to the nine-argument contract and preserve its inactive,
  identity-bound result under the new authentic-receipt refusal.
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
For the existing declaration-only compatibility case in
`shadow-self-host-evidence.test.sh`, pass a newly created empty `BUNDLE_ROOT`.
That case has two real legacy records, so an empty root is its only legal layout;
it must not manufacture a completed child-5 bundle.

`SOURCE_GIT_DIR` is one held bare object database for the scope's target. The scope
and every enforced or write record eligible to contribute must name its repository
id, hash algorithm and exact target commit. A referenced legacy record is always
reporting-only and creates no Git prerequisite, even when its revision and identity
match the current scope. The locator does not prove a repository id. Git object
hashes and the eligible enforced/write record relations prove the exact bytes used
by this inactive evaluation.
The legacy-only compatibility test creates a genuine local bare object database,
passes its physical held directory as `SOURCE_GIT_DIR`, and verifies bare-repository
shape, expected object format, stable config and object-directory metadata. No
record is eligible to contribute, so the reader performs no commit, tree or blob
lookup and the database may contain no objects. An invented directory, supplied
JSON or bare locator still proves no repository identity or Git fact. Never fetch,
reconstruct or require any of the legacy records' historical objects for this
reporting-only case.

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
measured refs and facts, not an authorization decision.

The existing reader control FIFOs carry a closed three-frame handshake. The reader
writes exactly `READY\n` after `OUTPUT` is complete. The driver snapshots the
observation, records its exact SHA-256, and runs `scope-gates.jq` once with that
snapshot as the fixed slurp input. It validates and retains that evaluation but
does not publish it. The driver then writes exactly `SEAL\n`. The final reader
frame has the ASCII form `COMMIT <size> <sha256>\n`, with single spaces, canonical
decimal size without a leading zero, and lowercase SHA-256. It is at most 96
bytes and must arrive in one complete write. Any missing, partial, duplicate,
reordered, oversized or trailing frame, early EOF, timeout, signal, nonzero exit
or reap error is `E_RUNTIME` and publishes no evaluation.

On `SEAL`, keep the command ledger open while the reader rechecks the control
FIFO, every held package/input/bundle/store/Git/identity descriptor, and the full
anchor. These remain the existing real checks: a Darwin rule may make another
fixed UUID call, and every such call appends its actual four-field command row.
Only after this complete recheck succeeds may the reader atomically close ledger
append. `record_command` refuses every call after closure. It also refuses before
an append that would exceed 4,096 rows. Do not cache an ACL or UUID result, omit a
fresh rule call, replace a full recheck with metadata-only work, or pre-record a
command that did not run.

After ledger closure, write one exclusive canonical `terminal.json` beside
`OUTPUT`, bounded by the same one-MiB document limit. Its exact top-level fields
are `schema_version`, `kind`, `id`, and `body`; kind is
`scope_shadow_evidence_terminal`, id equals the observation id, and body has
exactly `observation_sha256` and `commands`. The digest equals the exact retained
observation bytes. `commands` is the complete final ledger with the original
four-field row shape and original order. No fact, result, status, replacement
observation or authorization field is allowed. Persist and close that file, then
derive the commit size and digest from those exact in-memory canonical terminal
bytes. Write the complete bounded commit frame to the held FIFO and require that
single write to accept every byte. The size is from 1 through one MiB and equals
the terminal byte length; the digest is not a field read back from terminal.
Neither value may exist before the full SEAL recheck, ledger closure and actual
terminal serialization. Exit without another component, Git, ACL, UUID or group
call. Closing already-held descriptors is the only work after the commit frame.

The driver retains the parsed commit size and digest received while the reader is
still its owned child. It then requires the reader's successful exact reap and
empty stderr, followed by EOF with no extra FIFO byte, before opening terminal.
Snapshot at most the committed size plus
one byte with no-follow and regular one-link checks; require exact size and
SHA-256 equality to the commit frame, canonical bytes, exact closed shape, the
one-MiB and 4,096-row caps, the retained observation digest, and every command
row. A terminal's own digest, a later reread or matching metadata cannot replace
the control-frame commitment.

The observation's original `commands` must be an exact ordered prefix of the
committed terminal commands. The driver forms the unique final observation only
by replacing that array in its retained snapshot; deleting `body.commands` from
both forms must produce byte-identical canonical documents. This structural check
uses the existing fixed `jq_bin`; it does not run scope policy again or create a
second evaluator or fact source. Recheck the package, seven documents, directory
trees, retained observation bytes and the committed terminal snapshot, and require
the named terminal bytes still equal that snapshot. Only then may the driver
publish the already validated original jq evaluation.

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

The private Git owner holds the named bare repository, its ancestors, config and
object database plus the physical `/usr/bin/git`; it exposes only the current
config, `rev-parse`, `ls-tree` and `cat-file` operations with their existing output
bounds. It records every fixed call in the caller's private ledger object.
`write-shadow.py` passes its existing workspace ledger and retains its current
`_Workspace.execute` rechecks. The scope reader supplies the live ledger that the
terminal protocol closes after the full SEAL recheck. This is a concrete private
interface, not a generic subprocess, workspace callback or unrecorded second Git
implementation.

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
The shared private owner holds the physical Python and `_consumer.py` descriptors,
the fixed deadline and a closed command ledger. Its Darwin UUID method accepts
only the canonical UUID array; its group method accepts only one canonical
`{gid}` object. They keep the existing fixed argv, 10-second role cap,
32-KiB/16-byte output bounds, saved mask, close-all, signal cleanup and unique
reap. `enforced-reproduction.py` constructs this owner and keeps its existing
ledger entries; the scope reader constructs the same private owner from its held
physical files. Neither path accepts a runner callback or arbitrary argv.
Keep `_communicate_native` returning its private child-result object. The
`_DarwinLedger.native_communicate` adapter unwraps only that object's
`returncode` and returns `(int, stdout, stderr)` to the shared owner. The owner
still requires integer zero and empty stderr. Do not change the native C, roles,
argv, environment, mask, bounds, cleanup or reap contract, and do not add a
callback or a generic result coercion.
These are the only `enforced-reproduction.py` changes: its existing two roles call
the private owner's closed methods, and its private ledger adapter unwraps the
native return code. All other driver roles, request handling, ledger rows,
timeouts, cancellation, signal cleanup and reap behavior remain byte-for-byte
compatible at their public boundaries.

Separate record readability from qualification eligibility before opening any
bundle. Resolve every scope ref to exactly one canonical record in `SHADOW_SET`,
verify its digest, closed record form and bounded set membership, and retain a
reporting row for it. First compare target repository id, target hash algorithm,
exact target commit and complete qualified identity with the current scope. A row
is eligible only when that comparison matches and its closed form is an actual
enforced or withheld-write record. Legacy rows are never eligible. Apply the
existing required-environment selection only to eligible rows. Duplicate eligible
rows, missing required environments or extra eligible identities keep their
existing refusal behavior.

A shape-valid legacy row remains readable and appears in the observation as
noncontributing whether or not its identity comparison matches. It has no bundle,
origin, receipt, native identity, Git or qualification effect. Never rewrite or
drop its raw record, infer facts from it, or let it satisfy a required environment. A
claimed enforced or write row can contribute only after every bundle,
controlled-store, checker, native, current-Git and record relation below passes;
provided JSON, a matching digest or the bare locator alone never makes it eligible
or authentic.

For each eligible completed bundle, perform these checks in this order:

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
   bundle bytes. Keep the retained canonical origin observation and digest as the
   archival record's complete provenance. Match its stable store and attempt
   identifiers, plus the enclosing record's fixed-package and payload references,
   to the same retained bytes. Never use that archived observation to authenticate
   the current read.
   Require the new canonical origin observation to name the same store and attempt
   and to bind every freshly read file's size and digest. It need not equal the
   archived observation byte for byte: a sibling attempt completed before this
   acquisition may lawfully change store-directory metadata. The fresh read alone
   authenticates current origin. Preserve all owner, group, mode, ACL, link,
   no-follow, inventory, held-descriptor and before/after checks in
   `read_store_attempt`, then recheck the anchor and held store after comparison.
   Any mutation during that acquired read refuses as stale.
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

For each eligible enforced or write record, derive source and candidate facts from
`SOURCE_GIT_DIR`. Read the current source commit, candidate commit and trees with
the shared fixed Git primitive. Require the source commit to equal the scope's
exact revision and the candidate's sole parent to be that source commit. Compare
repository, algorithm, commit and tree ids with the incident, qualified identity,
materializer response, preparation records, publisher request and post-write
verification. A noneligible legacy row neither invokes Git nor supplies one of
these comparisons.

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
It computes required-environment and qualification results only from rows marked
eligible by the field-for-field comparison above and fully authenticated by the
reader. Reporting rows remain visible but cannot enter those predicates.
Add the new reason only when a required environment has no one complete authentic
bundle. Structural ambiguity or a failed fixed relation stays a closed error.
Output remains inactive, observation-only, authority none, enabled false and
qualification unavailable. Do not add coverage, freshness, enablement, provider
or publication fields reserved for #544.

Update the existing declaration-only compatibility assertion deliberately. Its
two legacy records and empty bundle root now produce reason ids containing
`scope.eval-failing` and `scope.sandbox-receipt-missing` in the policy's canonical
order. Preserve its exact per-case identity and gate relations, unavailable
qualification, absent proposal, inactive output, authority `none`, and disabled
state. Run both the pre and post scope case for each retained record group. Across
the two groups this preserves the four actual commit ids in their raw record JSON:
`d3f6d525328838b9c2de819699e53d8909ab7a3f`,
`0427390224c25147650f1bd3b6e43ed6911b97a7`,
`413a2f02a46ababa987039be65089e95c1916765`, and
`e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e`. Both the selected and unselected
legacy rows remain readable, reported and noncontributing. The genuine local bare
database is held and format-checked but none of those four commits is looked up.
The test must still fail on malformed input, a changed selected identity relation
or an attempt to make either row contribute. Do not accept `E_USAGE`, omit or
rewrite a record, synthesize a receipt, fetch historical objects, or retain the old
one-reason expectation.

## Same-contract controlled-origin fixture

The positive origin case must exercise the production consumer checks. It may not
patch metadata functions, replace `ANCHOR`, copy an origin document or run writer
and reader as one uid.

Use one fixed private test harness from
`scripts/test/scope-qualification.test.sh`. It loads the reviewed physical
`sandbox/v1/host-supervisor.py` from the root-owned fixture package, verifies that
file and package before and after use, and calls only its real
`check_store_root`, `create_attempt_dir`, `write_payload` and
`write_receipt_file` functions. It has no public command, launch path, VM call,
callback or substitute storage predicate. The writer subprocess runs as the
dedicated non-root writer and supplies the exact canonical stdout, stderr,
evidence manifest, evidence file and synthetic completed receipt built by the
fixed fixture. These run facts prove this storage and consumer contract only;
they do not claim a VM launch or native environment qualification.

The harness calls `check_store_root` first and retains its returned store fd. It
then calls `create_attempt_dir` exactly once, `write_payload` once, and
`write_receipt_file` last. The real functions perform exclusive creation,
`fchown`, `fchmod`, per-file and per-directory `fsync`, fixed inventory writes and
the final store-root `fsync`. Because `write_receipt_file` closes `attempt_fd`,
the harness transfers that fd's ownership before the call and never closes or
uses it again; it closes the retained `store_fd` exactly once in all exits. The
consumer starts only after the writer has exited and the parent has rechecked the
closed attempt. A sibling attempt completed before acquisition may change only
the fresh store-directory metadata; the consumer must still reread the old
immutable attempt successfully when all current checks pass. A sibling creation
started after acquisition begins mutates the held store during use and must make
the read refuse as stale.

On an ordinary disposable Linux CI runner, the existing test job may use its
already available noninteractive sudo to create one unique writer account, one
distinct consumer account and one consumer group for this test. It first refuses
if the fixed anchor exists. Root creates the anchor, reviewed package,
configuration, fixture registry/accepted bytes and unique store/work roots with
the production ownership and modes. The writer belongs to the consumer group;
the consumer remains a different uid with read-only group access. Cleanup is
trap-owned, removes only the unique fixture identities and paths, and fails the
test if any account, group or object remains. No workflow edit or new CI
permission is required.

Run the real scope evaluator as the consumer account. The bundle and actual bare
Git snapshot live outside the controlled store. Assert actual uid/gid, mode,
platform ACL, link, no-follow, held-descriptor, fresh-origin and `check-bound`
success. Then prove the consumer cannot create, replace, rename, chmod, link or
remove a store object. No production anchor may be overwritten.

Use the same setup for paired negatives: caller-created store copy, same bytes
under the wrong owner or store id, writer/consumer uid collapse, missing group,
extra ACL grant, symlink/hardlink, metadata swap, changed receipt/payload and
anchor/package drift. Pair a successful reread after a sibling attempt completed
before acquisition with a refused sibling mutation during acquisition. In both
cases keep the old attempt's raw bytes and original receipt `terminated_at`
unchanged; the reread never refreshes qualification age. On macOS include a
supplementary-group-only positive and the existing UUID-qualified ACL checks.
Record actual `id`, filesystem metadata
and ACL command output with the test evidence. Fixture native-qualified entries
prove only this closed consumer path; they never claim CPU/wall proof, VM
qualification or a production identity.

Prepare the same fixed harness and cases for macOS, including the concrete Darwin
runner owner above. Run them only on a verified disposable evidence host whose
owner has separately authorized noninteractive root setup, account/group lifecycle
and the fixed anchor. This plan does not authorize the current development Mac,
create that environment, install a runtime, add a user/group, write the anchor or
change host permissions. Reuse only an already available physical runtime and
dependency closure; do not download or install one. Until such a host and authority
are verified, keep the macOS real-principal positive and G3 blocked while ordinary
code and tests may be prepared. Do not replace either platform's proof with mocks,
same-uid files, copied origin, permanent refusal or a skipped positive.

## Proof and completion

Add focused cases for every spec R6 item. Besides the real fixture above, cover:

- all three forms; exact inventories; missing/extra/early marker; swapped bundle
  directories; copied origin; fixed-package drift; stale descriptors; wrong
  attempt, candidate, environment, policy, payload, store and checker bytes;
- readable noneligible legacy rows at another revision and identity; unchanged
  reporting order and refs; attempts to count, authenticate through, or derive Git
  facts from such a row refuse without dropping or rewriting it;
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
- a real fixed-owner control in which the initial observation is READY, the
  subsequent full SEAL recheck performs another actual Darwin UUID resolution,
  and the terminal ledger contains that row exactly once after the original
  command prefix. Keep every descriptor held through this check and prove the
  original non-command observation bytes and original jq result do not change;
- refusal before publication for missing, partial, duplicate, reordered or
  trailing READY/SEAL/COMMIT frames; noncanonical size/digest text, wrong committed
  size or digest, EOF, cancel, timeout, nonzero exit and reap
  failure; absent, noncanonical, truncated, replaced or oversized terminal
  bytes; wrong observation digest or id; removed/reordered/changed prefix rows;
  malformed, duplicate or extra command fields; 4,097 rows; a late command after
  closure; and terminal or held-object mutation through use. Pair the caps with
  exact-limit successes, preserve the first failure, and prove no result bytes
  appear before terminal validation and successful reader exit;
- use the existing fixed test-only frontend-copy synchronization technique to
  pause after the reader exits but before the driver's first terminal open. In
  separate controls, replace the real committed terminal with canonical bytes
  that delete the genuine late UUID suffix or substitute a different shape-valid
  suffix. Both must fail the control-frame digest before publication; retain the
  unchanged genuine late-UUID positive beside them. Add no production pause,
  callback or environment switch;
- the complete existing 149-check shadow-enforced suite proving the shared Darwin
  owner keeps fixed UUID/group argv, original ledger entries, bounds, timeout,
  cancellation, signal cleanup and unique reap, with every other driver role
  unchanged. Its rows/recipe fixture executes the actual owner and actual adapter:
  it captures the fixed tuple at the test-only native State prepare boundary and
  supplies `_NativeChildResult`, stdout and stderr only at the private
  `_communicate_native` boundary. Preserve every prior success and refusal
  assertion, including malformed, missing, reordered, duplicate, extra, trailing,
  oversize, empty, count, 128-row, group, member and nonmember cases. Restore the
  native owner and transport before the real Darwin and cancellation cases;
- the existing self-host compatibility harness with its empty legacy bundle root,
  four unmodified real pre/post record commit ids, a genuine locally created bare
  object database with no historical-object lookup, nine arguments, both
  intentional refusal reasons, both rows reported but noncontributing, and
  unchanged identity, relation, qualification and inactive-output assertions.

Preserve existing byte-for-byte outputs where the new authenticity requirement
does not intentionally change the result. Update docs with the exact nine-argument
input contract after `evaluate`, the digest-directory layout, deterministic missing
reason, inactive status and #544 boundary. Restore instructions list the new reader
and do not describe fixture setup as installation or activation.

On the final implementation head, run and retain complete output for:

```sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/shadow-enforced.test.sh
bash scripts/test/shadow-self-host-evidence.test.sh
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
