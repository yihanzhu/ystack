---
spec-blob: 1aa98f5b467bbca0ee01d45f105129737ea24422
risk: high
drafted: 2026-10-06
---
# Plan: inactive shadow-consumer integration

Tracks #506. This implements Step-8 child 5 under the accepted spec. The authoring base
is `c5ef9bda4a3a02153a8ebf854143de9cc56b9b8b`; base movement is external context, not
permission to change meaning. Intent blob: `6feb2ad7dd5f096bdd483ed9bace07cae2c24be5`.

Plan PR: `review_size: accepted-exception`, 700–825 lines. The five-slice contract, closed
native context, direct-result release and signal/fd proof need one coherent implementation
brief. This changes only the soft size budget.

## Files that change

Only `work/shadow-consumer-integration/plan.md` changes in the plan PR. The five
implementation slices keep their accepted order. Slices 1, 2, 4 and 5 retain their
landed scope. SC-CANCEL-3 repairs slice 3 on the original branch and PR only; it does
not create another implementation attempt. The first four track #506; only the fifth
closes it.

| Slice | Exact implementation paths, excluding the common documentation set |
| --- | --- |
| 1 — bound evaluator/checker | `control/v1/sandbox-bound-policy.json`, `control/v1/sandbox-bound-decision.json`, `control/v1/control-policy-set-sandbox-bound.json`, `control/v1/evaluate-bound-sandbox.sh`, `control/v1/sandbox-bound.jq`, `enforcement/v1/check-sandbox-receipt.sh`, `enforcement/v1/sandbox-receipt.jq`, `scripts/test/control-sandbox-bound.test.sh`, `scripts/test/sandbox-receipt.test.sh`, `scripts/test/portable-core-schema.test.sh` (only the spec R10.9 expected-path addition) |
| 2 — trusted dependencies and origin reader | `shadow/v1/_consumer.py`, `scripts/test/shadow-enforced.test.sh` |
| 3 — enforced reproduction | `shadow/v1/_cancel_release.c`, `shadow/v1/build-cancel-release.sh`, `shadow/v1/_consumer.py`, `shadow/v1/enforced-reproduction.py`, `scripts/test/shadow-enforced.test.sh` |
| 4 — add-only materialization | `shadow/v1/_consumer.py`, `shadow/v1/write-shadow.py`, `shadow/v1/write-materialization-input.jq`, `scripts/test/shadow-write.test.sh` |
| 5 — withheld request and complete integration | `shadow/v1/_consumer.py`, `shadow/v1/write-shadow.py`, `scripts/test/shadow-write.test.sh`, `scripts/test/shadow-enforced.test.sh` |

The common documentation set is exactly `docs/components.md`, `RESTORE.md`, and
`ci/required-files.txt`. The SC-CANCEL-3 slice-3 repair therefore has exactly eight
paths: its five table entries plus this three-file set. In `ci/required-files.txt` it
only appends the two native files. `scripts/test/shadow-slice.test.sh` remains prior
slice history and is not a repair path. Each other slice may change only its accepted
component descriptions and manifest entries. Keep shell drivers/tests executable.
Intermediate entry points refuse operations whose remaining checks are not implemented;
they cannot emit a completed write bundle early. No other source or accepted artifact
changes.

| Slice | Classification | Net-line range | Evidence for the estimate |
| --- | --- | --- | --- |
| 1 | Accepted exception | 1000–1200 | Closed R10 evaluator with bounded snapshots and full refs; shared checker preserving legacy outputs; paired binding and compatibility tests, fixed data and restore docs |
| 2 | Accepted exception | 1200–1400 | Complete installed-byte/verifier binding, full ancestor/ACL/store validation, and meaningful trust-boundary regression proof |
| 3 | Accepted exception | 4200–5000 | The preserved 3597-line candidate plus the private C/build boundary, context/provenance and ledger repairs, and paired signal/fd/Linux regressions remains one enforced-reproduction concern. |
| 4 | Accepted exception | 1200–1700 | Full frozen-bundle, input, patch, digest and candidate-tree relations with real materializer proof |
| 5 | Accepted exception | 700–1100 | Complete two-attempt admission and integration proof, including withholding, determinism and source/store purity |

