---
spec-blob: e161301045491f5f41d2fb2df0c6ad0a6284f914
drafted: 2026-10-15
---

# Plan: harden scope qualification evidence core

Tracks #541. Risk is high. This is the nonterminal child-6 core. It authenticates
the existing child-5 evidence at one exact revision. Issue #544 remains mandatory
before child 6 completes or child 7 starts.

Implementation PR: `review_size: accepted-exception`, 2,600–13,800 net changed
lines. The private evidence reader, held-path and Git checks, closed evaluator
relations, and a real two-principal origin fixture form one security boundary.
Most of the range is proof: complete classification, bundle, Git, terminal and
authenticated-set controls, plus the same-contract owner, group, ACL, descriptor
and receipt lifecycle. It also covers the complete fixed runtime guard and its
owned native-format controls. It includes final-mode initialization and complete
mode regressions for the five fixed fixture directories. The range preserves
readable controls and does not relax tests, CI, review, or any acceptance standard.

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

Keep the fixed fixture chown/chmod options and `--` before the first owner or mode
operand. Preserve each original program, target, role, recursive extent and
nonzero failure; do not ignore errors or widen the owned paths.

In the assembler's private Darwin tools/python3 creation block, initialize only
that newly and exclusively created symlink to final mode 0744, without following
it, before any consumer use. Use os.chmod with follow_symlinks=False. Keep the
original target, root uid/gid, global umask and Linux behavior unchanged. Creation
failure must not overwrite or chmod an existing leaf. Initialization failure
retains the original nonzero error before probe/consumer launch, without retry
or fallback. Touch no target, P, Versions, Current, ancestor, ACL or other tree;
add no administrator command, public API or diagnostic mechanism. Keep production
realpath and NOFOLLOW checks unchanged.

Freeze and uniquely extract this actual creation/initialization block for owned
022/077 umask controls. Check link type/mode, target text, owner/nlink and unchanged
mask, target bytes and target mode. Retain the old 077 creation block's actual
mode comparison; a 0700 link must fail the final-mode postcondition. Prove existing
leaf refusal without overwrite and separately reach creation and nofollow chmod
failures, preserving the original error and preventing later probe/consumer use.
Label controlled OS seams honestly. Linux must add no nofollow chmod. Same-uid
owned controls prove construction only; the original full Mac must still prove
this path with its real different-uid consumer and complete restoration. Include
all old and new ordinary raw output under the original 16 MiB cap; do not truncate
evidence, remove controls or relax cleanup to fit it.

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
runner owner above. Run them only on the verified disposable evidence host under
[the approved temporary supply](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6180555883)
and [existing-parent supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6189713897),
with the [approved 3.15 supplement and accepted source review](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6203606687)
and [fixed Versions-mode approval](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6205434290).
Bind that supply to these accepted `work/scope-genuine-macos-proof/` artifacts:

| Artifact | Git blob |
| --- | --- |
| Intent | `336c520dcdc7dacb6bbf3b52d34ab07f12b50f0d` |
| Spec | `d17c985b9651ff46c259997fb54d8fc214293357` |
| High-risk plan | `035d20d9bf2dbce30efadcb0f8d0d72691a696ef` |

Use the workflow published at `5b4acf99e77ce7dd68db6a2607f683a6f99ca68e`,
from reviewed head `fbb46bcfa7437f1b364e054d83dddf50f45d6cb4` against base
`aff1175d4cd7831a64421d29811ced02d978a1b3`. Actual supply and cleanup across
separate job-step processes still require complete Mac job evidence. When mode
preparation is used, this includes durable journal reopening and verified mode
restoration. Same-process controls or a green cleanup step cannot replace that
proof. The workflow Git
blob is `e4a856ae71942e34b76568000428dc3b6f5af0a6`; its SHA-256 is
`ee8d312b1f36fab443d02adf960b1ad9f7fbedc7bb123b902eb1451d6c6cecaf`.
The complete shared entry/guard body SHA-256 is
`3c229ffd250d8b255ae59ae1f507e3815c9f6bfb25b793c9075871675a1a540c`.
The separate post-guard identity assertion passed through `-c` has SHA-256
`e11560926ec9ab0188cd448a723a9c2eee5bef4064cc3445d7a25cd5e4377229`.
The published provision body SHA-256 is
`625a0e3e21588c90a921c003032501b6780b5ee9ac4cb29e463f1cea6232a053`;
only the workflow supplies and cleans the runtime. The same-PID transition belongs
to the shared guard. Keep these exact bytes; a changed dependency returns through
its artifact gate before fixture changes.

| Fixed manifest data | SHA-256 |
| --- | --- |
| Complete official source | `e0d204e2827885c5f2f4278e709981b7fc1e02424d3bfa5ae2ff2af789789d26` |
| Selected version subset | `3176a7d3551aaa719fa8ed26964237d0d1771184c6ce7a5159bbf039e7816572` |
| Supply mode map | `9184f6976c2be2e1430594adbb406293168c0201c849e31bfd671f2c8e83fb9e` |
| Runtime expectation table | `d6a212cf50fd2593c75e8e011c321e65fa8609cce7add72e69d16ff0e78252c4` |

Use the accepted Mac plan's fixed ASCII compact JSON, sorted keys and no final
newline for the shared guard's selected, supply and runtime-table checks. Keep
all fixed hashes, row selection, fields, order and counts unchanged. Preserve
product canonical encoding and its ledger/closure uses; do not strip bytes to
force a digest match.

The workflow supplies only official Python 3.15.0 and jq 1.6 in the initially
absent `Versions/3.15` and `ystack-private-tools` trees under the existing
`/Library/Frameworks/Python.framework`. The existing-parent supplement SHA-256 is
`d811e67bf53b8bcbd0417d5db686c297adbe325c47de3ab048d92bdfeead4880`;
the fixed 3.15 supplement is
`6cbb39e4a5bcc391913e98de09bc95dac7a78e4c7585424777bd149dfdf0fca8`.
The fixed Versions-mode supplement is
`399d3a10cac7add2bf2e77da613235fac353e7f9473f1d3cdbdff303ad9afa93`.
The fixed package is `https://www.python.org/ftp/python/3.15.0/python-3.15.0-macos11.pkg`,
exactly 89,032,014 bytes. Its SHA-256 is
`7c7e7eca61cbfa5f0c6f80cd594cddbfd492f4e8b3fb87e3d9fa1efebaec43ed`;
the decompressed TOC SHA-256 is
`72a73d8e5b05959f062df93f21e5829a5aac4526c833dd24cba4941462a29924`.
Keep the published workflow's complete signature/content verification and its
basic-trust/pkgSign limitations. Do not fetch or execute package scripts here.
Core test files do not fetch, supply, repair or clean those trees or their existing
parents. They add no development-Mac, runtime, host or account scope. Keep Linux's
original runtime behavior.

In the Darwin branches of `scope-qualification.test.sh` and
`shadow-enforced.test.sh`, bind P only to
`/Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python`.
Its image SHA-256 is
`23a6212221922087dafd5a0e59631efa00b75b5f2e47945ba404c67be2c54c0b`.
Bind the prefix separately to `/Library/Frameworks/Python.framework/Versions/3.15`
and jq to `/Library/Frameworks/Python.framework/ystack-private-tools/jq`.
Replace the old bin/name-derived layout only at these fixed test boundaries.
Scope's outer evaluator and genuine setup, and the native suite, use the same P.
Add no path override, environment trust flag, alternate runtime or product API.

Keep one literal entry/guard body in a fixed heredoc in
`scope-qualification.test.sh`. The native suite reads only that body from its
fixed physical package path `scripts/test/scope-qualification.test.sh`. Use the
existing non-privileged system Python and held NOFOLLOW reader with its current
16-MiB source-byte cap. Require one exact opening heredoc line and one exact
closing `PY_MAC_FIXED_RUNTIME_GUARD` line.
Retain the read bytes and recheck the source identity. Verify the extracted body
against the fixed guard SHA-256 before writing an exclusive private guard file.
Do not source the shell file, execute the scope suite, evaluate other source text,
add an auth-only mode or accept a caller-selected path or command.

During exact-head source preparation and before publication, mechanically compare
the scope literal, native extraction and pinned workflow body byte for byte. Each suite runs that same body through its own
actual empty-to-real authentication. Keep the complete failure diagnostics,
predicates, cleanup and shared deadline unchanged. Use only the fixed source
manifest from the workflow's existing owned cache. Treat that cache path as a
locator. Retain bounded bytes, verify the fixed manifest digest, and place them
beside each test's private guard. Missing or changed bytes refuse. Core tests must
not fetch them or accept a caller's replacement manifest.

Invoke each guard through the existing non-privileged system Python as:

```text
/usr/bin/python3 -I -S -B GUARD PACKAGE P GUARD empty 0 0
```

Here GUARD is that test's owned exact guard file and PACKAGE is its held physical
package. Verify the complete 4,502-row source: 3,934 regular files, 529 directories
and 39 links, including each row's UID/GID/nlink and fixed content or link text.
The exact version subset has 4,496 rows: the same regular files, 527 directories
and 35 links. Add only the two fixed tool rows. Authenticate all 4,498 objects;
do not scan old versions into the runtime set or ignore extra new-tree objects.
Hold the existing framework root, Versions and every physical ancestor with
NOFOLLOW directory descriptors, exact named identity, UID 0, modes without group
or other write bits, and actual empty ACLs. Authenticate the supplied runtime with
its original regular/nlink, identity, ownership, mode, byte and ACL checks.

Accept only the 35 fixed new links. Authenticate each used step and its held
physical parent before inspecting its canonical target within the new version.
Preserve publisher bytes and link text. Old versions, top-level Current and root
aliases remain unchanged and provide no runtime dependency or cleanup authority.
Missing required targets, loops, escapes, changes and unknown ACLs refuse. Keep
all original scans, the native-image closure and system-cache boundary, and every
byte, object, command and shared deadline cap. The fixed closure contains 91
loadable x86_64 images: 90 also contain ARM64 and one is x86_64-only. They comprise
3 executables, 10 dylibs and 78 bundles, with 17 internal V3.15 edges, 117 system
library edges and 3 `/usr/lib/dyld` edges. Execution remains x86_64 only.

The guard treats only these exact prefix-relative files as static data:

