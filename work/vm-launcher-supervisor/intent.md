# Intent: VM launcher and supervisor for the real sandbox receipt
Author: Claude (yshifu, intent author at the operator's direction). Status: draft.

## Problem

Step-8 R7 makes a real sandbox receipt mandatory before any write scope is
proposable, and requires the environment's registry entry to record native
qualification from this concern (`work/step8-bounded-write-readiness/spec.md:267-281`,
`:278-279`). The boundary map still reads "Declaration only, `unproven`" for the
execution-boundary row (`spec.md:341`). The receipt kind and the verifier now exist,
but nothing today can produce a real receipt:

- The receipt check validates caller-supplied bytes only and always reports
  `origin_check: "not-performed"` (`enforcement/v1/sandbox-receipt.jq:554`;
  `work/enforcement-evidence-binding/spec.md:304-306`). Its accepted identity set
  ships with `environments: []` (`enforcement/v1/accepted-identities.json:1`), so no
  receipt can be `valid` (`work/enforcement-evidence-binding/spec.md:178-183`).
- No supervisor store exists. Its rules (fixed root, supervisor-principal ownership,
  `0750`/`0440` modes, exclusive `receipt.json`, descriptor-relative consumer read)
  are "implemented by concern 4" (`work/enforcement-evidence-binding/spec.md:56-79`),
  and no supervisor host account exists to own it (`:84-93`).
- No component observes the ten identity slots, the lifecycle and teardown fields,
  or the six limit rows the receipt records (`spec.md:120-150`, `:206-221`).
- The verifier is built only with the host compiler
  (`verifiers/file-digest/v1/build.sh:32`) and tested under a temporary root
  without mounts. Its spec leaves the real
  `/sandbox` paths, read-only and write-only mounts, the fixed limits, containment
  and guest-toolchain identity to this concern
  (`work/fixed-file-digest-verifier/spec.md:236-242`, `:38-44`).
- Nothing supplies what the verifier expects from a launcher: the instruction as a
  regular file on fd 0, the exact argv and four variables, and a fresh evidence
  directory (`work/fixed-file-digest-verifier/spec.md:58-78`, `:145-148`;
  `verifiers/file-digest/v1/verifier.c:675-678`).
- The #396 bundle is not frozen or supervised: its record says `immutable: false`,
  `authenticated_receipt: false`, `supervisor_handoff: "required"`
  (`preparation/v1/prepare-candidate.py:1928-1929`). The verifier relies on this
  concern for immutable input (`work/fixed-file-digest-verifier/spec.md:139-141`).
- The policy's verifier digest is still the all-ones demonstration value
  (`control/v1/sandbox.jq:179-182`), and all three registry entries are
  `proof_state: "unproven"` (`shadow/v1/shadow-environments.json:1`).
- No runtime, release, kernel or image is selected
  (`work/real-sandbox-boundary/spec.md:86-90`). The CPU, wall-time, memory, output
  and write-only-evidence rows are still blocking, and task control and cleanup
  still lack proof (`spec.md:104-124`). Local research found no VM CLI on the host
  (`spec.md:191-193`).

The sandbox decision names this as its third child concern: "resolve all remaining
mechanism blockers, pin the release/kernel/image, implement the table's limits and
lifecycle with full tests" (`work/real-sandbox-boundary/spec.md:160-161`), under the
unchanged ceiling (`spec.md:20-27`). Step-8 R8 lists it as child concern 4, after
concerns 2 and 3, with installation and native qualification reserved
(`work/step8-bounded-write-readiness/spec.md:294`). Concerns 5 and 7 depend on it
directly (`spec.md:295`, `:297`).

## Proposed outcome

One inactive VM launcher and host supervisor, with a guest supervisor, that is the
only producer of `sandbox_enforcement_receipt`. Nothing runs it outside tests until
the reserved decisions below are answered. For one attempt it:

- **Refuses before launch unless every byte matches.** It digest-checks the pinned
  host runtime, guest kernel and configuration, guest init, image, both supervisors,
  the verifier executable built with the guest toolchain, the toolchain and the
  instruction against the environment's accepted set
  (`work/enforcement-evidence-binding/spec.md:120-128`, `:169-183`). A missing,
  changed, placeholder or unsupported identity refuses launch
  (`work/real-sandbox-boundary/spec.md:45-52`). Image acquisition is never part of
  an attempt (`spec.md:99-100`).
- **Freezes the candidate.** It checks the #396 bundle's `candidate/` tree against
  its `manifest.json` and the record's `manifest_sha256`
  (`preparation/v1/prepare-candidate.py:2167-2184`, `:1925`) and exposes it read-only
  at `/sandbox/candidate`. Tools are read-only at `/sandbox/tools`, scratch is
  bounded read-write and evidence is write-only
  (`control/v1/sandbox-policy.json:1`). The source Git directory, checkout and
  bundle metadata never enter the guest.
- **Boots one disposable offline guest** with no network device, no
  candidate-accessible host share and no verifier-reachable supervisor endpoint
  (`work/real-sandbox-boundary/spec.md:94-100`, `:108-109`).
- **Runs the fixed verifier** as the policy states: exact argv, only the four
  variables, ambient descriptors closed, and the bound instruction bytes opened as
  a regular file on fd 0 (`work/fixed-file-digest-verifier/spec.md:58-78`). It
  records the exit status (0, 64 or 73) and binds stdout, stderr and the evidence
  payload by digest only (`spec.md:165-169`, `:183-189`).
- **Enforces and observes the six limits** with the observers the R6 table names
  (`work/enforcement-evidence-binding/spec.md:206-221`), recording bound, observed
  value, resolution, observation and enforcement. Where a mechanism can exceed a
  bound at any instant, it records `enforcement: "none"`. A limit is never raised,
  and an unknown or partial value is never recorded as a pass.
- **Tears down with confirmation.** It terminates the whole verifier tree and
  destroys only the named attempt's VM and storage. Only then does it write the
  final receipt, with its lifecycle, teardown and timing fields, into the
  supervisor store under the R2.3 rules (`spec.md:56-79`, `:137-153`).
- **Keeps a failure receipt** for refusal, runtime error, supervisor timeout,
  unconfirmed teardown and unavailable observation. A failure never becomes
  satisfaction (`spec.md:283-300`).

The G2 spec must, for every row of the boundary map, name the mechanism, its
observed evidence, its observation limits and its trusted producer
(`work/real-sandbox-boundary/spec.md:63-66`), or record the row as still blocked.
It must also name the exact runtime, kernel, image and tool bytes, host changes,
acquisition endpoints, offline configuration, synthetic probes, cleanup and rollback
that the installation request will carry (`spec.md:203-209`).

Success means synthetic and dry-run tests prove the contract without a hypervisor:
a fake runtime behind the launcher's one runtime interface, a fixture store in a
temporary directory owned by the test account, and a test-only accepted set. They
cover each refusal before launch (changed, missing and placeholder bytes; manifest
mismatch; a store, attempt or nonce collision), exact argv, environment and fd 0
wiring, each limit row's `hard`, `none`, `unknown`, `partial` and `unavailable`
recording, success, violation, refusal, deadline, cancellation, runtime error and
teardown failure. Against the merged receipt check with the test-only set, two
expectations are stated separately:

- A failure receipt whose observed identities are all in the test-only set, with
  a missing dependency recorded `unobserved` and the failure recorded in its
  lifecycle, teardown or limit rows, yields `check_verdict: "valid"` with
  `enforcement_verdict: "failed"` and the matching `failure.*` reasons, as does
  every success, violation and failure receipt built from accepted identities.
- A receipt that records an observed digest outside the test-only set yields
  `receipt.identity-unaccepted`, and one that records a placeholder digest yields
  `receipt.placeholder-identity` (`enforcement/v1/sandbox-receipt.jq:205-206`,
  `:502-510`). Neither is ever `valid`, whatever its lifecycle records.

Every receipt produced is refused by the shipped check, whose accepted set is
empty. Each denial has a paired positive control. Tests and docs state that this proves contracts, not the Apple
VM boundary (`work/real-sandbox-boundary/spec.md:68-74`). Restore-manifest entries
cover the new paths, and every existing gate, policy and test behaves as before.

## Affected users and systems

The operator, who reviews each gate and owns the three reserved decisions. The
operator's Apple silicon host, which is touched only after those decisions. The
receipt contract and check in `enforcement/v1` and the verifier in
`verifiers/file-digest/v1`, read and not changed. The #396 preparation bundle, read
as input. The sandbox policy and decision and the environment registry, read and not
changed here. The later shadow-consumer integration (5), scope-gate hardening
(6) and kill-switch register bootstrap (7), which consume the receipt and the
qualification. CI,
which runs the new tests on Linux runners without nested virtualization.

## Constraints

- Risk: high. This is the security, containment and receipt-origin boundary. G1
  intent, then G2 spec, then an operator-merged high-risk plan come before any
  code, each with independent review and required CI. Tracks #463.
- Depends on concerns 2 (#436) and 3 (#437), both closed. Step 7 (#426) is closed.
- Reserved decisions per step-8 R8 row 4 and RC-1 items 2 and 4
  (`work/roadmap-program-authorization/decision.md:314-326`). Each is its own
  decision request, asked only when its reviewed package exists, and nothing
  enables before every one is answered:
  1. installing the hypervisor runtime and guest toolchain on the operator's
     machine, including any acquisition endpoint;
  2. native qualification of the named environment, its accepted-set entry, and
     its registry `proof_state` change from `unproven`;
  3. creating the dedicated supervisor host account and accepting it, with the
     host administrator, as the receipt-origin trust root, or authorizing a
     signing credential instead (`work/enforcement-evidence-binding/spec.md:84-93`).
- Ships inactive: no installation, acquisition, VM boot, native probe, credential,
  network, host-account creation, model call, target execution, activation or
  write. Tests use only synthetic secrets and sentinels.
- Byte-identical unless the G2 spec names one exact, reviewed change: `config/**`,
  `control/v1/**` (including the all-ones tool digest), `enforcement/v1/**` (the
  accepted set stays `environments: []`), `verifiers/file-digest/v1/**`,
  `preparation/v1/**`, `shadow/v1/**` (registry included), `scope/v1/**` and the
  RC-1 item 3 constitution paths.
- The ceiling of `work/real-sandbox-boundary/spec.md:20-27` is unchanged. A row
  that cannot hold records `enforcement: "none"` and stays blocked; any weaker
  acceptance standard returns to the operator (`spec.md:118-124`).
- The environment inherits no qualification from any existing registry entry
  (`work/real-sandbox-boundary/spec.md:68-72`). A runtime, kernel, image, verifier,
  policy or instruction change invalidates the affected evidence.
- A digest detects changed bytes; it does not authenticate the producer. Receipt
  origin rests on the store rules and the trust root, never on content.
- Core records stay model-, harness- and provider-neutral. The runtime sits behind
  one launcher interface, and no runtime name becomes a core contract.
- Non-goals: wiring the receipt into the shadow driver and replacing
  `tool.git-blob-digest` (concern 5); the `scope-gates.jq` change and
  `scope.sandbox-receipt-missing` (concern 6); replacing the policy's tool digest;
  any change to the receipt kind, the verifier or the preparation bundle format; a
  generic orchestrator or candidate-code runner; and any real self-host or
  write-shadow run.

## Open questions

- Which runtime release, kernel and image are named, and how are their digests
  pinned in the spec before the reserved installation lets anyone acquire the bytes?
- Which mechanism, if any, enforces each blocking row as a hard bound (aggregate
  CPU, wall deadline with teardown, memory with overshoot, combined output, scratch,
  write-only evidence)? Which rows stay `enforcement: "none"`, and is qualification
  then still possible?
- How is the frozen candidate exposed read-only (a copied image or block device, or
  a read-only share) so that no host path or later mutation reaches the guest?
- How does the guest supervisor return observations to the host without a channel
  the verifier can reach or forge, and which observations are only host-side?
- Where does the component live, in which language, and how is its own identity
  built and bound as `host_supervisor` and `guest_supervisor`?
- Which environment is qualified first: a new registry entry for the exact
  host/guest/runtime combination, or one of the existing `env.local-macos-*` entries?
  How is its `scratch_bytes` value chosen?
- How do fixture-store tests stand in for the supervisor principal without
  weakening the R2.3 ownership checks, and what stays honestly unproven until
  native qualification?
- What exactly does each of the three decision requests carry, and in what order
  are they asked?
