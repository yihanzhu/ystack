---
intent-blob: 260a66350c0fad4d8d9bda4c68811e95b9783c5d
risk: high
drafted: 2026-09-27
---

# Spec: enforcement-evidence binding for the real sandbox receipt

Tracks #436. Step-8 child concern 2 (`work/step8-bounded-write-readiness/spec.md:292`),
first child of the sandbox decision (`work/real-sandbox-boundary/spec.md:155-157`).
It defines one receipt kind, the documents a consumer checks it against, one pure
consumer check, and the host-side origin rule that later concerns implement. Nothing
here produces a real receipt, runs a sandbox, or changes what any shipped gate accepts.
All citations are to origin/main at `272ec0f`.

## Requirements

### R1. Placement and kind separation

1. The new component lives in `enforcement/v1/`. `control/v1/**` stays
   byte-identical: its evaluator is a declaration check with a pinned decision
   (`control/v1/evaluate-sandbox.sh:152-179`), and a receipt is not a declaration.
2. Four document kinds are defined, each `schema_version: 1`, with the exact top-level
   keys `body`, `id`, `kind`, `schema_version` used by every control document
   (`control/v1/sandbox.jq:59-61`):
   - `sandbox_enforcement_receipt` (R3), written only by the host supervisor;
   - `sandbox_receipt_expectation` (R4), written by the consumer before launch;
   - `sandbox_accepted_identity_set` (R5), a reviewed repository document;
   - `sandbox_receipt_check` (R7), the check's output.
3. The receipt sits beside `sandbox_policy_evaluation` and references it by digest
   (R3.4); it never embeds or rewrites it. A consumer tells the two apart only by the
   exact `kind` and `schema_version` strings, never by which fields are present. A
   `sandbox_policy_evaluation` given where a receipt is expected is refused with
   `receipt.declaration-only`; any other kind or schema version with
   `receipt.kind-unsupported`.
4. Old records keep their meaning. `enforcement_proof: "declaration-only"`,
   `authority_effect: "none"` and `qualification_effect: "none"`
   (`control/v1/sandbox.jq:263-272`), `environment.satisfied` in the shadow driver
   (`shadow/v1/reproduce.sh:436-440`) and `environment_evaluation_ok`
   (`scope/v1/scope-gates.jq:462-479`) are unchanged, and nothing reads a
   declaration as enforcement.

### R2. Origin: how a consumer authenticates a receipt without a credential

1. **Trust model.** The verifier, the candidate, its output and every caller-supplied
   document are untrusted, and so is every process of the operator's interactive
   account, including any producer, reviewer or agent harness. The host supervisor
   runs under a dedicated host account (the supervisor principal) that no other
   component uses, and the sandbox decision already places it inside the trusted
   runtime boundary (`work/real-sandbox-boundary/spec.md:118-124`). The consumer is
   trusted to read, not to write. No signing credential is used.
2. **Authentic origin is a channel property, not a content property.** A receipt is
   authentic only when the consumer itself reads it from the supervisor store under
   R2.3. Matching field values, a matching digest, or a copy with the same bytes read
   from anywhere else prove integrity at most, never origin
   (`work/real-sandbox-boundary/spec.md:54-61`).
3. **Supervisor store rules** (implemented by concern 4; checked by concern 5):
   - The store root is fixed in the supervisor's trusted configuration, never taken
     from a caller argument, the verifier, or the candidate. It is a host directory
     outside every `/sandbox/*` root and never shared into the guest.
   - Root and per-attempt directories are owned by the supervisor principal with a
     group containing only the consumer's account, mode `0750`, with no ACL entries.
     No account other than the supervisor principal (and the host administrator,
     R2.5) can create, replace or change anything in the store.
   - Each attempt has exactly one receipt at `<store>/<attempt_id>/receipt.json`,
     created exclusively, fsynced, then mode `0440`, link count 1. A second write
     for the same attempt id fails and the supervisor records a failure instead.
   - The consumer opens the file relative to a directory descriptor for the store
     without following symlinks; requires a regular file and parent directories
     with the owner, group, mode and link count above; copies at most 1,048,576 bytes; re-checks the same metadata
     after the read; and then runs the R7 check on the copied bytes.
   - The consumer records an origin section `{state, store_id, method,
     observation_sha256}` in the record it attaches the receipt to, with `method:
     "controlled-storage.v1"` and `state: "authenticated"` only when every rule
     held; otherwise `state: "unauthenticated"`, which never counts.