| File | Whole-file SHA-256 | Required bounded structure |
| --- | --- | --- |
| `Frameworks/Tcl.framework/Versions/9.0/libtclstub.a` | `74fd3db0166b27cbe6aeaa4ef642a2bcca7e68d2fec4c05467bf5c04978d0670` | x86_64/ARM64 fat archives; two symbol indexes and ten MH_OBJECT members total |
| `Frameworks/Tk.framework/Versions/9.0/libtkstub.a` | `c8fac1a39815dbe3ce300961ca125a196363354f0290ff21be65e7592349e935` | x86_64/ARM64 fat archives; two symbol indexes and four MH_OBJECT members total |
| `lib/python3.15/config-3.15-darwin/python.o` | `8c1ab81c7a71dbc98218a6ddf230353b2fcb73e51fdc3a0c9ec050ed461f7e21` | x86_64/ARM64 fat LLVM wrappers with bounded bitcode payloads |

Require the published guard's exact path/hash, magic, slice, member and wrapper
checks. These data objects grant no load or execution permission. Unknown or
malformed native containers and static data offered as a loaded image refuse;
no filename suffix can bypass classification.

The same guard enters P with `-I -S -B` and retains its PID and 120-second deadline.
Use the published guard's fixed private `CLOCK_UPTIME_RAW` clock across both
stages without renewing that budget. At its sole owner boundary, require the
authenticated P's fixed same-source seconds, rate and sleep contract, monotonic
non-adjustable provider and finite readings. Read local monotonic `m` before raw
`u`; pass `m + (deadline - u)` only with finite positive remaining time within
the original bound and a finite result. Keep raw expiry checks before and after
owner use. Keep the consumer's local-monotonic API and code unchanged for this
binding.
Require actual physical `sys.executable == P`, version 3.15.0 and at least 3.11,
fixed prefix/base_prefix, isolated flags and the original closed startup paths.
Never assign sys.executable or inject __PYVENV_LAUNCHER__. Under authenticated P,
use the existing real Darwin owner and UUID resolver. Repeat all original runtime,
module, stdlib/include and loaded-image checks. Scope repeats this complete guard
before its first privileged P execution. Keep the genuine principal, store, Git,
ledger and account/anchor cleanup behavior and all original refusal cases.

Use one private `fixed_stdin_module_paths` prelude in the scope fixture for both
fixed stdin calls, `PY_MAC_RUNTIME` and `PY_MAC_IMPORT_CLOSURE`. Compose that one
literal with each call's own fixed body; do not copy the classifier, import a
helper module or execute it in a separate namespace. Keep both real `-I -S -B -`
invocations and their existing data arguments. Composition or transmission failure
retains the original nonzero exit and child lifecycle. Each process first imports
builtin sys and binds its executing `__main__` object and namespace to
`sys.modules['__main__']`, before other imports. Require
name `__main__`, file `<stdin>`, spec None, argv[0] `-` and effective `-I -S -B`
flags. After imports and before use, recheck that same object, namespace identity,
mapping and attributes; reject any other module key aliasing that object. Exclude
only this bound entry object. Keep runtime's P and jq as explicit candidates;
keep the import-closure body's actual fixed reader import and `_cancel_release`
absence check. Every other nonempty module file retains the original physical,
absolute, regular-file, lstat, UID/mode, ancestor and symlink checks. Pseudo-paths
on other modules, wrong startup or entry rebinding refuse. Do not filter by path
text or existence, normalize a bad path into acceptance or add a general resolver
or caller-selected source. Keep the native fixture's file entry, workflow, shared
guard, identity entry and provision unchanged.

Use the fixed jq bytes with the original SHA-256 and actual jq-1.6 version checks.
A private test copy may retain the existing owned-cache behavior and cleanup. It
must originate from the authenticated fixed jq. No Darwin downloader or fallback
may run. Neither test changes or removes the workflow-owned supply trees or
modifies their existing parents.

Require all 13 native-reader controls with actual owned files: valid extraction;
missing and duplicate opening markers; missing and duplicate closing markers;
wrong guard bytes; oversized, changed held and symlink sources; valid, wrong and
missing manifests; and exclusive guard creation that refuses overwrite.
Require all four scope manifest-reader controls on actual owned files: valid
manifest, wrong manifest, missing manifest and wrong guard. Use the exact reader
boundaries and record each result and descriptor cleanup. Every refusal occurs
before P execution. These controls do not replace either suite's actual
empty-to-real authentication or prove Mac host qualification.

Adapt the existing owned guard and entry controls to this fixed layout. For the
metadata-only controls, create owned empty physical installation and Versions
parents. Copy only the authenticated new version and tool trees into them. Do not
copy or traverse old framework contents. Bind the extracted guard's fixed paths,
including `fixed_tools`, to these owned objects. Keep real objects, actual ACL/API
errors, held changes, cancellation and exact reap. Preserve identity, version,
prefix, startup-path and deadline refusals. A metadata-only
extracted-boundary control uses its recorded objects and cannot execute copied
runtime bytes or claim the actual entry positive. The positive requires the real
fixed P and actual same-PID transition on the approved Mac host. Keep all original
37 scope controls, 149 native controls and both complete suites. These bindings do
not qualify a host or change the product installation boundary. Adapt the owned
native-format controls to the new fixed containers and pair valid data with
unknown, malformed and loaded-static refusals. Preserve the approved fixture
`/usr/bin/cc` helper/native builds; add no compiler, SDK, runtime rebuilding,
source download or administrator authority. Do not replace unrelated historical
fixture facts or Linux runtime selection.

Keep the Mac guard wrapper's observation private to this scope fixture. Bind its
fixed source lines once. Authenticate the actual guard and consumer code objects,
files and callers; select only their required trace events. Preserve real
`_foreground` call/return, identity return and the final identity exception,
including actual child reap and pipe-close evidence. Do not disable observation,
cache a safety scan, alter the shared guard or query a failed object.

Only `observer_source.watched` and the Mac `wrapper_prefix.bound` classifier may
reuse their original code-authentication result within one trace session. Keep
`source_codes` and `bound_codes` fixed after their original authenticated source
reads and compilation. Every new actual code object first undergoes the original
filename and structural CodeType-set test. Structurally equal distinct objects
remain eligible under that test; same-name unequal or inequivalent replaced code
keeps its original refusal. Identity is only a reuse key, never a new permission gate.
Retain a strong code reference with each cached classification result to prevent
id reuse. Discard all entries when that session ends. Positive entries and negative
eligibility markers share the same 512-entry limit per classifier. Add no public
selector or reusable cache API.

Reuse a classification result only after bounded confirmation of an exact built-in
immutable constant graph: scalar constants, tuples, frozensets and nested code.
Inspect at most 1,024 nodes, 32 nesting levels and 64 KiB of scalar/code payload
per qualification;
do not invoke custom hash/equality to decide qualification. On a cache miss,
mutable or custom values, an uncertain or over-limit graph, a full cache or
reentrant incomplete qualification keep the original classification on every
call. Qualification only decides whether to retain the original result; it adds
no refusal or acceptance.

Only exact native CodeType objects may have a negative eligibility marker. Mark
only after a source filename matched, the original set test returned, and bounded
qualification returned ineligible normally. Key by id; retain only a weakref.ref
with no callback, and require ref() is code on each hit. Never hash the weak
reference or use custom hash/eq for marker identity. Retain no strong reference to
an unqualified constant graph. Every negative hit still performs the original
filename and structural set tests, with their short circuit, busy/reentry boundary,
result, exception and custom hash/eq effects. Skip only the repeated qualification
walk. A later mutable-graph change may lose an optimization opportunity, never an
original classification. Dead or mismatched references, unavailable or failed
weak-reference creation, full shared capacity, reentry and qualification exceptions
keep the original path. Marker failures cannot change its result or exception.
Clear markers with the session; cache no exception or safety fact.

Never cache exceptions or let qualification failure change the original result
or exception. Keep event selection, order and fields unchanged. Cache no source
read, metadata, ACL, held-path recheck, safety scan, execution or owner state.

Use one private `scope_fixture_owner_cancel` boundary to connect the original
1,800-second alarm and fixture exit to the existing root driver. Keep the same
alarm start. Make Bash's wait interruptible. Bind the cancellation channel before
launch and use the fixed sudo/P entry's stdin, not an assumed preserved high FD
or a new sudo option. Only that owner consumes it. Close every unrelated writer;
EOF or cancellation prevents every later child launch, including between controls.
Distinguish owner never launched, launch attempted without confirmation, active,
and completed. Only a proven never-launched state can omit owner confirmation.

Reuse `run_control` and its existing terminate, wait, kill and pipe-close boundary.
Keep its 145-second total and 15-second closing window; cancellation does not
restart either. Reap the owner's tracked child and its tracked foreground, then
close their pipes before issuing a bounded completion record. Bind that record to
the current authenticated root driver, invocation and held fixture identity.
Require this confirmation and completion of the original launch wait before
teardown deletes any root-fixture or ordinary-tmp object. EOF, Bash wait, a PID or a missing PENDING
file alone proves no quiescence. Missing, stale, malformed or uncertain completion,
unreaped children and pipe-close errors keep PENDING and failure with zero deletion.
Preserve the original failure on confirmed cancellation. Do not discover arbitrary
PIDs, use sudo kill, add a process-manager API or enlarge permissions. The unchanged
workflow still refuses restoration for a negative signal or unknown phase outcome;
fixture confirmation does not override that rule or prove final D/V/T restoration.

Only the original `run_control` calls `unchanged-copied-existing-layout` and
`held-module-identity-change` may add an optional `supervision` field to their
existing report. Keep `end`, the first and last finite values returned by the
original loop deadline-assertion `time.monotonic()` call, original `readiness`,
and a fixed phase. Preserve that call's `not cancelled[0]` short circuit, position,
count, result and exception; do not sample the separate select-timeout or cleanup
clock calls. Phase is `launch` before the original Popen, `loop` before the original
loop owner check, `wait` before the original normal child wait, or `report` before
the original report. Freeze at the first original exception before cleanup, or
at the normal report; cleanup cannot overwrite it. Use only exact builtin finite
floats, the original bool and these enums; absent or invalid fields are GAP.
`end - 145` is a derived supervision start, not child launch time. Loop values
and phase show reached code points, not child liveness or isolated scan cost.
Bound this optional field, including its key and delimiters, to 256 encoded bytes.
Collection, encoding or space failure omits only this field and cannot replace
the original result or exception. Add no report on an original early-exit path,
sink, writer, clock, query, callback, child or invocation. Keep all original fields,
stdout/stderr and first-error ordering, the 65,536-byte child-output cap and the
16 MiB ordinary raw cap. Guard bytes, safety reads, all local/global deadlines,
reap, pipes, PENDING, cleanup and restoration stay unchanged.

