---
spec-blob: 1aa98f5b467bbca0ee01d45f105129737ea24422
risk: high
drafted: 2026-10-11
---
# Plan: inactive shadow-consumer integration

Tracks #506. This implements Step-8 child 5 under the accepted spec. The authoring base
is `9295d658405afaae98cfea724fba24184f271fe1`; base movement is external context, not
permission to change meaning. Intent blob: `6feb2ad7dd5f096bdd483ed9bace07cae2c24be5`.

Plan PR: `review_size: accepted-exception`, 900–1200 lines. The five-slice contract,
closed native context, fixed native signal checkpoint, direct-result release and
State-owned child handoff, and the fixed writer-child roles need one coherent
implementation brief. The range keeps complete signal/fd/platform and fixed
child-lifecycle proof readable and changes only the soft size budget.

## Files that change

Only `work/shadow-consumer-integration/plan.md` changes in the plan PR. The five
implementation slices keep their accepted order. Slices 1 and 2 retain their landed
scope; slices 4 and 5 keep their accepted scope and order. SC-CANCEL-3 repairs slice 3
on the original branch and PR only; it does not create another implementation attempt.
The first four track #506; only the fifth closes it.

| Slice | Exact implementation paths, excluding the common documentation set |
| --- | --- |
| 1 — bound evaluator/checker | `control/v1/sandbox-bound-policy.json`, `control/v1/sandbox-bound-decision.json`, `control/v1/control-policy-set-sandbox-bound.json`, `control/v1/evaluate-bound-sandbox.sh`, `control/v1/sandbox-bound.jq`, `enforcement/v1/check-sandbox-receipt.sh`, `enforcement/v1/sandbox-receipt.jq`, `scripts/test/control-sandbox-bound.test.sh`, `scripts/test/sandbox-receipt.test.sh`, `scripts/test/portable-core-schema.test.sh` (only the spec R10.9 expected-path addition) |
| 2 — trusted dependencies and origin reader | `shadow/v1/_consumer.py`, `scripts/test/shadow-enforced.test.sh` |
| 3 — enforced reproduction | `shadow/v1/_cancel_release.c`, `shadow/v1/build-cancel-release.sh`, `shadow/v1/_consumer.py`, `shadow/v1/enforced-reproduction.py`, `scripts/test/shadow-enforced.test.sh` |
| 4 — add-only materialization | `shadow/v1/_cancel_release.c`, `shadow/v1/_consumer.py`, `shadow/v1/enforced-reproduction.py`, `shadow/v1/write-shadow.py`, `shadow/v1/write-materialization-input.jq`, `scripts/test/shadow-enforced.test.sh`, `scripts/test/shadow-write.test.sh` |
| 5 — withheld request and complete integration | `shadow/v1/_consumer.py`, `shadow/v1/write-shadow.py`, `scripts/test/shadow-write.test.sh`, `scripts/test/shadow-enforced.test.sh` |

The common documentation set is exactly `docs/components.md`, `RESTORE.md`, and
`ci/required-files.txt`. The SC-CANCEL-3 slice-3 repair therefore has exactly eight
paths: its five table entries plus this three-file set. In `ci/required-files.txt` it
only appends the two native files. `scripts/test/shadow-slice.test.sh` remains prior
slice history and is not a repair path. Each other slice may change only its accepted
component descriptions and manifest entries. Keep shell drivers/tests executable.
Intermediate entry points refuse operations whose remaining checks are not implemented;
they cannot emit a completed write bundle early. No other source or accepted artifact
changes. Slice 4 has exactly ten paths: its seven table entries plus the common set.

The current SC-CANCEL-6 repair claim is the exact seven-path subset
`shadow/v1/_cancel_release.c`, `shadow/v1/build-cancel-release.sh`,
`shadow/v1/_consumer.py`, `shadow/v1/enforced-reproduction.py`,
`scripts/test/shadow-enforced.test.sh`, `docs/components.md` and `RESTORE.md`.
The build script removes the obsolete PAC flags from the same fixed physical-P
recipe. `_consumer.py` retains only the native ACL/qualifier repair and fixed Darwin
UUID/group-reader, GID short-circuit and parent comparison owner closure below. The
driver and native module implement the fixed blocked-work/checkpoint owner described
in section 5. This amendment does not claim `ci/required-files.txt`.

| Slice | Classification | Net-line range | Evidence for the estimate |
| --- | --- | --- | --- |
| 1 | Accepted exception | 1000–1200 | Closed R10 evaluator with bounded snapshots and full refs; shared checker preserving legacy outputs; paired binding and compatibility tests, fixed data and restore docs |
| 2 | Accepted exception | 1200–1400 | Complete installed-byte/verifier binding, full ancestor/ACL/store validation, and meaningful trust-boundary regression proof |
| 3 | Accepted exception | 4200–7500 | The preserved candidate plus the private C/build boundary, context/provenance and ledger repairs, the fixed native signal owner/checkpoint, the State-owned child owner, and complete negative/positive and actual-native paired proof remain one enforced-reproduction concern. |
| 4 | Accepted exception | 1200–1700 | Full frozen-bundle, input, patch, digest and candidate-tree relations with real materializer proof |
| 5 | Accepted exception | 700–1100 | Complete two-attempt admission and integration proof, including withholding, determinism and source/store purity |

If the complete readable change cannot fit its accepted slice, stop before an
unexplained overrun and return through the plan gate. Do not remove proof or create
extra parallel initiatives. No bootstrap, workflow, installation or policy-authority
change is included.

The slice-3 estimate includes the native source/build boundary; Python context,
provenance, ledger and release work; completion-fd and authoritative-outcome proof;
the fixed native signal handler/checkpoint, actual binding and driver call; the
State-owned child owner and its complete lifecycle validation; complete negative/positive
and actual Mac/Linux paired proof; and the required docs. The range leaves bounded room
for readable integration tests without compressed code or omitted proof.

## Order of work

### 1. Fixed bound control tuple

Implement spec R10 before any consumer entry point. The new fixed files are the
normal path for this complete declaration; do not normalize claims into legacy
placeholder claims or import an executable legacy jq program as a module.

- Start the bound policy from the legacy policy's exact fields. Replace only the
  tool's `sha256` with R10.2's closed `identity_binding` object. Keep the logical
  policy/decision IDs and all non-sandbox policy-set sections unchanged. Give the
  bound set its specified separate ID.
- `evaluate-bound-sandbox.sh evaluate DUTY CLAIM OBSERVATION` has four arguments.
  Its paths are fixed relative to its reviewed package, including the accepted set
  and registry. Snapshot canonical documents, reject duplicate keys, and use the
  existing pinned jq identities before executing jq. Fixed inputs are at most
  1 MiB each; existing depth/member/string caps remain in force.
- `sandbox-bound.jq` checks the complete claim, duty and observation shapes. Reuse
  the generic policy-set validator; retain the claim and duty predicates' exact
  semantics from `control/v1/sandbox.jq`. Compare the complete fixed declaration,
  substituting only measured verifier digest d in the expected tool object.
  Unsupported/partial values cannot satisfy the bound evaluator.
- Validate the same-bound-set duty refs, core contract, policy/decision refs, exact
  duty document digest and claim-to-duty stage-result relation. The observation
  envelope and five body fields are exactly spec R10.3. Its environment equals
  claim.id; entry hash, target repository and accepted-set hash identify one
  unambiguous registry/accepted entry. Require measured d = claim tool digest =
  observation verifier digest and d in that entry's verifier list.
- Emit the unchanged `sandbox_policy_evaluation` schema-1 envelope and existing
  body fields, plus `verifier_binding` containing the observation body and hash.
  Use the spec's closed satisfied/refused reason IDs. Malformed references or
  fixed-byte drift fail without output; a valid incomplete declaration is
  inconclusive. This remains declaration-only with both effects `none`.

Build hashes in this order: evaluator driver/program and policy; then the new
fixed decision, including unchanged validator driver/program refs; then the bound
policy set; finally checker pins. Compare full refs, including IDs/media types.
Do not make a source file pin its own final digest. The trusted consumer/checker
closure pins the tuple; the evaluator checks its measured source pair against the
fixed decision and its fixed validator dependencies before producing a result.

Add `check-bound RECEIPT EXPECTATION EVALUATION OBSERVATION` as the only new checker
verb. The shell driver selects the fixed bound files and passes an explicit internal
mode to jq; caller documents never choose that mode. Factor shared receipt shape,
accounting and outcome predicates in the existing checker, retaining `check`'s
original output bytes for original inputs. The bound branch validates the additional
observation/result relation and the fixed bound tuple, without relaxing legacy pins.
Require receipt verifier `{state:"observed",sha256:d}`, not just membership. Preserve
all existing subject, attempt, store, accepted-set, mechanism, limit and verdict checks.
The checker continues to report no origin authentication.

### 2. Trusted parent context and dependency snapshots

Keep the spec's CLI argument lists unchanged. The trusted parent supplies the helper
and native acceptance context on inherited descriptor 3, opened read-only before
launching the consumer. It is not a REQUEST field, environment lookup, candidate file
or runtime approval prompt. The descriptor is a channel from the already trusted caller,
not independent authentication of an arbitrary caller. An untrusted party able to launch
a different consumer or forge its parent's context is outside this invocation trust
boundary; candidate/request data must never obtain that ability.

The context is canonical JSON, at most 16 KiB, with exact envelope
`{schema_version:2,kind:"shadow_consumer_parent_context",id:"shadow.parent",body}`.
The body has exactly `helper_source_sha256`, `helper_build_record_sha256`,
`helper_executable_sha256`, `helper_executable_size`, `helper_path`, and
`native_release`. Keep the accepted helper field types and bounds exactly. The native object
has exactly `source_sha256`, `build_script_sha256`, `build_record_sha256`, `binary_path`,
`binary_size`, `binary_sha256`, `python_path`, `python_sha256`, `python_abi`,
`dependency_record_sha256`, and `loader_mode`. All digests are lowercase SHA-256; `binary_size`
is 1–16 MiB in bytes; both paths are physical and absolute; `python_abi` is 1–128 printable
ASCII bytes; and `loader_mode` is `rtld-now-local.v1`. Missing descriptor, writable fd,
unstable bytes, wrong schema, extra/missing/duplicate fields, noncanonical input, bad bounds
or an unaccepted identity exits 1 with `E_PARENT_CONTEXT` before executable effects.

Before starting the consumer, the trusted parent reviews the committed
`adapters/local-git-materializer/v1/object-closure.c`, the compiler/build inputs and
the resulting executable. Its retained build record binds source bytes, compiler
identity, argument vector and resulting bytes; the parent supplies the accepted
record digest and executable identity. Tests compile the existing source using the
existing fixture build recipe. Product execution does not compile, fetch, provision
or approve a helper. Real provisioning still needs its separate authority.

`_consumer.py` consumes descriptor 3 before opening REQUEST. Require an ordinary
read-only file descriptor, bounded stable contents and exact context shape; reject
missing or writable descriptors. Close it after capture and do not inherit it in
children. Pin the reviewed helper source digest from this plan's accepted source
base in the implementation:
`f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27`.
Independently verify the package source equals that pin. A different build may be accepted by the trusted parent only from this source.
The context's result digest is an acceptance input; recomputing a request-selected
binary digest does not create acceptance.

