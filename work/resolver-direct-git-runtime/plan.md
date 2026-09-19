---
spec-blob: 23fd320f594edc983a19fc71381d6b87fe9864d4
drafted: 2026-09-14
---
# Plan: Direct Git selection for the resolver runtime

Tracks #316. Risk: high. Gate mode: artifact-high.
Spec PR #320 merged as 241b6babb1fe08dfb9a12d7bc8b22299a9c628f8.
The accepted intent is a495d935a4dd1907bac4b30a18f52cff81550893.
This plan changes no code. Independent acceptance and protected plan merge precede
implementation on `ystack/impl/resolver-direct-git-runtime` from that plan-base.

## Files that change

Exactly three existing restore-listed files may change during implementation:

| File | Change |
| --- | --- |
| `scripts/lib/profile-resolution.sh` | One private platform initialization boundary and selected Git at all five executable positions. |
| `scripts/test/portable-profile-resolution.test.sh` | Preserve all 47 cases and assertions; add bounded capture controls, real cleanup/output/identity proof, and initialization in the two Git-using internal helper bodies. |
| `docs/components.md` | Fixed installed platform dependencies, actual proven native tuples, inactive status and separate trusted-parent work. |

Keep the runtime wrapper, jq helper, native helper, fixture builder, C test launcher,
core artifacts, workflows and restore manifest byte-identical. No new helper file,
public selector, test environment option or committed generated evidence is added.
Do not edit the accepted artifacts or the preserved #271 attempt.

Review size: accepted-exception, proposed 550–900 net implementation lines. The
estimate is 100–160 library lines, 430–710 focused-test lines and 20–30 documentation
lines. All are one dependency repair. The existing test is 746 lines; new producer,
reader, byte-identity, file-predicate and actual launch checks need readable fixtures.
This is an estimate, not measured output or permission to omit coverage. Record the
actual size before review; unexplained excess returns through separate plan review.
Do not compress code, remove original assertions or count a broad new concern here.

## Order of work

### 1. Bind the accepted inputs and write the failing controls

Before the first code commit, fetch default and require the recorded plan-base.
Use the sole current build claim on #316 and a clean deterministic implementation
branch. If base moved before code, obtain the separate unchanged-plan refresh first.
Preserve any existing branch rather than rewriting it. The implementation author
is separate from this plan author and its independent reviewer.

Record original blobs from the accepted source:

- Library: 966c0aef858676c890f7cea2f911b196a7de9331.
- Focused test: 615b9c4560e55f8d38a9e20575134a9b4221f68d.
- Runtime wrapper: 54e174128a9f2f1a13ea17794d54696698b72eec.
- Jq helper: 9004cb7bd38fc165d8b1414786a520af23cfb9b3.
- C test launcher: f4de7e48c688b6adb3669f69a221d2aa7bf43b15.

The first test commit establishes the new private-boundary checks and real directory
assertions. Retain its initial failure and exact source/head identity. A missing new
function is valid first red evidence but does not by itself demonstrate a repaired
native startup. Do not rerun an unchanged native failure until it happens to pass.
Existing native failure records remain available; do not delete or prewarm caches.

### 2. Implement bounded observation and closed selection

Add private functions with fixed roles, all in the library. Sourcing defines them
without executing uname, Git or file operations. Keep them private and unreachable
through caller options. Tests may replace only these narrow observation/predicate
boundaries in fresh sourced shells; the real launcher supplies no caller functions.

Use separate narrow stages for fixed uname invocation, bounded reading and decimal
encoding. Production stages execute only `/usr/bin/uname -sm`, `/bin/dd bs=1 count=65`
and `/usr/bin/od -An -v -tu1`, respectively. Their arguments are constants, not a
caller-provided command list. Stage separation permits a test to fail one actual
pipeline position without replacing the entire selection or the installed tool.
A paired positive uses the real reader and encoder. Do not create a generic tool
broker, PATH search or reusable command execution API.

The private observer runs in a subshell. Set pipefail explicitly there regardless
of the sourcing caller's options. Declare variables separately from the checked
assignment. Capture the three-stage pipeline in an explicit conditional; it must
remain the final command inside that inner capture so no later success masks its
status. Any stage failure refuses, including valid-looking output with nonzero
status. Suppress raw tool stderr at this boundary; only the initializer emits the
existing dependency diagnostic. The containing shell's option state must not change.