Within this private boundary, use one zero-payload `.ready-complete` leaf at the
same fixed owner stem. Refuse an existing ready or completion leaf, including a
symlink, before launch. Only the authenticated current owner may create the
completion leaf, after the original ready write, mode 0444, file fsync, close and
parent fsync all succeed. Create it with O_CREAT|O_EXCL|O_NOFOLLOW and mode 0400.
Keep the inherited umask unchanged: 022 and 077 both yield 0400. Reject any other
resulting mode; do not repair it. Creation publishes the entire empty signal;
never write it or change its mode after it becomes visible. Check it without
following links: a root-owned regular file, one link, size zero and mode 0400.
The unprivileged channel needs only its metadata, not permission to read content.
Bind it to the existing invocation and context; add no generic publisher or path
selector. Within the original ten-second wait, wait for this completion leaf,
then perform the original ready strict snapshot and payload/context check once.
Keep every identity field, including ctime. Do not retry a bad snapshot, add a
settling sleep or extend a deadline. Ready publication or validation errors keep
the original nonzero result. Completion proves neither owner exit nor receipt,
quiescence or deletion permission. Keep the original Bash state, wait, receipt
and cleanup rules; only their independent confirmation may permit cleanup.
PENDING or unknown owner completion still permits zero deletion.

For supervision facts, extract the actual old/new `run_control` boundary in the
existing owned controls. Compare clock calls, order, returned values and original
exception identity, child creation/terminate/wait/kill and pipe-close effects.
Cover normal completion, early cancellation, no loop entry, cancellation before
and after readiness, the original clock exception, nonfinite/missing values and
encoding/cap failure. Prove the short circuit adds no clock call, first-error
facts survive cleanup, other labels gain no field, and no original early failure
gains a report. Keep all prior controls; ordinary seams do not prove kernel
closure or the actual Mac cause. Measure complete raw bytes before source review.

At the existing `completed_evidence` boundary, retain wrapper/channel source
sharing. Owner-control drivers may also share only their uniquely extracted,
byte-identical contiguous `run_control` source span within this execution. Emit
its complete bytes and bound length/digest before any reference. Retain each
driver's full prefix, suffix, span position and complete-source SHA; reconstruct
its exact bytes and verify that SHA against the already-held pre-execution source
before each case. Keep the complete frozen generated files and executed sources.
Different spans need their own full preceding payload or remain full; do not
normalize text or assume entire drivers match. Missing, forward or wrong references
cannot replace full evidence. Reuse the existing private payload/reference format,
not a new cache or source framework. Add no source read or runtime change.
Prove full-before-reference order, exact reconstruction, differing drivers and
spans, wrong/missing references and unchanged execution bytes/calls. Keep every
other payload and control; measure the complete new raw under the same cap.

The same boundary may share only the byte-identical selector_setup span in the
existing genuine_relation_preexec.reader_source and launch_capture_preexec.reader_copy
reports within this execution. Require one unique contiguous occurrence in each
actual generated reader; never share different complete readers. Use only existing
capture.selector_insertion and capture.copies values. Emit the complete span
payload before any existing canonical five-field reference. Keep every report's
other fields, binding, full prefix/suffix, byte offset/span length and complete
source length/SHA. Reconstruct the exact source; keep its full frozen generated
file, original source inverse, and actual execution bytes/calls unchanged. Preserve
fully recoverable actual source before the original execution and related assertions.
Different spans need their own full preceding payload or remain full. Missing,
wrong or forward references, non-unique spans, or wrong prefix/suffix/offset/length/
SHA must reject reuse or retain full evidence. Normalize nothing. Prove every
actual reader's exact reconstruction and binding, direct rejection cases, complete
canonical full-before-reference order and indices. Retain the original six shared
objects and 26 generated-source inverse checks and all other controls. Add no
source read, query, OS/runtime/process/interface or trust root. This changes only
report expression; no generic diff, compression, cache, logging framework or
cross-run sharing. Measure the complete new batch's recursive raw under the same
16 MiB cap; a projection cannot establish PASS or remove an earlier volume failure.

In existing CI, compare old and new observers on real owned calls and events.
Cover identity refusal, real foreground return/reap, direct-callee stat/bool/errno,
exceptions and early GAP. Compare event order and field meaning while retaining
actual varying identities and times; do not hand-fill identity. Check wrong code
objects, same-name callers, one-time source-line binding and required local events.
Before source publication or another full Mac run, require a complete readable
private candidate and its actual 14-path size. Run the real extracted old and new
classifiers in both boundaries on the same owned call sequences. Preserve event
order, fields, refusals and frame-local GAP, including nonwatched direct-callee
stat/bool/errno, identity and foreground return/reap/pipe events. Cover structurally
equal new code objects, same-name unequal code and inequivalent replace/rebind,
mutable/custom
hash/eq constants, uncached exceptions, capacity saturation and reentrancy.
For negative markers, also cover live/dead references, identity mismatch,
unavailable/failed weak-reference creation and shared positive/negative capacity.
Use the exact full guard code graph and real oversized graphs as inert code data
in the existing ordinary boundaries; do not execute guard/runtime bytes. Reuse the
two classifiers, four observer cases and actual wrapper sequence. Compare complete
results, events, fields, GAP, custom effects, foreground/reap/pipes and exceptions.
Record actual callback counts, classification requests, original structural tests,
qualification entries/visited nodes and new-object counts. Keep the existing
positive-cache authentication reduction proof. Require equivalent observations
and useful reduction of repeated qualification; each negative hit must still make
its original membership tests. Record whole ordinary-call wall time for the same
work sequence, without artificial heating. Add no per-event
timing, evaluator/reader call, runtime, sudo or diagnostic CI. If equivalence,
counts or measured work show no useful reduction, stop the candidate before full
execution. These results do not promise completion within the Mac deadline.
After this gate, require fresh independent exact-byte source preparation, then
the original same-final-head Mac/Linux proof and separate G3. Run the exact
private cancellation boundary with a fixed test-only short
alarm and real owned children. Cover never-started and starting owners, normal
completion, cancellation between and during calls, EOF and completion races,
missing/wrong confirmation, unreaped children and close errors. Prove no new launch
and cancel/reap/close/confirm/wait before delete. After any attempted launch,
missing confirmation permits zero deletions. These controls add no production
selector, runtime, sudo or diagnostic job. In the original complete Mac suite,
also prove the real Bash → fixed sudo/P → root driver → reduced-privilege child
and foreground cancellation, reap and confirmation chain. Use a fixed short
cancellation case at the existing controlled-fixture entry, with no additional
administrator command or general selector. Ordinary owned controls cannot replace
this root-chain proof or normal full-suite restoration. Preserve actual alarm
failures and the original 300/1,800/120-second limits.

Use the actual extracted ready publisher, channel and fixed call site in owned
controls. Pause deterministically after ready creation but before completion;
prove the reader has not entered its payload snapshot. Release the same writer
and require one strict snapshot of the fully published ready. Cover ready write,
mode, file fsync, close, parent fsync and completion creation failures; missing,
stale, wrong-invocation, wrong-owner/type/mode, linked or nonempty completion;
and post-completion ready drift. No failed preparation or check may reach the
alarm sender. Keep the original 022/077 umask controls without changing umask.
Do not add production synchronization hooks or weaken an earlier check to reach
a later branch. Preserve the real normal/cancel/alarm chain, its original signal
status, wait/reap/pipes/receipt proof and unknown-state zero-deletion controls.
Only `PY_GUARD_CONTROLS`, `PY_FIXTURE_OWNER_CHANNEL` and their necessary ordinary
controls may change for this readiness boundary. Keep the four capture restrictions, classifiers,
shared guard, entry and product consumer unchanged by it. Run the complete owner,
21 layout and 17 same-call controls and static gates; measure the complete output
against the original 16 MiB cap. Retain fresh exact-byte source preparation and
the original same-final-head Mac/Linux, root-chain, restoration and G3 proof.

Bind both complete composed scope stdin bodies in existing CI by bounded
extraction, each body's digest and prelude-before-body order. For each body, run
its exact extracted stdin classification and physical-file boundary in a trusted
real `-I -S -B -` process. Reuse one control template; verify both fixed callers
use the single prelude and retain their own imports and assertions. One
classifier-only run cannot replace either entry's boundary controls. Show that
the old collection includes its real entry and refuses, while the shared
classification excludes only that entry and retains all real imported files.
Reject another module's pseudo-path, wrong name, file, spec, argv or effective
flags, entry aliases, object/mapping/namespace rebinding, and relative, missing,
changed or unsafe real files. Use only an explicit owned-file UID/mode fact
adapter; do not fabricate a positive main object, execute the supplied P or sudo,
or add a diagnostic job. Keep nonzero failures and bounded child reap. These
owned-data boundary controls do not execute the privileged complete bodies;
actual P/jq and fixed-package reader-import positives still require the original
complete Mac suites and same-final-head Linux proof.

Until actual supply, host checks, complete tests and cleanup pass, keep the Mac
real-principal positive and G3 blocked. Keep CPU/wall evidence NONE and production
identities empty. Preserve every prior failure. Do not replace either platform's
proof with mocks, same-uid files, copied origin, permanent refusal or a skipped
positive.

## Fixed one-shot Git reference

Use one temporary private `scope_first_git_reference` test boundary in
`scope-qualification.test.sh`. Its fixed source entry replaces only that head's
suite dispatch. Retain the complete original suite text and assertions. Add no
argument, environment selector, workflow, product entry or fallback. The initial
one-shot allowance is consumed. Remove its temporary entry before preparing the
fixed worker-path correction below. Permit only one corrective fresh-head
invocation of the existing approved Mac workflow after this amendment is accepted
and merged. Dispatch consumes this allowance even if Git never starts; no further
retry is allowed. This reference head cannot be merged or accepted as complete
scope/Mac proof.
Do not run the original first-config foreground before or after the reference.
Ordinary enablement controls are separate from this real reference invocation.