If the complete readable change cannot fit its accepted slice, stop before an
unexplained overrun and return through the plan gate. Do not remove proof or create
extra parallel initiatives. No bootstrap, workflow, installation or policy-authority
change is included.

The slice-3 range starts from the measured 3597-line candidate. Allow 250–450 lines for the
native source/build recipe, 150–300 for Python context, provenance, ledger and release,
300–650 for paired regressions, and 20–60 for the three common files. Replacing the old
exception path offsets part of that addition. The rounded 4200–5000 range leaves readable
room without padding, compressed code or omitted proof.

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
physical `/usr/bin/cc` once. The common argv is `-std=c11 -Wall -Wextra -Werror -O2
-fvisibility=hidden -fPIC` plus the two captured Python include directories and fixed
source/output paths. Darwin adds `-bundle -undefined dynamic_lookup`; Linux adds
`-shared`. Any other platform or empty/nonphysical sysconfig value refuses. OUT ends
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

The dependency record is parent-retained canonical evidence, not a bundle sidecar. It
binds the actual P/framework, extension, loader and relevant libc/system images, plus
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

For the production anchor, walk from `/` to the exact spec R3 path. First require
root ownership and no non-root write grant for config/script and their ancestors.
Only then parse config and trust principal_uid, consumer_gid, store_id and store_root.
Check real/effective consumer UIDs, supplementary group membership, and nonzero
separate supervisor UID. There is no caller/test environment override of this path.
Validate installed files and verifier path under R10.1, permitting only root or the
already authenticated supervisor principal where that contract allows it.

On macOS use one private ACL boundary in `_consumer.py`. Before cancellation
admission, bind the fixed descriptor ACL retrieval, iteration, qualifier-copy and
free functions from the absolute system C library and account for that small native
wrapper in the parent's source/runtime closure. The parent copies each entry's tag,
permission bits and exact 16-byte UUID while the descriptor remains held, frees all
native ACL and qualifier allocations, and performs the existing metadata checks
around the capture. It never calls membership resolution or initializes that service,
including for compatibility UUIDs. Keep the 128-entry maximum and original ordering.

Resolve only the captured UUID bytes in one fresh fixed child per bounded ACL batch:
`P -I -S -B S/shadow/v1/_consumer.py _resolve-darwin-uuids`. This is a private role
in the existing source file, not a public CLI, helper registry or selectable command.
The role cannot invoke the parent consumer or recurse. Its canonical JSON input is
an exact array of at most 128 lowercase 32-hex UUIDs and at most 16 KiB. Its canonical
JSON output is at most 32 KiB and has one positional result per input. Each result
has exactly `{uuid,status,kind,id}`. Status is `resolved` or `unresolved`; a resolved
row has kind `user` or `group` and an unsigned 32-bit id, while an unresolved row
has null kind and id. Reject duplicate JSON keys, extra or missing rows,
reordered/mismatched UUIDs, unknown fields, malformed values and trailing data. Map
only a resolved user row to the existing identifier; group and unresolved rows keep
the existing no-identifier semantics. A membership miss stays unresolved; transport,
protocol or process failure refuses the ACL observation. A child result supplies
neither permission bits nor an authorization decision.

The already trusted parent fixes P and the reviewed physical S under spec R2.1/R2.4
before the first ACL operation, using the admitted standalone invocation and retained
source bytes rather than an ACL observation made through this resolver. Recheck those
identities and `_consumer.py` before each launch. This breaks the bootstrap cycle:
ACL checks do not establish the interpreter or resolver source that they invoke.
The enforced-reproduction entry constructs one module-private resolver from the
existing cancellation-aware runner and the fixed argv, then passes that value through
every parent-facing held-path rule and recheck that can inspect a Darwin ACL. It is a
fixed concrete adapter, not an arbitrary callable. A missing resolver refuses before
the first Darwin ACL capture; the child role cannot construct or receive one. Thus
every existing ACL caller is accounted for, with no default in-process membership
fallback, caller-supplied callback or request-selected runner. Linux keeps fd-based
POSIX ACL xattr reads and makes no resolver call. Fail on unsupported or unreadable
ACL observations on either platform.
Accept no ACL on store objects. Root-only anchor checks reject every grant permitting
another principal to modify it; later installed-object checks follow VM R10.1 exactly.

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
| Resolve Darwin UUIDs | `P -I -S -B S/shadow/v1/_consumer.py _resolve-darwin-uuids` |

