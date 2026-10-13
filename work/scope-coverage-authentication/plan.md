---
spec-blob: b9a68fca1aa756ec76baa26471d707026bc42fab
drafted: 2026-10-13
---

# Plan: authenticate later-revision scope coverage

Tracks #544. Risk is high. This is the mandatory second delivery of Step 8 child
6. It implements the complete parent R3 later-revision rule for the fixed write
workflow and task. The accepted #541 core remains the exact-revision foundation.
Both deliveries must pass before child 6 completes or child 7 starts.

Implementation PR: `review_size: accepted-exception`, 4,800–7,200 net changed
lines. The fixed source operation, current-request ownership, raw history
normalizer, full Git comparison, and real two-principal source fixture are one
authentication boundary. About half of the range is the complete positive and
damage-case proof. The range does not relax readability, tests, CI, review, or
any acceptance standard.

## Files that change

The plan PR changes only this file. The implementation may change only:

- `scope/v1/read-shadow-evidence.py` — extend the #541 private reader with the
  qualifying/current pair, evaluator-owned request, fixed source launch, source
  attempt read, and measured coverage observation.
- `scope/v1/evaluate-scope.sh` — retain the nine-argument public command, hold
  the private workspace and pass the closed internal observation to jq.
- `scope/v1/workflow-scope.jq` — admit the exact coverage block only for the
  fixed write workflow and task.
- `scope/v1/scope-gates.jq` — validate the internal coverage observation and
  apply identity, history, age, current-binding, and invalidation rules.
- `scope/v1/scope-policy.json` — add only `scope.enablement-stale` to the closed
  reason vocabulary if #541 has not already added it.
- `sandbox/v1/host-supervisor.py` — add the one fixed `coverage-read` operation,
  source admission, bounded collector lifecycle, source receipt, and durable
  exact-inventory write.
- `sandbox/v1/coverage-source.py` — new private schema and normalizer for the
  fixed collector frame, raw forge pages, and canonical coverage observation.
- `shadow/v1/_consumer.py` — add the dedicated fixed source-configuration and
  coverage-attempt readers by reusing the existing held-path controls.
- `scripts/test/scope-qualification.test.sh` — add the full same-contract source
  fixture and every R9 positive and negative.
- `docs/components.md` and `RESTORE.md` — document the inactive source boundary,
  fixed files, restore set, and proof commands.
- `ci/required-files.txt` — add `sandbox/v1/coverage-source.py` exactly once.

Do not change a workflow, `scripts/test/run-all.sh`, portable-core capability,
profile binding, duty or stage contract, tracked production source configuration,
registry, accepted identity, credential, network route, installation script,
publisher, target writer, or construction marker. The implementation uses
`Closes #544` only after #541 is complete; that closes child 6, with no activation.

Before the first code commit, compare the accepted #541 implementation with its
plan and bind this work to the actual private reader, runner, Git owner, bundle
reader, and fixture symbols. A name-only or layout-only difference is a normal
base update and must be recorded in this plan's exact tuple and review. A changed
contract, extra authority, or missing safety control returns through this plan
gate. Do not create a second implementation because a private symbol moved.

## Fixed public flow

Keep `evaluate-scope.sh` as the sole public entry. Its command stays:

```text
evaluate SCOPE SHADOW_SET DASHBOARD RISK KILL DUTY MARKER BUNDLE_ROOT SOURCE_GIT_DIR
```

Do not add a coverage argument, source locator, endpoint, host, credential,
provider id, raw fact, observation, trust flag, or fixture switch. The first
seven inputs retain their canonical one-MiB snapshots and stale checks.
`BUNDLE_ROOT` and `SOURCE_GIT_DIR` retain the #541 held physical checks and prove
nothing by their path. The validated scope selects coverage only when its
workflow and task are exactly the accepted write pair.

For that pair, `workflow-scope.jq` requires one exact `coverage` block with only:

- `coverage_base` as the target repository's canonical revision ref;
- `coverage_rule_version: "scope-coverage.v1"`; and
- sorted unique qualifying shadow-record refs.

Existing shadow refs remain the current refs. Both sets resolve by raw digest in
the same held shadow set and bundle root. A partial or mixed workflow/task pair
is malformed. A scope matching neither field must omit coverage and keeps the
#541 exact-revision, full-identity, no-change path. Record fields and caller
booleans never select the class.