Reuse the original fixed runtime authentication, fresh fixture/package setup,
consumer role and cleanup. Require the original consumer UID 56001, authenticated
physical P3.15 and fixed Git; refuse an identity mismatch instead of selecting
another role or runtime. Prepare only the needed fixed setup through its existing
commands and roles. Preserve every invoked safety check. Bind the new owned config
bytes, modes, paths, source and environment before launch; do not reuse an old
failed tree or claim that new path bytes match an earlier run. Retain the original
nine-argument first-config shape and exact reader environment contract. Root-owned
fixture preparation is not a second consumer reference or a comparison arm.

Bind the reference worker's existing `name` scalar to `str(Path(sys.argv[0]))`.
This is the fixed root-generated `program = fixture / 'guard.py'` wrapper that
launched the worker, not the runner-private `guard_file` or a shared-guard copy.
Keep the original arguments, lstat count and identity comparison. Freeze and
verify the actual wrapper source, path and worker binding under the existing
checks. Do not change roles, permissions, the shared guard or its entry source.

Run exactly one consumer Git through standard `subprocess.Popen` and
`communicate`, with empty input, three PIPEs, `close_fds=True` and
`start_new_session=True`. Keep the original 30-second execution limit. Do not call
product `_foreground`, `communicate_bounded`, a native collector or an evaluator
for this reference. Standard communicate is a test capture method, not the
product's incremental output cap or an independent kernel implementation. Use
only the controlled small config. Save its complete stdout/stderr and existing
call, error and closure evidence before result assertions. Require the original
1 MiB stdout, 65,536-byte stderr, owner-output and ordinary-raw limits together;
no success may discard, filter or truncate evidence to fit them. Add no collector.
The product's online limits and success predicates do not change.

Reuse `scope_fixture_owner_launch`, its authenticated stdin cancellation channel,
`ScopeFixtureOwnerCancel` and the fixed `run_control` supervision boundary. Use
one closed reference case for the fixed consumer, not a caller-selected program
or UID. Keep the original 145-second owner deadline and its 15-second closing
window. Admit launch only with the required execution and closing time remaining
and no cancellation; never reset the outer alarm or extend any deadline. The
reference worker uses the existing cancellation-to-unwind behavior. In its
finally path call the unchanged `enforced-reproduction.stop_child` once on the
actual owned Git Popen. Reserve that helper's existing ten-second bound inside
the original closing allowance. It sends only its original TERM/KILL to that
owned group and proves group disappearance and direct-child wait. Do not swallow
PermissionError, retry cleanup or use the failed product foreground to reclaim it.

Bind the reference completion to this actual Popen, its group disappearance,
original wait result and three closed pipes, plus the authenticated current root
driver, invocation and fixture. Extend only this fixed case's existing completion
validation; an empty `foreground_calls` list is not reference proof. The root
owner must also reap its worker, close its pipes and complete the original Bash
wait/confirmation before any fixture or tmp deletion. Cancellation, uncertain
launch, missing/stale proof, surviving group, failed wait or close keeps PENDING
and zero deletion under the original rules. A partial record, cached returncode
or marker alone grants no cleanup authority. Preserve the first error, signal and
workflow restoration refusal. Prove this integration before the real reference;
if it cannot close within these existing boundaries, do not dispatch it.

On a successful reference and confirmed ordinary fixture cleanup, print
`REFERENCE_ONLY` and exit zero from the scope phase. Emit no 37-check PASS marker
and do not continue the original genuine case. Failure or unknown state remains
nonzero/PENDING. The unchanged workflow may then run its original native suite;
even a green job is not complete scope/Mac acceptance. Preserve the real workflow
cleanup result separately; reference closure does not prove D/V/T restoration.
After this corrective invocation reaches a terminal state and its original
evidence is sealed, remove the temporary entry in a normal new commit.
No complete scope/Mac proof or G3 may start while it remains.
Preserve the old red evidence and all original tests.
A reference result is a cross-run fact with cold-start and host state limits,
not a root-cause verdict or a product fix. Final acceptance still requires the
original complete Mac then same-head Linux, restoration and G3.

Before dispatch, freeze the full generated reference source and bindings. Reuse
one actual extracted owned-control lane with real short-lived children. In its
existing positive, replace the unused `guard_path.write_text` with an assertion
that this fresh owned path is absent. The worker must use the existing wrapper
and complete the original receipt chain without an extra invocation or mocked
lstat. This checks path selection, not cross-UID access. Prove
exact command/environment/input and one invocation, normal complete raw capture,
nonzero/stderr refusal, timeout and cancellation, actual stop_child group reap,
wait and all pipe closes. Cover launch failure, TERM/KILL failure, surviving group,
wrong/missing completion and output overflow; no unknown case may delete data or
continue the suite. Keep controlled failure seams explicit. Prove the fixed root
owner receipt binds the reference child, rejects the empty original foreground
proof and preserves the first failure. Ordinary same-UID controls do not prove the
real Mac consumer or root chain. Preserve every existing ordinary/owner control,
source inverse and safety proof. Measure the complete recursive new raw batch
against 16 MiB. Complete fresh local proof, fresh independent source preparation
and required CI before dispatching the corrective reference at that exact head.
Do not hide source, remove controls or compress evidence to fit. This exception
adds no identity/select observer, runtime, source download, administrator command,
permission, further retry allowance or product behavior. Its removal does not
retire any original UNKNOWN finding or relax the final proof.

## Private Linux fixture failure observation

Limit the diagnostic change to `scope-qualification.test.sh` at its existing
`PY_STALE_PREPARE`, private frontend-copy and `evaluation_reasons` failure boundary.
Keep the original eight protected slots, calls, glob order and bindings unchanged.
Use one precreated slot 8 for the other existing calls through `evaluation_reasons`,
with fixed identity `evaluation-reasons`; reuse the four bodies bound below.
There are at most nine slots. Do not add a case registry, selection option or new
call site. Keep direct evaluator calls, expected-error calls and genuine fixtures
outside this nine-slot boundary. Only the first genuine call has the separate
fixed failure capture below. Preserve all 78 expanded `expect_reasons` calls from the
51 source call sites, their nine data arguments, order, assertions, result,
evaluator stdout/stderr, READY/SEAL/COMMIT and cleanup.
Add no invocation, public mode, product hook, helper path, provider, trust input or
predicate. Keep the original 300/1,800-second limits, with no retry, deadline reset
or TMPDIR relocation. Diagnostic overhead does not increase either time limit.

The diagnostic boundary follows private candidate SHA-256
`f807180c483a689ae6ebb8985fa99f4088836b6280da0d3591481b151fba6850`.
These decoded-body hashes are the observation baseline. Keep the literals
readable and multiline. Only `observer_source` may change for the trace dispatch,
source-line binding, fixed phase facts and the classifier contract above;
the other three bodies remain exact. Cost sampling adds no dispatch optimization;
only the two classifiers above may reuse authenticated code results:

| Embedded body | Decoded-byte SHA-256 |
| --- | --- |
| observer_source | `0c2b1c8c8cb9c662c55e17e134f408693ab4ead8f27357ad6cb2b7bcc0b820eb` |
| frontend_capture | `a21a722a59923fa6ad18f6f6dd26385d46dcd5a3733083f9d7625777d73c4af8` |
| emit_capture | `153556128c04167c2a73d6c91c86b37bd3e1d34eb35fdeea44e865803301afb4` |
| exit_capture | `95bc34214161aa79167d7f33e8cf4980d70177f7771fa5bf30672e8f0e1739ac` |

The candidate binds the unchanged capture contract. Freeze the actual revised
`observer_source` decoded bytes, generated private copies and their bindings at
the implementation's exact head/base. Verify the other three baseline hashes
unchanged and measure the combined fixture digest separately. New independent
source preparation must accept these actual bytes before full execution; retain
the separate implementation G3. Do not reuse the baseline hash for changed bytes
or accept a future digest.

Precreate all nine log, binding, wrapper and line-map slots before held acquisition.
Reuse slot 8 only after the prior synchronous call and its original cleanup finish;
no concurrent writer or unfinished call may share it. Before each use, clear only
its existing owned log/binding through the existing no-follow identity boundary,
then bind index 8, its fixed boundary identity, all seven current document hashes,
fixed source hashes, private frontend bytes and canonical exact argv hash. Keep
indices 0–7 and their exact glob bindings unchanged. Reuse the existing bounded
binding/copy code. Scope the frontend selection to this private call; do not alter
subsequent calls. Missing or failed reset/binding means GAP, never a prior call's
record or binding. Do not create per-call leaves or accumulate success records,
except the two fixed, bounded cost samples below.
The four source files remain the evaluator, private reader, `_consumer.py` and
this test. No failed-input metadata query is added; input measurement stays before
that call's held acquisition.
Retain the existing no-follow, bounded-byte and stable-identity reads. Event SHA
is observed data and supplies no approval. Case-binding records stay at most
3,072 bytes; missing, changed, unreadable or oversized data stays GAP.

Only the private frontend copy's original emit_error may capture incoming status,
real caller line/function and existing reader variables in bounded memory. Its
incoming `$?` is the status at emit_error entry, not a claim about the earliest
external command. Preserve the exact copy-to-original line map. The existing EXIT
chain runs the original cleanup exactly once, preserves its entry status, then
appends only to the preauthenticated existing FD19 sink. Close FD19 for the reader
launch. Keep signal_exit unchanged. Early errors, signals, child/subshell paths,
sink errors and transport gaps remain GAP. Do not query failed input metadata.

Prebind the Linux observer's fixed source lines once. Authenticate its actual
code objects, files and callers and select only needed events. Apply only the
session-local classification reuse above; keep source authentication complete.
Keep watched recheck line events and real direct-callee return/exception events,
including callees outside watched files. Preserve component tracking and actual stat, bool,
errno and identity returns. A watched-file filter alone is insufficient. This
changes trace dispatch, not safety reads, capture fields, predicates or output.

The existing HeldPath observer may serialize only original same-call return,
exception and errno events and values already present in the original recheck
frame. Keep before/current/named/after/after_named/expected as frame-local data.
Python can retain locals from a previous component. A retained after/after_named,
or another local after an early metadata failure, does not establish the current
component's state. Interpret it with the exact guard line, component index/name
and actual same-call events. Missing values stay GAP. Add no stat, ACL query,
enumeration, object reread, variable reset, rule change or held-directory entry
to fill gaps or change the original predicate.