`dd` bounds raw bytes delivered to `od` before any shell allocation. Its one-byte
records avoid a short pipe read being mistaken for an entire large record. At most
65 raw bytes reach the encoder; its decimal representation is therefore bounded.
Never capture raw uname bytes directly or decode the decimal text back into a raw
shell string. NUL is decimal 0; LF is decimal 10, so command substitution removing
od's formatting newline cannot erase the original byte distinction.

Inside the observer subshell, set a fixed ASCII whitespace IFS and disable globbing.
Split only the bounded decimal rendering. Reject zero tokens or more than 64. Check
each token as canonical decimal 0–255 without eval or arithmetic on unchecked text;
reject malformed test-seam output. Build one normalized space-separated decimal
sequence with shell builtins. Do not use a here-document, here-string, file, cache,
process substitution or scratch directory to carry the probe. Emit the sequence only
on success. Local parsing options stay inside this subshell.

The initializer first clears the private selected-Git value. Use a private predicate
requiring a regular executable final path which is not a symlink for uname, dd and
od, before using them. Their fixed containing OS directories remain trusted, as in
the spec. Observe and match the entire normalized sequence against the three exact
raw byte strings in R1: Linux x86_64 LF, Darwin x86_64 LF, Darwin arm64 LF. Generate
those literal decimal sequences from the specified bytes during implementation and
independently compare their meaning in review; never derive supported rows at runtime
from another platform observation.

Select only `/usr/bin/git` for Linux and
`/Library/Developer/CommandLineTools/usr/bin/git` for either Darwin row. Validate
that exact selected file with the same predicate before assigning the final private
selection. On any failure leave selection empty, stdout empty, return nonzero and
emit exactly `E_RUNTIME dependency` plus LF via the existing FD 3 error boundary.
An earlier selection, misleading inherited variable or failed second initialization
must not survive. No environment, file presence, discovery command, alternate Xcode,
version probe, fallback or installer may select Git.

The bound is on bytes entering od/shell allocation, not all kernel pipe bytes a
finite producer may emit. A producer can block or keep its pipe open; the existing
300-second supported launcher bound governs. Do not add or claim a probe watchdog.
Component fixtures use finite terminating producers. Sourced component calls have
no independent timeout; they do not inherit the C launcher’s public time bound.

### 3. Wire the actual runtime and private Git callers

Call initialization in main after the existing usage, trusted marker, helper, jq and
bound-awk checks, and before scratch creation or any Git call. Keep all other existing
dependency checks. Remove the unselected `/usr/bin/git` from the generic inventory;
the initializer validates the selected path. It may already have validated dd/od,
but preserve their dependency guarantee and do not change unrelated checks.

Change only the executable token at these five sites, quoting the selected value:

1. The existing `exec` in `profile_resolution_git`.
2. Startup hash-object of `scripts/core-contract.sh`.
3. Startup hash-object of the selected generation registry.
4. Startup hash-object of that generation's `contracts.jq`.
5. Startup hash-object of that generation's `core-ingress.sh`.

Retain all arguments, environment, redirects, status handling and four expected blob
comparisons. Preserve every current core merge/generation/receipt/schema constant,
limits, object verification, NUL parsing, private repository rule and SHA format.
Keep the Git wall/CPU watchdog and exact owned-child lifecycle unchanged.

In the test, initialize the real boundary after sourcing in
`expect_internal_budget_failure` and `expect_cache_reuse`, before their actual
Git-backed calls. Establish FD 3 correctly and refuse failed initialization. Keep
all three budget invocations, zero-debit second cache hit and same-inode assertion.
Do not initialize the unrelated internal scratch-ledger or accounted-core helpers.

### 4. Add component proof without changing installed tools

Each component runs the actual library in a fresh Bash process. Start with caller
pipefail off; repeat successful and failing status controls with it on. Prove that
sourcing does not probe and that initialization leaves the caller's pipefail, IFS
and globbing settings unchanged. Product main and private tests use the same logic.

Use byte fixtures produced directly by builtin printf or finite fixture files, not
lossy shell capture. Producer controls flow through the real bounded reader/encoder.
An observation-string replacement alone proves only selector behavior. Narrow reader
and encoder wrappers may supply exact failure statuses while forwarding through their
real fixed stage; pair them with genuine success. No installed tool is altered,
shadowed, chmodded or removed to simulate dependency absence.