The driver snapshots and measures its package before invoking the private reader.
It creates one exclusive scratch child for the reader output. The reader returns
one canonical internal `scope_shadow_evidence_observation`; its coverage section
is either a complete authenticated result or one closed missing/stale state. The
driver passes only that observation to jq and rechecks all input, package,
directory, Git, request, expectation, and output objects before success.

## Qualifying and current evidence

Extend the #541 reader rather than create another evidence evaluator. Authenticate
the qualifying and current bundles through the same fixed package, controlled
store, receipt checker, native registry, accepted set, record-form, held Git, and
write relations. Every required environment has exactly one row in each set.
Missing, duplicate, foreign, unproven, legacy, or cross-form rows cannot count.

Compare the closed coverage identity field by field. It contains only the scope,
workflow, task, model request, artifact refs, complete resolved-profile source and
bindings, environment and registry entry, control policy bytes, coverage base,
and rule version named by the spec. Preserve the sole forge materialization
capability. No digest supplied by the scope replaces this comparison.

The qualifying rows bind `coverage_base`. The current rows bind R. Everything
outside the closed identity is recomputed for R, including target and candidate
Git facts, stage/profile/result refs, materialization, publisher request,
post-check, sandbox receipt and current source refs. A value matching the base is
neither required nor sufficient.

## Evaluator-owned request

After both bundle sets and the bare Git snapshot pass, the private reader creates
32 random bytes from the physical runtime and derives one unique attempt id. In
an exclusive directory it writes canonical `coverage_source_request` and
`coverage_source_expectation` files with create-exclusive, mode `0600`, file
fsync, directory fsync, and retained read-only descriptors. No source process
starts before both are durable.

The request and expectation contain exactly the fields in spec R3. The reader
derives every ref from held scope, seven original documents, authenticated bundle
sets, current profile/stage/result/materialization/publisher/post-check facts,
qualifying receipts, Git observation, and the fixed source package selected by
the root-owned configuration. It accepts none of those values back from a caller.

Add one closed source method to the concrete private child owner used by the
reader. This is a #544 responsibility; #541 supplies no sudo owner or source
launcher. The source method opens and holds physical `/usr/bin/sudo`, the current
Python and installed supervisor, reuses the reader's one deadline and closed
command ledger, and accepts only the canonical request bytes. It exposes no argv,
environment, callback, role, timeout, or output-limit argument.

The method records role `coverage-source-boundary`, the request digest, fixed argv
digest, sudo digest, and supervisor digest in that ledger. It rechecks all three
executables before and after use. Use the existing private bounded child lifecycle
and its process-group cleanup; extend that concrete owner with this one method
rather than copy the lifecycle or expose a generic runner. The source role has a
120-second cap within the reader's deadline, zero stdout, at most 16 KiB stderr,
a clean environment containing only `PATH=/usr/bin:/bin`, `LC_ALL=C`, and
`LANG=C`, TERM then KILL cleanup bounded to 10 seconds, and one exact reap. Its
only argv is:

```text
/usr/bin/sudo -n -u #SOURCE_UID -- P -I -S -B ANCHOR/host-supervisor.py coverage-read
```

Send the held request bytes on stdin. `SOURCE_UID` is the same dedicated
supervisor principal already fixed by the held host configuration. The source
cannot alter the held expectation. A reused nonce or attempt, request mismatch,
timeout, nonzero exit, signal, malformed frame, uncertain reap, late file change,
or changed expectation refuses before any facts count.

## Optional source installation

Do not widen the exact sandbox host-config schema. The coverage path opens the
optional fixed siblings `coverage-source-config.json` and
`coverage-source-accepted-identities.json` relative to the already held anchor
descriptor. Absence is the normal production state and produces
`scope.enablement-stale`. Presence requires the existing root-owner, mode, ACL,
one-link, no-follow, ancestor, held-descriptor, and final-recheck controls.

The source config is one canonical closed document. It fixes:

- operation `coverage-read.v1` and rule version `scope-coverage.v1`;
- the three query families and each exact schema version;
- a physical source-package manifest and its SHA-256;
- one physical collector executable and its SHA-256;
- one target-specific canonical `publisher_identity_ref`;
- the accepted-set path and digest; and
- the existing store id and dedicated principal/group relation.

