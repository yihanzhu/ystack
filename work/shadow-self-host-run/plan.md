---
spec-blob: a1674656fcf440113b8e7b5f955f4a4065e621cd
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

**New evidence, under `shadow/evidence/self-host-transition/v1/`.** Seven shared
files and fourteen per case, thirty-five in all:

| Path | What it is | Lines |
| --- | --- | ---: |
| `README.md` | Input tuples, dependency commits, digests, outcomes, replay recipe | 90-130 |
| `verification-instructions.md` | Requirement 14's minimal file-digest procedure | 45-70 |
| `checksums.json` | Relative-path inventory and SHA-256 of every other bundled file | 1 |
| `resolved-profile.json` | The resolver's output, shared by both runs | 1 |
| `environment-claim.json` | The real claim for `env.local-macos-ystack-self` | 1 |
| `control-policy-set.json` | The policy set the driver was handed | 1 |
| `duty-evaluation.json` | The duty evaluation the claim references | 1 |
| `{pre,post}/incident.json` | `incident.ystack-transition.{pre,post}` | 2 |
| `{pre,post}/qualified-identity.json` | The identity each run was performed under | 2 |
| `{pre,post}/sandbox-evaluation.json` | The shipped evaluator's declaration-only document for that run | 2 |
| `{pre,post}/assembled/*` | The assembler's seven outputs, native names | 20-40 |
| `{pre,post}/state/*` | The driver's four state files, native names | 8 |

Canonical JSON is one line per file, so the JSON count is small and the review work is
in the expanded documents, not the line count. The four assembler decision texts
(`finish-condition.txt`, `verification-instructions.txt`, `output-contract-decision.txt`,
`policy-decision.txt`) are raw text and carry most of the `assembled/` lines.

**New test:**

- `scripts/test/shadow-self-host-evidence.test.sh` (new, mode `0755`, 300-390 lines).
  Requirements 15, 16 and 17 together: the offline evidence check, the scope-consumer
  compatibility harness, and the maintenance-consumer conversion. One file, because all
  three read the same committed bytes and none of them runs a real reproduction.

**Existing files:**

- `ci/required-files.txt` (+38). A block headed
  `# First self-host shadow evidence` after the assembler block at lines 414-417,
  listing all thirty-five evidence paths and the new test.
- `docs/components.md` (+30-40). A `## First self-host shadow evidence` section after
  the assembler write-up, which today runs to line 1395 before
  `## Inactive maintenance loop` at 1397.
- `README.md` (+2). One index row after the assembler row at line 289.
- `RESTORE.md` (+18-22). A restore block after the assembler block at lines 223-241.

### What does not change

`shadow/v1/reproduce.sh`, `shadow/v1/assemble-materialization-input.sh`,
`shadow/v1/materialization-input.jq`, `shadow/v1/incident-record.jq`,
`shadow/v1/qualified-identity.jq`, `shadow/v1/shadow-environments.json`,
`adapters/local-git-materializer/v1/*`, `control/v1/*`, `scope/v1/*`,
`maintenance/v1/*`, `evals/v1/seed-set.json`, `profiles/default/v1/*`, and every
accepted intent, spec or plan. The evidence is committed output; if a shipped
component refuses it, the component is right and the run is wrong.

### Review size

`review_size: accepted-exception` for the **implementation PR**, one concern — the
first real self-host evidence pair and its durable verification — with an
evidence-based range of **600-800 net lines**.

This is above the spec's earlier 250-450 figure, which the spec itself asked this plan
to refine against the real interfaces. Two things grew once I read them:

- The focused test carries requirements 15, 16 **and** 17. The spec allots 100-170 for
  it. Against the real consumers that is 300-390: `scope/v1/evaluate-scope.sh` takes
  seven separate input documents (`scope/v1/evaluate-scope.sh:73`), and
  `maintenance/v1/incident-to-eval.sh` needs both directions plus the cross-pairing
  refusal, on top of the twelve evidence checks requirement 15 lists.
- The manifest block is 38 lines, not a handful, because the spec's design requires
  every committed evidence file to be appended to `ci/required-files.txt` and the
  design names thirty-five of them.