The native recipe is private and fixed:
`/bin/bash -p S/shadow/v1/build-cancel-release.sh build P OUT`, where S and P are
reviewed physical paths and OUT does not exist. The script accepts no environment
compiler or flag override. It creates OUT mode 0700, reads only sibling
`_cancel_release.c`, queries P under `-I -S -B` for its include directories,
`EXT_SUFFIX`, `SOABI`, implementation/version and build configuration, and invokes
physical `/usr/bin/cc` once. Both platforms use `-Wall -Wextra -Werror -O2
-fvisibility=hidden -fPIC` plus the two captured Python include directories and fixed
source/output paths. Darwin uses `-std=gnu11` and `-bundle -undefined dynamic_lookup`.
Linux uses `-std=c11` and `-shared`. Neither platform uses the former PAC flags or
ptrauth header; there are no signed allocator-slot observations to authenticate.
Production and every compile-time test build use the same platform
recipe. Any other platform or empty/nonphysical sysconfig value refuses. OUT ends
with exactly the extension and canonical `build-record.json`; no install or import is
performed by the recipe.

The build record is at most 1 MiB and has one schema-1
`shadow_cancel_release_build_record` envelope. Its body has exactly platform and
architecture, source/build-script digests, compiler physical identity/digest/version
digest, complete argv and its digest, P locator/digest/implementation/version,
SOABI/EXT_SUFFIX/configuration, output name/size/digest and `test_build:false`. The trusted
parent compares each value to captured bytes, separately accepts the dependency record, then
supplies the closed context. Production never calls this script; test builds in a fresh
private directory have no native admission authority.

The consumer compares the complete actual compiler argv to this fixed recipe and
rejects missing, repeated, reordered, substituted or extra flags with E_DEPENDENCY
before native load. Production and test variants record exact source/script/compiler,
P/ABI and output identities. Review the actual checkpoint, handler and sealed-release
code boundaries; their contracts cannot be inferred from compiler flag presence.
No allocator callback slot, private allocator layout or PAC probe is an admission
input. Keep actual loader/dependency provenance for the selected public signal,
spawn/wait, ACL and fixed-release effects required by this plan.

The dependency record is parent-retained canonical evidence, not a bundle sidecar.
Before creating context, the trusted parent accepts its complete contents and proof;
its digest preserves that acceptance, never establishes behavior by itself. It binds
the actual P/framework, extension, loader and relevant libc/system images, plus
the source/package/build identity used for every internal-behavior assumption and the
no-deferred-first-use call graph. Linux includes the physical ELF interpreter/loader
and libc paths, hashes and build IDs, complete binary package version and source package
revision. macOS includes P/framework and extension UUIDs, relevant image/install-name
and shared-cache UUIDs, architecture and actual JIT/build facts; `Py_ENABLE_JIT=null`
does not prove JIT disabled, and an image without separate disk bytes gets no invented
hash. Historical Linux timestamp inference and reference Apple/GNU source versions do
not satisfy this record. Missing actual identity or unresolved source correspondence
refuses that runtime; no whole-OS source certification is added.

After reading REQUEST, require its helper locator to equal the context locator.
Open the helper with held no-follow ancestors and compare metadata before/after
reading. Compare the captured bytes and size to the independently accepted tuple
before any helper execution, including the adapter's `version` probe. Copy only
those checked bytes into an exclusive file in WORK's private dependency directory;
set file mode 0500 and directory mode 0500 before use. Pass this snapshot, never
the request path, as materializer argument seven. Recheck snapshot bytes/identity
before each adapter invocation and after use; recheck the original held/name tuple
before invocation and before completion. A failed check refuses without starting
that child. Changes to the original after the last check cannot replace the
separate executable snapshot. Same-principal malicious modification of private
consumer memory/storage is outside the trusted-parent boundary, not solved by a
post-execution hash. Document that residual without granting candidate access.

Apply the same bounded-copy-before-version sequence to jq, whose expected digest
is the existing fixed platform pin. Python is the physical trusted interpreter
from the invocation; `/usr/bin/git` is the fixed Git. Load `_consumer.py` through
its verified absolute sibling location under isolated Python, not user module
search paths.

Before P starts, the parent rejects every unaccepted `LD_*` or `DYLD_*` loader
setting; clearing it after startup is not evidence. Before the first receiver census,
the driver matches `sys.executable`, P bytes and ABI to the context, snapshots the
private extension, and temporarily sets the interpreter's accepted flags to
`RTLD_NOW|RTLD_LOCAL` for that one absolute load. It completes module/type/State
initialization, symbol/method binding and the dependency record's relevant first-use
work, restores the prior non-tail loader setting, and retains strong references to the
module, State and bound methods through release. Unknown flags, identity or deferred
work refuses before effects. There is no tail import, `dlopen`, `dlsym` or `dlclose`.

Keep helper/context provenance in the existing record and never retain local paths.
`consumer-provenance.json.body.native_release` has exactly `context_version:2`,
`source_sha256`, `build_script_sha256`, `build_record_sha256`, `binary_locator_sha256`,
`binary_size`, `binary_sha256`, `python_locator_sha256`, `python_sha256`, `python_abi`,
`dependency_record_sha256`, and `loader_mode`. Locator hashes are over accepted UTF-8
physical paths; every other value equals the context.
The object adds no command row, sidecar, inventory member or authority. A frozen
enforced bundle without this exact object or matching current context refuses as stale;
the unchanged legacy reader alone may read a record without `record_form`.

### 3. Immutable installation and controlled store

Implement one private held-path reader in `_consumer.py`, used for dependencies,
installed observations and store snapshots with separate explicit rule sets. It
uses `os.open` with `dir_fd`, `O_NOFOLLOW` and directory flags, plus `fstat` and
named-entry checks. Hold ancestor descriptors until the operation finishes.
Compare device, inode, kind, uid/gid, mode, link count, size and nanosecond change
metadata before/after each read; bound bytes while reading, not after allocation.

For the production anchor, walk from `/` to the exact spec R3 path. Require root
ownership and no non-root write grant for config/script and their ancestors before
parsing config and trusting principal_uid, consumer_gid, store_id or store_root.
Require nonzero principal_uid distinct from the consumer's real and effective UIDs.
For authenticated consumer_gid, read its real and effective gid first. Either exact
match satisfies spec R3 without a supplementary query. Otherwise protected Darwin
uses the fixed State-owned group reader below and never calls `os.getgroups()` in the parent.
The protected Linux path keeps its separately accepted actual closure. There is no caller/test
environment override. Validate installed files and verifier under R10.1, permitting only root
or the authenticated supervisor where that contract allows it.

On macOS use one private ACL boundary in `_consumer.py`. Before cancellation
admission, bind the fixed descriptor ACL retrieval, iteration, qualifier-copy and
free functions from the absolute system C library and account for that small native
wrapper in the parent's source/runtime closure. Prepare the captured-row container
and ctypes entry holders before `acl_get_fd_np`. After that call returns an owned ACL,
enter its `finally` before any further Python allocation or copy. After each successful
`acl_get_qualifier`, enter a nested `finally` before `ctypes.string_at`, hexadecimal
conversion, row construction or append. Attempt exactly one matching `acl_free` for
every acquired qualifier and ACL on normal, `OSError`, `MemoryError` and other Python
exits; never rely on freeing the ACL to free a qualifier. Do not invoke the resolver
after capture fails. Preserve the existing metadata checks, exact tag/permission/UUID
bytes, 128-entry maximum and original ordering.
The parent never calls membership resolution or initializes that service,
including for compatibility UUIDs.

Resolve captured UUID bytes only in one fixed child per bounded batch:
`P -I -S -B S/shadow/v1/_consumer.py _resolve-darwin-uuids`. This remains a private
role, not a public CLI, registry or selectable command. Input is an exact canonical
array of at most 128 lowercase 32-hex UUIDs and 16 KiB. Output is at most 32 KiB with
one positional exact `{uuid,status,kind,id}` row per input. Resolved rows have user or
group kind and uint32 id; unresolved rows have null kind/id. Reject duplicate keys,
unknown fields, malformed values, trailing data and missing, extra, reordered or
mismatched rows. Map only users; groups and membership misses remain unresolved.
Transport, protocol or process failure refuses the observation. A result supplies no
permissions or authorization; the role cannot invoke the parent or recurse.

Darwin supplementary membership uses a separate fixed private role and argv:
`P -I -S -B S/shadow/v1/_consumer.py _read-darwin-group`. Stdin is exactly canonical
`{"gid":G}\n`, at most 32 bytes, where G is the authenticated uint32 consumer_gid. The
child calls existing `os.getgroups()` once with its original Darwin extended semantics.
Its only stdout is canonical `[]\n` or `[G]\n`, at most 16 bytes, containing actual
matching group-id data.
Query error exits nonzero with no accepted output. The parent validates exact bytes and
itself requires `[consumer_gid]`; the child returns no member, accepted, permission,
principal or policy field. This caps no legitimate group list and does not replace the
Darwin query with the nonequivalent plain syscall.

Before the first Darwin ACL capture, the trusted parent fixes P, reviewed physical S
and `_consumer.py` under spec R2.1/R2.4. It rechecks them before either child. No ACL or
group result establishes those identities. The enforced entry constructs concrete
module-private UUID and group reader adapters from the existing State runner and fixed
argv; they are not callables,
subclass hooks or request-selected runners. A protected Darwin `load_anchor` requires
both adapters, uses the gid short-circuit above, and refuses a missing group reader
without in-process fallback. An ordinary nonadmitted consumer may retain its legacy
local group query, but cannot enter the protected reproduction or supply its source closure.
Linux keeps fd ACL reads and makes no UUID resolver call. Unsupported or
unreadable ACL observations refuse. Store objects accept no ACL; root and installed
rules preserve every existing R10.1 permission and principal decision.
Open store_root, attempt directory, receipt and payload descendants relative to
held descriptors. Enforce spec R3's uid/gid, 0750/0440, no-ACL and single-link rules.
Use the existing fixed payload names/inventory; reject extra/missing/aliased names.
The reader returns immutable bytes and an observation, never an unverified path.
Record only relative names, metadata, sizes/digests and result in the observation.
Failures remain unauthenticated, even if receipt contents happen to pass the checker.

The installed verifier's observed bytes supply d. Build the exact spec R10.3
observation from this read, registry entry and accepted set, and compare all three
environment/target/set relationships before evaluating or launching. Empty shipped
accepted identities refuse. Tests substitute the private OS-observation functions
in-process; production CLI, environment and accepted files contain no fixture mode.

### 4. Component calls and bounded execution

Let S be the reviewed physical source root, P the physical Python interpreter, J the
checked jq snapshot, H the accepted helper snapshot and G the selected core module
directory derived from the existing core wrapper/registry. I and R are captured
materialization input/response; C is the candidate root; W contains fresh private
scratch children. Use argument arrays and no shell command strings.