The publisher identity is an independent root-controlled expectation. The
evaluator holds it from this configuration and compares every qualifying
publisher-PR actor ref with it. It is not derived from a PR row, publisher
request, scope field, matching digest, resolved-profile publisher binding, or
caller label. It does not add a field to the closed coverage identity or to the
exact evaluator-owned request.

The accepted set is a separate canonical closed document. It is inactive and has
zero or one row for this source id. A qualifying row matches operation version,
host-supervisor digest, source-package digest, collector digest, and normalizer
digest field for field. Duplicate, absent, unqualified, foreign, placeholder, or
caller-labelled rows refuse. Do not populate a tracked production config or set.

`coverage-source.py` is part of the measured root-owned package and is compared
byte for byte with the repository source before use. The source-package manifest
is a finite closure over that normalizer, the one collector, and its fixed query
schemas. It is not a plugin manifest or provider registry. A future production
collector, credential, route, installation, and accepted identity require their
own artifact and authority decision.

## Fixed collector protocol

The supervisor validates installation and configuration before parsing stdin.
It claims the nonce in the existing held work root and claims the same attempt id
in the existing controlled store before collector execution. It invokes only:

```text
COLLECTOR coverage-read.v1
```

Use a clean fixed environment, stdin as the canonical request, closed unrelated
descriptors, one foreground process group, a fixed deadline, bounded stdout and
stderr, TERM/KILL cleanup, and exact reap. The request contains no endpoint,
host, credential, executable path, page path, cursor supplied by the caller, or
trust flag. The collector and its root-owned package choose physical requests and
pagination.

Collector stdout is one existing binary frame. Record zero is canonical
`capture.json`; remaining records are consecutive `raw/0000` through
`raw/NNNN`. Capture rows contain only family, page index, response status, input
cursor, and output cursor. The three families are fixed default-branch history,
publisher pull requests, and complete branch-rule history. Each family starts at
index zero, forms one cursor chain, and has one terminal cursor. Require every
family, at most 128 pages, at most one MiB per page, at most 64 MiB total raw
bytes, and at most one MiB for every canonical document. Reject missing, extra,
duplicate, reordered, truncated, oversized, unknown-family, bad-status, or
unterminated input before normalization.

The supervisor computes request digest, raw sizes, raw digests, and the canonical
raw manifest itself. It never accepts a collector manifest, receipt, normalized
observation, source identity, status claim, or timestamp. The fixed normalizer
reads only held raw bytes and emits the six-field observation in spec R6. It has
no network, caller-file, environment-provider, dynamic import, or plugin path.
Re-normalize before storage and again in the consumer; both canonical byte strings
must match.

## Durable source attempt

Reuse `check_store_root`, `create_attempt_dir`, `mkdir_excl`, `write_excl`, and
`write_receipt_file`. Add one dedicated `write_coverage_payload` beside the
existing launch writer because the coverage inventory has a required `raw/`
directory. Do not make the existing launch inventory caller-configurable.

The source attempt has exactly:

```text
receipt.json
payload/request.json
payload/raw-manifest.json
payload/observation.json
payload/raw/0000 ... payload/raw/NNNN
```

Write every file mode `0440` and every directory mode `0750` as the source
principal and consumer group. Use exclusive relative creation, one link,
per-file fsync, raw-directory fsync, payload fsync, attempt fsync, receipt last,
and final store-root fsync. The supervisor writes canonical started/completed UTC
seconds and the exact source identity, query, effects, request, manifest, and
observation digests. Effects are only `read-forge-metadata` with no target write,
publication, or authority effect.

Add a dedicated `read_coverage_attempt` to `_consumer.py`. Its inventory and
bounds are constants, not arguments. It opens every object descriptor-relative
with the existing owner, group, mode, ACL, link, no-follow, held-descriptor, size,
and before/after metadata rules. It compares the stored request byte for byte with
the held request; verifies receipt, nonce, attempt, source identity, query,
manifest, page chain, raw bytes, and observation; runs the same normalizer; then
rechecks every descriptor and the anchor. Copied bytes, archived origin, caller
directories, matching digests, and supplied JSON remain unauthenticated.

The fresh origin may reflect lawful store-directory metadata changes completed
before acquisition. It authenticates the current read by itself. A mutation
during the acquired read refuses stale. The archived source origin never
authenticates a new read and no reread refreshes the qualifying sandbox receipt's
original `terminated_at`.

## History and decision rules