Keep the 12,000-byte reader record, 16,384-byte sinks and combined failure export,
and 512-byte frontend memory record before its bounded exit fields. Preserve the
accepted sink-only identity/size checks and exact output format. At the existing
failure-only export, use the active original protected slot or the current slot-8
binding. Export at most the unchanged combined cap; missing current preparation
exports GAP without reading or presenting a prior invocation's evidence. Preserve
original exit behavior and do not export successes. Check sequential slot reuse,
reset/binding failure, stale-record exclusion, four body hashes, original argv and
call counts with owned data and the original full suite; add no diagnostic CI.
The owned exit-zero control does not prove actual frontend success,
which removes its traps before cleanup. Preserve the prior Mac stat-adapter limits;
they do not prove actual Linux stat, evaluator execution or historical cause.

Actual execution still needs accepted exact-head source preparation and the
original test gate. Require separate independent implementation review of this
boundary. Keep the historical Important finding and exact cause UNKNOWN. A current
success or NO_REPRO cannot close that finding, hide a real failure or turn E_STALE
into success. Preserve all original controls and complete same-head Linux and Mac
proof before the separate core G3.

## Fixed same-call scope evidence

Keep this evidence work inside the existing scope fixture. In the original
terminal `run_case`, export an unexpected result before its original assertion:
public stdout/stderr, the existing private terminal error, and the current reader
and injected frontend byte hashes. For `size-mismatch`, retain original COMMIT
values, actual wait return/status and already-produced reader stderr through the
private frontend-copy boundary. A preset zero is not a completed wait. Missing
stages are GAP. Keep full bounded-input digests, byte counts, bounded prefixes and
truncation flags within one 16,384-byte encoded failure export. Output failure
cannot replace the original failure. Keep the E_RELATION expectation and every
original case. Use the actual extracted COMMIT parser, wait/stderr/EOF admission
and terminal snapshot in owned N/N+1 controls: a real writer sends a legal frame
and exits, real wait and EOF succeed, and a regular N-byte file has its original
digest. N passes; N+1 reaches the original size predicate and exact refusal line.
Do not hand-fill wait, simulate the token or substitute an earlier framing error.

Use one separate private `genuine_relation_capture` boundary for only the first
existing genuine `run(scope_argv)`. Before its held acquisition, prepare the
frontend and reader source copies only at their existing paths in the owned
fixture package. Bind the exact original bytes, fixed insertion sites, complete
copy bytes and original-line maps. Removing only those insertions must restore
both originals byte for byte. Keep source_path, __file__, PACKAGE, reader launch
and every original source, held, ACL and identity check unchanged; authenticate
the actual inserted files, never label them with the original hashes. Touch no
repository source, supplied runtime, old version or Current. Apart from the fixed
probe-program insertion below, change no command or nine data arguments.
After the call and all its reader/writer processes are proved closed, recheck owned identities and restore the original source-copy
bytes before any later call. Unknown closure keeps PENDING; no restoration,
extra administrator command, repeated call or ignored restoration error is allowed.

Within this same capture, retain three existing launch strings: the exact target
argument used when creating tools/python3, python_bin after the original successful
command-v, and the post-realpath python_bin passed at the original reader launch.
Retain the creation argument once; do not query the link or read sys.executable
again for capture. Bind it to this invocation and the actual source/copy digests.
Use fixed insertion sites for the two Bash values. Keep the target, commands,
environment, data arguments and reader launch unchanged. The original realpath
program has only the fixed observation insertion below.
A stage not reached or a missing, unsupported or over-limit value is GAP.
Each value's encoded JSON string is at most 1,024 bytes. Encode paths safely in the
existing binding/records; never interpolate raw values into JSON or shell code.
Use the existing failure writer; add no program invocation for collection, reader
probe, filesystem query or new sink. These values are observations, not authority
or proof that a path is physical. Keep the same record and export caps below.

In this one original probe, retain sys.executable at its existing read and call
os.path.realpath once with its original argument and options. Bind the original
lstat/readlink functions before that call. Each original primitive invocation
must delegate exactly once with unchanged arguments and effects, return the same
result object or rethrow the same original exception. Restore both bindings in
finally. Observation failures must not alter that behavior, realpath's original
error suppression, its result, stdout/stderr or exit status. Add no query,
resolve, retry, process, interpreter, reader or evaluator invocation.

Retain only the first original OSError: operation (lstat or readlink), safe ASCII
type name of at most 80 characters, existing exact-int/null errno and existing
exact-str path. Include the original probe input. Each encoded JSON string is at
most 1,024 bytes. Only the matching path's already-returned native lstat result
may supply its exact-int mode/uid/gid; retain no object collection or whole locals.
Use built-in field access, not repr/str(error), custom getters or callbacks.
Missing, wrong-type, over-limit or unencodable values and observation failures
are GAP, never an inferred cause. Retain at most one probe record of 2,048 encoded
bytes in the same prebound sink. Use the existing identity, source/copy, invocation
and argument bindings and bounded-write checks. Close the writer on every path;
no extra sink, environment selector or program invocation is allowed. The original
synchronous probe completion proves only this probe and its writer ended, not
reader/owner closure or permission to clean up or restore anything.

At the original Bash emit_error entry, retain its real caller function, original
line and fixed phase. Only at the reader's existing exception mapping retain the
original exception type, its already-computed pre-mapping code and bounded actual
traceback function/line pairs. In that same reader insertion, follow at most three
existing underlying exception objects: cause first, otherwise context, including
suppressed context. Stop identity cycles. For each, retain only an ASCII identifier type name
of at most 80 characters, existing errno (exact int or null), and at most eight
original traceback function/line pairs. Use built-in field access that cannot
invoke custom lookup, getters or callbacks. Only a frame whose f_code is exactly
c._open_held.__code__ may supply its existing path (exact str, at most 1,024
characters), index (exact int) and name (exact str, at most 255 characters).
Function names use the same 80-character bound; line numbers are exact ints.
In this same reader record, retain the outer OSError's native errno descriptor
only as exact int/null. Within the existing traceback bounds, retain at most one
foreground state whose f_code is exactly c._DarwinChildOwner._foreground.__code__.
Restrict it to the first genuine evaluator's original first Git config call:
`/usr/bin/git --no-replace-objects --git-dir=<original> config --file <original> --name-only --list --no-includes`.
Require the original exact list of nine exact strings, only those two path slots
variable, and at most 2,048 encoded argv bytes; bind that exact argv in the record.
Read only existing finite exact-int/float timeout/end and cancelled as an exact
single-element list of an exact bool. Record cleanup_signal only at the original
cleanup killpg traceback site, from its original TERM/KILL loop constant; it is
not a received signal. From an exact original Popen instance's native dictionary,
retain only existing positive exact-int pid and exact-int/null returncode.
Cached None is not liveness. These are exception-mapping facts, not a snapshot at
an earlier predicate: final cancelled=False excludes that one-way bool trigger;
True cannot distinguish cancellation from a prior deadline failure. Only at the
authenticated _foreground deadline/cancel rejection, with that exact code/config binding,
allow an optional io group of at most 1,024 encoded bytes. Require original outputs
as an exact dict of two exact-int fd keys and exact-bytearray values in the original
stdout/stderr insertion order. Retain their lengths and original exact-int cap and
error_cap bounds; out-of-bound lengths are GAP. Retain at most the first 256 stderr
bytes as hex with an explicit truncated bool; retain no stdout content. From the
already-held exact native SelectorKey and exact-int events, map its existing fd
only to those original channel keys. Missing or foreign keys are GAP. Record an
existing exact-bytes chunk length separately: BlockingIOError can leave an older
chunk with another selected key, so do not attribute it to last_selected. These
are retained exception-mapping facts, not selector state at the failed predicate.
Do not inspect the selector after finally or call fileno/get_map/select/read.
Missing, wrong-type, over-limit or unencodable I/O facts are GAP. Include the group
only when both group and whole-record caps fit; otherwise retain all required
original fields with io GAP. I/O formatting failure takes that same fallback and
cannot discard the old record or replace the first error. Add no other buffer
contents or lengths, whole locals, dynamic getters, callbacks or repr. Missing or
invalid frame, command, object, scalar or binding is GAP. Apart from the fixed
first_git_select_observation and first_git_process_snapshot below, do not poll, wait,
getpgid, inspect proc/ps, send kill0, read a clock or add a syscall, query, trace
callback or process. Apart from the owned cleanup repair below, keep original
signals, Popen, call order and exceptions unchanged. These facts grant no cleanup
or restoration permission. Keep
cleanup_signal GAP when finally has overwritten the original loop value.

Retire the four posterior builtin observations and only their method-specific
controls. Preserve their complete evidence and UNKNOWN findings. This disposition
replaces a diagnostic method; it does not claim a repair or change acceptance.

Repair only the owned exception cleanup in product _foreground. Keep its first
raised object as the outer exception. For the existing child with cached
returncode None, attempt the original TERM then KILL once each, with the original
ProcessLookupError handling. A different signal error must not skip the remaining
original signal attempt or the one original child.wait(timeout=10). Retain signal
and wait failures in a bounded, acyclic cause chain in occurrence order, with the
latest cleanup failure as the first error's direct cause. A wait failure therefore
takes that cause position without losing preceding signal failures. Successful
wait cannot erase a signal error or turn the original failure into success.
Keep the original finally responsibilities and order for selector, three pipes,
handlers and signal mask on every exit. Add no signal, retry, poll, OS query or
time allowance. Keep the original success path, I/O, cancellation and deadlines.
Neither EPERM, wait return nor pipe closure proves group disappearance, deletion
permission or restoration. Unknown closure remains PENDING. This repair does not
establish the cause of the Git timeout or close historical UNKNOWN findings.

Keep first_git_select_observation private to this same disposable reader copy.
Bind the original execute_git first-config nine argv, code, source/copy and
invocation. Consume once-only state before installing the adaptation around only
its original _foreground call; wrong bindings, other Git calls and re-entry get
no installation or counts. Bind the repaired, independently reviewed product
_foreground text, AST and exact code object; the diagnostic copy must not edit it
or retain stale source or line pins. Only the owned cleanup repair above may
change that product boundary. Keep
argument evaluation order and counts, the timeout expression and environment()
once each, and the surrounding recheck/record_command positions. Add no
evaluator, reader or Git invocation.