| Operation | Exact argv after expanding these validated paths |
| --- | --- |
| Materialize | `/bin/bash -p S/adapters/local-git-materializer/v1/materialize.sh materialize I TARGET SOURCE_GIT C W/materializer H J` |
| Validate input | `J -L G -e --arg command validate-input -f S/adapters/local-git-materializer/v1/protocol.jq I` |
| Validate response | `J -L G -e --arg command validate-response -f S/adapters/local-git-materializer/v1/protocol.jq RESPONSE_CHECK_BUNDLE` |
| Prepare | `P -I -S -B S/preparation/v1/prepare-candidate.py prepare --input I --input-sha256 IH --response R --response-sha256 RH --candidate-repository C/repository.git --output PREP --scratch W/preparation --jq J` |
| Inspect | Same preparation argv with operation `inspect`, same output and a fresh empty scratch directory |
| Evaluate | `/bin/bash -p S/control/v1/evaluate-bound-sandbox.sh evaluate DUTY CLAIM OBSERVATION` |
| Check receipt | `/bin/bash -p S/enforcement/v1/check-sandbox-receipt.sh check-bound RECEIPT EXPECTATION EVALUATION OBSERVATION` |
| Trace | `/bin/bash -p S/telemetry/v1/validate-trace-ledger.sh validate INCIDENT_ID ATTEMPT_ID LEDGER` |
| Convert seed | `/bin/bash -p S/maintenance/v1/incident-to-eval.sh convert INCIDENT FROZEN_SHADOW EMPTY_SEED_DIRECTORY` |
| Build write input | `J -L G -S -c --arg phase PHASE --rawfile contract CONTRACT --rawfile patch PATCH --slurpfile metadata METADATA -f S/shadow/v1/write-materialization-input.jq PHASE_INPUT` where PHASE/PHASE_INPUT are exactly the captured original input for `stage-request` or the captured first-phase document for `final-input` |
| Inspect write Git | `/usr/bin/git --no-replace-objects --git-dir=CAPTURED_SOURCE_OR_CANDIDATE` followed only by `config --file CAPTURED_CONFIG --name-only --list --no-includes`, `rev-parse --is-bare-repository`, `rev-parse --show-object-format`, `ls-tree -r -t -z --full-tree FULL_OID`, `cat-file commit FULL_OID`, or `cat-file blob FULL_OID` |
| Resolve Darwin UUIDs | `P -I -S -B S/shadow/v1/_consumer.py _resolve-darwin-uuids` |
| Read Darwin group | `P -I -S -B S/shadow/v1/_consumer.py _read-darwin-group` |

Child environment is classified only by closed role. Roles 1 and 12–15 receive exactly
`PATH=/usr/bin:/bin`, `LC_ALL=C` and `LANG=C`. Roles 2–11 and 16–18 receive the
existing 14-key `clean_env` defined below. Clear inherited Git configuration, hooks,
prompts, loader/Python variables, functions and network/proxy settings.
All children close inherited descriptors except their declared stdio. Use a new
process group per ordinary component. Each ordinary child has a 120-second deadline,
64 KiB stderr cap and its upstream output cap (1 MiB where no tighter cap exists).
Preparation/inspect have 300 seconds, matching their existing operation bound.
On expiry stop that owned child group, wait at most 10 seconds and record failure;
never call a truncated output successful. Consumers have a 1,200-second overall
budget; a deadline only removes opportunities for work, never relaxes admission.