Fixed script calls receive only `PATH=DEPENDENCY_BIN:/usr/bin:/bin`, `LC_ALL=C`,
`LANG=C`; DEPENDENCY_BIN contains the checked jq. Clear inherited Git configuration,
hooks, prompts, loader/Python variables, functions and network/proxy settings.
All children close inherited descriptors except their declared stdio. Use a new
process group per ordinary component. Each ordinary child has a 120-second deadline,
64 KiB stderr cap and its upstream output cap (1 MiB where no tighter cap exists).
Preparation/inspect have 300 seconds, matching their existing operation bound.
On expiry stop that owned child group, wait at most 10 seconds and record failure;
never call a truncated output successful. Consumers have a 1,200-second overall
budget; a deadline only removes opportunities for work, never relaxes admission.
The resolver uses the same cancellation-aware child runner, fixed cleared environment,
new process session, applicable mask, `close_fds=True`, no `pass_fds`, and declared
stdio only. It has a 10-second batch deadline within that overall budget, a 32 KiB
stdout cap and 64 KiB stderr cap, with no retry. Normal completion waits and reaps,
closes every pipe and selector, and validates output before using it. Timeout,
cancellation or failure performs the existing one bounded owned-group cleanup and
confirms disappearance within its 10-second maximum. No resolver work or resource
survives into the completion tail.

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

Keep cancellation in the existing private `CancellationSignals` boundary. It owns
the watched `TERM`, `HUP` and `INT` dispositions, sticky latch, owned-child cleanup,
private wakeup pipe and retained output-directory descriptor. Its only outer
acquisition path is the existing reviewed executable invocation `PYTHON -I -S -B
SOURCE/shadow/v1/enforced-reproduction.py reproduce REQUEST WORK OUTPUT` from the
trusted parent in spec R2.1/R2.4. An imported or library call without that private
startup admission refuses before any signal, mask or wakeup API call. Nested scopes
borrow the outer latch and cleanup state; they cannot acquire a lease, install a
wakeup fd, retain completion or define another transfer point.

`_cancel_release` is private to this boundary. It exports only `prepare_state()`, and
the returned opaque non-subclassable `NativeState` has fixed methods
`block_entry()`, `resume_consumer()`, `hold_completion(fd)`, `block_final()`,
`rollback_marker()`, `finish_release()` and `outcome()`. Every method except
`hold_completion` is NOARGS; that method accepts one exact built-in integer directory
fd and duplicates it internally. There is no how/mask/path/syscall-list/callable
argument, generic operation dispatcher, public cancellation API or REQUEST-selected
value. Calls outside the fixed phase refuse before a native effect.

State is allocated before the first census and contains only the necessary authority:

- entry and final native `sigset_t` values and direct entry, resume, final and finish
  mask-result cells, each tagged `NOT_RUN` or `RETURNED(raw_rc)`; an old mask is usable
  only for its successful capture;
- one completion-fd ownership value, the immediately captured dev/inode/type, and
  fixed close/fstat/unlinkat/fsync result cells storing direct rc and errno copied in
  the next C statement after failure;
- one phase value (`prepared`, `entry-blocked`, `consumer`, `final-blocked`,
  `release-running`, `sealed`), one rollback-attempted value, and `first_failure`
  pointing to the first fixed result cell without overwriting it; and
- preallocated outcome singletons and strong references required for the module,
  State and every bound method to survive the protected interval.