The normalized observation contains exactly repository, default branch, baseline
and current snapshots, first-parent commits, publisher pull requests, and branch
rules. Compare its repository and immutable branch identities with the held
request. Require R to be the authenticated current default-branch tip and a
first-parent descendant of `coverage_base`.

Use the #541 held Git owner for an independent interval. Walk the exact first
parent from R through the base. Compare every commit id, parent, and tree to the
source observation in order. Compare the base snapshot only with base Git facts
and the current snapshot only with R facts. Missing, alternate-parent, duplicate,
rewritten, or caller-supplied history refuses.

For every commit, compare its own tree. No commit may change `.ystack/` or a CI
workflow. Under `ystack-evidence/`, accept only additions tied to this scope's
own publisher PR. Bind PR node/number, fixed publisher identity, base, head,
merge, source branch, scope, changed paths, and retained publisher request to the
actual Git change. Foreign, direct, rewritten, deleted, changed-existing, or
ambiguous evidence refuses. Ordinary source changes outside protected sets stay
allowed. Compare the publisher actor ref directly with the independently held
`publisher_identity_ref`; a source row cannot define or authenticate its own
expected publisher.

Replay the complete branch-rule event interval from the authenticated baseline.
After every event and at current, require the full sorted set of all rules that
apply to the default branch to equal baseline. Compare rule id, target pattern,
enforcement, bypass actors, type, and bounded canonical parameters. The four
required enforcing kinds are a minimum, not an exhaustive allowlist. Addition,
deletion, a permanent field change, or A-to-B-to-A change in any fifth kind
refuses.

Parse age from the original authenticated qualifying sandbox receipt
`timing.terminated_at`. Compare it with the authenticated current source receipt
`completed_at` at their full UTC precision. Accept only a real difference greater
than or equal to zero and less than or equal to exactly 2,592,000 seconds. Never
truncate, floor, round, or discard a fractional second; 2,592,000 seconds plus any
fraction refuses. A future or malformed value also refuses. A new source attempt,
store reread, or copied timestamp cannot refresh it.

Jq receives only the closed measured result. It emits
`scope.enablement-stale` for missing, incomplete, unauthenticated, replayed,
stale, or invalid coverage. Malformed shapes and runtime failures keep their
closed driver errors. Output remains inactive, observation-only, authority none,
enabled false, qualification unavailable, and contains no grant, tip-read,
credential, publisher, target-write, activation, or production authority.

## Same-contract fixture

Extend the #541 fixture in `scope-qualification.test.sh`; do not add a second
fixture framework. On Linux CI, reuse its unique dedicated writer, distinct
read-only consumer, consumer group, root-owned anchor, controlled store, and
actual bare Git repository. Add the optional source files and a root-owned offline
collector package only inside that disposable fixture. The outer root setup also
creates one unique fixture-only sudoers file with exclusive no-follow creation,
root ownership, mode `0440`, and one exact `NOPASSWD:NOSETENV` command. Validate
that file with physical `/usr/sbin/visudo -cf` before running the consumer. The
command permits only the consumer to become the source uid for the physical
Python, `-I -S -B`, exact held supervisor path, and final `coverage-read` argument
shown above. It has no wildcard argv, shell, `env`, alternate executable,
`SETENV`, launch role, collector command, or store-writer command.

A unique trap removes only that sudoers file, verifies it is absent, then removes
the fixture accounts and group. Prove the exact command reaches the real source
request and that an extra, missing, reordered, or replaced argument, a different
Python or supervisor, an environment assignment, `launch`, a shell, and every
writer/helper command all fail. The consumer must still fail every direct store
write, chmod, link, rename, and removal. This temporary rule exists only on the
ordinary disposable Linux CI fixture. Production and the current development Mac
install no rule. The macOS positive waits for a separately verified disposable
host with an already authorized equivalent exact-command setup.

The fixture collector is the authoritative offline forge. Its physical package
contains pinned raw repository/default-branch, PR, and full rule-history pages.
The root-owned config selects them and one fixed fixture publisher identity ref.
The evaluator caller cannot name, replace, or supply a page, cursor, source
observation, publisher expectation, or accepted identity. Run the actual consumer
under the read-only identity and the actual source supervisor and collector under
the dedicated source principal. Prove a matching raw PR actor passes and a changed
or foreign actor refuses while the held publisher expectation remains unchanged.