4. **Offline readers.** A receipt retained in an evidence bundle keeps its bytes and
   its recorded origin section. An offline reader can check integrity and the R7
   bindings; it cannot re-authenticate origin. That rests on the host being trusted
   when the record was made.
5. **Residual and the question it raises.** A compromised supervisor principal or
   host administrator can write the store and defeat R2.3. This is the credential-free answer's limit, not a gap in
   it. The question is asked inside concern 4's already-reserved decision
   (installation and native qualification, `work/step8-bounded-write-readiness/spec.md:294`),
   not now, because creating the supervisor principal is itself an installation:
   *"Create the dedicated supervisor host account and accept it and the host
   administrator as the trust root for receipt origin, with no signing key, for
   environment `<id>`; or authorize a supervisor signing credential (named store,
   principal and lifetime) first?"* No account or credential is selected or created
   by this spec.

### R3. The receipt

1. **Envelope.** `kind: "sandbox_enforcement_receipt"`, `id` matching `id_ok`
   (`control/v1/sandbox.jq:4-5`). `body` has exactly the keys `attempt`,
   `contract_version`, `control`, `identities`, `limits`, `origin`, `outcome`,
   `payload`, `subject`, `teardown`, `timing`. `contract_version` is exactly `"v1"`.
   Bytes are canonical `jq -S -c` text with one trailing newline, at most 1,048,576
   bytes, depth at most 32 and at most 4,096 members, as
   `control/v1/evaluate-sandbox.sh:91-117` bounds control inputs.
2. **`origin`** (content claims only; R2 is the proof): `producer_role:
   "host-supervisor"`, `store_id` (`id_ok`), `accepted_set_sha256`: the SHA-256 of
   the accepted identity set the supervisor launched under.
3. **`attempt`:** `attempt_id` (`id_ok`), `attempt_number` (integer 1-1024) and
   `launch_request_sha256`: the SHA-256 of the consumer's launch request, which
   carries a 256-bit nonce the consumer drew from operating-system randomness before
   launch and never exposed to the guest.
4. **`control`:** `policy_sha256`, `decision_sha256`, `policy_set_sha256`,
   `evaluator_driver_sha256`, `evaluator_program_sha256`, and
   `sandbox_evaluation_sha256`: the declaration evaluation that admitted the launch.