Do not add parallel valid/executed/error copies. `NOT_RUN` distinguishes a Python
argument, recursion or dispatch failure before the C body from a native call that
returned nonzero. State has no destructor that closes the completion fd, rolls back a
marker or repeats release. `hold_completion` duplicates ownership and stores the owned
fd before returning to Python, then records its fstat identity; Python never receives
an unrecorded duplicate awaiting assignment.

Admission requires the Python main interpreter thread and a fresh closed startup
whose reviewed physical runtime, standard/native dependency closure and exact imports
establish that file-descriptor wakeups begin disabled with the chosen warning setting
and no Python or native signal owner exists. This is source/runtime evidence about the
already accepted fixed invocation, not a request field, certificate, interpreter-name
allowlist or claim that Python >=3.11 alone proves the invariant. Place admission after
only reviewed imports. Unknown provenance refuses without calling `set_wakeup_fd`;
never install and restore a temporary fd to discover an arbitrary prior owner. Once
admitted, the setter's returned disabled value is only a consistency assertion. Release
restores the known disabled/warning pair, never a guessed former owner's state.

Prove one process-wide watched-signal receiver with both an OS observation and a
closed-code invariant. On Linux, read `/proc/self/status` under a fixed byte cap and
require one well-formed `Threads: 1` field plus matching process identity. On macOS,
load and bind fixed system libproc before the protected tail, call
`proc_pidinfo(PROC_PIDTASKINFO)` into the documented fixed-size `proc_taskinfo`, require
the exact result size and `pti_threadnum == 1`. Use no helper executable, privilege,
polling or task suspension. Observe once before product effects and again after final
ordinary cleanup while watched signals are blocked; malformed, inaccessible, truncated,
mismatched or non-one results refuse, and temporary observation-descriptor close failure
also aborts.

The census is necessary but insufficient. Evidence for each actual physical macOS and
Linux runtime must identify its version/build and the startup, stdlib and native closure
relevant to this path, and show that the interval after the first observation plus the
finite final tail cannot create a native receiver or waiter, change the watched mask or
dispositions, or replace/read the wakeup fd. The initialized tail permits only the
private OS observation, mask/read/pending APIs, primitive bookkeeping, rollback and
fixed release. It has no imports, components, subprocesses, arbitrary callbacks, lazy
native loads, audit/trace callbacks or finalizers that can create or consume a receiver.
The plan requires this truthful evidence before runtime admission; a Python thread
registry, mocked count, implementation-name check or asserted source property is not
proof.

On macOS that evidence covers the parent's prebound ACL capture/free wrapper but not
membership internals, because all membership calls occur after exec in the resolver
child. Process isolation plus checked child termination prevents that child's native
threads, callbacks and service state from becoming parent receivers. This does not
claim the membership service is thread-free. The proof must inspect the parent's
actual admitted call graph and show no remaining membership symbol call or lazy load;
unknown parent native closure still refuses. Linux keeps its existing independent
runtime proof.

After admission, call `block_entry()`. Its C body uses the hard-coded HUP/INT/TERM set,
calls `pthread_sigmask(SIG_BLOCK,...)` once, and stores raw rc and the old mask before
it can return. Only rc 0 installs the outer owner. If Python dispatch or assignment is
interrupted after return, unwind consults State and restores the valid native old mask;
it never relies on `entered = True`. `NOT_RUN` or nonzero rc never reads an
uninitialized mask or installs an owner. Nested scopes borrow that owner and State.

While the watched set is blocked, create one private nonblocking close-on-exec pipe,
install its write end with the known warning mode, install consumer handlers, then call
`resume_consumer()` to restore the entry old mask from State. Its real rc is stored
before return. The signal module writes a byte when a handled signal is received; the
handler independently makes the latch sticky. Children inherit neither pipe endpoint
nor owner state and preserve the applicable caller mask.