Build real Git commits A, ordinary source B, own-publisher evidence C, and current
R. The source pages and bare Git facts must agree on the complete first-parent
interval. Keep `.ystack/`, workflows, and the complete applicable branch-rule set
unchanged. Include the four required enforcing kinds and an unchanged fifth kind.
Use identical closed coverage identity and freshly derived current refs.

For the exact 30-day positive and its one-second neighbors, use the real UTC time
written by the source supervisor. Create a fresh qualifying fixture and fresh
source attempt for each case. Start just after a second boundary and permit at
most eight new attempts within 120 seconds solely to obtain the intended exact
delta. Retain every failed attempt and record both authenticated timestamps for
each. If no attempt matches, the test fails. Never reuse a nonce, alter a completed
receipt, patch or truncate the clock, pass a time environment variable, or treat
an unmatched attempt as a skip or pass.

Prepare the same fixed fixture and cases for macOS. Run them only on a verified
disposable evidence host whose owner already authorized root setup, account/group
lifecycle, anchor, and physical runtime. This plan does not create or install
that environment. Until it exists, ordinary code and tests may be prepared, but
the macOS real positive and G3 remain blocked. A mock, same-uid tree, copied
origin, permanent refusal, or skipped test cannot replace either platform's real
positive.

## Proof and completion

Besides the real positive, cover every spec R9 case:

- exact write pair; each partial and mixed pair; read-only exact-revision positive
  and cross-revision refusal; forged coverage fields cannot select the class;
- every closed-identity field and every current-derived ref changed separately;
- absent/duplicate/foreign/unproven source config and accepted identity; changed
  supervisor, source package, collector, normalizer, query schema, publisher
  expectation, anchor, store, owner, group, mode, ACL, link, descriptor, request,
  expectation, nonce, attempt, receipt, manifest, page, cursor, observation, and
  final recheck;
- replay of the first genuine attempt during a second same-R evaluation, followed
  by a new genuine attempt that passes;
- another repository/default branch; non-descendant and second-parent paths;
  missing, duplicate, reordered, alternate, and incomplete first-parent history;
- protected Git changes; direct, foreign, rewritten, deleted, changed-existing,
  wrong-PR, wrong-publisher, wrong-base/head/merge/path evidence; legal ordinary
  source changes remain allowed;
- branch-rule add/delete and every field change; permanent and A-to-B-to-A changes
  in the fifth kind; the unchanged five-kind interval passes;
- age one second before, exactly at, and one second after 30 days, plus future and
  malformed values; qualifying reread preserves the original time;
- collector timeout, signal, nonzero, oversized or malformed frame, partial store
  write, receipt failure, cancellation, exact group cleanup, and unique reap;
- no target write, publication, credential, network call, production config,
  accepted production identity, activation, or capability/profile change.

Preserve every #541 core positive and negative. Run and retain complete output on
the exact implementation head for:

```sh
bash scripts/test/scope-qualification.test.sh
bash scripts/test/sandbox-launcher.test.sh
bash scripts/test/shadow-enforced.test.sh
bash scripts/test/shadow-write.test.sh
bash scripts/test/shadow-self-host-evidence.test.sh
bash scripts/test/sandbox-receipt.test.sh
bash scripts/test/local-git-materializer-protocol.test.sh
bash scripts/test/local-git-materializer-adapter.test.sh
bash scripts/test/portable-core-schema.test.sh
bash scripts/test/run-all.sh
```

Run the materializer protocol and adapter suites shown above and every related
integration test discovered by the existing full runner. Do not create an alias
for an absent aggregate test name. Run the real principal proof on Linux and
macOS and record OS, filesystem, uid/gid/groups, ACL, timestamps, source package
and exact head. Dispatch the six-shard full matrix from that head and require all
shards, checks, aggregate CI, and external required checks green. Quick CI is
additional evidence only.

Before publication, run `git diff --check`, compare the diff with this exact path
list, verify intent/spec/plan blobs and risk, require the new manifest entry once,
and prove tracked production config, registry, accepted set, workflow, capability,
profile, and duty files did not change. A separate read-only reviewer reads the
complete exact-head/base diff and raw proof. Resolve every Important finding. The
named manager alone performs the protected merge and records the receipt. No
artifact, test, fixture, or merge may claim native qualification, enablement,
production source availability, or child 7 completion.