The rest is close to the spec's own breakdown: 135-200 for README and verification
instructions, 60-110 of committed evidence bytes, 50-64 for documentation, index and
restore. Midpoint 700. If the real diff lands outside 600-800, stop and return to the
gate rather than compressing the test or dropping evidence files.

`review_size: accepted-exception` for **this plan PR**, one concern — the complete
pre-code design for the first real self-host run — with an evidence-based range of
**545-605 lines**. Requirement 2's declaration-only framing carries real cost in this
plan: the precondition gate, the evaluator call, the marker checks, the consumers'
vocabulary and the documentation rule each have to state the boundary between a
declaration and enforcement, and the exact invocations — the validator's verb and the
`PATH` the two standalone calls need — are design detail a reader cannot infer.

## Order of work

### The precondition gate

**No run step below may execute until both of these are merged on `main` with their
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

**No sandbox dependency gates these runs.** Per requirement 2 the runs use the shipped
declaration-only evaluation exactly as shipped — `control/v1/evaluate-sandbox.sh` with
`control/v1/sandbox-policy.json` and `control/v1/sandbox.jq` — and claim no execution
boundary. A real boundary is a step-8 prerequisite, not this run's. Two limits hold
regardless. First, the evaluator compares declarations, so although the driver
proceeds only when the verdict is `satisfied` (`shadow/v1/reproduce.sh:436-442`,
matching `.body.verdict`), what it proceeds on is a declaration verdict and nothing
more: the single expected reason is `sandbox.declaration-satisfied`
(`control/v1/sandbox.jq:256`), and enforcement stays `unproven`. A verdict that is not
`satisfied` stops the run at `environment.not-satisfied`; it is not worked around. Second, the placeholder digests stay out of the evidence: the fixtures at
`scripts/test/shadow-slice.test.sh:128-195` build their control policy and decision
references from repeated-character values (`("2" * 64)`, `("b" * 64)`), and
`control/v1/sandbox-policy.json` pins demonstration `/sandbox/*` roots with a verifier
digest of 64 ones. Any such digest in a committed reference stops the run rather than
being retained.

**What the coder may do before that gate clears**, because none of it needs a run:

- Write the whole of `scripts/test/shadow-self-host-evidence.test.sh` except the
  assertions that read committed evidence bytes: the jq-1.6 provisioning block copied
  from `scripts/test/shadow-slice.test.sh:24-51`, the temp-directory and result
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

### Prepare the disposable source (requirements 9, 10)

Operator-run on Darwin, no network, no credentials. `$SRC` is a fresh path outside the
user's repository; nothing below ever touches
`/Users/yihanzhu/git/ystack/.git`.

```sh
git clone --bare --no-hardlinks -- /Users/yihanzhu/git/ystack "$SRC"
git --git-dir="$SRC" remote remove origin
rm -rf -- "$SRC/logs" "$SRC/info/grafts" "$SRC/objects/info/alternates"
find "$SRC/hooks" -type f ! -name '*.sample' -delete
printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n' \
  > "$SRC/config"
```

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
git --git-dir="$SRC" show-ref | shasum -a 256
git --git-dir="$SRC" cat-file --batch-all-objects --batch-check='%(objectname)' \
  | shasum -a 256
```

Both digests go in the README, taken before the first run and again after the last one.
They must be equal. Also confirm both revisions and the root are present:

```sh
git --git-dir="$SRC" cat-file -t 0427390224c25147650f1bd3b6e43ed6911b97a7
git --git-dir="$SRC" cat-file -t d3f6d525328838b9c2de819699e53d8909ab7a3f
git --git-dir="$SRC" rev-list --max-parents=0 0427390224c25147650f1bd3b6e43ed6911b97a7
```

### Resolve the real profile (requirement 11)

One resolution, shared by both runs, through the entry the `resolver-trusted-parent`
spec defines:

```sh
resolver/v1/resolve-profile.sh "$JQ" "$RESOLVE_OUT" "$REQUEST" "$MAP" > resolved-profile.json
```

`$JQ` is the pinned jq 1.6 (Darwin SHA-256
`5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`, the value both
shipped scripts check). Provision it the way the focused suites already do
(`scripts/test/shadow-slice.test.sh:24-51`): fetch the pinned jq 1.6 release asset for
the platform into the shared cache, verify that digest, then copy it into a fresh 0700
directory `$JQ_DIR` under the file name `jq` (mode `0555`), so `$JQ` is `$JQ_DIR/jq`.
`$JQ_DIR` is needed as a directory, not just as a path to a binary, because two
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

### Assemble each run's input (requirement 12)

Once per case, with `$OUT_DIR` a fresh empty 0700 directory:

```sh
shadow/v1/assemble-materialization-input.sh assemble \
  repo.ystack "$SRC" "$REV" "$REQUESTED_AT" \
  "$REPO/profiles/default/v1" "$RESOLVED_PROFILE" "$JQ" "$OUT_DIR" "$CLAIM"