Use one fixed private native-selector adaptation that overrides only select.
Bind the real already-loaded native class, constructor and select implementation
to the authenticated runtime; names or mutable module attributes alone are not
proof. Keep the file-extension/Mac branch. A built-in select branch must bind
its exact module, authenticated bootstrap BuiltinImporter, spec/loader and
selectors reference, default class and epoll backend to the same authenticated
runtime and actual carrying object. Missing __file__, a built-in string or an
arbitrary executable digest is not that proof. Use the same closed source-shape
predicate in select_source_inputs and the generated binding; retain held bytes,
rechecks, selectors/abc methods, constructor/globals/inheritance and backend
identity. Do not invent an extension path or accept other no-file loaders.
Only the Linux built-in branch may use one private constructor-carrier qualifier
in this fixture. Authenticate the bootstrap's real _imp.is_builtin registration
for select and the exact loaded epoll type before querying its source. Through
the runtime's existing authenticated ctypes.pythonapi handle, call public
PyType_GetSlot(PyTypeObject *, int) -> void * with public Py_tp_new 65, then
dladdr(const void *, Dl_info *) -> int on the non-null slot pointer. Bind the
supported Linux pointer ABI and Dl_info four-pointer field order; do not read a
PyTypeObject layout. This is the actual constructor slot, not
the generic __new__ wrapper returned by PyCFunction_GetFunction. Never call the
pointer. Require the supported Linux Dl_info layout and a successful result with
a bounded, terminated image pathname of at most 4,096 bytes. Use only that
physical absolute pathname as the carrier locator; reject aliases or missing
files. Hold its complete bytes with the existing executable size cap, no-follow,
owner/mode/ACL/identity and before/after rechecks. The generated binding must
repeat the same source relation and match that held carrier and digest.
Allow at most one registration, slot and image lookup per existing source-input
or generated-binding admission, never per select or event. Retain the exact
runtime, module, backend and function objects throughout admission. Do not load
another image or handle, discover libraries, enumerate images/processes, inspect
ELF dependencies, invoke a constructor or add a runtime provider. This identifies
one constructor's carrying file; it is not full function-address attestation or
native qualification. Local headers establish interface provenance only. Require
the actual supported Linux ABI, current-runtime symbol exports and held-file
relation in the real positive. Missing symbols, unsupported ABI, null/unmatched
origin, an unholdable or oversized carrier, or drift stops that branch without
retry, a larger limit, another loader, trust root or Linux skip. The extension
and Mac branches must perform none of these new queries.
Construct once through the original native constructor. Keep its native
instance/resources and original register/get_map/unregister/close implementations,
order and call counts. Add no extra select or other method call, generic registry,
arbitrary proxy or public API. If the fixed class cannot preserve those behaviors
and original closure, STOP; do not select another interface.

Allow only `first_git_process_snapshot` in this same private Mac fixture copy.
Only at original select call 101, after 100 normal empty returns and no raised
select, bind its live exact foreground frame/code, nine argv, selector and owned
Popen PID. Invalid counters mean no observation; add no select or polling trigger.
Require live cancelled exact False, a finite original end and at least three
seconds remaining on that same monotonic clock. Consume the single attempt before
spawn. Missing identity, cancellation or insufficient time means zero spawn/GAP;
never use exception-mapping values, restart end or infer an outer budget.
Run only the authenticated fixed Python P with -I -S -B and one frozen private
helper source for this PID, at the same consumer UID with fixed C locale. Bind P,
helper, consumer and ctypes bytes through the existing held/no-follow owner, ACL,
mode, source and native-closure gates. Do not run ps or any setid helper, add a
loader, or weaken the original runtime or system-cache authentication.
Use only the helper's existing _DARWIN_ACL_FUNCTIONS.library handle for fixed
/usr/lib/libSystem.B.dylib. Do not replace/reload that handle, change its ACL
signatures, load libproc or another image, or use a fallback.
Bind the installed SDK declarations and libSystem re-export evidence before use;
header/stub hashes are provenance, not proof of the actual loaded library.
On the original x86_64 runtime, require the declared proc_pidinfo signature
int(int,int,uint64_t,void*,int), PROC_PIDT_SHORTBSDINFO 13 and the exact 64-byte
proc_bsdshortinfo layout: four uint32 fields, comm[16], then eight uint32 fields,
including uint32 uid_t/gid_t. Check ctypes sizes, alignment and every offset.
Call proc_pidinfo once with owned PID, flavor 13, arg zero and one zeroed 64-byte
buffer. Missing symbol, unsupported ABI, denial, EINTR or return other than 64 is
GAP with no retry. On exact success require matching PID; retain only PID, PPID,
PGID, UID, numeric status and the bounded 16 comm bytes. After that same-PID
success, call proc_pidpath once for that PID through the same authenticated
handle, with signature int(int,void*,uint32_t) and one zeroed 4,096-byte buffer.
Bind its SDK declaration, buffer limit and libSystem export before use. Require
an exact positive returned length below that limit and a matching NUL-terminated
absolute path. Retain at most 256 path bytes as hex in optional image_path_hex;
never truncate a longer path into a valid observation. Missing symbol, denial,
EINTR, invalid type/length/termination, overlong data or encoding failure makes
only that field GAP, preserving the valid six fields. Add no retry or fallback.
Do not follow, normalize, open or query the returned pathname. The two queries
are sequential, not an atomic identity proof; PID reuse or exec between them is
not excluded. Apart from this image call, decode no other fields or query argv,
environment, a process table, descendants or another flavor. Do not use a sampler.
These calls run only in the supervised helper, never in the reader thread; their
native duration has no synchronous one-second guarantee. All helper startup and
authentication consume the same collection window. No new evaluator, reader or
Git invocation is allowed; this helper is not a new product or runtime provider.
This is one direct observation child in its own group with bounded pipes. Within
the original end allow at most one second to collect and one second to terminate,
kill if needed, wait and close its pipes, using the existing owned-child pattern.
Check live cancellation during supervision; do not mask signals or swallow it.
Keep original outer alarms effective. An early outer timeout still fails/PENDING;
local admission does not promise outer time or successful closure. Uncertain
observation-child closure means PENDING, no continuation, deletion or restoration.
On known closure, unavailable/failed/invalid observation is GAP and original select
still receives its original arguments once. Preserve all original calls and errors.
Retain at most 768 stdout bytes and 128 stderr bytes, fixed parsed fields and the
observation status in one optional group of at most 1,024 encoded bytes. Overflow
is GAP. Export only through the existing first-config failure record and its
original eligible exits; no success output or new sink. Required old fields and
all existing record/export/raw caps take priority. A matching PID/comm or image
pathname is only a post-launch stage clue, not birth identity, binary
authentication, a blocked syscall or closure proof. It cannot authorize retry of
the consumed reference.

Before enabling this boundary, freeze its exact generated source and inverse.
Use actual extracted ordinary controls for once-only/foreign-frame/other-call
rejection, exact counter/remaining admission, cancellation before and during spawn,
the actual fixed helper and short TERM-resistant owned children, complete
wait/group/pipe closure, source/runtime refusal, missing symbol, ABI/offset drift,
exact and short native returns, denial/EINTR without retry, wrong PID/fields and
16-byte/nonterminated comm encoding. For the image field, add an actual owned-child
positive and controlled missing-symbol, denial/EINTR, invalid return/termination,
wrong PID argument, overlong, binary-path encoding and cap/write-failure cases.
Prove exactly one permitted call per API on the same PID, no image call after
invalid short-info, valid six-field retention on image GAP, no pathname access,
and unchanged cancellation, supervision and loaded-library boundary. Freeze the
exact helper bytes and inverse. Ordinary local results do not establish the CI
ABI, runtime or target state.
Show original select arguments, results, exceptions, order and all deadlines
unchanged; no artificial successful closure or extra evaluator/Git call. Keep every
existing shared control. Measure the entire fresh recursive raw batch at 16 MiB
before publication, using only existing lossless source sharing. Retire this
private observation after its actual evidence is used for a separately reviewed
normal-path correction; keep the evidence and all shared lifecycle controls.

For select counts retain only entered, returned, raised, nonempty, events_total
and last_length.
The first five are exact builtin ints from 0 through 2^31-1; last_length is an
exact builtin int in that range or GAP.
Before each original select delegation increment entered; on return increment
returned. Only for an exact builtin list, use builtin len to update last_length,
events_total and nonempty. Do not iterate events or inspect keys, fd, attributes,
repr or buffers. Delegate the original arguments once and return the same list
object. On an original exception increment raised when safe and bare rethrow the
same object with its cause/context. A non-exact result, counter overflow or
collection failure makes this new group permanently GAP; original delegation,
return or exception still follows the original path. Do not retry collection or
swallow cancellation as an observation failure.

At the existing failure mapping, require the original exact foreground frame,
code, first-config argv and this invocation's selector instance identity. Export
only with retained cancelled exact False and the existing exact positive
builtin-int PID, through either of two original exits: the original deadline
Refusal with the same-frame killpg PermissionError, native errno 1, retained in
its cleanup cause chain after the original cleanup wait succeeds, with no wait or
finally failure; or that exact deadline-site Refusal E_RUNTIME object
reaching the mapping directly after cleanup/finally returned normally, without a
cleanup failure. Bind both chains to the newly reviewed product source and code;
add no eligible failure site or observation field.
The direct exit must bind the same original foreground code/frame, nine config
argv, selector instance and invocation. It adds no error site or call. Normal
cleanup return or cached returncode -15 proves no full-tree closure or restoration.
All other ends discard counts without output. Retained False is not a current cancel token;
add no query to obtain one. Do not infer blocking, PID identity, kernel readiness
or an EPERM cause from counts or GAP. Keep cleanup_signal GAP and every original
identity, context and I/O check.

Restore the exact temporary binding in finally on every exit, including install,
constructor, delegation, cancellation and cleanup failures. This restores no
child or filesystem state and grants no cleanup permission. Prove native resource
closure and original cancellation through the actual boundary before enabling it.
Outside first_git_process_snapshot, add no queries, clocks or processes. Do not
replace original Popen/read/write/killpg/wait or their signal handling, add threads
or grace, or alter an original deadline or exception beyond the owned cleanup
contract above. A select wrapper adds a private
traceback frame: bind it honestly and retain every original
frame in order, the same exception and cause/context. Do not claim byte-identical
whole tracebacks or let new frames displace original facts under existing bounds.
Keep the original deadline check outside the wrapper and its exact frame mapping.