Before the final decision, finish every admitted component action, evidence/identity
and inventory check, marker/file/directory fsync, child cleanup and ordinary resource
close. The marker remains provisional. Before L, pass its trusted held directory fd
once to `hold_completion`; State owns the duplicate and original dev/inode/type before
Python resumes. Close the ordinary seal fd before L. Then call `block_final()`, which
stores the real mask rc and final old mask before return. Only its successful result
permits the final native-thread observation and exactly one nonblocking one-byte pipe
read. Any returned byte sets sticky
delivered-or-uncertain, regardless of identity. EOF, uncertain descriptor state or any
error other than the expected empty `EAGAIN`/`EWOULDBLOCK` sets the same flag; only that
expected empty result clears this input. Never drain, retry or make a second read. An
unrelated-byte-full pipe therefore aborts even if a later watched byte was lost, and
concurrent replenishment cannot extend the fixed observation. Read the sticky latch and
take one watched `sigpending()` snapshot while the set remains blocked.

The decision inputs are: outstanding exception; sticky latch; delivered-or-uncertain;
watched pending set; and any admission, preparation, observation or release-preparation
failure. Every nonempty input selects abort and stays sticky. Success requires all
preconditions complete and all five inputs clear. That successful pending-set sampling
instant is completion handoff **L**; native finish and the later Python assignment are
not L. No semantic, durability, child or ordinary resource work and no second completion
decision follows L.

Abort never calls `sigwait` and never drains, consumes, replays, counts or manually
invokes a signal. While watched signals remain blocked, call `rollback_marker()` so
State uses its owned directory duplicate for at most one descriptor-relative unlink of
fixed `bundle.json` and one fsync, recording each direct result. A Python preparation or
release-preparation failure that became sticky before L takes this same rollback path
before unmask while the fd is usable. Later native success cannot erase it. Then
continue bounded best-effort release, restore the exact original handlers, known
disabled wakeup state, active parent and caller mask, and close ordinary owned
descriptors. Caller-blocked pending
signals with original returning or default dispositions remain blocked and pending.
For original `SIG_IGN`, exact disposition restoration after rollback may discard a
pending signal while it is still blocked; that is the caller's original kernel
semantics, not consumer consumption or replay. A signal newly blocked by finalization
follows its original disposition after rollback as the exact disposition and mask are
restored; ignored discard may occur at disposition restoration before unmasking.
Default disposition may terminate the wrapper after marker removal; returning or
ignored controls report nonzero `E_RUNTIME`. Never relabel that pre-L abort as a post-L
caller signal. Other failures keep their existing `E_RUNTIME` behavior.

After L and while watched signals remain blocked, restore original handlers, the known
disabled wakeup/warning pair and active parent, then close ordinary pipe fds. No caller
handler wrapper delays the original disposition. Call `finish_release()` exactly once.
Its native critical tail uses the valid final old mask with `pthread_sigmask`, records
the direct return code immediately if the call returns, performs any required rollback,
and closes the final completion duplicate before Python can dispatch a caller. It does
not call Python, CheckSignals, release the GIL, allocate, DECREF, import, load or resolve
a symbol, open/dup an fd, invoke a callback or create a receiver.

A nonzero mask result is a true sticky failure. While the owned fd is still usable,
perform the not-already-attempted fixed unlinkat/fsync rollback before closing it. A
successful native mask result cannot erase an earlier sticky failure. For the final
close, store rc and errno immediately. Success makes ownership closed and never touches
that integer again. Failure performs exactly one fstat. EBADF, fstat error, identity
mismatch or missing no-reuse proof marks the fd unusable and never unlinks, reopens or
retries it. Only when the admitted process is actually single-threaded, the fixed tail
has no fd allocator/replacement, unknown native callback or pthread-cancellation cleanup,
and dev/inode/type still match may State treat it as the original usable directory,
perform a not-already-attempted unlinkat/fsync, and make at most one conditional close.
Each unlink/fsync/close result remains independent and sticky; no failed cleanup is
reported as removal success.

The final native tail has at most one mask call, two close calls, one fstat, one unlinkat
and one fsync. A pre-L rollback already attempted is not repeated. This finite count is
not a syscall wall-time guarantee. It makes no EINTR-state guess and has no loop, path
reopen, replacement handle, second census or second completion decision.