Writer roles 16 `write-seed-conversion`, 17 `write-materialization-input` and 18
`write-git-inspection` bind the three writer operations above. The general environment
has exactly `PATH=DEPENDENCY_BIN:/usr/bin:/bin`, caller-owned disposable `HOME` and
`TMPDIR`, `LANG=C`, `LC_ALL=C`, `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_NO_REPLACE_OBJECTS=1`, `GIT_NO_LAZY_FETCH=1`,
`GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `GIT_CONFIG_COUNT=1`,
`GIT_CONFIG_KEY_0=core.hooksPath` and `GIT_CONFIG_VALUE_0=ABSENT_NO_HOOKS_PATH`.
DEPENDENCY_BIN contains only the checked private jq. Role 19 and every mismatched argv
or environment refuse.
Each writer role keeps the 120-second deadline and 64-KiB stderr cap. Converter stdout
is at most 1 MiB; builder stdout is at most 8 MiB; tree listings are at most 16 MiB and
commits are at most 1 MiB. A blob read is bounded by its expected length plus one;
other smaller Git results use tighter bounds. Truncation is failure.

The private runner no longer makes a Python `Popen` object the sole owner between
kernel spawn and reap. It puts one serial child's authority in the existing
`NativeState`. State is already strongly held before the first pipe, attribute,
file-action or argv allocation. Record each of the six pipe ends and every later
resource immediately after acquisition. A prepare failure attempts every acquired
resource once, keeps the first error and creates no child.

`prepare_child()` accepts one exact built-in tuple: closed role integer, absolute UTF-8-bytes
executable, tuple-of-bytes argv and tuple-of-bytes environment. Roles 1–15 retain their
accepted meanings. Add only the three writer roles 16–18 above; role 19 stays unreachable.
Every role requires its exact executable/argv, classified environment and own
stdin/stdout caps. Reject path-like objects,
callables, NUL, unknown or mismatched role, extra environment, nonfixed stdio,
conflicting descriptors and existing argument/environment/file/output bounds. Never
accept a REQUEST-selected program, PATH search or generic dispatcher/action list.
Before spawn copy every byte, create all pipes/actions, and preallocate return objects.

`spawn_child()` is NOARGS. The selected public `posix_spawn` writes pid directly to
State. On return zero, the next C statement records raw pid, the platform-proven pgid,
all fd ownership and `OWNED` before Python can allocate, dispatch, decref, run a
callback or explicitly check signals. A nonzero return records the direct rc and
`NO_CHILD` without reading undefined pid. An interrupted native return or Python
assignment therefore leaves the same State as owner.

Use the preallocated integer fds with the existing bounded selector I/O; no file
object or finalizer owns them. Native fixed operations close each named parent pipe,
observe exit without consumption, send the TERM and KILL group stages, perform one
final reap, and check group absence. Each records direct rc, errno, status and
ownership before returning. Use the selected platform's public `waitid` with
`WEXITED|WNOHANG|WNOWAIT` only after its exact contract is accepted. A successful
matching observation marks `exit_observed` but leaves the leader waitable, so pid/pgid
identity remains reserved. A lost observation return cannot lose ownership or consume
the leader.

Every signal that may still be required occurs before final reap. The normal no-signal
path is limited to the exact fixed role, executable, argv and environment contracts in
section 4. After all pipes reach EOF/close, require a matching successful WNOWAIT
observation. Before reap, its recorded `si_code` and `si_status` must be `CLD_EXITED`
and zero. There must be no recorded child error or outstanding cleanup signal stage.
Only then may the fixed command's normal completion contract establish that TERM and
KILL are not required. The fixed leaf commands do not spawn descendants. Compound
commands finish their foreground work before successful exit. The materializer's two
finite environment-list process-substitution producers retain the observed stderr until
they exit. A role number alone gives no such contract to an arbitrary caller or test
program. The sudo/supervisor role keeps its separate authenticated receipt and teardown
requirements; wrapper exit never proves VM teardown.

The converter's reviewed source runs its fixed jq/utilities synchronously, creates one
fixed-family seed and completes scratch cleanup before its successful foreground exit.
The builder's final fixed source and core graph must prove a pure synchronous JSON
transformation; it may not name or execute a program. Jq and the closed read-only Git
operations are leaf commands. These source contracts, exact role tuples, EOF on every
pipe, zero `CLD_EXITED` WNOWAIT status and no recorded child error are all required for
the no-signal path. The role number alone proves none of them.

Nonzero or signal exit, an unknown observation, cancellation, timeout or communication
failure enters cleanup while the leader remains waitable. Do not use a pre-reap group
query or `EPERM` as normal-path proof. Cleanup attempts TERM, retains the waitable leader
through its grace period, and attempts the bounded KILL stage before reap whenever TERM
did not close every group obligation. Leader exit after TERM does not skip a still-required
KILL. Late cancellation before reap also enters or finishes those stages; cancellation
after reap cannot signal the old pgid.

The abnormal fixed-role descendant success fixture owns one unique exclusive
acknowledgment. Its designated reaper emits it only after `waitpid` returns the exact
descendant, `WIFSIGNALED` is true and `WTERMSIG` is `SIGKILL`. Within the existing
bound, a one-to-one test-only forwarding proxy may wait for and validate that
acknowledgment before the same
real State's first real group query. Wrong, missing or late acknowledgment fails before
that query. The channel is not inherited by the tested child or descendant and does not
hold stdio open. The acknowledgment never substitutes for the unchanged native result:
the original native gate remains the sole success condition and still requires actual
`ESRCH`, unique reap, pipe completion and every original
fd/identity gate. No production wait, sleep, scan, API, State field, lifecycle change,
query retry or `EPERM` reinterpretation is allowed. Keep a fresh isolated actual
UNKNOWN/EPERM control with raw first failure and no L; never reset unresolved `OWNED`
state and continue the same invocation.

`reap_child()` is the sole consuming operation. It is legal only after a matching
nonconsuming exit observation and after State has marked every TERM/KILL stage either
completed or not required by the normal-path condition above. When no signal stage was
requested, native reap also requires the recorded `CLD_EXITED`/zero observation. That
native gate is necessary but not sufficient: only the trusted driver may bind it to the
fixed command contract, and no caller boolean may grant the shortcut. Entered cleanup
keeps the existing strict signal-stage gate. Reap stores raw rc/errno/status and
`leader_reaped` before returning. A lost reap return cannot cause a second consume.
After reap only no-effect group-absence observation and pipe bookkeeping may run; never
signal through the old, possibly reused pid/pgid.
`leader_reaped` is not `group_absent` and neither proves pipes complete. Only all three
allow `COMPLETE` and a later serial child. Unknown observation/consume results do not
grant a retry or advance authority.

Both private identity roles use this same cancellation-aware State runner, fixed
three-key clean environment, new process session, saved original caller mask, declared
stdio only, close-all and no extra inherited fd. Each permits only one serial child,
has a 10-second deadline within the overall budget, 64-KiB stderr and no retry; UUID
stdout remains 32 KiB and group stdout is 16 bytes. Normal completion records wait,
unique reap, group absence and every pipe/selector close before parsing output.
Timeout, cancellation, child failure, malformed output or later allocation failure
uses the same bounded owned-group cleanup. No identity child or resource survives
into the completion tail, and the two roles never run in parallel.

The only future native argv is `/usr/bin/sudo -n -u #UID -- P ANCHOR/host-supervisor.py
launch`, with stdin the complete frame and UID/config/P already checked. The
consumer's 180-second deadline and 10-second cancellation observation follow spec
R4.5. Do not infer teardown from wrapper termination. Tests never invoke this argv;
they substitute the private launch function while running the real remaining path.
No plan acceptance authorizes an actual native call.

Create the command ledger before constructing the Darwin resolver or calling
`load_anchor`. Route every actual nonempty resolver batch through the same ordered
`record_command` path as other children; repeated argv create repeated rows and empty
batches create none. Complete the final resolver-backed anchor/ACL recheck before
freezing provenance. After freeze, only child-free held/named metadata seal checks may
run, and they still fail on identity drift. Native module methods are not child
commands and never get invented ledger rows.

### 5. Cancellation and completion ownership

Keep cancellation in the private `CancellationSignals` boundary. Its outer owner
is acquired only by the reviewed standalone `PYTHON -I -S -B` invocation and trusted
parent of spec R2.1/R2.4. An imported/library invocation refuses before signal, mask
or wakeup APIs. Nested scopes borrow the same State; they install nothing, own no
completion descriptor and define no second handoff. One invocation has one owner.

During acquisition, product work and ordinary cleanup, the main thread blocks HUP,
INT and TERM. Python bytecode, allocation, exception creation, ACL capture/free,
child preparation and status conversion run only in that blocked state. The fixed
native checkpoint observes pending watched signals with sigpending and sets the
sticky cancellation latch without changing the mask or consuming a signal. Original
caller mask restoration happens only in release. This preserves cancellation,
single L, sticky failures, usable-held-fd rollback and post-L caller protection.
It does not promise zero allocation throughout reproduction or port it into C.

`_cancel_release` still exports only `prepare_state()`. Opaque, non-subclassable
State has the fixed methods `block_entry()`, `arm_consumer()`, `checkpoint()`,
`hold_completion(fd)`, `block_final()`, `rollback_marker()`,
`commit_completion(payload)`, `abort_release()` and `outcome()`, plus the existing
serial child methods `prepare_child(spec)`, `spawn_child()`, `child_fds()`,
`close_child_stdin()`,
`close_child_stdout()`, `close_child_stderr()`, `observe_child_exit()`,
`reap_child()`, `term_child_group()`, `kill_child_group()`, `check_child_group()`
and `child_status()`. Remove `resume_consumer()` and allocator observation methods.
Hold and child prepare take their existing exact built-in fd/closed tuple. Commit
takes only the exact built-in bytes described below; every other method is NOARGS.
There is no caller-supplied signal, mask, timeout, callback, operation list, generic
dispatcher, new helper or public event loop.

State is prepared before the first census and is the sole authority. It contains:

- the original entry mask, fixed watched mask and original native sigaction for
  each watched signal; separate capture/install/restore result and ownership cells;
- owned nonblocking/CLOEXEC pipe ends with acquired/attempted/direct-result cells;
  one `volatile sig_atomic_t` cancellation latch, assigned only the constant 1 by
  the fixed handler or main-thread pending observer; observer reads/writes occur
  with watched signals blocked, and only preparation initializes it to zero;
- entry/final/checkpoint/finish raw result cells, including checkpoint pending and
  fixed membership results, tagged NOT_RUN or RETURNED,
  saving errno immediately for APIs that return -1; pthread_sigmask stores its
  direct error code, not an errno-derived replacement;
- the existing completion duplicate, captured dev/inode/type, individual
  close/fstat/unlinkat/fsync cells and one rollback-attempted value;
- one retained exact bytes object, its read-only pointer/length, and marker
  open/write/file-fsync/file-close/directory-fsync raw cells; marker fd ownership
  is stored before any later call, distinct from the retained directory duplicate;
- the existing serial-child record, raw pid/pgid, six fd ownership/result cells,
  nonconsuming observation, unique reap, TERM/KILL/group checks and outstanding
  pipe/group duties; no Python pid object becomes authority;
- one phase (`prepared`, `entry-blocked`, `consumer`, `final-blocked`,
  `commit-running`, `release-running`, `sealed`), one decision (`undecided`,
  `abort`, `completed`), first_failure referring to the first result cell, and
  preallocated outcomes.

Do not create parallel valid/executed/error copies. NOT_RUN distinguishes failure
before a C body from an actual API return. No destructor closes a descriptor,
repeats release, rolls back or reaps. Module, State and bound methods have strong
references through release. The module additionally retains this single State for
its invocation lifetime, including a partial restoration failure; handler storage
cannot be freed while any installed action can reference it. No second acquisition
is permitted after sealing or partial failure. This is bounded private ownership,
not a reusable signal service or cleanup delegated to interpreter destruction.

Before acquisition, require the main interpreter thread, reviewed fixed imports,
no trace/profile/audit/finalizer path able to call an arbitrary owner-changing
callback, and the actual accepted P/startup/dependency identities. Retain the
existing evidence that Python's wakeup fd starts disabled with the accepted warning
setting and no competing signal owner. Do not discover it by a temporary setter.
Neither `signal.signal` nor `signal.set_wakeup_fd` is called anywhere in ownership
or release. The Python handler table and disabled/warning pair stay unchanged.
For the admitted fresh product startup, bind the existing default SIGINT Python
handler and default HUP/TERM actions. A SIGINT already queued by the old Python
trampoline before native acquisition may raise KeyboardInterrupt after block_entry
returns; entry's raw ownership must already be in State. The outer entry exception
path calls abort_release, produces no L and starts no product effects. Never clear
Python pending flags, consume/replay signals or invoke a caller to drain them.
Arbitrary pre-existing Python/native owners remain outside the closed startup;
this does not weaken arbitrary caller protection after L. Returning-caller fixtures
retain their post-L purpose and must state their injection boundary explicitly,
with a separate real queued-default-INT entry-failure control.
Native sigaction saves and restores the complete real kernel action, including
mask and flags. It restores the original Python trampoline, SIG_IGN or SIG_DFL as
applicable; it neither manually invokes a Python callable nor edits its table.

Observe actual thread count once before product effects and again after final
ordinary cleanup while watched signals are blocked. Linux reads capped
`/proc/self/status` and requires matching pid and one exact `Threads: 1` field.
Darwin uses preloaded/bound fixed libproc, exact-size PROC_PIDTASKINFO and
`pti_threadnum == 1`. Malformed, inaccessible, truncated, non-one, mismatched or
observation-close failure refuses before effects or selects final abort. A mocked
count, Python thread registry or implementation name cannot replace either check.

The interval proof concerns signal and resource effects of the actual parent roots:
reviewed driver/control flow, fixed Python/native dependencies, ACL capture/free,
State child APIs, bounded selector/I/O and their normal/error cleanup. Python
allocation is allowed while blocked. Public pthread creation inherits the creating
thread's mask; it does not prove the initial mask of a workqueue/kernel-created
thread or prevent an existing/new thread from changing its mask. Identify the
actually reachable thread creation paths and prove any temporary thread remains
watched-blocked, does not wait for/consume watched signals, change watched actions,
call a Python signal setter or replace the private pipe, and has exited before
final census. If there is no creation on a root, close that root at its relevant
contract. Any reachable active unmask, waiter, competing handler or unknown initial
thread mask still prevents admission. Do not add a multi-receiver fallback: volatile
sig_atomic_t is not a cross-thread synchronization design. Both census observations
remain necessary and are not proof of the absence of transient competing receivers.

Use actual dependency identities and the public API or finite implementation facts
needed for those effects. Do not enumerate every allocator class, every malloc/free
algorithm, whole Python or whole OS. The old four signed slots, PAC authentication,
80/288/144-byte profiles, XZM class bytes and zone+0xf0 observations are removed;
they served the former unblocked-Python invariant and are not new admission inputs.
Keep their historical raw evidence outside product artifacts. No private slot is
read, decoded, stripped or guessed. Existing default-runtime/startup and no-setter
proof is still required where it establishes these signal effects; a dependency
name or UUID alone proves no behavior.

The already identified RNG-error to libc abort route must be covered explicitly.
Its actual bound mask writes use all-ones, 0xfffff9df, 0xffffffdf and 0xffffffe7;
HUP/INT/TERM bits 0, 1 and 14 are set in each. On this accepted Darwin image those
successful writes preserve the new watched-blocked invariant; an error must have
the bound API's unchanged-mask semantics. This is not a claim that abort preserves
the full caller mask or performs product cleanup. Retain finite proof for the
relevant cleanup/workqueue/action edges of this actual route; its SIGABRT action
is not a watched action. Do not delete it merely because abort does not return, or
expand RNG algorithms to exclude a path whose watched-mask effect is now compatible.
These allocation/fatal-capable roots end before any marker is created. From marker
creation through L, the fixed native commit below has no allocation or unknown
callback. Fatal prefix controls record the last externally observed boundary and
absence of a marker, never completed cleanup or an E_RUNTIME return. Compatible
watched bits alone do not prove marker rollback, and an unrelated unknown receiver
edge is not admitted by this mask calculation.

`block_entry()` performs the one fixed pthread_sigmask(SIG_BLOCK) and records rc
and the original mask before returning. Success enters entry-blocked; failure
never reads an uninitialized old mask or installs an owner. `arm_consumer()` runs
while blocked: acquire the private pipe, set both ends nonblocking and CLOEXEC,
then install one native sigaction for each watched signal. Each successful
sigaction atomically captures its previous action into State; store its installed
ownership before any further call. Partial failure stops installation and uses
`abort_release()`. Interrupted Python assignment consults State, not an entered flag.
The normal arm result enters consumer with watched signals still blocked.

The native handler saves errno, assigns latch=1, attempts one nonblocking write of
one fixed byte to the stable private write end, and restores errno. Its sa_mask
contains all watched signals, with neither SA_NODEFER nor SA_RESETHAND; the three
handlers cannot nest and lose updates. No counting, read, loop, allocation, Python,
GIL operation, formatting, callback or lazy symbol lookup occurs. EAGAIN, EINTR or
another write failure cannot clear the latch. Pipe saturation is not cancellation
loss. Prebind/first-use the handler's actual write/errno path before census and prove
the accepted implementation is async-signal-safe; the handler never calls malloc.

`checkpoint()` makes one fixed sigpending call into a native sigset_t while the
watched set stays blocked. Record its raw rc and errno immediately; a failed call
never reads the output set. On success, test only fixed HUP, INT and TERM through
sigismember, recording the three direct results; any watched member assigns latch=1.
Do not count signals or clear the latch on an empty later observation. Pending or
membership failure is sticky and prevents new work. Once a checkpoint failure is
recorded, later calls return the rooted failure singleton without another syscall
or overwriting the result cell referred to by first_failure. Cleanup continues its
separately owned duties. On ordinary success return only an already-rooted status
singleton, with no allocation, DECREF, Python callback, GIL release or lazy lookup.

This is a nonconsuming cancellation observation, not delivery, waiting or another
completion decision. Repeated observations leave the pending signal in the kernel.
A signal arriving after a checkpoint is observed at the next existing checkpoint
or the final pending sample; it cannot turn a sampled clear prefix into completion.
Do not use pselect, a timeout/unblock fallback, sigsuspend, sigwait, signalfd, drain,
replay, manual handler invocation or a second event loop. The private native actions
remain installed during the lease: an originally ignored watched signal can become
pending instead of being discarded by SIG_IGN. Keep the handler/latch/private pipe
and final one-byte observation; do not introduce an unblock to exercise them in the
product. Actual normal/error contracts for this fixed observation must bind both
selected platforms.

Call this method at existing private cancellation checkpoints, immediately before
new child/evidence effects, and around existing bounded I/O waits. Retain Python's
current selector wait at most 0.1 seconds and child wait sleeps at most 0.02 seconds,
all while watched-blocked; do not rebuild child communication in C. Ordinary control
raises cancellation from the native latch while blocked, stops new work and begins
the existing owned-group cleanup. Cleanup observes checkpoints without aborting its
outstanding TERM/KILL/observe/reap/pipe duties. Preserve the 180-second supervisor
deadline and further 10-second cancellation observation, including the existing
bounds and refusal on exhaustion. The checkpoint adds no syscall hard-time promise.
Caller-originally-blocked watched signals also remain pending; observing them may
stop new work sooner but never unblocks or consumes them. Every early observation
can only cancel or fail; only the final post-durability pending sample may create L.

The child record remains the only spawn-to-reap owner. `prepare_child` copies the
saved original entry mask into its explicit POSIX_SPAWN_SETSIGMASK attribute;
never copy the now-blocked ambient parent mask. Preserve the existing child default
signal set, exact executable/argv/env, session/pgid, stdio and no-extra-fd contract.
No owner or pipe is inherited across exec. All Python conversions occur with parent
watched-blocked. Spawn writes the raw pid/pgid/owned fds before returning; error
writes NO_CHILD. An interrupted return/getter cannot erase an owned child. Preserve
waitid/WNOWAIT observation, leader identity while any group signal remains required,
at most one final reap, and separate leader-reaped/group-absent/pipes-complete facts.
No raw fork, private syscall, Popen fallback, parallel child, pid scan or destructor.

Under that accepted runtime closure, prepare_child checks one fixed platform
predicate before pipes. Require the compiled public session, saved-mask, defaults,
stdio/close-all and wait contracts; a macro, API name or version alone is not proof.
Darwin requires CLOEXEC_DEFAULT and the bound spawn-filter branches: fixed env
excludes POSIX_SPAWN_FILTERING_RULES_PATH, and the public default path
/usr/local/share/posix_spawn_filtering_rules is absent. Check that fixed absence
before preparation and recheck before spawn; any other result refuses. Parent
acceptance must bind protected ancestors and absence through use, including ACLs;
a past ENOENT alone is insufficient. Existing administrator/same-principal trust
residuals stay unchanged. No private selector or rule parser is added.
Linux uses public posix_spawn_file_actions_addclosefrom_np(3) after the three
stdio dup2 actions and existing pipe-close actions. Its nonzero direct rc fails
preparation with one cleanup per acquired resource. No usable close-all contract
means refusal, never inheritance of extra fds or a fallback fd scan.
Bind these effects and both platforms' normal/error wait contracts to the actual
images. Linux records full package/source revision, file hash and build ID, then
uses corresponding source or bounded actual function bodies for spawn mask,
close-all, setsid, wait and release cancellation paths; generic GNU source is insufficient.

First establish actual Mac and Linux public-call controls from the same source;
a separately identified test build may bypass only the closed platform gate while
leaving those calls uninjected. This proves platform behavior, not production
admission. With those controls and the relevant source closure reviewed, implement
the fixed predicate as an ordinary development candidate under this plan. No new
context token or runtime bypass is added. Then run both platforms' production
builds, test_build:false, with no bypass: all normal/error pairs, canonical
reproduction, relevant suites, full matrix and fresh independent G3 remain required.
Only final exact-head, per-platform exact-output evidence permits acceptance;
test variants, permanent false guards and stale output cannot supply a positive.

Finish every semantic, identity, evidence-durability and owned-child operation
before marker creation. Perform final resolver-backed anchor/ACL recheck before
ledger freeze; after freeze do no child work. Ordinary child-close OSError tries
every other distinct owned child once, preserves the first error, never retries an
unknown-result fd and leaves definitely unattempted responsibility in its original
container. It does not promise attempt-all for arbitrary BaseException.

Prepare the final canonical bundle payload as exact built-in bytes in Python after
validating all 29 evidence files and cross-document relations. Use the existing
1 MiB consumer document ceiling for this private argument; the fixed spec R5.7
manifest of 29 fixed names, bounded byte counts and digests fits below that ceiling.
It is not a new document field or a caller-selectable limit. Validate nonempty
length within 1,048,576 bytes before native effects; retain the original canonical
UTF-8, sorted keys, compact encoding and trailing LF. No C JSON parser is added.
The reviewed driver generates these bytes from accepted snapshots; REQUEST supplies
neither a raw marker payload nor a method/operation selector. An exact bytes type
alone is not evidence authentication; the unchanged trusted-driver checks are.

Require the original empty-output and held-identity checks, call hold_completion
once and normally observe authoritative `native-release.pending` with no failure.
A None return is not that confirmation. NOT_RUN, dup/fstat failure or interrupted
confirmation creates no marker and leaves any duplicate owned by State. The Python
seal path writes/fsyncs the evidence, prepares and retains bytes and confirms hold;
it no longer writes bundle.json. Its returned bytes are prepared output, never a
completion assertion. Finish source/tool/held-and-named identity rechecks, the exact
29-file inventory check, ordinary seal-fd close and all other ordinary cleanup.
The private output has no admitted competing writer. The later exclusive addition
of only bundle.json therefore supplies the exact completed 30-file inventory;
there is no allocating post-marker listdir/set or held-path recheck.

Then block_final records its real block result and enters final-blocked. Complete
the second census and Python active-parent restoration before any marker open or
byte. Any failure or outstanding exception uses abort_release, which records the
fixed preparation-abort input, uses the common native release and never creates L.
A fatal allocation during these prefix steps leaves no marker and needs no claimed
dead-process rollback. Keep all fixed call binding/first use before first census.

Only the fully prepared normal path calls commit_completion(payload), once. Remove
the separate success-capable finish_release method: there is one commit/decision/
release path, and abort_release cannot complete. Before opening the marker, C checks
final-blocked phase, the confirmed hold and no earlier failure, PyBytes_CheckExact,
nonzero bounded PyBytes_GET_SIZE and the read-only PyBytes_AS_STRING pointer. These
checks use the exact built-in type, never a conversion or buffer-export protocol.
Take one strong reference before opening; State retains the bytes through its
invocation lifetime, so no payload DECREF/free or foreign finalizer occurs in this
call or its return handoff. Capture the fixed length without narrowing overflow;
the ceiling is below SSIZE_MAX on each accepted platform. Invalid arguments or
preconditions refuse before marker creation and take the ordinary abort path.

Once State enters commit-running, remain in this one C call through sealed. Use
only prebound, initialized public APIs whose actual normal/error contracts exclude
allocation, lazy binding, Python, pthread-cancellation cleanup and unknown callbacks
in this short path. Do not release the GIL, call CheckSignals, return to Python,
allocate, DECREF, reopen by a caller path or add a generic I/O engine. These facts
must bind the actual platform; calling an API public alone is not the proof.

Open only fixed bundle.json relative to State's confirmed directory duplicate with
O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC and mode 0600. Store raw rc/errno and
acquired marker fd ownership immediately before any next call. A failed open owns
no marker name and cannot unlink an existing entry. Make exactly one write call
for the full retained length. Record its raw ssize_t return and errno immediately;
only return == length is success. A short positive return, zero, EINTR or any other
error is a true sticky failure; do not retry, loop, pad or fabricate errno for a
positive short write. This one-call bound handles partial writes by refusal.

After a full write, fsync the marker once. Close the acquired marker fd exactly
once, including on a prior write/fsync failure. Record the attempted/result and
consume its close authority before proceeding. Failed close makes that fd's state
unknown; never retry or use that integer, even if EINTR might leave it open. The
separate held directory remains rollback authority. Only after successful write,
file-fsync and close may C fsync the output directory once. Each operation has its
own raw result and first_failure never changes. On success, no subsequent durability
or Python preparation remains. A partial-write or other marker failure proceeds directly to
abort/rollback and release in this same C call, never to L or an early Python return.

After all marker operations succeed, observe the private pipe with exactly one
nonblocking one-byte read. Any byte, EOF, unknown descriptor or error other than
EAGAIN/EWOULDBLOCK makes abort sticky. Never drain, retry or read twice. Read the
sticky latch and take exactly one final sigpending snapshot. The inputs are prior
preparation failure, any raw failure, latch, uncertain pipe and watched pending.
Any set input selects abort. Only their absence and all preconditions permit completed. The successful
final pending sampling instant is **L**; neither the marker's last byte/fsync, mask
restore, C return nor Python assignment is L. No semantic work, child work, second
decision or Python call follows L.

For abort, while blocked and the directory duplicate is usable, use the original
not-yet-attempted descriptor-relative unlink of bundle.json and directory fsync.
Only State's successful exclusive open authorizes removal of the marker name;
failure before open creates none and never removes an unowned existing entry.
Record each direct cleanup result independently; failure is never asserted removal.
There is at most one rollback unlink/fsync pair, including after partial write or
an unknown marker-close result; a failed marker close is never retried. The failed
commit's directory-fsync and rollback's directory-fsync have distinct obligations
and cells, not an EINTR retry. For success or abort, still blocked, restore each
installed original native sigaction once and immediately record rc/errno. A restore
failure is sticky and attempts that same one-time rollback before unmask while the
directory duplicate is usable. Do not claim a failed action restore succeeded.
No Python signal/wakeup setter is used.

Only after every action that can reference the pipe has actually been restored may
the native release close each pipe endpoint once. Store ownership/result first;
never retry an unknown-result pipe integer. If any action remains installed, retain
the private pipe and rooted State through process lifetime rather than leave a
handler writing through a closed/reused fd. This failure is never success or a
restoration pass. Its fixed bounded resource retention prevents a secondary fd/UAF
hazard, makes no retry loop and permits no further product operation. Pipe-close
failure likewise stays sticky and rolls back through the usable completion fd.

Finally restore the exact original entry mask, not the already-blocked mask captured
by block_final. This native critical tail records the actual mask rc immediately
if it returns, performs any still-required one-time rollback, and closes the final
completion duplicate before returning to Python. It calls no Python, CheckSignals,
GIL release, allocation, DECREF, symbol lookup, fd allocator or callback. Accepted
original native dispositions and the Python signal trampoline must satisfy this
fixed tail's relevant no-fd-reuse/no-arbitrary-native-callback contract.

A true mask error stays sticky. For a failed final close, save errno and perform
exactly one fstat. EBADF, other fstat failure, dev/inode/type mismatch or absent
no-reuse proof makes the fd unusable; never unlink, reopen or retry that integer.
Only with actual final one-thread census and no fd allocator, replacement, unknown
native callback or pthread-cancellation cleanup in this fixed tail may matching
identity authorize the not-yet-attempted unlink/fsync and one conditional close.
The tail after original-mask restoration has at most one mask call, two close
calls, one fstat, one unlinkat and one fsync. Earlier rollback is not repeated.
The blocked commit prefix has at most one open, one write, one marker-file fsync,
one marker close and one directory fsync. The following blocked native release has
three bounded action restorations and at most two pipe closes. These are call bounds,
not hard wall-time guarantees.

Before C returns, seal phase, decision, all ownership, first_failure and outcome.
The epilogue only INCREFs and returns a preallocated strongly rooted singleton;
`outcome()` is a read-only NOARGS getter, never release. Repeated release calls are
inert with respect to consumed effects and cannot retry. Diagnostics occur later.

Observed lease-time signals remain pending: restoring original SIG_IGN may
properly discard them, while restoring an originally unblocked returning action
permits its natural delivery. Caller-blocked signals remain blocked and pending.
No consumer consumes, replays or claims to have delivered an observed signal.
Original SIG_DFL may terminate inside unmask before rc/close. A pre-L cancellation
first takes the required rollback path; a post-L caller signal does not undo the
sealed completion decision. Report only the last real observation, no imaginary
cleanup or E_RUNTIME from a dead process. Returning or ignored controls classify
normally observed authoritative State. No wrapper delays
original disposition solely to force a report or cleanup.

After L and successful native release, an arbitrary caller exception must retain
the marker and caller ownership, including Refusal, identical errno/text OSError,
MemoryError, ValueError and SystemExit. It cannot create an inconclusive bundle,
rollback or repeat product work. A real earlier/native failure remains sticky even
when the caller also raises. If a new caller event interrupts outcome observation,
propagate it with normal context through the complete outer-main reporting boundary;
make no product report, E_RUNTIME guess or repeated cleanup. There is no promise
that one caller exception defeats every later event. Every outer continuing branch
consults State rather than inferring native failure from an exception's class/text.

Keep schema 2, original CLI/P, 29-file inventory, provenance shape, frozen-reader
contract and production inactivity. Add no producer status, terminal-result trust,
sidecar, accepted identity, helper, upstream VM change or qualification authority.

### 6. Reproduction, pre-launch expectation and frozen record

Validate all captured input relations before materialization. Require no-change
response and exact incident source revision for reproduction. Build the protocol's
response-check object with exactly `input`, `response`, `verified_receipt`,
`receipt_utf8`, and `stage_result_sha256`; hash actual canonical nested documents,
not caller-supplied digest strings. Require the protocol's true result and validate
the actual candidate via preparation followed by inspect.

Generate exactly verifier R3's three instruction lines: magic, `path PATH`, and
`sha256 EXPECTED`, each LF-terminated. Retain these raw bytes in provenance. Refuse
named checks. Verify supplied qualified identity with the existing jq predicate;
its profile/request/target and instruction refs must match captured real bytes.

Execute the bound evaluator and retain its output; never accept REQUEST's claimed
satisfied document. Require the exact same-bound-set DUTY from a prior stage. For
fixtures, first run the real materializer on an acyclic prerequisite input with its
own earlier environment declaration, obtain request/profile/result, then execute
`control/v1/evaluate-duty.sh evaluate BOUND_SET PRE_REQUEST RESOLVED PRE_RESULT`.
That evaluator accepts the bound set through unchanged generic set validation.
Build the complete claim afterward with this duty's actual digest/stage refs and
measured fixture verifier. The consumer's input can then bind this claim without a
claim→request→duty→claim cycle. Never relabel an evaluation made for the legacy set.
The fixture harness retains that prerequisite tuple and verifies the consumer’s
retained duty bytes and refs against it. These declarations still supply no real
child-9 duty authority.

Build request and expectation in this order:

1. Subject environment id/hash and target come from the authenticated config,
   selected registry entry and incident. Source repository/hash/commit/tree and
   candidate commit/tree come from the verified materialization/preparation record.
   Candidate preparation_record_sha256 and manifest_sha256 hash retained raw bytes;
   incident_sha256 hashes the captured incident.
2. Control has exactly `policy_sha256`, `decision_sha256`, `policy_set_sha256`,
   `evaluator_driver_sha256`, `evaluator_program_sha256`, and
   `sandbox_evaluation_sha256`, all computed from the fixed retained bytes.
3. Launch envelope is schema 1, kind `sandbox_launch_request`, id ATTEMPT_ID. Body
   has attempt `{attempt_id,attempt_number:1}`, control, instruction_sha256, fresh
   64-hex OS nonce, authenticated store_id and subject. Serialize canonically.
4. Expectation is schema 1, kind `sandbox_receipt_expectation`, id ATTEMPT_ID. Its
   body contains store_id, subject, control and attempt extended with
   `launch_request_sha256` hashing the completed request. Persist and fsync both
   before the launch function is entered; test that ordering directly.
5. Construct YSFRAME1 exactly as VM R3: fixed records request.json, evaluation.json,
   incident.json, record.json, manifest.json, instruction, then candidate/%05d in
   manifest file order; hash framed headers/content and append the end record.
   Stream checked preparation export files; do not reconstruct an export from Git.
   Enforce each upstream cap and the complete 88,080,384-byte frame ceiling.

Only R3-authenticated receipt/payload bytes reach the completed-evidence path.
Run check-bound, validate the result and exact request/expectation/evaluation/store
relations. Require exact d equality in receipt, observation and claim even with two
accepted verifier values. Require payload exit 0, empty stdout/stderr, the one fixed
result file and its canonical bound shape. Match instruction/path/expected/observed
bytes against preparation manifest and evidence/receipt hashes. Mismatch is a
completed comparison; refusal, unavailable limits or incomplete teardown is not.

Build new records using spec R5's discriminated forms and the existing record's
field names, media types and inactive/effect/qualification values. Set check.execution
from the actual fixed-verifier result; set tool identity to tool.verifier only when
executed. Map match→no-change and mismatch→reproduced; preserve the spec's failure
precedence and original upstream reasons. Seal the existing trace event shape by
hashing each event without record_digest, then validate the ledger with its exact
incident session and current attempt. Do not introduce a trace→shadow-record cycle.

Provenance retains instruction and observation raw bytes, trusted parent context
hashes without host paths, component/tool source hashes and fixed command-role/argv
hashes. Keep evaluator raw driver/program bytes, all 29 spec R5 evidence files and
all their cross-document bindings. Prepare canonical bundle.json bytes and complete
all ordinary checks/cleanup before section 5's fixed native commit writes the marker
last, fsyncs file and output directory, and seals the single decision. Enforce the
exact inventory through the checked 29-file prefix and sole exclusive marker add.
Partial failures keep evidence without a completion marker. JSON canonicalization is UTF-8 sorted
keys, compact separators, one trailing LF, no nonfinite numbers or duplicate keys;
prove agreement with pinned jq on all generated documents.

### 7. Deterministic write materialization field map

Before preparing a write, verify the completed frozen reproduction inventory and
reopen its original controlled-store attempt. Require identical receipt/payload
snapshots and repeat the fixed evaluator/checker checks. Keep this fresh observation
only in outer write provenance. The committed reproduction bundle never changes.
Run the existing converter and require its sole output
`eval-seed-case-stale-moved-artifacts.json`; copy those exact bytes as eval-seed.json.
Invoke it only through role 16 with the captured incident, frozen shadow and fresh empty
output directory. Require stdout to equal the sole canonical seed file byte for byte.
No fresh origin or outer-attempt data enters this conversion.

Create exactly spec R7's 32 files under the absent `ystack-evidence/<incident-id>/`.
Use its exact README bytes. Require allowed_paths sorted and exactly equal to this
set, with unchanged scope/config protected-path rules. Build an add-only Git text
patch in sorted path order with mode 100644, `/dev/null` old files and exact new
bytes, including the no-final-newline marker where needed. Compute Git blob IDs
using the source hash algorithm. Refuse binary/invalid UTF-8, existing paths, path
aliases, unsafe segments, any deletion/change and patches above 1,048,576 bytes.

`write-materialization-input.jq` transforms the captured no-change input with only
the following replacements. `_consumer.py` supplies actual byte hashes as explicit
jq args after constructing the bytes; jq checks shapes/relations using existing
core modules. No payload hash is inferred from its textual representation.
Role 17 uses `--rawfile` for the contract and patch, never an argv scalar for the
up-to-1-MiB patch. Small digest/attempt facts come from one canonical metadata file.
The two fixed phases emit exactly one canonical JSON document each; hash the captured
stage-request bytes between them. Recheck J, G, the builder source and every captured
input before and after use. No caller filter, module path or extra phase is accepted.

| Location | Required value or replacement |
| --- | --- |
| profile, resolved_profile, manifests | Keep complete pairs byte-identical; validate their full graph |
| stage_request.content.id | `request.shadow-write.` plus first 32 hex digits of SHA256(write attempt id UTF-8 bytes) |
| body.initiative_id | `initiative.shadow-consumer-integration` |
| body.workflow_id / task_class_id / stage_id | `workflow.shadow-evidence-commit` / `task.commit-shadow-evidence` / `stage.materialize` |
| requested_by, source, base, target_repository_id, target_revision | Keep original validated values |
| selection_ref, repository_context_ref, resolved_profile_ref | Keep original refs and revalidate against retained resolved profile |
| environment_ref | Environment id and SHA256 of the write request's captured same-environment bound claim |
| operation | Retain forge binding, materialize capability, four existing candidate/evidence/scratch/read permissions, source-tree/output IDs, network deny |
| attempt | write attempt id, number 1, result id with `result.shadow-write.` plus the same 32-hex suffix; timestamps copied from original requested_at |
| body.requested_at | Original requested_at; all three attempt times equal it |
| risk | Routine tier; reason_ids `["shadow.evidence.candidate-only"]`; new fixed policy ref; required_gate_refs `[]` |
| gate_decision_refs / prior_evidence_refs | `[]` / `[]`; no invented real gate evidence |
| finish_condition / verification_instruction / operation.arguments.materialization_contract | Keep existing scope-ref shapes and input IDs; replace corresponding decision/subject/scope digests from the new bytes below |
| inputs | Keep source-tree ref; replace finish, verify, materialize and producer-patch content refs; sort by input_id |
| payloads / trust_context.verified_payloads | Exactly materialize JSON and producer-patch text, same IDs/media and exact raw strings; verified content/hash agree with input refs |
| stage_request.sha256 | Hash the completed canonical stage_request.content after all replacements |

The materialization contract has schema 1 and unchanged kind/settings, exact 32
allowed paths, max_changed_paths 32, max_patch_bytes 1048576 and required
allowed_modes `["100644","100755"]`. Actual additions are separately constrained
to 100644; never replace that protocol field with a singleton.

Define four LF-terminated plain-text records, retained in outer provenance:
finish: `Finish after all planned evidence files exist in the disposable candidate.`
verify: `Verify every planned path, mode and byte digest, then run the fixed incident check.`
output-contract: `Add only the listed evidence files; preserve all existing target files.`
policy: `Routine candidate-only evidence preparation. Network and publication are denied.`
Use existing decision/content IDs and media types from materialization-input.jq;
replace each actual digest everywhere it appears. The contract subject hash is the
canonical contract hash; its scope/decision hash is the output-contract text hash.
Patch data is exact UTF-8 diff bytes; its hash appears in the producer-patch input
and verified payload. Validate generated input before invoking the unchanged adapter.

Validate response, then independently compare the actual candidate tree to source:
exactly 32 added paths, each expected blob/mode, no other delta, one commit parent
equal to target revision. Prepare and inspect that candidate and run the same R4
incident check. Generate the outer qualified identity from retained profile/config/
model/prompt/skill refs, the new request ref, original target and actual instruction
ref; validate it using the unchanged predicate. Never reuse a stale request hash.
Role 18 accepts only full validated OIDs and the closed read operations in section 4.
It first applies the existing seven-key source-config admission to the captured config.
It accepts no revision expression, pathspec, caller option, write command, hook, filter,
credential, transport or network action. Compare raw tree/commit/blob facts in the
parent; the child never grants authorization. Roles 16–18 finish and release their
single State-owned child before any completion marker can be created.

### 8. Withheld admission and completion

Derive write_set from verified candidate facts, sorted by path. Each row has exactly
path, mode, raw SHA-256, git_blob_oid and add_only:true. Hash the canonical array.
Create the spec R8 publisher request with id equal to the incident id, exact body
keys, fixed branch/title/body bytes, base revision and candidate tree. Use the
specified neutral schema-1 kind; retain publisher-body.txt outside the candidate.

Implement one private admission function comparing request/body/write_set hashes,
source/parent/tree, allowed paths, completed authenticated write verification and
frozen bundle refs. Its only success is checked/effect:none. Publication is always
withheld with the exact reason; no branch creation, push, forge call or transport
is present. Post-write verification is a data object with exactly `target_revision`,
`candidate_tree_id`, `write_set`; its values equal the checked request and write set.
The write form's workflow_id and task_class equal the generated stage request IDs;
bundle_ref is a content ref to the frozen bundle.json bytes.

Seal the outer record/trace/completion bundle only after these checks. Its inventory
is the spec R5 set plus publisher-body.txt, using the generated write input/response
and separate write receipt. No outer nonce, timing, receipt, provenance or request
enters the candidate. Repeat preparation with the same frozen bundle and source,
varying only outer attempt identity and fresh nonce/timing. Require equal candidate
tree IDs, canonical write sets, publisher request bytes and post-write digests.

## Risks

- Helper trust is established before its version probe. The inherited context is
  meaningful only under the trusted-parent precondition. The separate checked
  executable snapshot removes a request-path replacement race; a self-hash or
  post-execution check would not. Private tests must prove the malicious marker
  never executes, including replacement during snapshot preparation.
- Store origin is the highest-risk boundary. Preserve descriptor/ACL checks and
  fail on unreadable state; no path-only reader, caller UID or archived observation
  replaces it. A compromised administrator/supervisor remains the accepted residual.
- Bound evaluation is necessary but not enforcement. Fixed hashes, same-set duty,
  actual evaluator execution and exact verifier equality are separate assertions.
  The receipt checker remains integrity/accounting validation, not origin proof.
- Complete evidence can exceed the text patch budget. Refuse rather than trim,
  split or bypass the materializer. A later publisher needs its own accepted work.
- All success controls here are simulated fixture proof. Empty accepted identities,
  unproven registry entries, CPU/wall enforcement `none` and blocked native
  qualification stay unchanged. No native installation, sudo, real target,
  credentials, scope gate, policy widening, publisher or activation is authorized.
- Completion additionally depends on truthful source/runtime closure evidence plus
  the fixed Linux or macOS native-thread observation for the already accepted isolated
  invocation. This plan does not qualify a runtime by assertion. Missing closure,
  unknown imported provenance, unknown wakeup ownership or failed observation refuses
  before effects; no implementation name or undocumented callback timing admits it.
- The State-owned runner removes the known pid-to-Python-owner allocation window but
  does not make a public API name proof of platform behavior. Darwin filter routing and
  Linux parent mask/close-all behavior stay fail-closed until actual evidence binds
  them. Do not replace that evidence with empty environment, constant presence,
  simulated State tests or a private fork/syscall path.

## Proof

Every negative case has a positive control and asserts the last completed boundary,
absence of later effects and absence of a completion marker. Test changed linked
values with their dependent hashes recomputed, so rejection proves relations rather
than merely a stale checksum. Tests use the real unchanged component interfaces;
only private OS identity/ACL/launch observations are substituted in-process.

Production `_cancel_release` contains no fault selector. Native failure proof compiles
the same source into separately identified test-only variants with
`YSTACK_CANCEL_RELEASE_TESTING` and one fixed `YSTACK_CANCEL_TEST_CASE` enum per binary.
Each enum selects a closed compile-time wrapper case; there is no runtime environment,
REQUEST, callable or operation-list switch. `build-record.json` marks those variants
`test_build:true`, and production context validation rejects them. A case may return a
simulated direct rc/errno, close then report the selected failure, or interrupt the
entry handoff after its old mask is stored. Every assertion says `simulated`; only
uninjected platform calls and real delivered signals are reported as kernel/runtime
observations.

| Suite | Required assertions |
| --- | --- |
| control-sandbox-bound | Valid complete same-set duty/claim/observation; actual evaluator execution; full-ref/source pins; altered role/argv/root/limit/partial claim; legacy-set duty; wrong entry/target/set; zero/ones/unlisted digest; two accepted unequal verifier digests; shipped empty set refusal |
| sandbox-receipt | Original check results byte-identical; explicit mode cannot be auto-selected; bound observation digest and exact d; all six control fields; retained legacy shape/accounting/mechanism/limit/outcome refusals; CPU/wall none cannot satisfy |
| shadow-enforced | Schema-2 parent-context absent/writable/malformed/schema-1/request-forged; exact helper/native field types and bounds; `E_PARENT_CONTEXT`; source/build/compiler argv and identity/P/ABI/binary/dependency mismatch; unapproved/raced helper or native binary leaves no execution marker; pinned jq before version; root/config principal bootstrap; every directory/file mode/owner/ACL/link/alias/read-race boundary; no native load after precheck failure |
| shadow-enforced | Same-P actual Mac and Linux normal reproduction passes with the fixed native owner; every Python/ACL/child conversion and checkpoint boundary is watched-blocked. Real pending HUP/INT/TERM, originally blocked/unblocked/ignored controls, repeated observations and no-signal controls prove sigpending sets the sticky cancel status without delivery, mask change or consumption; a signal after one observation is caught by the next checkpoint or final sample. Raw pending/membership failures stop new effects, preserve first_failure across later calls and reach sticky rollback; injected errors remain labelled simulated. No checkpoint can create L, no timeout/unblock fallback exists, and no primitive-only result or permanent false guard is a product positive. |
| shadow-enforced | Native handler has all-watched sa_mask, fixed sticky assignment and one nonblocking write, preserves errno, and never calls Python/allocator/CheckSignals or changes dispositions; TERM/HUP/INT combinations cannot lose the latch; full pipe, write EINTR/error and repeated delivery preserve cancellation; source plus exact output review establishes the fixed call boundary, paired real deliveries establish actual behavior. |
| shadow-enforced | Entry/partial arm/raw action capture and every restore/pipe-close failure retain authoritative ownership across lost returns; all original sigaction fields restored on success; restoration failure is sticky, rolls back while fd usable, and retains live handler storage plus pipe rather than closing/reusing an endpoint still referenced; no second acquisition/retry/destructor cleanup; queued pre-acquisition CPython flags and old returning-handler controls cannot be silently excluded or misclassified. |
| shadow-enforced | Actual root-specific thread/mask evidence distinguishes inherited blocked pthreads from workqueue/explicit-unmask paths; temporary threads cannot be receivers/waiters and must end before final census; a negative explicit-unmask/competing-owner fixture demonstrates why inheritance alone is insufficient, not a new runtime detector. Known RNG→abort watched-mask writes remain blocked on the bound image; source/error-path proof cannot be replaced by noreturn or preflight success. Fatal prefix controls assert their last real boundary and no marker; no allocator/unknown-callback path remains from first marker byte to L. |
| shadow-enforced | Real unchanged-P production build on Mac uses exact gnu11/bundle recipe and Linux exact c11/shared recipe, neither with PAC flags; exact argv mismatch and test_build refuse before load; source/script/compiler/P/ABI/output and relevant actual loader/libc/dependency identities match. RTLD_NOW/local load and module/State/symbol/first-use precede census; strong references survive release and partial restoration. Unknown relevant startup/thread/mask/handler/spawn or release contract refuses, without whole-OS certification; provenance keeps exact schema 2, path digests and the 29-file inventory. |
| shadow-enforced | Fixed platform predicate accepts the proven normal condition and refuses unsupported close-all or changed/uncertain Darwin default-filter conditions before child effects. Real inheritable extra fds, including a high-numbered fd and the parent's held descriptors, never reach exec while declared stdio does. Linux closefrom action errors retain direct rc and bounded preparation cleanup. Record gate-only controls separately; repeat the real controls on each final production output, with accepted complete dependency evidence and no test bypass. |
| shadow-enforced | Real noncompatibility Darwin UUID resolution in the fixed child plus controlled UID, group, unresolved and lookup-error semantics in original order; exact 128-entry/16-KiB/32-KiB/64-KiB bounds; malformed, duplicate-key, missing, extra, reordered and mismatched results; no path/fd/permissions/decision in the protocol; all root, principal, nonprincipal, harmless/dangerous grant and no-ACL controls remain paired; a `MemoryError` at the first post-ACL operation frees the ACL exactly once without resolver use, and a `MemoryError` during the 16-byte qualifier copy frees that qualifier then the ACL exactly once, with paired normal controls preserving UUID bytes and order |
| shadow-enforced | Actual UUID and group-role execs have checked P/S, distinct fixed argv/role, clean environment, saved mask and no inherited owner or held descriptor; neither child's native threads change the parent's census or owner. Primary real/effective gid match starts no membership child and traps parent os.getgroups; actual Darwin supplementary-only membership returns exactly the authenticated gid and passes unchanged R3 checks; actual nonmember returns empty and refuses. A controlled child-level `os.getgroups()` error exercises the same role encoder/exit boundary, exits nonzero and refuses without fallback; no fixture-only positive passes. Exact canonical gid input, empty/singleton output, extra input/field/value, malformed/oversized output, role/argv/env mismatch, normal unique reap/close, timeout and cancellation preserve one bounded cleanup and disappearance. Delayed UUID reply plus held/name mutation still refuses; every ACL caller retains its fixed resolver and nonempty ACL semantics. |
| shadow-enforced | State-owned child prepare fails after each individual pipe/attr/action/buffer acquisition with no child and one attempt per acquired resource; spawn nonzero records NO_CHILD; spawn success records raw pid/pgid/fds before a lost native return, Python assignment or later output allocation; nonconsuming exit observation and final reap each preserve raw results across lost returns; leader-before-descendants and TERM-then-leader-exit controls keep identity waitable while a required KILL remains; late cancellation before reap finishes applicable signal stages, while late cancellation after reap never signals; final reap occurs once only after matching exit observation and no remaining signal authority; normal, nonzero, exec-error, timeout, cancellation and oversize keep leader-reaped, group-absent and pipes-complete distinct; partial TERM/KILL/observe/reap/group-check/close failures retain first error and outstanding duties; repeated cleanup is inert only for consumed operations; test wrappers prove State control flow only, while actual Mac/Linux pairs prove exact executable/argv/env, session/pgid, stdio/no-extra-fd, signal mask/default, waitid/WNOWAIT and final-reap semantics, raw error/status and bounded group disappearance; the real driver pairs a real fixed normal command with synchronized actual nonzero and signaled leaders whose same-group descendant is ready, has closed stdio and remains alive, proving required TERM/KILL before one reap, no signal after reap, final absence on successful cleanup, retained raw failure otherwise and no completion marker; no arbitrary program may borrow a fixed role's normal contract; filter, wait or parent-mask UNKNOWN refuses before child effect and cannot be called a positive |
| shadow-enforced | The signaled-descendant success control reaches its first real group query only after the fixture validates the exact-child/actual-SIGKILL reaper acknowledgment. Pair that path with wrong-child, wrong-status, missing and timed-out acknowledgments that fail before query. The synchronized positive must still obtain real ESRCH; retain separate actual UNKNOWN/EPERM, no-L and raw-first-failure controls plus both old raw PASS/FAIL records without run selection. Run the original complete suite directly and the complete writer suite on the same final head, with actual Linux proof and fresh required CI; a still-unknown synchronized positive remains failed. |
| shadow-enforced | Actual materializer/preparation; pre-launch fsync ordering; nonce/request/subject/expectation equality; copied receipt; wrong candidate/evaluator/payload; success, mismatch, refusal, missing/partial evidence, timeout/cancel and unconfirmed teardown; raw instruction retention; exact 29-file inventory and marker-last behavior |
| shadow-enforced | Native finalization performs exactly one nonblocking one-byte pipe observation where any byte, EOF, uncertain descriptor or unexpected error aborts and only EAGAIN/EWOULDBLOCK permits the empty control; unrelated-byte saturation followed by delayed watched delivery and concurrent replenishment prove the fixed read bound; latch-only and pending-only refusals; no read retry, drain, wait, replay or signal consumption |
| shadow-enforced | Fresh reviewed executable positive; imported/missing-admission refusal before signal/mask/wakeup APIs; pre-existing wakeup owner under both warning modes retains fd, actions, mask, delivery and full-buffer warning behavior with zero Python signal/wakeup setter calls; native owner leaves Python handler table and disabled/warning pair untouched; nested scopes borrow; children receive saved original caller mask and no owner/pipe inheritance. |
| shadow-enforced | Both exact actual first/final native census observations remain required; entry non-one refuses before effects and final count/read/close failure selects abort and held-fd rollback. Actual bounded relevant-root evidence excludes transient competing receivers, waiters and owner replacement; census snapshots, mocks and implementation names alone do not. Final single-thread plus fixed tail proves no fd reuse. |
| shadow-enforced | Real TERM/HUP/INT on actual Mac and Linux before final block, while blocked before L and immediately after L, each paired with no-signal and caller-exception controls; original blocked, returning, `SIG_IGN` and `SIG_DFL` dispositions; checkpoint observation preserves pending, restore-IGNORE may discard, returning actions receive naturally after release, pre-L default termination follows the required rollback attempt, and post-L default termination preserves the completion decision; report only the last observed boundary; dual real failure/caller events preserve true first failure and never invent cleanup |
| shadow-enforced | NOT_RUN versus RETURNED(raw_rc/raw_errno) for entry/arm/checkpoint/final/commit/release; entry capture survives lost return and failed capture is never read; native phase/decision/result is sole authority; abort_release publishes earlier Python failure, creates no L and cannot later report success. Marker open/write/sync/close, final one-byte/pending decision, action/pipe restoration and mask/fd tail stay in one C call; fixed rooted singleton epilogue has no allocation/DECREF/callback and outcome never releases. |
| shadow-enforced | Empty-directory/held-identity precheck precedes hold; NOT_RUN, dup failure, dup/fstat failure, lost hold return and interrupted authoritative confirmation produce no marker; only normally observed no-failure consumer outcome (`native-release.pending`, not sealed success) permits the first marker byte; any owned duplicate is released once; normal close, simulated EINTR with original fd still held, simulated already-closed/EBADF, identity mismatch and unavailable no-reuse closure; exactly one fstat, no wrong-object unlink/reopen/EINTR guess, at most one conditional close and six bounded tail APIs; unlink/fsync failures remain distinct and sticky |
| shadow-enforced | Exact bytes/nonempty/1-MiB cap and fixed driver-generated canonical payload; subclass, bytearray, buffer exporter, oversized/invalid input and wrong phase refuse before open; all business/JSON/ordinary cleanup, final census and active-parent restoration precede marker creation. Real fatal prefix paired with normal control proves last boundary and absent marker, never imagined rollback. Review actual marker-to-L native call closure for no allocation, deferred first use or unknown callback; prepared bytes cannot stand in for completed outcome. |
| shadow-enforced | Exclusive fixed marker open failure, short/zero write, EINTR/other write error, file/directory fsync and marker-close failure preserve direct raw results and one cleanup attempt; partial/full marker removal uses only the separately usable held directory, never retries an unknown marker fd or deletes an unowned EEXIST entry. Pair true returning I/O failures and real HUP/INT/TERM after first byte, full write and fsync with actual Mac/Linux success and no-signal controls; distinguish simulated syscall cases. Boundary injection remains native until shared cleanup seals; a lost final Python-visible commit return still leaves raw State authoritative, with no early Python return after marker creation. No pre-L failure can be reported as completed and no success marker remains except an explicitly observed failed/unavailable rollback. |
| shadow-enforced | Earlier Python preparation/release failure rolls back before unmask through the usable held fd and survives later native success; post-L ValueError, identical errno/text OSError, MemoryError, SystemExit, driver Refusal and `_consumer.Refusal` pair with native success/failure; normal observation classifies authoritative State; a new sentinel interrupting observation crosses the real complete outer-main reporting boundary with its context, no fabricated E_RUNTIME/product cleanup/marker change/repeated release, and no promise that the earliest caller beats a later event |
| shadow-enforced | Ledger starts before resolver/load_anchor and retains early, repeated, final-recheck, failure and cancellation batches in order; empty batches add no row; freeze precedes no child and later held/named seal still detects drift. On Linux bind the real host fd-path function before mocking Darwin platform, then run the original metadata mutation refusal and positive block without swallowing EINVAL, skipping assertions or faking fstat |
| shadow-enforced | All semantic, durability, child and ordinary cleanup work precedes L; ordinary child-close OSError tries other distinct owned children once, retains the first error, never retries result-unknown fds, leaves definitely unattempted responsibility in the original container and makes repeated close inert; no arbitrary-BaseException attempt-all; no cleanup work follows L; preserve actual child handoff, recoverable I/O, one bounded group cleanup and disappearance, displaced-directory/held-descriptor rollback, late exceptions, and sticky unlink/fsync/close/native-action/private-pipe/mask/active-parent restoration failures; all Python preparation and active-parent restoration precede the first marker byte, and the unchanged Python wakeup pair has no restoration call to fail |
| shadow-write | Reauthenticate frozen receipt/payload; regenerate evaluation; missing/extra/modified evidence; seed converter refs; original profile graph unchanged; exact protocol input/response; altered payload/ref digests; required allowed_modes plus actual100644; add-only/single-parent/protected/existing/binary/oversize failures |
| shadow-write | Roles 16–18 each pair their actual fixed successful command with wrong-role, role 19, argv and environment refusal before spawn. Concrete final-binary checks retain saved mask, close-all, unique observe/reap and group disappearance. Nonzero, oversize, timeout and cancellation preserve raw State failure and no completion marker; unchanged native/platform receipts and the real `shadow-enforced` regression are compatibility evidence, never substitutes for these new-role controls. |
| shadow-write | Real role-16 converter emits the sole named canonical seed with stdout/file equality; extra inventory, byte drift and fresh-origin input refuse. Real role-17 phases use retained contract/patch/metadata files, accept the maximum valid patch without exceeding native argv, and reject malformed, extra-phase, changed-source/core/J/input and invalid generated protocol data. |
| shadow-write | Real role-18 fixed Git reads prove admitted config, bare/hash algorithm, complete source/candidate trees, sole parent and raw blob facts. Revision expressions, pathspecs, unlisted commands/options, writes, hooks/filters and changed metadata refuse. Pair every new role's positive with nonzero, oversized output, timeout/cancel and absence of an early completion marker. |
| shadow-write | Separate original/write attempt subjects; identical two-run tree/write_set/request despite nonce/time differences; zero producer/model/publisher calls; exact withholding/admission/post-write equality; source/store digests unchanged; no committed outer-attempt bytes |

Run the slice's new suites and affected compatibility suite before its review:
`bash scripts/test/control-sandbox-bound.test.sh`,
`bash scripts/test/sandbox-receipt.test.sh`,
`bash scripts/test/control-sandbox-policy.test.sh` (slice 1 legacy compatibility),
`bash scripts/test/shadow-enforced.test.sh`,
`bash scripts/test/shadow-write.test.sh`, as each becomes available.
Each test script must be runnable directly and discovered by the existing test
runner without editing its bootstrap or CI workflow.

For slice 1, add only `control/v1/control-policy-set-sandbox-bound.json` to the
existing corrective-v2 generation tracked-path expected list in
`scripts/test/portable-core-schema.test.sh`, preserving every other entry and check.
Run `bash scripts/test/portable-core-schema.test.sh` after all candidate files are
staged or committed. Verify the tested Git index contains their exact candidate bytes;
untracked-file runs cannot prove this guard. Keep legacy bindings and authority unchanged.

At slices 3 and 5 run the existing integration suites with `bash scripts/test/NAME`:
`shadow-slice.test.sh`, `shadow-assembler.test.sh`, `shadow-self-host-evidence.test.sh`,
`file-digest-verifier.test.sh`, `candidate-content-preparation.test.sh`,
`local-git-materializer-protocol.test.sh`, `local-git-materializer-adapter.test.sh`,
`maintenance-loop.test.sh` (converter coverage), and `scope-qualification.test.sh`.
Confirm the unchanged scope evaluator refuses the new record form until child 6.
Use the existing pinned jq 1.6 fixture cache; a system jq with a different version
cannot substitute. No new tool installation is needed. Use shellcheck 0.11.0 with
`-x -S style` on changed shell files and the repository’s required quick CI.
SC-CANCEL-3 remains a repair of original PR #519. Full run `38051431041` remains failed and
formal G3 remains NOT PASS. After this plan is independently accepted and protected-merged,
resume only the preserved clean implementation attempt by an ordinary merge whose first
parent is its verified current head and second parent is the accepted new main. Verify the
clean state, ordered parents, tree, history and unchanged implementation bytes before push,
then obtain a fresh exact claim/evidence tuple. Do not reset, clean, stash, rebase, force,
replay the patch, recreate the branch/worktree or use a dirty merge. Then allow the original Sol
repair; require the actual Mac/Linux proof, all relevant shadow suites, the six-shard full
matrix and one fresh G3 on exact head. Quick green is not that matrix.