Bound the six-field object to 256 encoded bytes and its source/copy/invocation-bound
optional group to 1,024 bytes in the existing reader record and sink. Required old
fields and still-applicable diagnostics have priority. Insufficient space, encoding
or write failure makes only this group GAP; preserve the complete old record,
first error and exit. Keep every record, sink, export and ordinary-raw cap. No
success export, event log or timing record is added. The small counting overhead
has no zero-latency or full-budget-success guarantee. Unknown closure remains
PENDING with no deletion or restoration permission. Retire this observation when
a separately reviewed repair removes this evidentiary need.
Missing, unsupported, wrong-type, cyclic or over-limit facts stay GAP. Do not
serialize whole locals, repr/str(error), other exception fields or source text.
Add no stat, open, ACL, readlink, resolve or other failed-object query, input
reread, re-evaluation or retry. Preserve the original exception and mapping;
diagnostic collection failure cannot replace them. Keep each encoded record at
most 4,096 bytes and the existing sink at most 8,192 bytes.
Capture at most one record from each Bash, probe and reader boundary;
an unreached or missing stage is GAP, not an inferred cause. Use one fixed,
precreated private sink outside evaluated and held trees, with the existing
no-follow, regular-file, identity and bounded-write checks. Prebind the invocation,
original/copy source digests and canonical exact nine-data-argument digest; accept
no earlier invocation's record. Use already retained preparation bytes and call
values; add no input reread, safety-object stat/ACL query, scan, trace callback or
environment selector. These insertions change none of the four Linux capture literals.

Export only this first call's unexpected failure before its original assembler
assertion. Keep its original stdout/stderr, error token, status, assertions,
wait/pipe/owner/cleanup and every deadline. Formatting, sink and export failures
cannot replace the original error. Bound the complete new encoded export,
including bindings and GAP, to 12,288 bytes. Together with the existing at-most
4,096-byte cost export it stays within the original 16,384-byte failure allowance.
Earlier I1 or terminal failures cannot reach this call; preserve both exporters
and their full caps. Unknown allowance means no new output. Export no success,
add no evaluator/reader invocation or retry, and grant no cleanup or restoration
permission from these records. This boundary obtains refusal provenance only;
it neither changes a predicate nor proves an ALRM or performance fix.

Use ordinary owned controls on the exact extracted insertions and original
failure boundaries. Distinguish direct Bash refusal from reader-mapped refusal;
cover original-line/phase mapping, missing-stage GAP, wrong invocation or source,
missing/wrong sink, overflow and formatting/write failure without masking the
first error. Exercise actual original _open_held with an owned controlled OS
failure to prove its suppressed context; direct Refusal is a separate control,
not OS-error coverage. Cover missing/wrong/cyclic/overlong context, exact frame
identity versus a same-name wrong frame, and type, formatting and sink failures.
For foreground facts, use the exact extracted mapping with original cancel and
deadline refusals and controlled TERM/KILL OSError exits. Reuse real owned
short-lived children in the existing foreground controls. Cover either signal
failure, both failures, ProcessLookupError, successful wait and wait failure.
Run the actual repaired _foreground code and prove the original first error's
identity, complete cause order, original signal order/counts, exactly one cleanup
wait(timeout=10), and the actual finally pipe/selector/handler/mask actions.
Keep wait-failure cases fail-closed; distinguish a controlled error after a real
wait from an unproven child closure. Update assertions that encoded skipped wait
or a replacement signal error. Preserve all old negative cases and capture their
new actual source/line/exception bindings before execution. These controlled
PermissionErrors do not reproduce the CI kernel cause or prove full restoration.
Cover existing native child fields, wrong frame/config argv, pseudo-child rejection,
None without a liveness claim, GAP, encoding/cap and formatting/write failures.
For io, prove original buffer order, bounds and channel provenance, partial EOF,
and an old chunk after BlockingIOError with another selected key. Cover binary
stderr beyond 256 bytes with exact prefix/truncation, missing or wrong types and
pseudo-keys with zero hooks, GAP, encoding/group/record caps, and formatting/write
failure isolation. The original required record and first error must survive a
failed optional group. Retain the complete original control sequence.
For first_git_select_observation, extract the original _foreground and actual
adaptation in the existing ordinary owner lane. Prove real runtime/class/method
binding and a real native path. On the actual supported Linux runtime, prove
select_source_inputs, full capture construction and native binding against its
real module/source shape. Keep the original six binding controls and add wrong
loader/spec/module/carrier rejection. For the private built-in qualifier, prove
the real registered epoll constructor slot, actual loaded carrier and held bytes
through both source-input and full generated-binding admissions on Linux. Reject
a different held file/digest, generic wrapper or wrong type/slot, wrong native
origin, missing symbol, unsupported layout, null/overlong path and carrier drift
or size overrun. Prove the fixed lookup counts and no constructor call or new
loader; label injected failures as controlled, not real source positives.
Preserve the real Mac extension/Kqueue path with zero new lookups and all
lifecycle/inverse controls. Metadata seams are not a real built-in positive;
fixed scripted native-result seams are controlled
branch evidence, not that proof. Preserve native construction, non-select calls,
closure and original argument evaluation order/counts. Cover empty/nonempty exact
lists with the same returned object, one delegation per original call, sentinel
exceptions with original frames in order plus the named wrapper, cause/context,
and cancellation propagation. Cover wrong frame/argv/instance, other calls and
re-entry; non-exact lists must invoke no custom len/iter. Prove output rejection
for bad PID, wrong error chain and cancelled True/GAP. Add an actual mapping-lane
control for the original deadline refusal with normal original cleanup and the
same direct Refusal reaching the mapper: export its existing counts once, preserve
exception identity/context/trace, original calls and binding restoration. Keep
the EPERM lane and every existing negative, native, lifecycle and source-inverse
control. Prove wrong direct error/site/frame/selector/invocation still exports no
group; neither branch adds success output or cleanup authority. Cover overflow and
collection failure permanently GAP while original effects continue, all group/
record/export failures with old fields retained, and exact binding restoration
on install/constructor/delegation/cleanup failures. Save actual facts before
assertions. Compare the same original delegation's result, exception and calls;
do not infer equivalence from totals across separate runs. Real stderr still
fails under the original rule; do not filter it or require the host to be silent.
Keep all shared foreground/I/O/context/invocation/source, first-error, cancellation,
cap, child/wait/pipe and native-lifecycle controls. Only builtin-query-specific
controls retire; retain old raw evidence. These enablement proofs precede fresh
independent source preparation and the original full Mac then same-H Linux proof.
They neither establish the actual CI cause nor replace restoration or G3.
Label controlled OS errors honestly; preserve all old and new ordinary raw output
under the original 16 MiB cap without truncation or removal of controls.
Apart from the fixed built-in carrier qualification, prove no added object
queries, unchanged original error/status/calls and no success export within the
same caps.
Freeze complete generated copies before
these ordinary controls. For the launch fields, use actual owned link creation and
the original extracted selection/launch sites to prove that each retained value
comes from that same invocation. Cover stage failure/GAP, quotes, backslashes,
control characters, unsupported encoding, length caps and wrong bindings. Preserve
the original call count, argv, environment, refusal and source checks; collection
or encoding failure cannot mask the original result. Keep success export absent.
For the probe, compare the exact extracted original and observed programs on an
actual owned success path and controlled original lstat/readlink errors. Prove
one delegation per original call, argument/effect equivalence, result/exception
identity, unchanged realpath result, stdout/stderr/status and final binding
restoration. Each error control must reach its named primitive; an earlier failure
is not coverage. Cover GAP, wrong types, overlong/unsafe encoding, observation and
sink failure, record/sink caps, wrong source/invocation and exact inverse. Use only
these ordinary controls; they do not prove the actual Mac query cause or a fix.
Check exact reverse restoration, actual copy-source authentication, closure before
restoration, unknown closure with no restoration, and unchanged later calls apart
from the fixed outer timeout exit below. Do not substitute owned controls for
actual genuine refusal evidence. Freeze the actual generated copies, insertion
bodies and bindings at exact H/B in fresh independent source preparation before
the original full proof and separate G3.

Only the original `outer_scope_raw = run(scope_argv)` call after the withheld
bundle swap may report its original `TimeoutExpired`. Match the exact stdlib
exception type and fixed call site. Require cmd to be an exact list of exact
strings matching that call's normalized scope_argv, and exact integer timeout 180.
Use only the exception's already-held native fields, without custom getters,
repr/str or whole locals.
Keep the first-call capture and general run function unchanged. Report only the
fixed boundary, bound argv digest, timeout, exact-bytes output/stderr lengths and
at most 256 stderr bytes as hex with an explicit truncated flag. No stdout
content. Bound lengths by the original run limit. Missing, None, wrong type,
overbound or inaccessible fields are GAP with a fixed reason; empty bytes means
length zero. Neither empty nor GAP identifies the internal cause or child state.
Emit at most one 1,024-byte encoded record through the existing assembler stderr
exit, best effort. Add no sink, writer process, source capture, query, clock or
child access; no communicate/read/poll/wait, evaluator call, retry or permission.
Keep original
argv, env, input, timeout, call count, reap, traceback and cleanup unchanged.
After the optional record, bare rethrow the same original exception. Collection,
encoding, cap or real stderr-write failure cannot replace it. Share the original
12,288-byte non-cost allowance and 4,096-byte cost allowance, within 16,384 total;
all existing records take priority. Unknown or insufficient allowance omits this
record, never the original traceback or evidence. Normal return adds no output.
These facts grant no cleanup or restoration permission and prove no timeout fix.

Use the actual extracted fixed call/handler boundary in ordinary controls. Prove
normal silence, one original call with unchanged arguments/env/input/timeout,
and exception identity, traceback and original call/reap effects. Cover empty
bytes versus None, binary stderr at 256 and beyond, wrong type/cmd/call site,
custom-hook rejection, safe encoding, record caps and a real stderr-write failure.
Each recording failure must retain the original exception. Keep all old controls,
raw-size and exact-source preparation gates; ordinary controls do not prove the
actual Mac cause. This adds no general run logger or new diagnostic invocation.