The critical tail ends only after State seals ownership, every direct result and
`first_failure`. The C epilogue may only return a new reference to a preallocated,
strongly rooted status singleton; that fixed INCREF is outside the sealed syscall tail and
performs no allocation, DECREF or callback. `outcome()` is a read-only NOARGS getter for
that singleton and never releases. Later diagnostic formatting has no control authority.
An interruption before, during or after the getter, Python assignment, formatting or GC
does not infer native failure, repeat a syscall or enter a retry loop.

Every outer recoverable/refusal branch checks authoritative State before cleanup logic.
When L occurred and native release succeeded with no earlier failure, any later caller
exception keeps the marker and caller ownership: driver `Refusal`,
`_consumer.Refusal("E_RUNTIME")`, `E_PARENT_CONTEXT`, identical errno/text `OSError`,
`ValueError`, `MemoryError`, `SystemExit` and other `BaseException` controls all pair
with the same completion result. They cannot create a new inconclusive bundle, roll
back, run another product action or relabel the event pre-L. A true native or earlier
failure remains sticky even if the caller also raises, and ordinary control that
continues reports the existing `E_RUNTIME` precedence.

`SIG_DFL` may terminate inside the unmask call before rc is recorded or the final close
runs; it may also terminate after a true failure and before best-effort rollback. Do not
delay the original disposition to obtain a report. Record only the last boundary an
external observer actually saw, never imaginary cleanup, success or an `E_RUNTIME`
return from a dead process. Returning or ignored dispositions follow the sealed outcome.

Keep the accepted frozen-reader contract. Add no producer status, terminal-result
trust, sidecar, inventory member, accepted identity, helper, launcher change or public
multithreaded cancellation API. Preserve all closed child-handoff, recoverable-I/O,
bounded-cleanup, durability, held-descriptor rollback and late-failure behavior.

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
all their cross-document bindings. Write exclusive canonical bundle.json last,
fsync file and output directory, and enforce the exact inventory. Partial failures
keep evidence without a completion marker. JSON canonicalization is UTF-8 sorted
keys, compact separators, one trailing LF, no nonfinite numbers or duplicate keys;
prove agreement with pinned jq on all generated documents.

### 7. Deterministic write materialization field map

