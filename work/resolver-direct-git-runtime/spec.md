---
intent-blob: a495d935a4dd1907bac4b30a18f52cff81550893
risk: high
drafted: 2026-09-14
---
# Spec: Direct Git selection for the resolver runtime

Tracks #316. Drafted from main 29aefc52fb68b42c27a9588f5f390e20c7efd20a.
This repairs one inactive runtime dependency. It neither delivers the trusted parent
nor accepts the pending Darwin cache exception.

## Requirements

### R1. Select one existing Git through a trusted platform observation

Add one private initialization boundary in `scripts/lib/profile-resolution.sh`.
Call it in `profile_resolution_main` after the existing usage, trusted-marker,
helper, jq and bound-awk checks, before scratch creation or any Git invocation.
Sourcing the library must not execute the probe. Do not read a preexisting selected
Git variable, infer the platform from file presence, or accept caller selection.

Use only the existing system executable `/usr/bin/uname` with the fixed argument
`-sm`. Before calling it, require a regular executable final path which is not a
symlink. Its containing system directories and OS installation remain trusted host
dependencies under the supported launcher contract; this does not claim protection
against an administrator replacing tools. Record its actual executable SHA-256 and
platform identity in test evidence, not a mutable version name alone.

Accept only these exact stdout byte strings, including one final LF:

| Platform bytes | Private selected Git path |
| --- | --- |
| `Linux x86_64\n` | `/usr/bin/git` |
| `Darwin x86_64\n` | `/Library/Developer/CommandLineTools/usr/bin/git` |
| `Darwin arm64\n` | `/Library/Developer/CommandLineTools/usr/bin/git` |

The table uses `\n` to show one LF, not two literal characters. Require successful
probe status. Empty, extra-line, truncated, NUL-containing, non-ASCII, oversized,
unknown OS/architecture or failed output refuses. Do not derive trust from OSTYPE,
MACHTYPE, HOSTTYPE, PATH, DEVELOPER_DIR, a caller variable or the presence of CLT.
No fallback to the Darwin shim, xcrun, xcode-select, another Xcode installation,
a PATH executable or a downloaded tool exists.

Bound capture before shell allocation: read at most 65 probe-output bytes, reject
anything above 64, and preserve byte identity rather than dropping NULs or trailing
LFs through plain command substitution. The existing fixed `/bin/dd` and
`/usr/bin/od` may provide bounded byte capture and a decimal representation for the
closed comparison. Validate these dependencies before using them; check the whole
pipeline status so a producer or reader failure cannot become platform success.
No probe file, cache or new scratch directory is created. The existing launcher
process, memory, file and 300-second invocation limits cover this startup call;
this spec adds no independent per-probe wall-time promise or watchdog.

After selection, require that exact Git path to be a regular executable final file
and not a symlink. Do not execute Git to discover a path. Keep all other existing
dependency checks. Missing/unsupported uname or selected Git, failed observation
or malformed output returns nonzero, empty stdout and exactly
`E_RUNTIME dependency\n`. Preserve earlier E_USAGE and binding/dependency precedence.
An inherited private Git variable must not survive a failed or new initialization.

### R2. Use that selection everywhere and preserve all Git checks

The selected value is a private runtime variable, assigned only from R1's table.
It replaces the fixed Git executable in all five existing invocation sites:

1. The `exec` inside `profile_resolution_git`.
2. Startup `hash-object` of `scripts/core-contract.sh`.
3. Startup `hash-object` of the selected generation registry.
4. Startup `hash-object` of the selected generation's `contracts.jq`.
5. Startup `hash-object` of the selected generation's `core-ingress.sh`.

The dependency inventory must validate the selected executable, not also require
the unselected Darwin shim. Quote the selected executable as one token. Keep each
call's current arguments, environment restrictions, redirects, status handling and
expected OID comparisons. No extra version/probe Git invocation is needed at runtime.

Preserve the four expected blob constants, core merge, generation, publisher receipt
and schema-major constants exactly. No pin is replaced with a newly computed value.
The private repository path remains the only repository used by bounded object reads;
startup checks remain checks of the same trusted runtime closure. No remote command,
checkout, filter, helper, hook, lazy fetch or writable source repository is introduced.
Retain object type/size/body/OID verification, NUL tree parsing and both SHA formats.