Retain the cost samples from protected slot 0's original `.github/workflows/ci.yml`
call and the original terminal `normal` call. Add only the first existing dashboard
shape call, `dashboard shape del(.body.flow)`, through the existing slot 8 boundary.
Bind that fixed source call, current source, private copy and nine data arguments
before held acquisition; the other eleven dashboard iterations are not selected. Reuse the
existing private copy/binding path, with no new slot, caller selection option or
case registry. Its two optional records are `dashboard-flow-frontend` and
`dashboard-flow-observer`; they use only the existing five phase fields and GAP.
Keep cost_selected false for this call and add no classifier qualification work;
slot 0 remains the only counted session. Preserve all 78 calls, order and results.
Precreate the same fixed 4,096-byte-bounded data leaf and one-byte eligibility leaf
outside all evaluated/held trees. Permit at most five sample records, each at most
1,024 encoded bytes, within that same data cap. Keep fixed case and current
source/copy/argv bindings; add no header, path list, environment dump or per-call
leaf. Use the existing sink identity boundary; add no safety-object or source/package
query. Keep the original three records and their optional counts/stage priority.
If storage or export space is insufficient, omit the entire new two-record group
as GAP; it cannot displace, shorten or prevent a required original record.
Keep these samples only until the original fixture ends. They are not success
proof, qualification output or evidence of CPU or classifier cost.

The same bounded parent Bash may retain one optional ALRM stage record in memory.
Record its entry SECONDS without resetting it or moving the original alarm. Use
only fixed enum points at initial runtime authentication entry/return, ordinary
controls complete, ok35, terminal complete, genuine setup entry, its runtime
authentication return, identity preparation complete and path preparation entry.
Each point has only its integer SECONDS or GAP. In path preparation, retain only
the last of the original libexec mkdir/identity and base mkdir/identity operations:
fixed operation enum, entered/returned, integer SECONDS and original return status
only after the command actually returned. Preserve original creation flags,
identity assignments, argv, order, errexit and failure handling; an if/OR-list
wrapper must not change them. Missing returned means no recorded return, not a
claim that a child is alive or that a command did not execute. Retain no dynamic
path, argv, environment or object data. Add no query, clock process or collector.
At entry to the original ALRM trap, freeze these values and trap-entry SECONDS
once, before cancellation or cleanup. Cleanup cannot overwrite the frozen facts.
Pass only that snapshot to the same existing cost-export call. Safely encode at
most one optional record of at most 1,024 bytes including its newline; add no leaf
or writer. Export it only with the three complete original samples, under all
existing eligibility, binding, writer-closure and saved 142/ALRM gates below.
The combined cost output still fits 4,096 bytes and the unused failure allowance.
Missing or invalid stage facts are GAP. Invalid encoding or insufficient space
omits only the optional record; it must not discard or shorten the original three
samples, change the first failure, or grant cleanup/restoration permission.
Unqualified, early-failure, normal-exit and other-failure paths gain no output.

Each selected private frontend reads Bash SECONDS at exactly five boundaries:
copy entry, before the original reader launch, after its real normal wait, and
before/after its original cleanup. Do not reset SECONDS or start a timing process.
Instrument that cleanup once for both EXIT and the success path that removes its
traps. Preserve the original call, return, signal and exit behavior. Mark an
unreached normal wait GAP; cleanup's tolerant wait cannot substitute for it.
The slot 0 and fixed dashboard observers each take five same-process monotonic
samples: preparation entry, before/after trace installation, runpy return or unwind,
and after trace restore. No other call gains phase samples or per-event clocks.
Preserve the original exception and mark unwind as failure, not normal completion.
Keep only finite, ordered differences; missing or invalid facts are GAP. Bash
facts have integer-second resolution. Do not subtract different process clocks.
Launch-to-wait includes frontend work and reader waiting; observed execution
includes imports, tracing and measurement overhead. Neither is isolated CPU or
callback cost. Cost sampling must not time callbacks, add source reads or change
trace dispatch. The separate classifier reuse above changes no timing boundary.

Only the same slot 0 observer row may add one optional `counts` group, at most
384 encoded bytes. Its eight fixed fields are `requests`, `filename_tests`,
`set_tests`, `result_reuses`, `negative_hits`, `qualification_entries`,
`qualification_nodes` and `dispatch_selected`. Count every original watched
request, including non-source requests and attempts that throw. Count filename
and CodeType-set tests only when their original short-circuit branch attempts
that test. Count original strong result-cache reuse for either True or False,
live matching weak-negative hits, qualification entries and nodes already visited
by the original walk. Count selected dispatch returns at the original branches
that return the existing trace. These are branch counts, not CPU attribution.
Use only facts from those original branches and existing node counts. Add no
classification, hash/eq, weak-reference call, query, source read, clock or callback.
Keep counts local to this selected observer session. Each value is an exact int
from 0 through 2,147,483,647. Collection failure, overflow or unavailable facts
make only the group GAP; stop its increments rather than grow an unbounded value.
Do not catch an original operation's exception to collect a count. Preserve the
classifier contract above, original effects, order, results, exceptions, reentry
and resource bounds. Keep the original five phases, completed status, eligibility
and closed-writer rules unchanged. Encoding or space failure omits only this
optional group. Preserve the original sample fields, three records and existing
stage priority; the original 1,024-byte row and 4,096-byte combined caps still hold.
No other slot gains counts or success export. Only in a session whose fixed
cost_selected is False may observer_source omit count_classification calls that
would immediately return without collecting data. Keep every original watched
request, filename/set test, hash/eq effect, short circuit, result and exception,
cache operation and trace event in its original order. Keep slot 0's eight counts
and five phases unchanged. This permits no other work reduction or change to the
Mac wrapper, guard, reader or evaluator. Apply the existing same-work equivalence
and useful-work gate above before source preparation or full execution.

Initialize eligibility to zero. Only the original terminal Python, after every
original terminal assertion passes, may write one and close it before returning.
Only the existing outer cleanup with saved status 142 and signal ALRM may export
cost, after its original cancel/wait attempts and before its original tmp deletion.
Cost export does not require another owner's cleanup to succeed. Require bound
eligibility 1 and all three original completed records, with current source/copy/argv
and existing identity/NOFOLLOW checks. Prove that their only fixed writers have
finished, closed their records and cannot write again. The optional dashboard
pair may export only when both records independently meet these same completion,
binding and closed-writer gates. Missing, incomplete or invalid new facts mean
GAP for that pair, without qualifying it or changing original-sample eligibility.
A marker, metadata, memory flag or another owner's state alone cannot prove closure.
Missing qualification, required original records, writer closure or source binding,
and invalid or oversized shared transport still mean no output. An unknown other
owner permits only reading this unrelated, previously
closed cost data. Keep owner confirmation, cleanup_genuine, PENDING, tmp deletion,
restoration and the original status 142/ALRM behavior unchanged.
Early I1 or terminal failure, successful exit and other failures produce no cost
export. Prove that an I1 export or terminal assertion failure cannot reach this
qualification point; otherwise suppress cost. Thus the original I1 bytes and
exporter stay unchanged, with no cross-subshell memory counter, lock or publisher.
Cost output is at most 4,096 bytes and must fit the original 16,384-byte unused
failure allowance; uncertain allowance means no output. Do not wait for a sample,
retry, query a failed object, fill missing data or use cost state to permit cleanup
or restoration.

Use real owned extracted boundaries to cover both cleanup paths exactly once,
nonzero wait, missing phases, exception/unwind, actual phase order, source/case
binding, wrong eligibility, incomplete writers and byte caps. For the dashboard
pair, use the actual extracted fixed frontend/observer/binding and exporter paths.
Prove selection of only that first source-bound call, both five-phase orders,
unchanged original calls/nine arguments/results/exceptions/cleanup, and no counts
outside slot 0. Cover wrong case/source/argv, later slot reuse, unwind, missing or
unfinished writer, malformed facts, write/encoding failure and per-row/combined caps.
An absent or overflowing pair must leave the original three records and stage
priority intact; normal exit or absent eligibility still exports nothing. Keep
all old controls and exact generated-source/inverse preparation. For the stage record,
exercise the actual extracted Bash/trap/export boundaries with a real ALRM: freeze
ordered points and entered/returned status once before cleanup changes state.
Cover a command with no recorded return, a real zero/nonzero return, fixed enums,
wrong types, missing values, encoding and byte-cap failures. Prove unchanged
command argv/order, errexit/failure behavior, original status/signal and all export
and cleanup gates. No eligibility or normal exit means no stage output; optional
overflow cannot lose the original samples. Unknown state grants no deletion.
For counts, reuse the actual owned classifier/observer boundaries and an
independent primitive witness on the same original request sequence. Cover
non-source and throwing attempts, short circuit, True/False result reuse, weak
negative fallback, selected dispatch, qualification nodes, custom hash/eq and
reentry. Prove unchanged effects, order, result, exception and original phases.
Missing facts, overflow, wrong types, encoding/cap and exporter failure may lose
only counts, not the original samples, qualification, first error or cleanup gates.
Measure full raw size and ordinary whole-work overhead without per-event timing,
extra evaluator/reader calls or artificial heating before source preparation.
For omitted unselected counter calls, compare the actual old/new extracted observer
on the same selected and unselected owned sequences. Require zero unselected
count_classification entries with unchanged original classification counts,
effects, events and exceptions; preserve slot 0's eight counts and phase boundaries.
Reuse the existing whole-work value gate: insufficient benefit or failed
equivalence stops this candidate before full CI, without a deadline-success claim.
Keep every original control. Show that early I1
and terminal failures cannot qualify, and that a real ordinary ALRM handled after
terminal completion exports once before deletion without changing status or
cleanup gates. Keep that normal-cleanup control. Also run the actual original
cleanup boundary with real closed samples and a refused owner confirmation:
export once, call neither deletion nor cleanup_genuine/restoration, preserve the
original failure and status 142/ALRM. The independent owned harness may reclaim
only its own data whose writers it has proved closed; an actually unreaped child
cannot be a passing control. Keep the I1 record and its full cap intact. Bind the
actual revised observer, generated private copies and timing injections at exact
H/B in new independent source preparation; keep the other three capture literals
exact.
All original calls, deadlines, owner/reap/restoration controls, complete Mac/Linux
proof and historical UNKNOWN findings remain. Add no evaluator/reader invocation,
retry, diagnostic CI, public selector, product change, permission or budget.

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