| Group | Actual required assertions |
| --- | --- |
| Accepted rows | All three exact byte rows select their fixed path; corresponding unsupported OS/arch cases refuse. |
| Byte identity | Empty, absent LF, doubled LF, extra line, prefix/suffix, embedded/prefix/suffix NUL, non-ASCII and truncated output refuse. |
| Bounds | 64, 65 and a finite longer raw byte fixture all refuse; confirm real reader hands no more than 65 bytes to encoder and the 65th byte is retained as overflow witness. A 64-byte string is not a valid platform. |
| Pipeline status | Each of producer, reader and encoder emits a supported-looking result but returns nonzero; actual initializer refuses with caller pipefail off and on. Pair each failure with success and verify the stage was reached. |
| Rendering | Malformed decimal, noncanonical token and value outside 0–255 refuse through the actual observer's parsing boundary. Preserve valid real-od positives. |
| File predicates | For uname, reader, encoder and selected Git: missing, nonregular, nonexecutable and symlink outcomes each refuse; paired valid-file control reaches observation/selection. |
| State | Inherited misleading selection cannot select Git; successful initialization followed by a failing one clears selection. |
| Error contract | Every refusal has nonzero status, empty stdout, exact one-line sanitized stderr and no following Git-use operation. |

The file-predicate seam supplies conditions only; it cannot replace the table or
initializer. Review its actual fixed predicates independently. Instrumenting a test
Git-use sentinel proves the component does not advance after a refusal; it is not a
trace of the public child. Keep evidence types labelled throughout the test output.

### 5. Extend actual launcher proof and retain every original case

Use the unchanged compiled C test launcher and existing setup. Finish fixture graph,
compilation, pinned jq preparation and source fingerprinting outside runtime HOME and
TMPDIR. Record actual platform and SHA-256 identities of uname, selected Git, Bash,
pinned jq, compiled launcher and native helper, plus runtime/library/helper source
blobs and hashes before/after the measured launches. No version-name-only proof.

The launcher exclusively creates each sandbox's home/tmp. Use a new outer sandbox
for every launch. Assert both directories exist, remain real directories and have no
entries after completed runtime execution and before cleanup. Inspect their entire
contents, not just the runtime scratch subdirectory. Retain raw child.stdout and
child.stderr alongside public output/status, outside these two directories.

Keep the existing normal positive's complete core validation. Run that exact same
request/map/input graph again in a fresh sandbox; compare full canonical bytes and
empty raw/public success stderr. Extend both bare and linked-layout positives and
repeat each with the same input map/request in another fresh sandbox. Compare each
layout's full output to the original normal result and inspect its own home/tmp.
Reusing input is required; reusing the exclusive sandbox is not permitted.

For malformed JSON and the valid request with an absent selected object, preserve
the existing expected error and ordering, then assert exact raw/public diagnostics,
nonzero status, no raw/public stdout, and empty home/tmp. Add the same directory and
raw-error evidence to the existing real Git-wall refusal while preserving its actual
less-than-ten-second and exact-child assertions. Report supervisor-forced termination
controls separately; do not require or claim completed shell cleanup after SIGKILL.

Keep full repository fingerprints before/after. Compare a retained old-runtime output
only if it belongs to this exact fixture graph. Do not regenerate an old baseline
through edited code. Fresh/reused/layout comparisons and the real core validator
remain mandatory even when no same-graph old output is available.

The complete original execution inventory is below. Preserve helper bodies and all
intermediate assertions, not just these pass labels. Types: L actual resolver via C
launcher; S supervisor control; C internal component; H direct native helper; D data
assertion; F complete source/repository fingerprints.