Existing tests which source the library and then invoke Git-using internal functions
must explicitly call the same actual initialization boundary first. They cannot
supply a different Git variable or gain a fallback merely because they bypass main.
Internal tests which do not use Git need not start a new platform probe.

### R3. Preserve behavior, limits and cleanup

The same accepted request, map and object graph produces the same canonical resolved
profile bytes and real core validation result. Keep request/map transport version 1,
core schema 2, opaque data handling and exact caller-owned scope references. Existing
malformed input, repository/object and resource refusals retain their tokens and order.
Only the newly specified dependency failures precede request parsing.

Keep all existing byte/accounting ceilings, snapshot rules, diagnostics, signal and
watchdog behavior. In particular, retain the 512 MiB global ledger, diagnostic reserve,
per-value and aggregate budgets, repository budgets, 30-second Git wall watchdog,
15-second Git CPU limit and existing launcher resource ceilings. No retries, sleeps,
cache deletion, prewarming, altered memory accounting or relaxed cleanup is a fix.

Actual successful and runtime-refused launches must leave their private TMPDIR empty,
including no xcrun_db, and private HOME unchanged and empty. Inspect these directories
after the actual runtime exits and before test cleanup. Runtime-owned scratch must
be gone; do not hide residue by inspecting only its selected subdirectory. Launcher
stdout/stderr capture files outside HOME/TMPDIR are expected retained evidence and
are not runtime scratch. Unexpected cache or other files fail the proof.

Keep fixture creation, compilation, jq preparation and source fingerprint commands
outside the measured runtime HOME/TMPDIR. They may use the unchanged existing test
setup; their shim effects do not prove or excuse runtime effects. Never delete or
prewarm a host/shared cache. Retain original failure logs and identify which process
phase produced each new observation.

### R4. Required proof through the actual supported launcher

Run the entire existing `portable-profile-resolution.test.sh` suite, preserving all
47 existing cases and their actual assertions. Add the cases below; no existing
case becomes a skip or is replaced by a synthetic counterpart. Retain real core
validation, SHA-1/SHA-256 multi-repository resolution, normal/bare/linked layouts,
source fingerprints, opaque data/loader controls, budgets and exact-child watchdog.

For real positive proof, use the unchanged C launcher with its existing clean envp,
limits and fixed execve of Bash/runtime/helper/jq. Run the actual installed uname
and the selected Git. Record source blobs and SHA-256s for the runtime library,
wrapper, helper, compiled test launcher, uname, Git, Bash and pinned jq, plus OS and
architecture. A Git toy, copied weaker runtime or imported function is not this proof.

Use a fresh normal fixture and then reuse the same mapped repositories/request for
a second actual launch with a new empty private sandbox. Compare full canonical
stdout bytes, empty success stderr, and unchanged repository fingerprints. Repeat
with the existing bare and linked maps. “Reused” means reused input repositories,
not bypassing the launcher's exclusive creation of each run's HOME/TMPDIR.

For runtime refusals, retain and inspect actual child stdout/stderr plus public
status for malformed JSON and a valid request with an absent selected object. Both
must reach their specified runtime errors, emit no partial stdout, leave HOME/TMPDIR
empty and preserve source fingerprints. Also assert empty private TMPDIR after the
existing real Git-wall refusal. If any retained resource case has a different
explicit existing cleanup contract, report its actual outcome separately; do not
mislabel supervisor-forced termination as a completed runtime cleanup path.

Prove unchanged output semantics with the existing real core validator and same
fixture graph. Where old supported-runtime output is retained for that same graph,
compare its full bytes; do not regenerate an “old” baseline through edited source.
The fresh/reused and layout comparisons remain mandatory even without an old capture.

Required native evidence is a supported Linux x86_64 run and a supported Darwin run
on the available x86_64 or arm64 host, with each exact tested tuple stated. The closed
mapping does not by itself qualify the other Darwin architecture. Existing CI must
run the complete suite on Linux. A missing native dependency or failed boundary is
unsupported evidence, not permission to skip the required Darwin proof or install tools.
All repository CI, shellcheck 0.11.0, schema and rename checks remain required.

### R5. Deterministic private negative controls and source inventory