```

`$REV` is `0427390224c25147650f1bd3b6e43ed6911b97a7` for the post case and
`d3f6d525328838b9c2de819699e53d8909ab7a3f` for the pre case. `$REQUESTED_AT` is the
frozen input timestamp for that case, in `YYYY-MM-DDTHH:MM:SSZ`, the same value the
incident record's `observed_at` carries — the real UTC time the digest was checked for
this exercise, not a re-dated outage time (requirement 7). `$CLAIM` is the real
environment claim; its `id` must be `env.local-macos-ystack-self`, because the driver
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
`$SRC` — the driver checks all of that at `shadow/v1/reproduce.sh:112-125`. The closure
helper is compiled from `adapters/local-git-materializer/v1/object-closure.c`, the same
way `scripts/test/shadow-slice.test.sh:52-55` builds it.

```sh
shadow/v1/reproduce.sh reproduce \
  "$CASE/incident.json" "$CLAIM" "$POLICY_SET" "$DUTY" \
  "$CASE/assembled/input.json" "$CASE/qualified-identity.json" \
  "$SRC" "$CANDIDATE" "$SCRATCH" "$STATE" "$CLOSURE" "$JQ"
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
policy and leaves enforcement `unproven`. No committed reference may carry a
placeholder digest — see the precondition gate.

### Repeatability (requirement 18)

Run each fixed tuple a second time, in fresh disposable candidate, scratch and state
directories, with the same pinned jq, the same `$SRC` and the same environment. Compare:

```sh
diff -r "$OUT_DIR_1" "$OUT_DIR_2"
shasum -a 256 "$STATE_1"/*.json "$STATE_2"/*.json
```

Assembler outputs and driver state must be byte-identical. They can be, because every
timestamp comes from the incident record rather than the clock. Repeat the source
ref/object comparison afterwards. This proves repeatability for these inputs on this
machine — not portability to Linux or to future dependency versions, and the README
says so.

### Capture, recoverability, inventory

Copy the twenty-eight per-case files and the seven shared files into
`shadow/evidence/self-host-transition/v1/`, unchanged. Build `checksums.json` as a
canonical document holding a finite relative-path inventory and SHA-256 for every
bundled file except itself. Every referenced document's raw bytes must be recoverable
from this directory, or from an exact committed Git object the README names by id.

Do not commit `$SRC`, `$CANDIDATE`, `$SCRATCH`, any binary, any credential, or any
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
   file) and a single JSON text.
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
   digest equals its bytes.
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
    enforcement proof or a qualified workflow, and none carries a repeated-character
    placeholder digest.
11. Negative cases: mutate a **copy** of each of an evidence file, a digest in
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
macOS machine, by the operator, against the operator's own ystack history. No agent
session performs them and no CI job performs them. The operator hands back the
evidence files; the coder commits them unchanged and writes the test, README and docs
around them.

The operator also confirms the environment registry entry and the incident timestamps,
because only the person who watched the transition can say when each digest was
actually checked.

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
and `control/v1/sandbox-policy.json` pins demonstration `/sandbox/*` roots with a
verifier digest of 64 ones. A placeholder digest in a committed reference stops the run;
review should look for those values in anything committed. The real execution boundary
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
   `evaluate-sandbox.sh` and `validate-incident.sh` command lines with theirs, and the
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