| # | Test label (verbatim) | Call/assertion lines | Kind / principal assertion |
| --- | --- | --- | --- |
| 1 | symlinked ambient awk is ignored | 460–461 | L; E_PARSE despite poisoned ambient PATH |
| 2 | missing required dependency is sanitized | 462;299–319 | L; E_RUNTIME dependency, no stdout, disposable helper actually removed |
| 3 | launcher sanitizes silent child failure | 464;256–274 | S; E_RUNTIME unexpected |
| 4 | launcher converts file limit to a token | 465;256–274 | S; E_LIMIT resource-limit |
| 5 | launcher bounds its process group | 466;256–274 | S; E_LIMIT process-limit |
| 6 | launcher bounds each process virtual address space | 467;256–274 | S; E_LIMIT resource-limit |
| 7 | Git wall watchdog kills and reaps the exact child | 468;276–297 | L; E_LIMIT time-limit, empty stdout, elapsed<10s |
| 8 | one pre-write ledger admits exact bytes and rejects one over | 469;402–425 | C; status0/50, scratch-size, unchangedremaining0, no over-limit file |
| 9 | core scratch receipt is exact and debited from the parent ledger | 470;427–452 | C; actual core validation, positive bounded debit, empty error |
| 10 | cache hits reuse one snapshot without another byte write | 477;366–400 | C; two actual Git-backed payload checks, statuses0/0, both budgets0, same inode |
| 11 | per-value budget keeps E_LIMIT | 478–479;322–364 | C; SHA256 large object, status50/value-size and exact public token |
| 12 | aggregate value budget keeps E_LIMIT | 480–481;322–364 | C; SHA1 object with value budget1, status50/value-size |
| 13 | global scratch budget keeps E_LIMIT | 482–483;322–364 | C; SHA1 object with global budget1, status50/scratch-size |
| 14 | request and repository-map transport remain version 1 | 486–489 | D; both real fixture version fields1 |
| 15 | cross-hash multi-repository resolution and real core validation | 490–510 | L; empty successstderr, no loader marker, schema2 refs, resolved_profile kind, actual core validate-profile-set |
| 16 | bare repositories resolve the same exact graph | 512–516 | L; full cmp against normal output |
| 17 | linked worktrees resolve the same exact graph | 518–522 | L; full cmp against normal output |
| 18 | one-segment path verifies its root tree before enumeration | 524–529 | L; actual one-segment resolved_profile |
| 19 | NUL tree parsing matches a quoted path as raw bytes | 531–536 | L; quoted-path resolved_profile |
| 20 | newline path is rejected without confusing tree parsing | 537–538 | L; E_INPUT locator-shape |
| 21 | bare repository rejects config include | 540–545 | L; E_REPOSITORY config-include; restore fixture config afterward |
| 22 | linked worktree rejects a broken gitfile | 547–552 | L; E_REPOSITORY gitfile; restore fixture gitfile |
| 23 | corrupt root tree fails before one-segment walk | 554–569 | L; actual corrupt loose root tree, E_OBJECT object-path; restore bytes/mode |
| 24 | unquoted inline comment is accepted and quoted comment characters stay literal | 571–580 | L; real modified valid config, exact cmp |
| 25 | quoted comment text is not stripped from storage format | 582–586 | L; E_REPOSITORY storage-format |
| 26 | map/source order and physical scratch do not affect output | 588–595 | L; reverse both relevant arrays, exact cmp |
| 27 | selected content remains inert and private | 597–601 | D on L output; no opaque token/private root leak or execution marker |
| 28 | caller-owned scope refs are copied unchanged | 603–607 | D on L output; exact selection_ref/repository_context_ref |
| 29 | runtime payload is inactive mode 0644 | 609–614 | D; platform stat exact644 |
| 30 | malformed request before map access | 616–618 | L; E_PARSE with absent map |
| 31 | zero manifests has fixed precedence | 620–622 | L; E_INPUT manifest-count with absent map |
| 32 | nine manifests has fixed precedence | 624–627 | L; E_INPUT manifest-count with absent map |
| 33 | noncanonical request | 629–631 | L; E_CANONICAL |
| 34 | locator map missing | 633–637 | L; E_REPOSITORY locator-map-missing |
| 35 | unused map rejected after source join | 639–643 | L; E_REPOSITORY map-extra |
| 36 | wrong selected object id | 645–648 | L; E_OBJECT object-path |
| 37 | revision expressions fail before Git | 650–654 | L; E_INPUT locator-shape |
| 38 | duplicate logical map id | 656–660 | L; E_INPUT map-shape |
| 39 | request one byte over transport limit | 662–666 | L;1MiB+1 raw bytes, E_LIMIT |
| 40 | selected value over per-value limit stays E_LIMIT | 668–669 | L; E_LIMIT value-size |
| 41 | manifest source join reports missing | 671–675 | L; E_RELATION manifest-source-missing |
| 42 | symlinked mapped root | 677–683 | L; E_REPOSITORY root |
| 43 | physical repository paths stay out of errors | 685–699 | L; nonzero, emptystdout, no secret-canary/physical root error text |
| 44 | mapped config include stays inert | 701–706 | L; E_REPOSITORY config-include |
| 45 | replacement refs fail before private Git | 708–714 | L; E_REPOSITORY replacement-state; fixture ref removed afterward |
| 46 | native helper enforces budgets before publish | 716–727 | H; actual snapshot-repository budget1, no stdout/published destination, E_LIMIT |
| 47 | refs, config, and object stores remain byte-identical | 729–739 | F; complete before/after fingerprints match |