Private tests may source the exact library in a fresh Bash process and replace only
the narrow observation/file-availability boundaries with controlled test responses.
Call the actual selection/validation logic. Keep such substitution solely in the
test file; no public option, environment test switch or alternate product launcher.
Do not remove, chmod, replace or shadow installed host tools to manufacture absence.

Cover each table row, every unsupported/malformed observation class in R1, failed
producer/capture status, missing/non-regular/non-executable/symlink uname and Git,
and an inherited misleading selected variable. A successful control must have a
corresponding failed one so accidental non-execution cannot pass. Assert the exact
selected path, nonzero status and sanitized dependency failure as appropriate, and
that a refused selection never reaches a Git-use boundary. These tests establish
component behavior, not native absence or real launch qualification.

A source inventory must show all five sites consume only the initialized selection,
all four unchanged expected blob comparisons remain enforced, the dependency list
matches selection, and no executable lookup/discovery or new public input exists.
Use executable-position analysis rather than forbidding every occurrence of the
text `/usr/bin/git`, which is a valid Linux table value and test preparation command.
Test coverage plus this inventory establishes propagation; do not invent dynamic
exec tracing or claim a component stub observed the actual public child's executable.

Check the same library's actual initialization is used by Git-using internal budget
and cache tests. Preserve watchdog control assertions and all original error checks.
The plan must enumerate the existing 47 cases and added proof, and state which rows
are source review, component controls or real launcher observations.

## Design

Implementation may change exactly these three already restore-listed paths:

- `scripts/lib/profile-resolution.sh`: private bounded platform observation,
  closed selection/validation and five-site propagation.
- `scripts/test/portable-profile-resolution.test.sh`: complete original suite,
  explicit initialization for private Git callers, new controls and actual cleanup
  and identity evidence.
- `docs/components.md`: explain the fixed platform dependencies, proven tuples,
  inactivity and still-separate production parent.

No new restore-critical file is needed; the existing manifest covers these sources.
Keep `resolver/v1/profile-resolve-runtime.sh`, `profile-resolution.jq`, native helper,
fixture builder and C launcher byte-identical. The runtime remains mode 0644.
Keep fixture-only helpers local to the focused test rather than adding a tool broker
or duplicating the library's selection logic. Separate the bounded observation and
file predicate only as needed for private controls; production always uses fixed
system paths, never a caller function or configurable executable.

Selection is an ordinary platform dependency choice behind this one private boundary.
It removes the known Darwin dispatcher cause rather than exempting its residue.
Document the invariant: the installed direct CLT Git must meet the same runtime
behavior and cleanup contract. Changed path/tool/platform behavior requires new
evidence and any affected artifact update; absence refuses without fallback.

The library's new blob necessarily changes the trusted parent's future dependency
pin. This initiative must not edit `work/resolver-trusted-parent/`, its implementation,
preserved WIP or tests. After this repair lands, that separate chain must reconcile
its exact library pin, newly needed uname/Git paths and source inventories through
its own G2/plan gates, retaining all 18 blob checks, three constant checks and full
R1–R10 proof. No parent acceptance or continuation is supplied here.

## Out of scope

Runtime installation, Git discovery, new public selector, network/credentials,
profile or manifest repinning, core/generation/schema changes, production parent,
input assembler, shadow integration, real target execution, cache exceptions,
shared-cache manipulation, sandbox/VM changes, activation and qualification.
Do not rewrite accepted artifacts from other initiatives to make this repair pass.

## Areas of concern

Risk is high because trusted executable selection and loader/runtime dependency
validation are security boundaries. A separately authored and independently accepted
high-risk plan must precede code. It must estimate full tests and source work honestly;
no implementation size or new native success is claimed by this draft.

The intent's platform question is resolved by the closed uname/Git design; whether
the installed tools actually meet the contract is answered only by R4 evidence.
The negative-test question is resolved by R5's component boundaries and independent
real launches. Fresh/reused output, cleanup and resource proof remain mandatory.
Whether the pending cache exception is unnecessary for #271 remains a later decision
after actual repaired-runtime evidence and separately accepted parent updates.

No intended north-star conflict is identified. If the fixed installed Git or uname
cannot meet these requirements, preserve the failure and return to the affected
artifact gate. Do not silently weaken cleanup, introduce discovery or change the
supported execution authority to obtain a pass.