5. **`subject`:** `environment_id`; `environment_entry_sha256` (SHA-256 of the
   environment's registry entry as canonical `jq -S -c` text);
   `target_repository_id`; `source` `{repository_id, hash_algorithm, commit_id,
   tree_id}`; `candidate` `{preparation_record_sha256, manifest_sha256, commit_id,
   tree_id}` from the preparation record and manifest
   (`preparation/v1/prepare-candidate.py:1906-1930`); and `incident_sha256`.
6. **`identities`:** exactly these ten slots, derived one-to-one from the byte
   identities of `work/real-sandbox-boundary/spec.md:45-47` (supervisor and guest
   kernel/configuration each split into two, as its design names a host and a guest
   supervisor at `:94-99`): `host_runtime`, `guest_kernel`, `guest_kernel_config`,
   `guest_init`, `image`, `host_supervisor`, `guest_supervisor`, `verifier`,
   `toolchain`, `verification_instructions`. Each value is `{state: "observed",
   sha256}` or `{state: "unobserved", reason_id}`. The remaining identities of
   `:48-49` (policy, decision, evaluator, policy set, source, candidate, incident,
   environment, attempt) are bound by R3.3-R3.5.
7. **`limits`:** exactly the six rows of R6, each `{bound, observed, resolution,
   observation, enforcement, reached, mechanism_id, observer}`: `bound` and
   `resolution` non-negative integers; `observed` a non-negative integer or `null`;
   `observation` one of `complete`, `partial`, `unavailable`; `enforcement` one of
   `hard`, `none`, `unknown`; `reached` boolean; `mechanism_id` `id_ok`; `observer`
   one of `host-supervisor`, `guest-supervisor`. `observed` is `null` exactly when
   `observation` is `unavailable`, and `observed` at or above `bound` requires
   `reached: true`; a row breaking either rule is malformed.
8. **`teardown`:** `state` one of `confirmed`, `failed`, `unconfirmed`, plus booleans
   `tree_terminated` and `storage_destroyed`. `confirmed` requires both true.
9. **`payload`** (untrusted verifier output, bound by digest only): `stdout_sha256`,
   `stderr_sha256`, `evidence_manifest_sha256`, `exit_state` one of `exited`,
   `signaled`, `not-started`, and `exit_code` (integer 0-255 when `exited`, else
   `null`). Payload content never changes the enforcement verdict.
10. **`timing`:** `admitted_at` and `terminated_at`, UTC `YYYY-MM-DDTHH:MM:SSZ`, with
    `admitted_at` not after `terminated_at`. Times are recorded honestly and never
    used for acceptance.
11. **`outcome`:** `verdict` and `reason_ids` (sorted, unique), derived by R8.
12. **Identity values.** Every `*_sha256` and observed `sha256` is 64 lowercase hex.
    Version names and mutable tags cannot appear, because no slot accepts anything
    but a digest. The all-ones digest (`control/v1/sandbox.jq:179-182`) and the
    all-zeros digest are placeholders and are refused wherever an identity appears.

### R4. The expectation

1. The consumer writes `sandbox_receipt_expectation` before launch, from its own
   inputs, never from the receipt. `body` has exactly `attempt`, `control`,
   `store_id` and `subject`, with the same shapes as R3.3-R3.5.
2. It is the record the receipt is attached to for step-8 R7.1
   (`work/step8-bounded-write-readiness/spec.md:275-277`): the attempt, candidate,
   environment and policy identities are compared here, field for field.

### R5. The accepted identity set

1. `enforcement/v1/accepted-identities.json`, `id: "sandbox.accepted-identities.v1"`,
   `body` exactly `{activation_state: "inactive", set_version: "v1", environments}`.
2. Each environment entry has exactly `environment_id`; `scratch_bytes` (positive
   integer); `identities` with the ten R3.6 slots, each a sorted unique array of
   1-8 digests with no placeholder; `mechanisms` with the six R6 rows, each a sorted
   unique array of 1-8 `id_ok` values. Observers are fixed by the R6 table, not by
   the set.
3. It ships with `environments: []`. With the shipped set, every receipt is refused
   with `receipt.identity-unaccepted`, so no fixture or forgery can pass the
   shipped check. Adding an entry is concern 4's reviewed change, together with
   that environment's native qualification.
4. **Not yet available.** No slot of a `satisfied` or `violated` receipt may be
   `unobserved`. `unobserved` is allowed only in a `failed` receipt, where the
   supervisor could not measure a dependency before refusing. Synthetic fixtures
   use ordinary synthetic digests with a test-only accepted set; they are never
   written to the shipped set.
5. **Relation to native qualification.** The receipt proves one attempt's
   enforcement; the registry's `proof_state`
   (`shadow/v1/shadow-environments.json`) records whether the environment qualified.
   Neither implies the other. The R7 check requires the environment to be listed in
   the registry and in the accepted set; it does not read `proof_state`. Requiring
   `proof_state` other than `unproven` is concern 6's rule
   (`work/step8-bounded-write-readiness/spec.md:278-279`).

### R6. Accounting semantics

The verifier task tree is the verifier process the guest supervisor starts with the
fixed argv (`control/v1/sandbox.jq:179-182`) and every process and thread descended
from it, including exited and reparented ones. It excludes both supervisors, whose
own bounds are accepted separately (`work/real-sandbox-boundary/spec.md:118-124`).
Bounds for the first five rows equal `control/v1/sandbox-policy.json` `limits`
(`control/v1/sandbox.jq:170-171`); none is raised or reinterpreted.

| Row | Bound | What is counted | Window | Observer |
| --- | --- | --- | --- | --- |
| `cpu_time_ms` | 30,000 | Total user and system CPU time of every task in the tree | Verifier exec to confirmed tree termination | guest-supervisor |
| `wall_time_ms` | 60,000 | Host monotonic elapsed time | Launch admission to confirmed tree termination | host-supervisor |
| `memory_bytes` | 536,870,912 | Peak memory charged to the tree, including shared, file-backed and kernel memory the mechanism attributes to it | Whole attempt | guest-supervisor |
| `output_bytes` | 10,485,760 | Bytes successfully written by the tree to stdout, stderr and under `/sandbox/evidence`, combined; counted as written, so overwrite or truncation hides nothing | Whole attempt | guest-supervisor |
| `process_count` | 32 | Peak concurrent tasks, processes and threads, including the verifier | Whole attempt | guest-supervisor |
| `scratch_bytes` | R5.2 value | Peak storage allocated under `/sandbox/scratch`, data and metadata as the mechanism attributes it | Whole attempt | guest-supervisor |

For every row: `mechanism_id` must be in that row's accepted list and `observer` must
equal the table's. `resolution` is the smallest increment the mechanism
reports. A mechanism whose behaviour permits exceeding the bound at any instant
(a rate limit, a poll followed by a kill, a documented temporary overshoot) records
`enforcement: "none"`. `reached` is true when the observed value met or exceeded the
bound or the mechanism stopped the tree. Unknown, partial, unavailable, `none` or
reached never reads as satisfied. The contract names no runtime or mechanism.

### R7. The consumer check

1. **Entry.** `enforcement/v1/check-sandbox-receipt.sh check <receipt> <expectation>
   <sandbox-evaluation>`; program `enforcement/v1/sandbox-receipt.jq`. It reads these
   fixed files from the repository, never from arguments:
   `control/v1/sandbox-policy.json`, `control/v1/sandbox-decision.json`,
   `control/v1/control-policy-set.json`, `shadow/v1/shadow-environments.json` and
   `enforcement/v1/accepted-identities.json`.
2. **Driver discipline,** as `control/v1/evaluate-sandbox.sh` does: pinned jq 1.6 by
   the digests at `:50-57`; physical regular files only; bounded snapshots; canonical
   inputs; unchanged re-check of every input and fixed file after evaluation; no
   network, credential, model call, subprocess other than the pinned jq, or write
   outside its own `mktemp` scratch. Usage, runtime, limit, parse and canonical
   failures exit 1 with one error code on stderr and no output. Everything else
   exits 0 with one canonical `sandbox_receipt_check` document on stdout.
3. **Output body,** exactly: `activation_state: "inactive"`, `authority_effect:
   "none"`, `qualification_effect: "none"`, `origin_check: "not-performed"`,
   `check_verdict` (`valid` or `refused`), `enforcement_verdict` (`satisfied`,
   `violated`, `failed`, or `none` when refused), `reason_ids`, and
   `receipt_sha256`, `expectation_sha256`, `evaluation_sha256`,
   `accepted_set_sha256`. `valid` has `reason_ids: ["receipt.valid"]`.
4. **Refusal reasons,** a closed list. The first three are exclusive: when one
   applies it is the only reason, since nothing else can be read. Otherwise every
   applicable reason is reported, sorted:

| Reason | Refused when |
| --- | --- |
| `receipt.declaration-only` | The receipt input is a `sandbox_policy_evaluation` |
| `receipt.kind-unsupported` | Any other kind, schema version or `contract_version` |
| `receipt.malformed` | Receipt or expectation fails its R3/R4 shape |
| `receipt.placeholder-identity` | Any identity or `*_sha256` is all-ones or all-zeros |
| `receipt.origin-mismatch` | `producer_role` is not `host-supervisor`, or `store_id` differs from the expectation |
| `receipt.replayed` | `attempt_id`, `attempt_number` or `launch_request_sha256` differs from the expectation |
| `receipt.subject-mismatch` | Any `subject` field differs from the expectation |
| `receipt.control-mismatch` | Any `control` field differs from the expectation, the fixed policy, decision or policy-set bytes, the decision's evaluator refs, or the evaluation input's digest |
| `receipt.evaluation-not-satisfied` | The evaluation input is not a `satisfied` `sandbox_policy_evaluation` whose policy set, policy and decision refs equal the receipt's |
| `receipt.environment-unlisted` | `environment_id` is absent from the registry or the accepted set, or `environment_entry_sha256` or `target_repository_id` differs from the registry entry |
| `receipt.stale` | `accepted_set_sha256` differs from the current accepted set's digest |
| `receipt.identity-unaccepted` | An observed identity or a `mechanism_id` is not in the environment's accepted entry |
| `receipt.limit-mismatch` | A `bound` or `observer` differs from R6 |
| `receipt.outcome-inconsistent` | The recorded `outcome` differs from the R8 derivation |

   `receipt.stale` covers a receipt made under an accepted set that has since
   changed (re-qualification, a new or withdrawn digest). Receipts are never
   refreshed; a new attempt produces a new receipt.
5. **What `valid` means.** The receipt is well formed, bound to this expectation,
   made under the current accepted identities and internally consistent. It says
   nothing about origin. Only `valid` with `enforcement_verdict: "satisfied"`, plus
   an `authenticated` R2.3 origin section, can ever count as enforcement evidence,
   and only through a later consumer change (concern 6).

### R8. Outcomes

1. **`satisfied`** iff every identity is `observed`; every row has `observation:
   "complete"`, `enforcement: "hard"`, `reached: false` and `observed` at most
   `bound`; and teardown is `confirmed`. `reason_ids: ["enforcement.satisfied"]`.
2. **`violated`** iff every identity is `observed`, teardown is `confirmed`, every
   row has complete observation and hard enforcement, and at least one row has
   `reached: true`. `reason_ids` are, for exactly those rows,
   `limit.cpu-time-reached`, `limit.wall-time-reached`, `limit.memory-reached`,
   `limit.output-reached`, `limit.process-count-reached` or `limit.scratch-reached`.
   Hitting the wall bound is `violated`, not `failed`.
3. **`failed`** otherwise. `reason_ids` are those that apply from this closed list:
   `failure.launch-refused` (the supervisor refused before exec, `exit_state:
   "not-started"`); `failure.runtime` (runtime or guest error); `failure.supervisor-timeout`
   (a supervisor control step exceeded its own bounded deadline);
   `failure.teardown` (teardown not `confirmed`); `failure.observation-unavailable`
   (an identity `unobserved`, or a row `partial` or `unavailable`);
   `failure.enforcement-unavailable` (a row `none` or `unknown`). At least one
   applies whenever R8.1 and R8.2 do not.
4. A failure never becomes satisfaction, and a failed receipt is still retained.

### R9. Inactivity and exclusions

1. Nothing produces a real receipt. No runtime selection, installation, VM,
   supervisor, store, native probe, credential, network, model call, activation or
   write. The check runs only on caller-supplied bytes.
2. Byte-identical: `control/v1/**`, `config/**`, `shadow/v1/**`, `scope/v1/**`,
   `preparation/v1/**`, `evals/v1/**`, `adapters/**`, `ROADMAP.md`, `AGENTS.md`,
   `REVIEW.md`, `NORTH_STAR.md`, `.github/**`, `scripts/merge-pr.sh`,
   `scripts/codex-review.sh`, `scripts/test/run-all.sh`, `scripts/lib/*.sh`, and
   every existing test script. No gate, policy or test behaves differently.
3. Nothing enables before step 7 (#426) closes.

### R10. Files and tests

1. The plan may create exactly: `enforcement/v1/sandbox-receipt.jq`,
   `enforcement/v1/check-sandbox-receipt.sh` (mode 100755),
   `enforcement/v1/accepted-identities.json`, and
   `scripts/test/sandbox-receipt.test.sh` (mode 100755). It may change exactly:
   `docs/components.md` (a new section after `## Inactive sandbox-policy evaluator`),
   `RESTORE.md` (one restore subsection), `ci/required-files.txt` (one block after
   `# Sandbox boundary decision records`, listing the four new files and this slug's
   intent, spec and plan), and `work/enforcement-evidence-binding/plan.md`.
2. `scripts/test/sandbox-receipt.test.sh` provisions pinned jq as
   `scripts/test/shadow-slice.test.sh:24-51` does and builds every fixture inline
   from synthetic digests. It proves:
   - one positive control each for `satisfied`, `violated` and `failed`, with a
     test-only accepted set;
   - each of the 14 R7.4 reasons alone, each paired with the positive control that
     differs only in the mutated field;
   - each R8 derivation rule, including every `failure.*` reason and a receipt whose
     recorded verdict disagrees with its rows;
   - each of the six R6 rows refusing `satisfied` for `partial`, `unavailable`,
     `none`, `unknown`, `reached` and an observed value above the bound;
   - replay: a valid receipt checked against a second expectation that differs only
     in nonce-bearing `launch_request_sha256`, then only in `attempt_id`;
   - a byte-identical copy of a valid receipt yields the same check (integrity), and
     the output still says `origin_check: "not-performed"`;
   - the shipped driver against the shipped files refuses every fixture receipt with
     `receipt.identity-unaccepted`, and a temporary repository copy with the
     test-only set accepts the positive controls end to end;
   - driver error paths: wrong argument count, non-canonical, BOM, oversize, deep
     and multi-root inputs, symlinked input, and an input changed during evaluation;
   - repeat runs give byte-identical output.
3. Existing suites that must pass unchanged, not edited:
   `scripts/test/control-sandbox-policy.test.sh`, `scripts/test/shadow-slice.test.sh`,
   `scripts/test/shadow-assembler.test.sh`,
   `scripts/test/shadow-self-host-evidence.test.sh`,
   `scripts/test/scope-qualification.test.sh`,
   `scripts/test/candidate-content-preparation.test.sh` and
   `scripts/test/portable-core-schema.test.sh`. `run-all.sh` discovers the new
   suite by name (`scripts/test/run-all.sh:66-69`) and is not edited.

### R11. Order and review size

1. This concern has no dependency (`work/step8-bounded-write-readiness/spec.md:292`).
   Concern 3 (#437) consumes the R3 kind; concerns 4, 5 and 6 consume R2, R5 and R7.
   Nothing here depends on a sibling's unmerged content.
2. `review_size: standard` for this spec and for the implementation.

## Design

The receipt is one supervisor-owned document with three kinds of content: what ran
(ten byte identities), what it ran against (control, subject, attempt), and what the
trusted observers saw (six accounting rows, teardown). The consumer's expectation is
written first and holds the nonce-bearing launch request digest, so replay across
attempts or environments fails a field comparison, and the store's one-receipt-per-attempt
rule makes a second receipt for the same attempt impossible to write.

The check is deliberately pure. It proves shape, binding, acceptance and internal
consistency, and it cannot prove origin, so its output says so in a fixed field.
Origin is proved once, at the host, by reading the store under R2.3; concern 5
records that in the shadow record and concern 6 requires both. The shipped empty
accepted set keeps the check fail-closed until concern 4 adds a reviewed,
qualified environment.

## Out of scope

The verifier (#437); the launcher, supervisor, store and native qualification
(concern 4); wiring the receipt and origin section into the shadow driver (concern 5);
the `scope-gates.jq` change and `scope.sandbox-receipt-missing` (concern 6); any
change to the ceiling, the demonstration policy, the registry or step 7.

## Areas of concern

- **Origin is only as strong as the host.** R2.5 states the residual and routes the
  one question to concern 4's existing reserved decision. Review should confirm no
  wording presents a digest match or a valid check as origin proof.
- **Content-level forgery.** A caller who controls both the expectation and the
  receipt can make them match; R7.5 is why `valid` alone never counts.
- **Scratch bound.** The policy has no scratch value. R5.2 makes it a per-environment
  accepted value fixed with concern 4's review, not a new policy limit.
- **Mechanism honesty.** R6 marks rate limits, polls and overshoot as `enforcement:
  "none"`, matching the blockers the sandbox decision records at
  `work/real-sandbox-boundary/spec.md:126-132`.
- **Supervisor split.** R3.6 splits "supervisor" and "guest kernel/configuration"
  into two slots each; merging them later would be a contract version change.

Intent open questions, answered: origin without a credential (R2, residual in R2.5);
replay binding (R3.3, R4, R7.4 `receipt.replayed`, R2.3 one receipt per attempt);
placement and telling kinds apart (R1); accounting per limit (R6); "not yet available"
(R5.3-R5.4); native qualification (R5.5).