### 6. Document and deliver only the proven inactive runtime

Describe the fixed installed paths and failure behavior in docs/components.md.
Name actual tested Linux and Darwin architecture tuples and tool identities in the
PR evidence; a table row does not qualify an untested Darwin architecture. State
that the production trusted parent and profile pins remain separate and inactive.
No live sync, install, target run or cache exception follows this repair.

Record an executable-position inventory showing five initialized Git calls, four
unchanged expected OID comparisons, selected dependency validation and the two
internal initializer sites. Do not ban all literal /usr/bin/git text: it is the
valid Linux table value and existing fixture setup. Independently review the full
diff for unchanged arguments, watchdog ownership, budgets and closure identities.
A static source inventory is not a dynamic execution trace.

## Risks

The riskiest change is rejecting a dependency failure without changing earlier
error precedence or letting successful pipeline output hide a failed stage. The
component controls must exercise the actual capture, not replace it wholesale.
Fixed finite reading and local pipefail avoid lossy command substitution and
caller-option assumptions. The bounded capture still relies on existing launcher
limits for stalled tools; no tighter time promise is made.

The direct CLT Git is an installed platform dependency, not a portable discovery
rule. A missing or incompatible installed tool refuses. If actual native execution
leaves any cache or fails a required boundary, preserve the first failure and pause
for the affected artifact decision. Do not introduce fallback, shared-cache cleanup,
prewarming, retries or a weaker emptiness standard to make the evidence green.

A changed library invalidates the preserved trusted parent's future library pin.
Do not update or resume #271 here. That initiative must independently reconcile its
artifact hashes, source closure, fixed uname/Git dependencies, 18 blob checks, three
constants and R1–R10 before its own implementation can continue. This PR cannot
accept the prior cache proposal by inference.

The simpler alternative of always invoking the Darwin shim retains the observed
startup residue. PATH/discovery broadens selection authority; capturing raw bytes
before truncation loses NUL/LF identity and the allocation bound. A whole fake
launcher cannot prove the real installed dependency. These alternatives are rejected
within the accepted design, not added as private fallbacks.

## Proof

Run from the exact implementation checkout. Preserve commands, full raw output,
exit codes, source/head/base, fixture phase and platform/tool identities. Initial
red evidence remains alongside green evidence. No source change may reuse stale
native or CI proof without determining and reviewing its actual effect.

1. `bash scripts/test/portable-profile-resolution.test.sh` on the available Darwin
   host: all 47 original cases plus every added component/actual-launch group above.
   Record the original case count separately from the added assertions. Actual
   fixed uname/Git must run through the unchanged launcher. Unsupported native
   dependency is a blocker, not a skip or invitation to install one.
2. The same full test through existing Linux x86_64 CI. Read the actual suite output,
   platform/identity records and cleanup checks; do not infer Linux from Darwin or
   infer an untested Darwin architecture from the mapping table.
3. `bash scripts/test/portable-core-schema.test.sh`, `bash scripts/check-rename.sh`,
   and `bash scripts/test/run-all-sharding.check.sh` (the actual CI sharding proof).
4. Use pinned ShellCheck 0.11.0 with `-x -S style` on all repository shell files and
   `git diff --check`. Run the existing structure/required-files check and confirm
   all three changed sources remain covered. No manifest edit is expected.
5. Publish one bounded PR with the full measured size and native proof. Run all
   required CI (checks, six test shards and aggregate ci) on the exact head/base.
   Compare the actual tracked test inventory to the full shard logs; each script
   must run once. Fresh independent Bugs/Security/Compliance review includes the
   full source inventory and all R1–R5 evidence. Resolve every Important finding.
6. The named Roadmap manager reads the entire independent verdict, rechecks exact
   head/base, scope, CI and protected state, then performs a normal protected merge
   and records its actual receipt. Use the terminal intake reference only on that
   implementation PR; this plan uses Tracks #316 and leaves the intake open.

The final result is this inactive runtime dependency repair. It does not qualify
self-hosting, external targets, the trusted parent or a live execution environment.