Before preparing a write, verify the completed frozen reproduction inventory and
reopen its original controlled-store attempt. Require identical receipt/payload
snapshots and repeat the fixed evaluator/checker checks. Keep this fresh observation
only in outer write provenance. The committed reproduction bundle never changes.
Run the existing converter and require its sole output
`eval-seed-case-stale-moved-artifacts.json`; copy those exact bytes as eval-seed.json.

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
| shadow-enforced | Real production recipe on actual Mac and Linux records exact source/script/compiler/P/ABI/output; accepted RTLD_NOW/local absolute load and init/State/symbol/first-use precede first census; strong refs survive release; unknown JIT, image/shared-cache UUID, loader/libc, complete package/source revision or dependency closure refuses; test-build identity and unaccepted LD_/DYLD_ context refuse without import; provenance exact fields/path digests and stale frozen-reader cases preserve the 29-file inventory |
| shadow-enforced | Real noncompatibility Darwin UUID resolution in the fixed child plus controlled UID, group, unresolved and lookup-error semantics in original order; exact 128-entry/16-KiB/32-KiB/64-KiB bounds; malformed, duplicate-key, missing, extra, reordered and mismatched results; no path/fd/permissions/decision in the protocol; all root, principal, nonprincipal, harmless/dangerous grant and no-ACL controls remain paired |
| shadow-enforced | Actual resolver exec has the checked P/S/argv/environment/mask and no inherited owner or held descriptor; a resolver with native threads leaves the parent's census and wakeup ownership unchanged; normal exit/reap/close, exit failure, timeout, cancellation and oversized output prove one bounded group cleanup and disappearance; delayed reply plus parent held/name metadata mutation refuses before result use; every existing ACL caller uses the fixed resolver and no in-process membership fallback |
| shadow-enforced | Actual materializer/preparation; pre-launch fsync ordering; nonce/request/subject/expectation equality; copied receipt; wrong candidate/evaluator/payload; success, mismatch, refusal, missing/partial evidence, timeout/cancel and unconfirmed teardown; raw instruction retention; exact 29-file inventory and marker-last behavior |
| shadow-enforced | Exactly one nonblocking one-byte pipe observation where any byte, EOF, uncertain descriptor or unexpected error aborts and only EAGAIN/EWOULDBLOCK permits the empty control; unrelated-byte saturation followed by delayed watched delivery and concurrent replenishment prove the fixed read bound; latch-only and pending-only refusals; no read retry, drain, wait, replay or signal consumption |
| shadow-enforced | Fresh reviewed executable positive; imported/missing-admission refusal before every signal/mask/wakeup API; an existing wakeup owner under each warning mode keeps its fd, handlers, mask, delivery and full-buffer warning behavior with zero setter calls; nested scopes borrow only; child mask and no pipe/owner inheritance |
| shadow-enforced | Linux capped `/proc/self/status` identity/`Threads: 1` and macOS preloaded fixed libproc exact-size/`pti_threadnum == 1`; entry non-one/unregistered native thread refuses before effects and final count/read/close failure rolls back; complete physical runtime/startup/dependency and initialized finite-tail evidence proves the census stays exclusive, while a mocked count, Python registry or implementation name does not |
| shadow-enforced | Real TERM/HUP/INT on actual Mac and Linux before final block, while blocked before L and immediately after L, each paired with no-signal and caller-exception controls; original blocked, returning, `SIG_IGN` and `SIG_DFL` dispositions; pending preservation/discard semantics; default termination reports only the last observed boundary; dual real failure/caller events preserve true first failure and never invent cleanup |
| shadow-enforced | Native `NOT_RUN` versus `RETURNED(raw_rc)` for entry/resume/final/finish; entry success interrupted before Python assignment still restores saved old mask; failed entry never reads it; nested scopes borrow one owner; direct result cells and first-failure precedence; module/State/method lifetime and fixed return epilogue have no allocation/DECREF/callback in the sealed tail |
| shadow-enforced | Completion dup ownership is recorded before Python handoff; normal close, simulated EINTR with original fd still held, simulated already-closed/EBADF, fstat error, identity mismatch and unavailable no-reuse closure; exactly one fstat, no wrong-object unlink/reopen/EINTR guess, at most one conditional close and six bounded tail APIs; unlink/fsync failures remain distinct and sticky |
| shadow-enforced | Earlier Python preparation/release failure rolls back before unmask through the usable held fd and survives later native success; post-L ValueError, identical errno/text OSError, MemoryError, SystemExit, driver Refusal and `_consumer.Refusal` pair with native success/failure; outer recoverable/refusal branches never repeat release or create new inconclusive output; interrupted getter/assignment/formatting/GC neither guesses failure nor retries |
| shadow-enforced | Ledger starts before resolver/load_anchor and retains early, repeated, final-recheck, failure and cancellation batches in order; empty batches add no row; freeze precedes no child and later held/named seal still detects drift. On Linux bind the real host fd-path function before mocking Darwin platform, then run the original metadata mutation refusal and positive block without swallowing EINVAL, skipping assertions or faking fstat |
| shadow-enforced | All semantic, durability, child and ordinary cleanup work precedes L; no such work follows it; preserve actual child handoff, recoverable I/O, one bounded group cleanup and disappearance, displaced-directory/held-descriptor rollback, late exceptions, and sticky unlink/fsync/close/handler/wakeup-fd/mask/active-parent restoration failures |
| shadow-write | Reauthenticate frozen receipt/payload; regenerate evaluation; missing/extra/modified evidence; seed converter refs; original profile graph unchanged; exact protocol input/response; altered payload/ref digests; required allowed_modes plus actual100644; add-only/single-parent/protected/existing/binary/oversize failures |
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
formal G3 remains NOT PASS. After this plan is independently accepted and merged, allow one
original Sol repair; then require the actual Mac/Linux proof, all relevant shadow suites,
the six-shard full matrix and one fresh G3 on exact head. Quick green is not that matrix.
