---
spec-blob: 918ad3a2c3b6150bc3f95a24dc1419f0ba88ce88
drafted: 2026-09-18
---
# Plan: shadow-self-host-run

Tracks #264. Risk: high, matching the accepted spec frontmatter. Gate mode is
`artifact-high`: this plan-only PR needs independent review, green CI and operator
merge before `ystack/impl/shadow-self-host-run` exists.

`work/shadow-self-host-run/spec.md` (blob above) is the contract and states
requirements 1-20 in full. This plan names the files, the order, the exact commands,
the risks and the proof. Where a step names a requirement, that requirement's own
wording is the detail to follow; this plan does not restate it.

Freshness, checked on `origin/main` at `d23a3314846f952e15dbd621bbd2214a02ec31d3`:
the spec's `intent-blob` is `5a0f933c1209a96e975af1ce5b46db50559e539b`, and
`git rev-parse origin/main:work/shadow-self-host-run/intent.md` returns the same
value, so the chain is current.

What I verified myself against real history, rather than copying from the spec:

- `git log -1 --format='%H %P' 0427390224c25147650f1bd3b6e43ed6911b97a7` gives parent
  `d3f6d525328838b9c2de819699e53d8909ab7a3f`. The subject is "Retire construction
  mode: the operating-mode transition (#261)"; the parent is "Add the operator kit for
  the operating-mode transition (#260)". So the first-parent relation in requirement 4
  is real.
- `git cat-file blob d3f6d52:config/construction-mode.json | shasum -a 256` is
  `b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93` — the expected
  digest both incident records carry.
- The same command at `0427390` is
  `5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda` — different, which
  is why the post-transition run reproduces.
- `git rev-list --max-parents=0 0427390` returns exactly one 40-hex root,
  `7908b159c0a2d24ce6ccdde6ee0f501acc483e75`, matching the `env.local-macos-ystack-self`
  entry in `shadow/v1/shadow-environments.json`. The driver's root check
  (`shadow/v1/reproduce.sh:394-414`) compares exactly that.

## Files that change

Nothing outside this list. Counts are net changed lines, honest estimates.

**New evidence, under `shadow/evidence/self-host-transition/v1/`.** Fifteen shared
files and fifteen per case, forty-five in all:

| Path | What it is | Lines |
| --- | --- | ---: |
| `README.md` | Input tuples, dependency commits, digests, outcomes, replay recipe | 90-130 |
| `verification-instructions.md` | Requirement 14's minimal file-digest procedure | 45-70 |
| `checksums.json` | Relative-path inventory and SHA-256 of every other bundled file | 1 |
| `resolved-profile.json` | The resolver's output, shared by both runs | 1 |
| `environment-claim.json` | The real claim for `env.local-macos-ystack-self` | 1 |
| `control-policy-set.json` | The policy set the driver was handed | 1 |
| `requester.json` | The `actor_ref` requester identity passed as the assembler's tenth input, identical for every assembly | 1 |
| `core-package-closure.json` | The exact core-contract package closure descriptor bytes that the policy set's `package_ref.sha256` names, stored with no trailing newline | 1 |
| `duty-evaluation.json` | The duty evaluation the claim references | 1 |
| `prerequisite/environment-declaration.json` | The bootstrap environment description the prerequisite stage request fingerprints | 1 |
| `prerequisite/input.json` | The assembler's materialization input for the prerequisite stage run | 1 |
| `prerequisite/stage-request.json` | That run's stage request, the duty evaluation's `request_ref` | 1 |
| `prerequisite/resolved-profile-document.json` | That run's resolved profile, the duty evaluation's `resolved_profile_ref` | 1 |
| `prerequisite/stage-result.json` | That run's stage result, the duty evaluation's `result_ref` and the claim's `stage_result_ref` | 1 |
| `prerequisite/materialization-receipt.json` | The materializer's receipt bytes, which that stage result references by digest | 1 |
| `{pre,post}/incident.json` | `incident.ystack-transition.{pre,post}` | 2 |
| `{pre,post}/qualified-identity.json` | The identity each run was performed under | 2 |
| `{pre,post}/sandbox-evaluation.json` | The shipped evaluator's declaration-only document for that run | 2 |
| `{pre,post}/materialization-receipt.json` | The receipt bytes that case's `state/materialization-result.json` references by digest | 2 |
| `{pre,post}/assembled/*` | The assembler's seven outputs, native names | 20-40 |
| `{pre,post}/state/*` | The driver's four state files, native names | 8 |

Canonical JSON is one line per file, so the JSON count is small and the review work is
in the expanded documents, not the line count. The four assembler decision texts
(`finish-condition.txt`, `verification-instructions.txt`, `output-contract-decision.txt`,
`policy-decision.txt`) are raw text and carry most of the `assembled/` lines.

**New test:**

- `scripts/test/shadow-self-host-evidence.test.sh` (new, mode `0755`, 310-400 lines).
  Requirements 15, 16 and 17 together: the offline evidence check, the scope-consumer
  compatibility harness, and the maintenance-consumer conversion. One file, because all
  three read the same committed bytes and none of them runs a real reproduction.

**Existing files:**

- `ci/required-files.txt` (+47). A block headed
  `# First self-host shadow evidence` after the assembler block at lines 414-417,
  listing all forty-five evidence paths and the new test.
- `docs/components.md` (+30-40). A `## First self-host shadow evidence` section after
  the assembler write-up, which today runs to line 1395 before
  `## Inactive maintenance loop` at 1397.
- `README.md` (+2). One index row after the assembler row at line 289.
- `RESTORE.md` (+18-22). A restore block after the assembler block at lines 223-241.
- `scripts/test/portable-core-schema.test.sh` (+2). Exactly one permitted change: the
  two paths `shadow/evidence/self-host-transition/v1/control-policy-set.json` and
  `shadow/evidence/self-host-transition/v1/core-package-closure.json` are added to the
  `schema_v2_corrective_expected_hits` list, in that list's existing sorted order, after
  `scripts/test/portable-core-v2-evidence-identity.test.sh`; no other allowlist, no
  generation list, no comparison and no import list changes. Both files are evidence
  that must retain their bytes verbatim under requirements 2, 12 and 14 — one is a
  byte-exact copy of `control/v1/control-policy-set.json` and the other the closure
  descriptor that policy set's `package_ref.sha256` names — so the corrective v2
  generation id beginning `g-c83c940a` necessarily appears in two tracked paths the
  closed allowlist does not yet name, and CI fails with "corrective v2 generation ID
  appears outside its closed tracked-path allowlist" until it does. #370 set the
  precedent for adding a single allowlist line under a plan amendment rather than
  editing the evidence bytes or dropping the files.

### What does not change

`shadow/v1/reproduce.sh`, `shadow/v1/assemble-materialization-input.sh`,
`shadow/v1/materialization-input.jq`, `shadow/v1/incident-record.jq`,
`shadow/v1/qualified-identity.jq`, `shadow/v1/shadow-environments.json`,
`adapters/local-git-materializer/v1/*`, `control/v1/*`, `scope/v1/*`,
`maintenance/v1/*`, `evals/v1/seed-set.json`, `profiles/default/v1/*`, and every
accepted intent, spec or plan. Inside
`scripts/test/portable-core-schema.test.sh` nothing changes but the two added
`schema_v2_corrective_expected_hits` lines named above. The evidence is committed
output; if a shipped component refuses it, the component is right and the run is
wrong.

### Review size

`review_size: accepted-exception` for the **implementation PR**, one concern — the
first real self-host evidence pair and its durable verification — with an
evidence-based range of **685-915 net lines**.

This is above the spec's earlier 250-450 figure, which the spec itself asked this plan
to refine against the real interfaces. Two things grew once I read them:

- The focused test carries requirements 15, 16 **and** 17. The spec allots 100-170 for
  it. Against the real consumers that is 310-400: `scope/v1/evaluate-scope.sh` takes
  seven separate input documents (`scope/v1/evaluate-scope.sh:73`), and
  `maintenance/v1/incident-to-eval.sh` needs both directions plus the cross-pairing
  refusal, on top of the thirteen evidence checks requirement 15 lists.
- The manifest block is 48 lines, not a handful, because the spec's design requires
  every committed evidence file to be appended to `ci/required-files.txt` and the
  design names forty-five of them.

- The prerequisite stage run adds six committed documents, six manifest lines, the
  README's account of the construction order and the test's recomputation of it:
  55-80 lines above the figure this plan first carried. It is not optional work —
  without it the duty evaluation has no acyclic source, which is what the rest of this
  plan's "Construct the duty evaluation and the claim" section settles.
- Retaining each case's materialization receipt adds two committed documents, two
  manifest lines, the README's account of how they were captured and the gates that
  bind them, and the test's recomputation: 25-30 lines above the figure this plan
  carried before. It is not optional either — without it both cases' stage results
  reference bytes nothing holds.

The rest is close to the spec's own breakdown: 155-230 for README and verification
instructions, 70-120 of committed evidence bytes, 50-64 for documentation, index and
restore. Midpoint 800. If the real diff lands outside 685-915, stop and return to the
gate rather than compressing the test or dropping evidence files.

`review_size: accepted-exception` for **this plan PR**, one concern — the complete
pre-code design for the first real self-host run — with an evidence-based range of
**1140-1190 lines**. Requirement 2's declaration-only framing carries real cost in this
plan: the precondition gate, the evaluator call, the marker checks, the consumers'
vocabulary and the documentation rule each have to state the boundary between a
declaration and enforcement, and the exact invocations — the validator's verb and the
`PATH` the standalone calls need — are design detail a reader cannot infer. The range
moved up from the 545-605 this plan first carried because the construction order for
the policy set, the duty evaluation and the claim has to be written out document by
document, with the producer and the referenced bytes named for each: an acyclic order
is not something a reader can infer from the shipped interfaces, and getting it wrong
is a digest cycle the operator only discovers mid-run. The written-out order is
about 180 lines of the total. It moved up again, from 770-820, for the third
precondition-gate entry: the shipped assembler's requester cannot pass duty
separation, and a blocked dependency has to be stated with the checks it fails, the
reason ids it produces, why no requester this plan could write would be honest, and
which gate owns the fix — about 45 lines, and the alternative is a reader who cannot
tell a blocking finding from an unexplored one. It moved up a third time, from
865-915, for two review findings: the isolated Git prefix for source preparation,
written out key by key with the reason each pin is there and the one the resolver
library pins that this step cannot (about 50 lines), and the receipt retention that
keeps the prerequisite stage result's own references resolvable (about 30). Both are
correctness of the operator's run, not commentary. It moved up a fourth time, from
955-1005, for two more review findings: the per-case receipt capture, which has to
state the supported invocation, why its bytes are the driver's own and the three
digest gates that prove it (about 85 lines), and moving dependency provisioning out of
the run procedure into its own pre-boundary step with the authorization it rests on
(about 50). Both are the difference between evidence that resolves and evidence that
does not, and between a run that honours requirement 10's boundary and one that
quietly crosses it.

## Order of work

### The precondition gate

**No run step below may execute until all three of these are merged on `main` with their
required proof green.** This is the single hard gate in this initiative.

1. **`resolver-trusted-parent`.** The implementation is in progress on
   `ystack/impl/resolver-trusted-parent`. Its plan
   (`work/resolver-trusted-parent/plan.md`) ships `resolver/v1/resolve-profile.sh` at
   git mode `100755` and `resolver/v1/trusted-launch.c`. Until that entry exists there
   is no supported way to produce a real resolved profile: the only launcher of
   `resolver/v1/profile-resolve-runtime.sh` today lives in `scripts/test/`, which
   `docs/components.md:1368-1372` states plainly. Requirement 1 forbids substituting it.
2. **`shadow-input-assembler`.** Already merged: `shadow/v1/assemble-materialization-input.sh`
   and `shadow/v1/materialization-input.jq` are on `main` and listed in
   `ci/required-files.txt:414-417`. Confirm its focused proof is still green at the
   implementation base.
3. **`shadow-input-assembler` again, for a requester duty separation accepts.** The
   assembler as shipped cannot produce a stage request that passes the duty evaluator,
   so the prerequisite duty evaluation that "Construct the duty evaluation and the
   claim" below depends on cannot be produced yet, and neither run can proceed.
   `shadow/v1/materialization-input.jq:111-118` builds `body.requested_by` from one
   binding and `:181` puts it in the request; that binding is
   `materialization-input.jq:108-110`'s `forge_binding`, the resolved profile's `forge`
   entry, chosen by the program and by nothing the caller passes. The duty evaluator
   then refuses it twice over: `control/v1/duty-separation.jq:120-121` accepts
   `body.requested_by.role` only when it is one of `manager`, `operator`,
   `orchestrator` (`:55`), and `:122-124` rejects a requester whose
   `adapter_instance_id`, `execution_boundary_id` or `principal_id` equals that of any
   protected binding (`:6-7`, `:96`, `:102`), which a forge identity does by
   construction because `forge` is itself one of the five protected roles (`:4`). The
   tuple therefore evaluates to `violated` with four reasons at once —
   `requester.role-denied` plus all three `requester.*-collision`s — and
   `control/v1/sandbox.jq:212` turns that into `duty.violated`, ending the run at
   `environment.not-satisfied`.

   **This plan does not construct a passing request itself.** The only requester the
   checks would accept is an identity in none of the resolved profile's bindings: a
   binding whose role is `manager`, `operator` or `orchestrator` cannot be added to the
   profile at all, because `duty-separation.jq:109-111` emits `profile.role-denied` for
   any binding outside the protected and dormant role sets (`:4-5`), and the profile's
   six committed bindings (`profiles/default/v1/profile.json`) are exactly `ci` plus
   the five protected roles. The only `orchestrator` requester identities anywhere in
   the repository are the synthetic `instance.orchestrator` / `boundary.orchestrator` /
   `principal.orchestrator` fixtures in `evals/v1/seed-set-duty.json` and
   `scripts/test/control-duty-separation.test.sh`. Writing the prerequisite request by
   hand from the assembler's other outputs with a requester of our own choosing would
   therefore be a document the pipeline never produces, resting on an identity nothing
   declares — the spec's out-of-scope rule forbids exactly that ("no local patch,
   weakened claim, fabricated reference or alternate private entry may make this run
   pass", `work/shadow-self-host-run/spec.md`), as does requirement 1's ban on
   substituting a shipped producer.

   So this is an incompatible accepted dependency, and by the same spec rule it returned
   to its own artifact gate: **`shadow-input-assembler`**. **That amendment has now
   landed on `main`** (spec #364, plan #365), and it settles the question the way this
   plan assumed: the requester identity is an explicit caller input, not a projection of
   a binding. The contract this plan now writes against is that amendment's, as
   `work/shadow-input-assembler/plan.md` step 5.1 states it — a **tenth positional
   argument `<requester-file>`, appended after the claim so the first nine keep their
   positions**, with nine inputs now refused as `E_USAGE`. The file's single JSON value
   is emitted verbatim as `body.requested_by`, and the amended
   `shadow/v1/materialization-input.jq` refuses it unless it satisfies
   `schema::actor_ref_ok`, carries a role in `["manager","operator","orchestrator"]`,
   and collides on `adapter_instance_id`, `execution_boundary_id` or `principal_id`
   with **no** binding in the resolved profile. Every assembler invocation in this plan
   therefore takes ten inputs; "The requester identity" below defines the one file all
   of them pass, and entries 4-8 are otherwise unaffected.

**No sandbox dependency gates these runs.** Per requirement 2 the runs use the shipped
declaration-only evaluation exactly as shipped — `control/v1/evaluate-sandbox.sh` with
`control/v1/sandbox-policy.json` and `control/v1/sandbox.jq` — and claim no execution
boundary. A real boundary is a step-8 prerequisite, not this run's. Two limits hold
regardless. First, the evaluator compares declarations, so although the driver
proceeds only when the verdict is `satisfied` (`shadow/v1/reproduce.sh:436-442`,
matching `.body.verdict`), what it proceeds on is a declaration verdict and nothing
more: the single expected reason is `sandbox.declaration-satisfied`
(`control/v1/sandbox.jq:256`), and enforcement stays `unproven`. A verdict that is not
`satisfied` stops the run at `environment.not-satisfied`; it is not worked around.
Second, requirement 2 divides the placeholder digests in two, and the evidence follows
that division exactly — recorded on intake #264 as decision request DR-4. The retained
policy and claim bytes keep the shipped verifier tool digest of 64 ones that
`control/v1/sandbox-policy.json` pins and `control/v1/sandbox.jq:policy_ok` fixes: the
claim's `body.tools` must repeat it literally or the evaluator emits `tools.not-fixed`,
so removing or rewriting it would make `satisfied` unreachable and would misstate what
was evaluated. The evidence and README label that value as the shipped demonstration
value, never as a real tool identity, per `work/real-sandbox-boundary/spec.md`
requirement 5. What the run refuses is a fabricated reference digest among its own
inputs: the control policy set's `body.core_contract.package_ref.sha256` and, for each
entry of `body.sections`, `policy_ref.sha256` and `decision_ref.sha256`; the duty
evaluation's `body.policy_ref.sha256`, `body.decision_ref.sha256`,
`body.policy_set.sha256` and each reference under `body.stage` (`request_ref`,
`resolved_profile_ref`, `result_ref`); and the claim's `body.policy_set_ref.sha256`,
`body.duty_evaluation_ref.sha256` and `body.stage_result_ref.sha256`. Each must be
recomputed from the exact committed bytes it names and equal the recorded value. A
repeated-character value of the kind the fixtures at
`scripts/test/shadow-slice.test.sh:128-195` build those references from (`("2" * 64)`,
`("b" * 64)`), or any digest that does not equal the SHA-256 of the real committed
bytes it names, stops the run rather than being retained. Every one of those fields has
a producer and a fixed place in an order where no document names bytes produced after
it; "Construct the duty evaluation and the claim" below is that order, and it is a
prerequisite of the assembly step rather than a detail of it.

**What the coder may do before that gate clears**, because none of it needs a run:

- Write the whole of `scripts/test/shadow-self-host-evidence.test.sh` except the
  assertions that read committed evidence bytes: the jq-1.6 provisioning block copied
  from `scripts/test/shadow-slice.test.sh:24-51` — this is a CI suite, which provisions
  its own pinned dependency exactly as the other suites do and is not inside
  requirement 10's run boundary; the operator's evidence session is, and provisions
  nothing — the temp-directory and result
  helpers, the inventory walker, the canonical-JSON helper, the trace-seal
  recomputation, and the harness scaffolding for both consumers.
- Write `verification-instructions.md` in full. It describes reading one named blob at
  one revision, hashing the raw bytes, and comparing — no run needed to write it.
- Fix the evidence directory layout and the `checksums.json` schema, and write the
  README's structure with the value slots empty.
- Prepare the docs, index row, restore block and manifest block, with the file list
  already final because the layout is fixed above.

**What waits:** every command in the two run sections, every committed evidence byte,
every assertion that reads one, and the README's filled-in digests and outcomes. The
test skeleton must fail loudly, not skip, while the evidence is absent.

### Before the evidence session: provision the pinned dependencies

**This step is not part of the run procedure and produces no evidence document.** It
happens earlier, on its own, and the session below begins only once it has finished.
Requirement 10 puts source preparation and execution behind a no-network,
no-credentials boundary, and that boundary starts at the next section. So every pinned
dependency the exercise runs under has to be in the operator's hands, verified, before
the boundary is entered — nothing inside it may fetch, and no step inside it may fall
back to fetching.

There is exactly one network action in this initiative and it lives here: fetching the
pinned jq 1.6 release asset over HTTPS —
`https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset`, with `$jq_asset`
`jq-osx-amd64` on Darwin and `jq-linux64` on `Linux:x86_64` — and verifying it against
the pinned SHA-256 for that platform — on Darwin
`5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`, on `Linux:x86_64`
`af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44` — the values
`scripts/test/shadow-slice.test.sh:24-51` and `shadow/v1/reproduce.sh:143-149` both
check. Discard a download whose digest does not
match; never install an unverified one.

It is the same fetch the shipped suites already perform into the shared cache
`${TMPDIR:-/tmp}/ystack-portable-core-jq16`, on a cache miss and never otherwise, so
running `bash scripts/test/shadow-slice.test.sh` once on the operator's machine fills
it and nothing further is needed. That is ordinary test work in an existing development
environment, which `AGENTS.md:46-49` already authorizes; this initiative asks for no
new network scope, and none of the run steps below inherits any. If that fetch is
blocked, or the digest does not match, it is the operator's own hand that resolves it —
a new credential or network scope is a question for the operator under the same lines,
not something a run step may take for itself.

The closure helper belongs to this step too: compile it locally from the committed
`adapters/local-git-materializer/v1/object-closure.c` the way
`scripts/test/shadow-slice.test.sh:52-55` builds it. That is a local compile of
committed source and reaches no network, but the session starts with both dependencies
already in hand rather than building one midway.

Record in the README as a **precondition line, not an evidence document**: the asset
name, the URL, the verified SHA-256, the cache path, and the date it was provisioned —
stated as work performed before the evidence session, outside requirement 10's
boundary.

### Prepare the disposable source (requirements 9, 10)

Operator-run on Darwin, no network, no credentials. `$SRC` is a fresh path outside the
user's repository; nothing below ever touches
`/Users/yihanzhu/git/ystack/.git`.

**Every `git` invocation in this section runs under an isolated Git configuration**, the
way the shipped tooling already isolates its own (`shadow/v1/reproduce.sh:294-298`,
`adapters/local-git-materializer/v1/materialize.sh:265-269`,
`scripts/lib/profile-resolution.sh:390-398`), and on the same terms the
`resolver-trusted-parent` plan sets for its provisioning step
(`work/resolver-trusted-parent/plan.md:76-90`): a cleared environment, a disposable
`HOME`, no system or global configuration, no credential helper, no prompt, no hook, and
nothing written into the operator's checkout. This is not belt-and-braces. The scrubbing
below happens *after* the clone, so ambient configuration gets to act first: a global or
system `url.<base>.insteadOf` whose key matches the absolute source path rewrites this
local copy into a network URL and invokes whatever credential helper the operator has
configured, and a global `core.hooksPath` runs a hook on the new repository — either one
breaks requirement 10's no-network/no-credentials boundary and the authorization
boundary `AGENTS.md:46-49` fixes. `$GIT_ISO` is that prefix, built once over `$GIT_HOME`,
a fresh, empty, private 0700 directory outside `$SRC` and disjoint from every other
directory this plan names, holding no `no-grafts` entry:

```sh
GIT_ISO=(/usr/bin/env -i HOME="$GIT_HOME" TMPDIR="$GIT_HOME" PATH=/usr/bin:/bin
  LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_SYSTEM=/dev/null GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
  GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_GRAFT_FILE="$GIT_HOME/no-grafts"
  GIT_CONFIG_COUNT=6
  GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
  GIT_CONFIG_KEY_1=core.useReplaceRefs GIT_CONFIG_VALUE_1=false
  GIT_CONFIG_KEY_2=core.attributesFile GIT_CONFIG_VALUE_2=/dev/null
  GIT_CONFIG_KEY_3=core.excludesFile GIT_CONFIG_VALUE_3=/dev/null
  GIT_CONFIG_KEY_4=fetch.fsckObjects GIT_CONFIG_VALUE_4=true
  GIT_CONFIG_KEY_5=core.multiPackIndex GIT_CONFIG_VALUE_5=false)

"${GIT_ISO[@]}" /usr/bin/git clone --bare --no-hardlinks -- \
  /Users/yihanzhu/git/ystack "$SRC"
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" remote remove origin
rm -rf -- "$SRC/logs" "$SRC/info/grafts" "$SRC/objects/info/alternates"
find "$SRC/hooks" -type f ! -name '*.sample' -delete
printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n' \
  > "$SRC/config"
```

`env -i` is what removes `GIT_ASKPASS`, `SSH_ASKPASS`, `GIT_SSH*`, `GIT_PROXY_COMMAND`,
`GIT_ALTERNATE_OBJECT_DIRECTORIES`, `http_proxy` and every other inherited Git or proxy
variable; `GIT_CONFIG_NOSYSTEM=1` with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` at
`/dev/null` is what removes `url.*.insteadOf`, `credential.helper`, `http.*` headers and
every other ambient key, and the disposable `HOME` keeps the search from finding one
anyway. `GIT_TERMINAL_PROMPT=0` means anything that still tried to authenticate fails
rather than asking. The six pinned keys are the resolver library's set minus
`protocol.file.allow`: that library pins it `never` because it never clones from a path,
whereas this step's source *is* a local absolute path, and `never` would refuse the
clone itself. Nothing is lost by leaving it out — with system and global configuration
gone there is no rewrite left to turn that local path into any other transport. Use
`"${GIT_ISO[@]}"` for the inventory and `cat-file` commands below too, and do not add
`-c` overrides of your own: the prefix is the whole configuration these invocations see.

`--no-hardlinks` is required: a hardlinked clone shares objects with the original, and
requirement 9 wants a disposable copy. The rewritten `config` is not cosmetic — the
driver and the assembler both walk every config key and refuse anything outside
`core.repositoryformatversion`, `core.filemode`, `core.bare`, `core.logallrefupdates`,
`core.ignorecase`, `core.precomposeunicode`, `extensions.objectformat`
(`shadow/v1/reproduce.sh:362-369`). A clone leaves `remote.origin.*` behind, which
would fail `E_SOURCE_CONFIG`. Do not run `git gc`, `git repack` or `git fsck --lost-found`
on `$SRC` between the two runs: requirement 18 wants the same source bytes both times.

Record the source refs and object inventory before and after the whole exercise and
keep the comparison (requirement 10):

```sh
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" show-ref | shasum -a 256
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" cat-file --batch-all-objects \
  --batch-check='%(objectname)' | shasum -a 256
```

Both digests go in the README, taken before the first run and again after the last one.
They must be equal. Also confirm both revisions and the root are present:

```sh
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" cat-file -t \
  0427390224c25147650f1bd3b6e43ed6911b97a7
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" cat-file -t \
  d3f6d525328838b9c2de819699e53d8909ab7a3f
"${GIT_ISO[@]}" /usr/bin/git --git-dir="$SRC" rev-list --max-parents=0 \
  0427390224c25147650f1bd3b6e43ed6911b97a7
```

### Resolve the real profile (requirement 11)

One resolution, shared by both runs, through the entry the `resolver-trusted-parent`
spec defines:

```sh
resolver/v1/resolve-profile.sh "$JQ" "$RESOLVE_OUT" "$REQUEST" "$MAP" > resolved-profile.json
```

`$JQ` is the pinned jq 1.6 (Darwin SHA-256
`5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`, the value both
shipped scripts check). **It is already in hand: this procedure provisions nothing and
reaches no network.** Take the already provisioned asset from the shared cache the step
before the boundary filled — `${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset` —
require it to be a regular file rather than a symlink, re-verify its SHA-256 against
that pinned value, and copy it into a fresh 0700 directory `$JQ_DIR` under the file
name `jq` (mode `0555`), so `$JQ` is `$JQ_DIR/jq`. If it is absent, is a symlink, or
does not match the pin, **stop with `pinned jq 1.6 asset not provisioned — run the
provisioning step outside the evidence session` and end the session.** Do not download
it here, do not substitute the operator's default jq (1.7.1 on the current Darwin
machine, which the shipped scripts refuse with `E_RUNTIME` anyway), and do not continue
with an unpinned binary: a fetch inside these steps would cross requirement 10's
no-network boundary, and a run that crossed it is not the evidence this initiative
owes. The same rule covers the closure helper — it is compiled before the session, not
here. `$JQ_DIR` is needed as a directory, not just as a path to a binary, because two
shipped entry points discover jq through `PATH` rather than an argument — see "The two
runs" below. `$RESOLVE_OUT` is a fresh empty 0700 directory; after the run
it holds exactly `home`, `tmp`, `child.stdout` and `child.stderr`. The resolved profile
has no file of its own — its bytes are the entry's stdout, which equals
`$RESOLVE_OUT/child.stdout`. `$REQUEST` and `$MAP` are the resolution request and
repository map that spec's R10 defines; build them against the committed
`profiles/default/v1` objects with this repository mapped, never a synthetic profile.

Record in the README: the request and map digests, the resolver source revisions, the
runtime and helper identities, and the resolved profile's SHA-256. The recorded
identities are the real Git and content identities even though the request may point at
caller-chosen local roots.

The producer config this resolution selects is the committed
`profiles/default/v1/producer-config.json`: provider `anthropic`, model
`claude.sonnet`, effort `high`, and the versioned `routines/coder.md` prompt reference.
These are **recorded configured settings, not evidence that a model ran** — the README
says so in those words. Nothing in this initiative calls a model, and the session that
performs the run must not write its own model into the identity.

### Construct the duty evaluation and the claim (requirements 2, 12)

This section produces `$REQUESTER`, `$POLICY_SET`, `$DUTY` and `$CLAIM`. It runs once, before either
assembly, because the assembler already needs the claim. `$PRE_REQ` is the retained
`prerequisite/` directory of the evidence bundle; `$OUT_DIR_0`, `$CAND0` and `$SCRATCH0`
are fresh, empty, private 0700 directories outside `$SRC` and disjoint from it and from
each other, on the same terms the driver checks for its own three.

**Why these cannot come from this run's own documents.**
`shadow/v1/materialization-input.jq:197` puts the claim's SHA-256 into the stage request
it builds, as `environment_ref.fingerprint_sha256`. So a duty evaluation over *this*
run's stage tuple would hash a request that already hashes the claim that references
that duty evaluation: claim -> request -> duty -> claim. No ordering of this run's own
steps breaks that cycle. The duty evaluation therefore covers a **prerequisite stage
run**, performed once before either evidence run, and the claim is built from its bytes
afterwards.

No committed tuple can be reused instead. Nothing in the repository holds a real
`stage_request` / `resolved_profile` / `stage_result` triple: the only such documents
are the synthetic payloads under `evals/v1/` and `scripts/test/`, whose references are
the repeated-character placeholders the precondition gate refuses.

**The requester identity.** Every assembler invocation below passes the same tenth
input, `$REQUESTER`, and it is retained as `requester.json`. Like the policy-set copy it
is produced by no tool and references nothing, so it precedes entry 1 and no entry
depends on it having been built later. It is the bare `actor_ref` the amended
`materialization-input.jq` emits verbatim as `body.requested_by`, and its values are
**the DR-5 identity proposed on intake #262**: role `operator`, principal
`principal.operator.yihanzhu`, adapter instance `instance.operator.local-macos`,
execution boundary `boundary.operator.local-macos`, with `implementation_id`
`implementation.operator.manual` and `implementation_version` `v1` completing the six
fields `schema::actor_ref_ok` requires. **These values are bound to the operator's
`approve DR-5` comment on #262. Until that approval exists the run does not start** —
not the prerequisite assembly, not either case, not the repeatability pass — because an
identity nobody declared is exactly the fabricated input the precondition gate refuses.
The distinct `.local-macos` and `.yihanzhu` suffixes are deliberate: they keep the
retained bytes from being mistaken for the synthetic `instance.operator` /
`principal.operator` fixture in `evals/v1/seed-set-duty.json`.

Construct it with the same canonical emitter as every other document this run writes:

```sh
"$JQ" -S -c -n '{role:"operator",
  implementation_id:"implementation.operator.manual",
  implementation_version:"v1",
  adapter_instance_id:"instance.operator.local-macos",
  principal_id:"principal.operator.yihanzhu",
  execution_boundary_id:"boundary.operator.local-macos"}' >requester.json
```

The exact bytes that produces, which are what gets committed, are

```json
{"adapter_instance_id":"instance.operator.local-macos","execution_boundary_id":"boundary.operator.local-macos","implementation_id":"implementation.operator.manual","implementation_version":"v1","principal_id":"principal.operator.yihanzhu","role":"operator"}
```

newline-terminated like the other canonical documents, and the offline check is
`shasum -a 256 shadow/evidence/self-host-transition/v1/requester.json` printing
`7596d803e09956c24a627d29558b22a583369080ac653941816c0fbadb2d68cd`. If the approved
DR-5 values differ from the ones above, the file, this recipe and this digest change
together and the run does not proceed on the stale pair.

**Duty separation accepts this requester, and that is checked, not assumed.**
`control/v1/duty-separation.jq:55` fixes `requester_roles` to
`["manager","operator","orchestrator"]`, so the `operator` role passes the role test at
`:120-121` that a `forge` requester failed. The collision test at `:122-124` compares
only `identity_dimensions` — `adapter_instance_id`, `execution_boundary_id`,
`principal_id` (`duty-separation-policy.json`) — against every protected binding, and
the six committed bindings in `profiles/default/v1/profile.json` are `instance.ci`,
`instance.forge`, `instance.producer`, `instance.publisher`, `instance.reviewer` and
`instance.verifier` with matching boundary and principal ids. None equals a
`.operator.local-macos` or `.operator.yihanzhu` value, and `operator` is in neither
`protected_roles` nor `dormant_roles` (`:4-5`), so no binding can carry it. The
prerequisite duty evaluation is what proves this on real bytes; a verdict other than
`satisfied` stops the run rather than being worked around.

**The order.** Each entry names what it produces and what it references; nothing
references a later entry.

1. **`control-policy-set.json`** — produced by no tool: it is `control/v1/control-policy-set.json`
   copied byte for byte, and `$POLICY_SET` is that copy. It references the shipped
   `control/v1/*-policy.json` and `*-decision.json` bytes and the core-contract package
   closure, all committed on `main` before the run. The shipped file and no other:
   `control/v1/evaluate-duty.sh:306-325` requires `body.core_contract.package_ref.sha256`
   to equal the digest of the live core closure it recomputes itself, and the
   `duty-separation` section's `policy_ref` and `decision_ref` to equal the shipped
   policy and decision digests; `control/v1/sandbox.jq:140-148` then requires the duty
   evaluation to carry those same two references. Confirm the copy before use with
   `PATH="$JQ_DIR:/usr/bin:/bin" control/v1/validate.sh validate "$POLICY_SET"`.

   **The closure descriptor those bytes name is retained too**, as
   `core-package-closure.json`, because `package_ref.sha256` is one of the reference
   fields the precondition gate requires to be recomputable from committed bytes and no
   shipped file holds the descriptor. `control/v1/evaluate-duty.sh:140-148` builds the
   descriptor with `jq -Rn -S -c` over a nine-line member table and hashes it through
   `sha256_text`, which pipes the value with `printf '%s'` — **so the hashed bytes carry
   no trailing newline**, and the digest of the newline-terminated form is a different
   value that satisfies nothing. `core-package-closure.json` is therefore written with
   no trailing newline; it is the one bundled `.json` for which that is true, and the
   README says so beside it. Reconstruct it deterministically from **the selected
   generation**, never from a generation id transcribed into this plan: the id is a
   closed-allowlist value, so the recipe reads it at run time from the one committed
   source that pins it, `scripts/core-contract.sh`, with the same extraction
   `control/v1/evaluate-duty.sh:62-69` uses. Hash the nine closure paths in the order
   `evaluate-duty.sh:122-130` lists them and feed the result to the evaluator's own
   program. The source is the **live committed tree at the run's `main`**, which is what
   `$REPO` is below and what the focused test's step 11 hashes; the nine member files are
   byte-identical at `d3f6d525328838b9c2de819699e53d8909ab7a3f`, at
   `0427390224c25147650f1bd3b6e43ed6911b97a7` and at `main`, so no revision checkout is
   performed and the `eff044bd…` digest below is the check that decides whether the
   right bytes were read:

   ```sh
   SEL=$(sed -n "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'\$/\1/p" \
     "$REPO/scripts/core-contract.sh")
   [ -n "$SEL" ] || exit 1
   : >"$SCRATCH/core-members.tsv"
   for rel in scripts/core-contract.sh core/v2/generation-registry.json \
     "core/v2/generations/$SEL/contracts.jq" \
     "core/v2/generations/$SEL/core-ingress.sh" \
     "core/v2/generations/$SEL/modules/profile_graph.jq" \
     "core/v2/generations/$SEL/modules/result_facts.jq" \
     "core/v2/generations/$SEL/modules/result_truth.jq" \
     "core/v2/generations/$SEL/modules/schema.jq" \
     "core/v2/generations/$SEL/modules/stage_request.jq"; do
     printf '%s\t%s\n' "$rel" \
       "$(shasum -a 256 "$REPO/$rel" | awk '{print $1}')" \
       >>"$SCRATCH/core-members.tsv"
   done
   "$JQ" -Rn -S -c \
     --arg selected_sha "$(printf '%s' "$SEL" | shasum -a 256 | awk '{print $1}')" \
     '[inputs|split("\t")|{path:.[0],sha256:.[1]}] as $members |
      {schema_version:1,kind:"core_contract_package_closure",
       semantic_identity:"core.contracts.v2",
       selected_generation_id_sha256:$selected_sha,members:$members}' \
     <"$SCRATCH/core-members.tsv" >"$SCRATCH/core-closure.nl.json"
   printf '%s' "$(cat "$SCRATCH/core-closure.nl.json")" >core-package-closure.json
   ```

   The second command is what drops the newline `jq` appends; it is the only
   transformation applied, and it removes bytes rather than re-serializing the document.

   That read yields the `core.contracts.v2` generation whose id begins `g-c83c940a`;
   the README records the full id it actually read, and this plan deliberately does not.

   The offline check is one command and needs no run, no network and no jq:
   `shasum -a 256 < shadow/evidence/self-host-transition/v1/core-package-closure.json`
   must print
   `eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963`, the value
   `control/v1/control-policy-set.json` records in
   `body.core_contract.package_ref.sha256` and the value the retained
   `control-policy-set.json` copy repeats. The redirect form is required: hashing the
   file by name prints the same digest, but a copy that acquired a trailing newline
   would hash to `06dbd5ec60040dd0d913ca011fd296d7cce78d604bb887a3be0656698f535cf1`
   instead, and that mismatch is the signal that the bytes were re-serialized rather
   than retained. If the digest does not match, the descriptor was not reconstructed
   from the pinned generation and the run stops rather than committing it.
2. **`resolved-profile.json`** — produced by the resolver entry, above. References only
   the committed `profiles/default/v1` objects and the resolution request and map.
3. **`prerequisite/environment-declaration.json`** — **constructed by this run**; no
   shipped tool emits it. It is the bootstrap environment description that the first
   stage run in a newly registered environment has to fingerprint, and it exists so that
   entry 4's `environment_ref` names real, earlier bytes instead of a claim that does not
   exist yet. Build it with `jq -S -c -n` from two real sources and nothing else: the
   shipped `control/v1/sandbox-policy.json` body's `environment`, `filesystem`,
   `isolation`, `limits`, `network`, `resources`, `sensitive_material` and `tools`
   sections copied verbatim, and `registry_entry_sha256`, the SHA-256 of the registry
   entry's canonical bytes. Select the entry by the registry's real field names: the
   array is `body.environments`, and entries key on `environment_id` and
   `target_repository_id`, not `id`. Require exactly one match first, the same test
   `shadow/v1/reproduce.sh:396-399` applies —
   `"$JQ" -e '[.body.environments[] | select(.environment_id == "env.local-macos-ystack-self" and .target_repository_id == "repo.ystack")] | length == 1' shadow/v1/shadow-environments.json` —
   and hash the canonical bytes of that one entry,
   `"$JQ" -S -c '.body.environments[] | select(.environment_id == "env.local-macos-ystack-self" and .target_repository_id == "repo.ystack")' shadow/v1/shadow-environments.json`.
   Against the registry on `main` that entry is
   `{"description":"Operator's local macOS checkout, ystack's own scrubbed bare source repository.","environment_id":"env.local-macos-ystack-self","evidence_scope":"self-host","proof_state":"unproven","source_root_commit":"7908b159c0a2d24ce6ccdde6ee0f501acc483e75","target_repository_id":"repo.ystack"}`,
   whose SHA-256 is
   `cc259fc1b27956e6e479e05a7f70c6cc350ad65fc6b6583252d142fed91666e8`.
   `schema_version` 1, `kind` `execution_environment_claim`, `id`
   `env.local-macos-ystack-self` — those two fields are all the assembler reads from the
   file it is handed (`shadow/v1/materialization-input.jq:101-105`, `:213-214`). It
   carries no `*_ref` field of any kind, so it can carry no fabricated reference. It is
   never passed to `control/v1/evaluate-sandbox.sh` and it is not the claim either run is
   evaluated under; the README says both of those things in words beside its digest and
   beside the jq program that built it.
4. **`prerequisite/input.json`, `prerequisite/stage-request.json`,
   `prerequisite/resolved-profile-document.json`** — produced by the shipped assembler,
   invoked exactly as in the next section but with entry 3's file in the claim position,
   the pre-transition revision, its own frozen `$REQUESTED_AT_0` and its own fresh 0700
   `$OUT_DIR_0`:

   ```sh
   shadow/v1/assemble-materialization-input.sh assemble \
     repo.ystack "$SRC" d3f6d525328838b9c2de819699e53d8909ab7a3f "$REQUESTED_AT_0" \
     "$REPO/profiles/default/v1" "$RESOLVED_PROFILE" "$JQ" "$OUT_DIR_0" \
     "$PRE_REQ/environment-declaration.json" "$REQUESTER"
   ```

   Ten inputs, with `$REQUESTER` last: the amended entry refuses nine with `E_USAGE`,
   so an invocation copied from this plan's earlier revisions fails closed rather than
   assembling under a binding-derived requester.

   Retain `input.json`, and extract the two documents the duty evaluator needs in the
   assembler's own canonical form — the extraction
   `scripts/test/shadow-slice.test.sh:119-120` performs:

   ```sh
   "$JQ" -S -c '.stage_request.content' "$OUT_DIR_0/input.json" \
     > "$PRE_REQ/stage-request.json"
   "$JQ" -S -c '.resolved_profile.content' "$OUT_DIR_0/input.json" \
     > "$PRE_REQ/resolved-profile-document.json"
   ```

   Their SHA-256s must equal the `sha256` fields of the assembler's own
   `stage-request-ref.json` and `resolved-profile-ref.json` in `$OUT_DIR_0`; if either
   differs, stop. `$REQUESTED_AT_0` is the real UTC time of this prerequisite run and
   differs from both cases' timestamps, so the three assembled inputs are distinct
   documents. They are not distinguishable by id — `materialization-input.jq` gives every
   request the id `request.shadow-input-assembler` — so the README distinguishes them by
   digest and says so. References entries 2 and 3.
5. **`prerequisite/stage-result.json`** and **`prerequisite/materialization-receipt.json`**
   — produced by the shipped materializer, read-only
   over the same `$SRC`, with its own fresh, empty, private, mutually disjoint 0700
   `$CAND0` and `$SCRATCH0`:

   ```sh
   /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash \
     "$REPO/adapters/local-git-materializer/v1/materialize.sh" materialize \
     "$OUT_DIR_0/input.json" repo.ystack "$SRC" "$CAND0" "$SCRATCH0" "$CLOSURE" "$JQ" \
     > "$PRE_REQ/materialize.json"
   "$JQ" -S -c '.stage_result' "$PRE_REQ/materialize.json" > "$PRE_REQ/stage-result.json"
   "$JQ" -j '.payloads[0].data' "$PRE_REQ/materialize.json" \
     > "$PRE_REQ/materialization-receipt.json"
   ```

   That is the driver's own call and its own extraction
   (`shadow/v1/reproduce.sh:452-461`), and `$CLOSURE` is the closure helper the
   provisioning step above compiled, already in hand. The script path must be the
   absolute one under `$REPO`, as written:
   `adapters/local-git-materializer/v1/materialize.sh:23-24` refuses `E_USAGE` when
   its own `BASH_SOURCE[0]` is not absolute, because it re-execs itself by that path
   and does not normalise it the way the assembler and the driver normalise their
   relative arguments. The driver passes an absolute path for the same
   reason (`shadow/v1/reproduce.sh:131`, `:138`, `:452`),
   so these bytes are produced the way the evidence runs produce theirs. It is a real
   materialization of real history, it writes nothing to `$SRC`, and it happens between
   the two readings of the source inventory, so requirement 10's before/after comparison
   still has to come out equal.

   **The receipt is retained, not just extracted.** The stage result this run keeps does
   not stand alone: `adapters/local-git-materializer/v1/protocol.jq:370-373` builds one
   `$receipt_ref` and puts it in `body.evidence[0].proof_ref` (`:415`), in
   `body.execution.metadata.tools.source_ref` (`:408`) and, for a `changed` outcome, in
   `body.outputs[0].ref` (`:392`). Those references name the receipt's bytes by digest,
   and the receipt exists only inside the response envelope, in `.payloads[0].data`. If
   the envelope is discarded after the `stage_result` extraction, the retained result
   points at bytes no committed file and no Git object holds, and the spec's
   recoverability requirement (`work/shadow-self-host-run/spec.md:217-220`) — every
   referenced document recoverable from the bundle — is not met. So extract the receipt
   as well, with `-j`: the payload is the exact UTF-8 the materializer hashed, trailing
   newline included, and `-j` writes it back unchanged, which is how the driver reads it
   (`shadow/v1/reproduce.sh:463`). It is already canonical `jq -S -c` output from the
   producer (`adapters/local-git-materializer/v1/materialize.sh:609-617`), so it satisfies
   the bundle's canonical-JSON rule as emitted; do not re-serialize it, because
   re-serializing bytes that are referenced by digest breaks the reference. Before going
   on, check that its SHA-256 equals `payloads[0].sha256` of the envelope **and** equals
   `body.evidence[0].proof_ref.sha256` and
   `body.execution.metadata.tools.source_ref.sha256` of the retained
   `stage-result.json` — and `body.outputs[0].ref.sha256` too if the outcome is
   `changed`. If any differ, stop: the pair is inconsistent and nothing downstream of it
   is worth building. `materialize.json` is the response envelope and is scratch; the
   `stage_result` document and the receipt bytes it references are both retained, and
   both appear in `checksums.json` and in the manifest. References entry 4.
6. **`duty-evaluation.json`** — produced by the shipped evaluator, and `$DUTY` is that
   file:

   ```sh
   PATH="$JQ_DIR:/usr/bin:/bin" control/v1/evaluate-duty.sh evaluate \
     "$POLICY_SET" "$PRE_REQ/stage-request.json" \
     "$PRE_REQ/resolved-profile-document.json" "$PRE_REQ/stage-result.json" \
     > duty-evaluation.json
   ```

   Four file arguments after the literal verb, in that order
   (`control/v1/evaluate-duty.sh:17`, `:104`). Run it from the real checkout: it derives
   the repository from its own path and recomputes the live core closure, and like the
   other standalone calls it finds jq through `PATH` and requires jq 1.6
   (`control/v1/evaluate-duty.sh:40-42`). Its stdout is already canonical — it emits
   through `jq -S -c` and then compares those bytes against their own canonicalisation
   (`:362`, `:382-386`) — so redirect it and do not reformat. Every reference in the
   document is computed by the evaluator from the bytes it was handed, never written by
   hand: `body.policy_ref`, `body.decision_ref`, `body.policy_set` and all three
   `body.stage` references (`:285-288`, `:396-412`). It also sets the document's `id` to the stage
   result's id, which `control/v1/sandbox.jq:148` requires. The verdict this run needs
   is `satisfied` with the single reason `duty.satisfied`
   (`control/v1/duty-separation.jq:180`) — the only satisfied form `sandbox.jq:135-137`
   accepts — and the focused test asserts exactly that pair over the committed
   `duty-evaluation.json`. A `violated` verdict is a stop, not something to work
   around: `sandbox.jq:212` would add `duty.violated` and the run would end at
   `environment.not-satisfied`.

   **Today that verdict is `violated`, and this entry is blocked.** The request entry 4
   hands the evaluator carries the forge binding as its requester, which duty
   separation refuses on the role and on all three identity dimensions at once. The
   third precondition-gate entry above sets out the four reason ids, why no requester
   this plan could write would be honest under the spec, and why the fix belongs to
   `shadow-input-assembler`'s artifact gate rather than here. Entries 4 to 8 wait on
   it. References entries 1, 4 and 5.
7. **`environment-claim.json`** — **constructed by this run**, and `$CLAIM` is that file;
   no shipped tool emits a claim. Build it with `jq -S -c -n --slurpfile` over
   `control/v1/sandbox-policy.json`, `duty-evaluation.json` and `$RESOLVED_PROFILE`,
   with these fields and no others — `control/v1/sandbox.jq:60` fixes the top-level key
   set and `:64-66` the body's, both exact, so a missing or extra field at either level
   is `invalid-input` and the evaluator refuses the claim outright:

   - Top level, exactly four keys: `schema_version` the literal `1` and `kind` the
     literal `execution_environment_claim` (`control/v1/sandbox.jq:61`), the `id` below,
     and `body` holding everything else in this list.
   - `environment`, `filesystem`, `isolation`, `limits`, `network`, `resources`,
     `sensitive_material` and `tools` copied verbatim from the shipped policy's body.
     That copy is what keeps the shipped all-ones verifier digest literal, which
     `sandbox.jq:179-183` requires and which the precondition gate keeps.
   - `execution_identity` with all four fields `control/v1/sandbox.jq:19-22` requires
     and no others (`:71` applies `identity_ok` to it, and `identity_ok` is an exact
     key-set check, so a claim carrying only `role` is refused as malformed):
     - `role` `verifier`, the role `control/v1/sandbox-policy.json`'s
       `body.required_role` fixes and `sandbox.jq:160`, `:204` check.
     - `adapter_instance_id` `instance.verifier`, `execution_boundary_id`
       `boundary.verifier` and `principal_id` `principal.verifier` — read out of entry
       2's resolved profile, from the `body.bindings[]` element whose `binding.role` is
       `verifier`, under the `binding` object's keys of those same three names. Those
       are the values the resolver carries through from the committed
       `profiles/default/v1/profile.json` binding `binding.verifier`, whose
       `adapter_instance_id`, `execution_boundary_id` and `principal_id` keys hold
       them. Take them from `$RESOLVED_PROFILE` with jq rather than typing the strings,
       so the claim states the identity that was actually resolved and moves with the
       profile if it ever changes.
   - `declaration_status` the literal `complete` (`control/v1/sandbox.jq:67`;
     `incomplete` is the only other accepted value and it forces an `inconclusive`
     verdict) and `effects` exactly `{external_writes:false, target_writes:false}`
     (`:72-73`) — both keys required, and `true` or `"unknown"` on either would make the
     run `violated` or `inconclusive`. Both are fixed by the policy, not chosen here.
   - `id` `env.local-macos-ystack-self`, because the driver reads the environment id out
     of the claim (`shadow/v1/reproduce.sh:258-264`).
   - `policy_set_ref`: `{schema_version:1, kind:"control_policy_set", id:` the set's own
     id `, sha256:` the SHA-256 of entry 1's retained bytes `}`.
   - `duty_evaluation_ref`: `{schema_version:1, kind:"duty_separation_evaluation", id:`
     the evaluation's own id `, sha256:` the SHA-256 of entry 6's retained bytes `}`.
   - `stage_result_ref` copied field for field from `duty-evaluation.json`'s
     `body.stage.result_ref`, which `sandbox.jq:210` compares for equality and which
     already names entry 5's bytes.

   References entries 1, 5 and 6 — nothing produced later. The README quotes the jq
   program beside the claim's digest, so a reader can rebuild the bytes and compare.
8. **`{pre,post}/assembled/*`**, then `{pre,post}/qualified-identity.json`, then
   `{pre,post}/state/*` and `{pre,post}/sandbox-evaluation.json` — the two evidence
   assemblies and the two runs in the sections below, each referencing entry 7's claim
   and everything above it.

Only entries 3 and 7 are written by this run rather than by a shipped tool. Both are
canonical `jq -S -c`, both are retained in the evidence, and neither carries a digest
that is not the SHA-256 of bytes retained beside it.

**How the focused test rechecks this.** `scripts/test/shadow-self-host-evidence.test.sh`
walks the same order offline over the committed bytes, recomputing each reference in
turn and stopping at the first mismatch, so a failure names the earliest document whose
bytes moved: the shipped `control/v1` policy and decision digests against
`control-policy-set.json`'s section references; `control-policy-set.json`'s digest
against `duty-evaluation.json`'s `body.policy_set.sha256` and the claim's
`body.policy_set_ref.sha256`; `prerequisite/environment-declaration.json`'s digest
against `prerequisite/input.json`'s
`.stage_request.content.body.environment_ref.fingerprint_sha256`;
`prerequisite/stage-request.json`, `prerequisite/resolved-profile-document.json` and
`prerequisite/stage-result.json` against the duty evaluation's three `body.stage`
references; `prerequisite/materialization-receipt.json`'s digest against the retained
stage result's `body.evidence[0].proof_ref.sha256` and
`body.execution.metadata.tools.source_ref.sha256` (and `body.outputs[0].ref.sha256`
where the outcome is `changed`), so this stage result's references to bytes outside
itself resolve to retained bytes — check 7 below does the same for each case's own
stage result and receipt; the duty evaluation's
`body.stage.result_ref` against the claim's
`body.stage_result_ref`, field for field; `duty-evaluation.json`'s digest against the
claim's `body.duty_evaluation_ref.sha256`; and `environment-claim.json`'s digest against
each case's `assembled/input.json`
`.stage_request.content.body.environment_ref.fingerprint_sha256`. These are requirement
15's checks in a fixed order, not extra ones, and none of them runs a reproduction.

### Assemble each run's input (requirement 12)

Once per case, with `$OUT_DIR` a fresh empty 0700 directory:

```sh
shadow/v1/assemble-materialization-input.sh assemble \
  repo.ystack "$SRC" "$REV" "$REQUESTED_AT" \
  "$REPO/profiles/default/v1" "$RESOLVED_PROFILE" "$JQ" "$OUT_DIR" "$CLAIM" \
  "$REQUESTER"
```

`$REQUESTER` is the retained `requester.json` defined above — the same file and the same
bytes as the prerequisite assembly used, for both cases. A per-case or per-run requester
would make the two cases incomparable and is not done.

`$REV` is `0427390224c25147650f1bd3b6e43ed6911b97a7` for the post case and
`d3f6d525328838b9c2de819699e53d8909ab7a3f` for the pre case. `$REQUESTED_AT` is the
frozen input timestamp for that case, in `YYYY-MM-DDTHH:MM:SSZ`, the same value the
incident record's `observed_at` carries — the real UTC time the digest was checked for
this exercise, not a re-dated outage time (requirement 7). `$CLAIM` is the claim
entry 7 of the construction order above produced; its `id` is
`env.local-macos-ystack-self`, because the driver
reads the environment id straight out of the claim
(`shadow/v1/reproduce.sh:258-264`) and matches it against the registry.

`$OUT_DIR` then holds the seven outputs the assembler commits: `input.json`,
`stage-request-ref.json`, `resolved-profile-ref.json`, `finish-condition.txt`,
`verification-instructions.txt`, `output-contract-decision.txt` and
`policy-decision.txt`. Copy all seven, unmodified, to `<case>/assembled/`.

Build each `qualified-identity.json` so that its `stage_request_ref` and
`resolved_profile_ref` equal the assembler's emitted `stage-request-ref.json` and
`resolved-profile-ref.json` exactly, and its `target_revision` equals that case's
`git_revision_ref`. The driver enforces both (`shadow/v1/reproduce.sh:285-292` and the
final relation check at `:657-667`), so a mismatch is a refusal, not a silent record.

Validate each incident before running it:

```sh
PATH="$JQ_DIR:/usr/bin:/bin" \
  shadow/v1/validate-incident.sh validate "$CASE/incident.json"
```

Both parts matter. The script takes exactly two arguments, the literal verb `validate`
and an **absolute** record path, and exits `E_USAGE` otherwise. It also resolves jq
through `PATH` and requires that binary's exact digest, so the operator's default jq —
1.7.1 on the current Darwin machine — makes it exit `E_RUNTIME`. Prepending `$JQ_DIR`
puts the pinned jq 1.6 first under the name `jq`, mirroring the fixed
`PATH="$scratch/bin:/usr/bin:/bin"` the driver uses for its own internal calls
(`shadow/v1/reproduce.sh:421`, `:606`). `$CASE` is an absolute path.

### The two runs (requirement 8)

Each run needs three fresh, empty, private, mutually disjoint 0700 directories outside
`$SRC` — the driver checks all of that at `shadow/v1/reproduce.sh:112-125`. `$CLOSURE`
is the helper already compiled before the session from
`adapters/local-git-materializer/v1/object-closure.c`, and `$JQ` the already
provisioned pinned binary; neither is built or fetched here.

The driver's scratch argument must be a **fresh, empty** directory created immediately
before each invocation — `$SCRATCH_D` below, not the `$SCRATCH` the closure
reconstruction already wrote `core-members.tsv` and `core-closure.nl.json` into, because
`empty_private_dir` at `shadow/v1/reproduce.sh:113-115` refuses a non-empty scratch root
with `E_WORKSPACE`.

```sh
mkdir -m 0700 "$SCRATCH_D"
shadow/v1/reproduce.sh reproduce \
  "$CASE/incident.json" "$CLAIM" "$POLICY_SET" "$DUTY" \
  "$CASE/assembled/input.json" "$CASE/qualified-identity.json" \
  "$SRC" "$CANDIDATE" "$SCRATCH_D" "$STATE" "$CLOSURE" "$JQ"
```

Post case: outcome `reproduced`, reason `check.failed-at-revision`
(`shadow/v1/reproduce.sh:516-517`), because the observed digest `5b3e0baf…` differs
from the expected `b913cf62…`. Pre case: outcome `no-change`, reason
`check.passed-at-revision` (`:513-514`), because the observed digest *is* `b913cf62…`.
An `inconclusive` result is kept for diagnosis and named in the README as an
unsuccessful attempt; it never stands in for either required outcome.

`$STATE` then holds the four state files the driver exports at
`shadow/v1/reproduce.sh:682-691`: `shadow-record.json`, `trace-ledger.json`,
`trace-receipt.json`, `materialization-result.json`. Copy all four to `<case>/state/`.
Both required outcomes come through the `check.completed` branch, so
`materialization-result.json` is present in both cases; if it is absent the run did not
materialize and is a diagnostic attempt, not one of the pair.

**The receipt those four files reference needs a second, separate call.** The exported
`materialization-result.json` is the materializer's `stage_result` document, and
`adapters/local-git-materializer/v1/protocol.jq:370-373` makes its
`body.evidence[0].proof_ref` and `body.execution.metadata.tools.source_ref` — and, for
a `changed` outcome, `body.outputs[0].ref` (`:392`, `:408`, `:415`) — name the
materialization receipt by digest. The driver writes those receipt bytes to
`$scratch/receipt.json` (`shadow/v1/reproduce.sh:463`), never exports them, and deletes
`$scratch` on every exit path (`:155-158`, `:694-695`). It has no retain flag and no
evidence directory of its own: the twelve arguments are the ones written above, and the
only directory it publishes into is `$STATE`. So retaining only those four files leaves
each case's evidence pointing at bytes no committed file and no Git object holds, which
the spec's recoverability rule (`work/shadow-self-host-run/spec.md:217-220`) refuses.
The prerequisite receipt cannot stand in — it binds a different stage request, and its
digest is not the one either case's stage result names.

Do not intercept the driver's scratch, bypass its cleanup or patch the driver. Obtain
each case's receipt through the materializer's own public interface, after that case's
run, with the same inputs the driver used, into a fresh, empty, private 0700
`$RECEIPT_OUT` and fresh, empty, private, mutually disjoint 0700 `$CAND_R` and
`$SCRATCH_R`, all outside `$SRC` and disjoint from it:

```sh
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash \
  "$REPO/adapters/local-git-materializer/v1/materialize.sh" materialize \
  "$CASE/assembled/input.json" repo.ystack "$SRC" "$CAND_R" "$SCRATCH_R" \
  "$CLOSURE" "$JQ" > "$RECEIPT_OUT/materialize.json"
"$JQ" -j '.payloads[0].data' "$RECEIPT_OUT/materialize.json" \
  > "$RECEIPT_OUT/receipt.json"
"$JQ" -S -c '.stage_result' "$RECEIPT_OUT/materialize.json" \
  > "$RECEIPT_OUT/stage-result.json"
```

The script path must be the absolute one under `$REPO`, for the reason entry 5 gives
(`adapters/local-git-materializer/v1/materialize.sh:23-24`).

**Why these are the driver's own bytes.** Every argument is the one the driver passed
it. `shadow/v1/reproduce.sh:189` snapshots the caller-supplied materialization input
byte for byte into `$scratch/materialize-input.json` and hands the materializer that
copy (`:453`), and the caller-supplied file is `$CASE/assembled/input.json` itself —
the driver re-checks that its digest is unchanged before publishing anything
(`:669-681`). `repo.ystack` is the incident record's repository id; `$SRC`, `$CLOSURE`
and the jq binary are the caller's own arguments, the jq one digest-checked against the
platform pin (`:143-149`) and used only as a snapshot copy of those same bytes
(`:169`). Only the candidate and scratch roots differ, and the receipt records no path:
`adapters/local-git-materializer/v1/materialize.sh:609-617` builds it from the input
snapshot plus the source and candidate commit, tree and changed-path values, and the
candidate commit is made with fixed author and committer identities and a fixed
`2000-01-01T00:00:00Z` date (`:589-598`). The same inputs therefore produce the same
receipt bytes — and requirement 18's repeatability run is the same claim tested twice.

That is the argument; these gates are what settle it. Before retaining anything,
require all of:

- `shasum -a 256 "$RECEIPT_OUT/receipt.json"` equals `payloads[0].sha256` of
  `$RECEIPT_OUT/materialize.json`;
- the same digest equals **both** `body.evidence[0].proof_ref.sha256` and
  `body.execution.metadata.tools.source_ref.sha256` of the driver-exported
  `<case>/state/materialization-result.json` — and `body.outputs[0].ref.sha256` too,
  where that document's outcome is `changed`;
- `cmp "$RECEIPT_OUT/stage-result.json" "<case>/state/materialization-result.json"`
  reports the two byte-identical.

The third is the determinism evidence, not a formality: if the re-invocation reproduced
the driver's entire stage result byte for byte, it reproduced the receipt whose digest
those bytes carry, and the second gate says so directly. If any of the three differs,
stop and reconcile — do not hand-write the receipt, do not re-serialize it, and do not
retain a stage result whose references resolve to nothing.

Extract with `-j`, exactly as the driver does (`shadow/v1/reproduce.sh:463`): the
payload is the exact UTF-8 the materializer hashed, trailing newline included, and it
is already canonical `jq -S -c` output from the producer
(`adapters/local-git-materializer/v1/materialize.sh:609-617`), so it satisfies the
bundle's canonical-JSON rule as emitted. Re-serializing bytes that are referenced by
digest breaks the reference.

Once the gates pass, copy `$RECEIPT_OUT/receipt.json` to
`<case>/materialization-receipt.json` and retain it; it appears in `checksums.json` and
in the manifest beside that case's four state files. `materialize.json` and
`stage-result.json` are scratch and are deleted with `$RECEIPT_OUT`, `$CAND_R` and
`$SCRATCH_R`; none of them is committed. This second materialization is read-only over
`$SRC` on the driver's own terms, and it happens between the two readings of the source
inventory, so requirement 10's before/after comparison still has to come out equal.

**The sandbox evaluation needs a second, separate call.** The driver runs the evaluator
into its own scratch (`shadow/v1/reproduce.sh:421-423`) and does not export the
document; it only records the digest inside the shadow record's
`environment.evaluation.value.evaluation_ref.sha256`. So obtain the bytes through the
shipped evaluator's own public interface with identical inputs:

```sh
PATH="$JQ_DIR:/usr/bin:/bin" \
  control/v1/evaluate-sandbox.sh evaluate "$POLICY_SET" "$DUTY" "$CLAIM" \
  > "$CASE/sandbox-evaluation.json"
```

The `PATH` is not optional and `$JQ` does not cover it: `evaluate-sandbox.sh` takes no
jq argument, discovers jq with `command -v jq` and checks that binary's exact digest
(`control/v1/evaluate-sandbox.sh:46-57`), so with the operator's default jq 1.7.1 on
the current Darwin machine it exits `E_RUNTIME`. The line above mirrors the driver's
own internal invocation, which runs the same evaluator under the fixed
`PATH="$scratch/bin:/usr/bin:/bin"` holding the snapshotted pinned jq as `jq`
(`shadow/v1/reproduce.sh:159-173`, `:421-423`) — the same reason the identical inputs
produce identical bytes.

Then require `shasum -a 256` of that file to equal the reference the shadow record
already carries, before retaining it. If it does not match, stop and reconcile — do not
intercept the driver's scratch, bypass its cleanup, or hand-write the document.

The retained document is declaration-only and the README says so in those words. Check
before retaining that its `sandbox_policy_evaluation` body carries the shipped marker
fields `enforcement_proof: "declaration-only"`, `authority_effect: "none"` and
`qualification_effect: "none"` (`control/v1/sandbox.jq:259-272`), and that a
`satisfied` verdict carries the single reason `sandbox.declaration-satisfied`. That
verdict is what the driver's `satisfied` branch reads
(`shadow/v1/reproduce.sh:436-442`); it records that the claim matched the declared
policy and leaves enforcement `unproven`. Retain the policy and claim bytes as
produced, including the shipped verifier tool digest of 64 ones, and label it in the
evidence and README as the shipped demonstration value rather than a real tool
identity. What may not be retained is a fabricated reference digest: recompute each
reference field listed in the precondition gate from the committed bytes it names and
stop the run on any mismatch.

### Repeatability (requirement 18)

Run each fixed tuple a second time, in fresh disposable candidate, scratch and state
directories, with the same pinned jq, the same `$SRC`, the same `$REQUESTER` and the
same environment — the repeatability assembly is the ten-input invocation above,
argument for argument, with only the output directory changed. Compare:

```sh
diff -r "$OUT_DIR_1" "$OUT_DIR_2"
shasum -a 256 "$STATE_1"/*.json "$STATE_2"/*.json
```

Assembler outputs and driver state must be byte-identical. They can be, because every
timestamp comes from the incident record rather than the clock. Capture the receipt
again on the second run, in its own fresh directories, and require the same three
gates plus equality with the first capture's bytes: that is the determinism the
receipt capture rests on, measured rather than assumed. Repeat the source
ref/object comparison afterwards. This proves repeatability for these inputs on this
machine — not portability to Linux or to future dependency versions, and the README
says so.

### Capture, recoverability, inventory

Copy the thirty per-case files and the twelve shared documents — everything in the
table above except `README.md`, `verification-instructions.md` and `checksums.json`,
which this step writes — into
`shadow/evidence/self-host-transition/v1/`, unchanged. Build `checksums.json` as a
canonical document holding a finite relative-path inventory and SHA-256 for every
bundled file except itself. Every referenced document's raw bytes must be recoverable
from this directory, or from an exact committed Git object the README names by id.

The README must also carry the delegation statement described under "Operator steps":
in plain words, who executed the evidence session, on whose machine and under which
session, and — when the operator delegated it — the operator's own quoted confirmations
of the environment registry entry and the two incident timestamps.

Do not commit `$SRC`, `$CANDIDATE`, `$SCRATCH`, `$SCRATCH_D`, any binary, any
credential, or any
machine-specific absolute path. The replay recipe uses caller-supplied scratch paths,
written as `$SRC`, `$CANDIDATE` and so on, exactly as in this plan. Do not redact or
re-serialize a hashed document to make it committable: if a document cannot be committed
as emitted, stop.

### The focused test (requirement 15)

`scripts/test/shadow-self-host-evidence.test.sh` runs offline, in CI, on Linux, with no
credentials, no model and no real reproduction. It checks the committed bytes:

1. `checksums.json` inventory matches the directory exactly — no extra file, none
   missing — and every digest matches.
2. Every `.json` under the evidence path is canonical (`jq -S -c` output equals the
   file) and a single JSON text. `core-package-closure.json` is the one documented
   exception to the trailing newline: its bytes are canonical `jq -S -c` output with the
   final newline removed, and the check asserts that exception explicitly rather than
   relaxing the rule for the directory.
3. Each incident passes
   `PATH="$JQ_DIR:/usr/bin:/bin" shadow/v1/validate-incident.sh validate <abs>/incident.json`
   — the verb and the absolute path are both required, and the suite's own provisioned
   jq 1.6 directory (`scripts/test/shadow-slice.test.sh:24-51`, already exported as
   `PATH` there) is what the script's `PATH` lookup must find.
4. Each `qualified-identity.json` equals its case's `stage-request-ref.json` and
   `resolved-profile-ref.json` by id and digest, and its `target_revision` equals the
   case's `git_revision_ref`.
5. The post record is `reproduced` / `check.failed-at-revision` at `0427390…`; the pre
   record is `no-change` / `check.passed-at-revision` at `d3f6d52…`; both carry
   `authority: none`, `deploy_authority: none`, `shadow: true`,
   `activation_state: inactive` and
   `qualification: {state: "unavailable", reason_id: "shadow.unqualified"}`
   (`shadow/v1/reproduce.sh:630`).
6. The producer patch payload is empty in **both** locations — `payloads[]` and
   `trust_context.verified_payloads[]` — and
   `stage_request.content.body.operation.arguments.network_mode` is `deny`, the exact
   pair the driver refuses on at `shadow/v1/reproduce.sh:266-282`.
7. `materialization-result.json` is present, its outcome is a no-change
   materialization, and the shadow record's `materialization.value.stage_result_ref`
   digest equals its bytes. Its own outward references resolve inside the bundle too:
   the SHA-256 of that case's `materialization-receipt.json`, recomputed from the
   committed bytes, equals `body.evidence[0].proof_ref.sha256` and
   `body.execution.metadata.tools.source_ref.sha256` — and `body.outputs[0].ref.sha256`
   where the outcome is `changed` — and the two cases' receipts differ from each other
   and from `prerequisite/materialization-receipt.json`, so neither case is recorded
   against another run's proof.
8. The trace seal recomputes: strip `record_digest`, hash each event in order, and
   require the recorded per-event digests, `first_digest`, `final_digest` and
   `event_count` to match, plus the shadow record's `trace_ledger_ref`.
9. Each retained `sandbox-evaluation.json` hashes to that record's
   `environment.evaluation.value.evaluation_ref.sha256`.
10. Each retained evaluation carries the declaration-only marker: its
    `sandbox_policy_evaluation` body has `enforcement_proof: "declaration-only"`,
    `authority_effect: "none"` and `qualification_effect: "none"`, and a `satisfied`
    verdict carries exactly `["sandbox.declaration-satisfied"]`. Alongside it, no
    committed document — evidence, README, verification instructions, `docs/components.md`
    section, index row or restore block — claims a satisfied sandbox boundary,
    enforcement proof or a qualified workflow. The check then asserts requirement 2's
    placeholder division as written: that the retained policy and claim bytes still
    carry the shipped all-ones verifier digest and that the evidence labels it the
    shipped demonstration value, and that each reference field listed in the
    precondition gate equals the SHA-256 recomputed from the committed bytes it names.
    It must not assert that the all-ones value is absent.
11. `core-package-closure.json` recovers the package reference offline: its committed
    bytes hash to
    `eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963`, which equals
    both the shipped and the retained `control-policy-set.json`'s
    `body.core_contract.package_ref.sha256`. The check hashes the bytes with no
    trailing newline added, asserts the file's last byte is not a newline, and asserts
    that the newline-terminated form hashes to the different value
    `06dbd5ec60040dd0d913ca011fd296d7cce78d604bb887a3be0656698f535cf1`, so a copy that
    regained the newline fails rather than passing silently. It also parses the
    descriptor and requires its nine `members[].path` entries and their digests to
    equal the live digests of those nine committed files at the pinned generation.
12. `requester.json` hashes to
    `7596d803e09956c24a627d29558b22a583369080ac653941816c0fbadb2d68cd`, satisfies
    `schema::actor_ref_ok` through the committed core contract, carries role
    `operator`, and its `adapter_instance_id`, `execution_boundary_id` and
    `principal_id` equal none of the six `profiles/default/v1/profile.json` bindings'.
    Every retained `input.json` — both cases' and the prerequisite's — carries
    `.stage_request.content.body.requested_by` equal to those exact bytes, so all three
    assemblies demonstrably ran under the one approved identity.
13. Negative cases: mutate a **copy** of each of an evidence file, a digest in
    `checksums.json`, and an outcome field, and require the test to fail on each. A
    test that passes on altered evidence proves nothing.

### The consumers (requirements 16, 17)

**Scope.** Exercise the shipped `scope/v1/evaluate-scope.sh` with a clearly marked
inactive compatibility harness. It takes seven documents in this order — scope,
shadow-set, dashboard, risk, kill, duty, marker (`scope/v1/evaluate-scope.sh:73`). The
harness supplies the two real unchanged shadow records as the shadow set, with the
actual identities, and whatever the other six slots need. The assertion is narrow: the
evaluator's complete shape and reference checks accept these records, and any other
missing gate evidence is reported distinctly from malformed shadow evidence. Require
the evaluator's own vocabulary for the classification — `outcome: "not-proposable"`
with `qualification: {state: "unavailable", reason_id:
"scope.enablement-requires-operator-pr"}` (`scope/v1/scope-gates.jq:924`, `:954`) — and
never restate it as a passing or proposable result. Do not copy or weaken the
validator, do not create live scope authority, and say in the harness header that
compatibility is not qualification.

**Maintenance.** Feed each incident with its matching shadow record to the real
converter:

```sh
maintenance/v1/incident-to-eval.sh convert <incident.json> <shadow-record.json> "$OUT"
```

`maintenance/v1/incident-to-eval.jq:59` maps a `file-digest` check to family
`stale-moved-artifacts`, and `:64-65` maps `reproduced` to
`{disposition: accepted, status: stale}` and `no-change` to
`{disposition: accepted, status: completed}`. Require exactly those, require the
generated skeleton to carry the converter's own
`qualification: {state: "unavailable", reason_id: "maintenance.no-adapter-exists"}`
(`maintenance/v1/incident-to-eval.jq:80`), require the
provenance digests to equal the supplied documents, and require the two cross-pairings
(post incident with pre record, and the reverse) to fail. The emitted
`eval-seed-case-stale-moved-artifacts.json` is a test output written to a temporary
directory; `evals/v1/seed-set.json` is not touched.

### Documentation, manifest, final proof

Add the manifest block, the `docs/components.md` section, the `README.md` index row and
the `RESTORE.md` block. The restore text says what restoration does and does not do: it
restores evidence and verification instructions, and it executes no run and registers,
activates or qualifies nothing. The registry entry for
`env.local-macos-ystack-self` stays `proof_state: unproven`; this initiative does not
change it.

None of this prose may describe the run as sandbox-enforced, qualified or proposable.
Each place that mentions the environment says the evaluation was declaration-only and
enforcement stays `unproven`, and points at `work/real-sandbox-boundary/spec.md` as the
record of what a real boundary would have to bind — a step-8 prerequisite, not this
run's. The focused test's check 10 enforces this on the committed bytes, so write the
documentation to pass it rather than patching the test.

Then run the Proof section on the final head and paste it into the PR body with commit
SHAs.

## Operator steps

Everything in "Prepare the disposable source", "Resolve the real profile", "Assemble
each run's input", "The two runs" and "Repeatability" runs natively on the operator's
macOS machine, under the operator's own user account, against the operator's own ystack
history. The operator may execute the session by hand, or delegate execution to the
manager session running on that machine — never to CI, never to a remote or cloud
session, and never to a coder subagent. When the session is delegated, the README and
the requester record state the delegation explicitly: who executed it, on whose machine
and under which session. The requester identity stays the DR-5 operator identity,
because the machine, the account and the authority are the operator's. The operator
hands back the evidence files; the coder commits them unchanged and writes the test,
README and docs around them.

The operator also confirms the environment registry entry and the incident timestamps,
because only the person who watched the transition can say when each digest was
actually checked. These two hand-confirmed items remain the operator's own
confirmations even when execution is delegated: the operator gives them in chat or on
the intake issue, and the README quotes them.

## Risks

**Overclaiming the declaration is the one that can sink this.** The evaluator compares
declarations, so a `satisfied` verdict here is cheap and easy to misread as a boundary.
Two failure modes follow. The first is language: a README line, a docs sentence or a
consumer summary that calls the run sandbox-enforced, qualified or proposable turns
honest evidence into a false claim, which is why the retained bytes must keep the
declaration-only marker and check 10 greps the committed prose. The second is fixtures:
a coder who finds the claim, policy set and duty at
`scripts/test/shadow-slice.test.sh:128-195`, sees them produce `satisfied`, and reuses
them — their references are repeated-character placeholders (`"2" * 64`, `"b" * 64`)
naming no real bytes. The answer to "where do the real ones come from, then" is the
construction order above, and its prerequisite stage run is the only reason that order
is acyclic; a coder who skips it will find no way to build the claim except by
inventing digests. A fabricated reference digest in a committed reference stops the
run; review should recompute each reference field listed in the precondition gate and
look for those repeated-character values in anything committed. The shipped verifier
tool digest of 64 ones that `control/v1/sandbox-policy.json` pins is the other half of
the division and is not the failure mode: it stays in the retained policy and claim
bytes, labelled as the shipped demonstration value, and check 10 asserts its presence
and its label rather than its absence. The real execution boundary
stays a step-8 prerequisite, and nothing here shortens or substitutes for it.

**Reading the real repository.** Both runs read history that contains the operator's
own work. The mitigations are the ones the shipped code already enforces — the driver
never writes to `$SRC`, refuses a materialization input carrying patch bytes or
network access before it consults anything else, and only ever runs Git object reads —
plus the before/after ref and object comparison this plan records. The residual risk is
the disposable clone itself: it holds the whole repository and must be deleted, and
never committed. The alternative I rejected was carving a narrow single-file repository
instead of cloning: it would be smaller, but requirement 9 wants authentic commits and
objects, and rebuilding commits would make the evidence about a fabricated history.

**Darwin runs, Linux CI.** The runs happen only on macOS; CI rechecks only durable
bytes and never possesses the historical repository. So a Linux reader gets the
evidence and the offline proof, not a reproduction. Two places this bites: the pinned
jq digest differs by platform (both scripts branch on `uname`), and the evidence must
carry everything the test needs, because CI cannot go and fetch a missing document.
That is exactly why `checksums.json` and the recoverability rule exist, and why the
test's first check is that the inventory is complete.

**Scope creep through the consumers.** The riskiest step to get subtly wrong is the
scope harness, because a harness that reaches too far starts to look like a
qualification claim. Keep it to shape and reference compatibility, keep the "inactive
compatibility harness" marker in the file, and keep the seed output in a temp
directory. The alternative — a second test file for the consumers — I rejected because
it would duplicate the whole evidence-loading half for no reviewer benefit.

**A refusal mid-exercise.** If the assembler or driver refuses, the answer is the
precondition gate or the operator's own inputs, not a local patch, a weakened claim or
a private registry entry. A
refused attempt is listed in the README as an unsuccessful diagnostic attempt and is
never relabelled as the accepted pair.

## Proof

Run on the final implementation head, with the head SHA pasted beside each command in
the PR body.

1. `bash scripts/test/shadow-self-host-evidence.test.sh` — the offline evidence check,
   both consumer harnesses, and every negative case. Paste the full output.
2. `bash scripts/test/run-all.sh` — the whole suite, showing nothing else regressed.
3. `bash scripts/test/shadow-slice.test.sh` and
   `bash scripts/test/shadow-assembler.test.sh` — the two shipped slices this work
   consumes, still green and still unmodified.
4. The operator's run transcript for both cases: the two `reproduce.sh` command lines
   with their outcome and reason ids, the two assembler command lines, the resolver
   command line with the `PATH` it ran under, the two standalone
   `evaluate-sandbox.sh` and `validate-incident.sh` command lines with theirs, the two
   per-case `materialize.sh` command lines that captured the receipts together with
   their three digest gates, the pre-session provisioning line (asset, URL, verified
   digest, date) marked as work outside requirement 10's boundary, and the
   dependency heads (`resolver-trusted-parent` implementation commit, assembler commit
   already on `main`).
5. The repeatability comparison: `diff -r` over both assembler output directories and
   `shasum -a 256` over both state directories, showing byte-identical results.
6. The source integrity comparison: the `show-ref` and `cat-file --batch-all-objects`
   digests before the first run and after the last, equal.
7. `git show <head>:shadow/evidence/self-host-transition/v1/checksums.json` alongside a
   fresh `shasum -a 256` walk of the committed directory, showing the inventory is
   complete and current.
8. Required CI green and independent non-author review on that exact final head.

None of this changes the registry's `proof_state`, grants write permission, or completes
a Roadmap step beyond this bounded observation.
