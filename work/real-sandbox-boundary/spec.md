---
intent-blob: e344e7d1fead76bc5f238d9796e279fd5816297f
risk: high
drafted: 2026-09-13
---

# Spec: real sandbox boundary decision

Tracks #287. This is a decision-only artifact. It ships no runtime or policy change.
The accepted intent was read at main `3f57aad58aed6424b07788c7f61403eae0c232a8`.

## Requirements

1. **Record an honest feasibility decision.** No available runtime has been shown
   to meet the whole existing ceiling. The decision is **blocked for real execution**,
   with a disposable Linux VM on the local Apple silicon host as the first design
   candidate. A runtime name, CLI option or satisfied declaration cannot unblock it.
   Each blocker below needs separately accepted implementation and evidence.

2. **Preserve the exact ceiling.** The verifier environment remains exactly LANG=C,
   LC_ALL=C, PATH=/sandbox/tools and TMPDIR=/sandbox/scratch, with no inherited
   image or caller variables. Candidate and tools are read-only; scratch is
   read-write; evidence is write-only from the verifier's side. Network is denied,
   there are no credential/secret references, and the verifier cannot access source
   history, host data or unrelated work. The fixed limits remain CPU 30,000 ms,
   wall time 60,000 ms, memory 536,870,912 bytes, output 10,485,760 bytes and 32 tasks.
   Values must not be increased or silently given weaker meanings.

3. **Separate preparation from verification.** A trusted preparation process reads
   only the scrubbed source repository and accepted input/dependency closure. It
   materializes and hashes a disposable candidate without executing candidate code.
   Materialization finishes before verification; the frozen candidate becomes
   read-only before the verifier starts. The verifier receives candidate content,
   not the source Git directory, original checkout or preparation credentials.
   Trusted instructions and expected answers are outside candidate control.

4. **Use one fixed verifier.** The first implementation concern is the file-digest
   incident check already consumed by the shadow slice. Candidate files are data,
   never executable instructions. Preserve the fixed tool path and argument shape:
   `/sandbox/tools/verifier verify --candidate /sandbox/candidate --evidence
   /sandbox/evidence`. The trusted instruction identity selects the expected check;
   candidate content cannot select a command, expected digest or authority. This
   narrow verifier still needs containment against a compromised process.

5. **Bind real bytes and evidence origin.** Before any qualified run, accepted
   records must name actual host/runtime, guest kernel/configuration, guest init,
   image, supervisor, verifier, toolchain and verification-instruction identities.
   Bind policy, decision, evaluator, policy-set, source/candidate, incident,
   environment and attempt identities too. Version names and mutable image tags
   are insufficient. Verify content digests against the accepted set before use;
   a missing, changed or unsupported dependency refuses launch.
   The all-ones verifier digest is demonstration data and cannot be a real identity.

6. **Keep evidence outside verifier control.** The host supervisor owns the durable
   receipt and binds it to the exact attempt and input/output bytes. Candidate
   output is untrusted payload, not its own enforcement receipt. A digest detects
   changed bytes; it does not authenticate their producer. Later design must bind
   receipts to the trusted supervisor's controlled channel and storage, reject
   forged/replayed/mismatched input and state how a consumer authenticates that
   origin. Do not substitute a caller's matching JSON claim. No signing credential
   is selected or authorized by this decision.

7. **Prove every row of the boundary map.** For each row, later design names the
   mechanism, observed evidence, observation limits and trusted producer. Unknown,
   unavailable, exceeded or unverified enforcement blocks a qualified result.
   Runtime failures retain a bounded failure receipt and never become satisfaction.

8. **Require separate proof for each environment.** Linux CI can prove contracts
   and synthetic behavior; it does not prove the local Apple VM boundary. Register
   the exact host/guest/runtime combination without inheriting qualification from
   either existing local-macOS registry entry. A runtime, kernel, image, verifier,
   policy or instruction change invalidates the affected evidence. Repeating a
   deterministic check must preserve outcome/input identities; attempt times and
   resource measurements may differ and must be recorded honestly.

## Design

### Current contract and selected direction

`control/v1/sandbox-policy.json` and `sandbox.jq:policy_ok` fix the demonstration
policy. `evaluate-sandbox.sh` binds caller documents and emits declaration-only
results with no authority or qualification. `shadow/v1/reproduce.sh` checks that
result, then directly materializes the candidate. It does not establish a real
verifier boundary. These files remain unchanged by this initiative.

Prefer an existing VM runtime over a new hypervisor. Apple Containerization is the
first candidate for the local Apple silicon host: its documented per-container VM
and supervisor transport provide useful primitives. No release, binary digest,
kernel or image is selected yet; this is an explicit provenance blocker, not a
placeholder selection. Its CLI resource flags do not close the blockers below.
[Containerization design](https://github.com/apple/containerization#design),
[CLI reference](https://github.com/apple/container/blob/main/docs/command-reference.md).

The proposed split is preparation → frozen candidate → offline VM verification →
teardown confirmation → final host-owned receipt → consumer validation. The host starts
one disposable VM with no candidate-accessible host shares, control sockets or
network device. A trusted guest supervisor remains outside the verifier task tree.
It configures limits and restrictions before launching the fixed verifier, and the
verifier cannot alter them or signal the supervisor. Image acquisition is separate
from an attempt; no implicit pull, registry login or forwarded SSH agent is allowed.

### Claim-to-enforcement map

| Claim | Required mechanism and trusted evidence | Current decision |
| --- | --- | --- |
| Candidate-only reads and immutable source | Preparation receipt binds source commit and frozen candidate digest; VM receives only candidate/tools; read-only mounts plus guest access controls; host owns the receipt. | Needs implementation and source/candidate mutation probes. |
| Cleared environment and fixed verifier | Supervisor closes ambient descriptors, supplies only the four exact variables and fixed argv, checks executable/tool/instruction bytes, records the actual launch identity. | No pinned real verifier or launcher exists. |
| No host or sibling access | VM boundary with no host shares or verifier-accessible supervisor endpoints; restricted guest process identity; synthetic host/sibling sentinels remain inaccessible. | VM release and transport restrictions unproven. |
| Network denied | No NIC plus guest syscall/socket restrictions; deny IPv4, IPv6, raw/packet, Unix and vsock escape routes and inherited sockets. Supervisor transport stays inaccessible to verifier. | Network-none alone is insufficient; denied-access probes required. |
| CPU at most 30,000 ms | Bound total verifier-tree CPU, including children/threads, rather than one process or a rate. Trusted accounting and termination must justify the ceiling. | Blocking: no accepted aggregate-budget mechanism. |
| Wall at most 60,000 ms | Host-controlled monotonic deadline from launch admission through verifier-tree termination; timeout cannot depend on the verifier. Record deadline, observed termination and teardown failure. | Blocking: timing and teardown guarantees unproven. |
| Memory at most 536,870,912 bytes | Bound verifier-tree memory with stated charging semantics, including descendants/shared allocations; separately bound trusted runtime overhead and prevent escape from the group. | Blocking: accounting/overshoot contract unresolved. |
| At most 32 tasks | Kernel task-tree control before launch, counting processes and threads; prevent migration or delegation by verifier; supervisor records configured bound and exhaustion. | Requires pinned guest controllers and adversarial proof. |
| Output at most 10,485,760 bytes | Combined stdout/stderr/evidence accounting under trusted control; do not accept excess payload. Separate bounded control metadata; scratch has a separately stated finite storage bound. | Blocking: no accepted combined-output mechanism or scratch bound. |
| Write-only evidence | Guest policy permits intended writes but denies listing/reads/read-after-create and alternate descriptor/link paths; export payload to supervisor-owned durable storage. | Blocking: an ordinary writable directory does not enforce this. |
| Complete cleanup | Host can terminate the whole verifier tree and destroy only the named attempt VM/storage, retaining durable receipt outside it; success requires confirmed termination. | Requires success, refusal, timeout, cancellation and crash tests. |

These rows define the required strength, not claims of hard real-time enforcement.
The limit scope includes all verifier descendants and threads, not the trusted
host/guest supervisors. Those supervisors are part of the explicitly trusted
runtime boundary; their resource/storage bounds and residual host exposure must be
accepted before qualification. Their exclusion is not permission for unbounded
resource use. If that split cannot preserve the current ceiling, the run remains
blocked and any weaker acceptance standard returns to the operator.

Linux cgroup v2 is a candidate for task-tree controls. Its cpu.max is a bandwidth
rate, not accumulated CPU time; memory.max documents temporary overshoot. A usage
poll followed by a kill does not prove a strict aggregate ceiling. Per-process
ulimits and per-file file-size limits are likewise insufficient for the CPU and
combined-output rows. Do not rename those mechanisms as proof of stronger claims.
[Kernel cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html),
[container ulimits](https://github.com/apple/container/blob/main/docs/ulimits.md).

Landlock's separate read/write/create rights are a candidate for evidence access,
with all required rights enforced by the pinned guest. Missing features must refuse,
never degrade. Seccomp can restrict syscall classes but does not replace pathname
policy. Later design must cover inherited descriptors and create/read, rename/link,
truncate and supervisor-channel paths before claiming write-only behavior.
[Landlock](https://docs.kernel.org/userspace-api/landlock.html),
[seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html).

### Proof and separately gated work

Later denied-access tests use only synthetic secrets, sibling/host sentinels and
bounded malicious fixtures. Cover source/candidate modification, forbidden roots,
all relevant socket families, environment/descriptor leakage, child escape,
resource exhaustion, output overflow, evidence reads and forged receipts. Exercise
normal completion, refusal, cancellation, deadline and supervisor/VM failure.
Expected denials need a positive fixture control; a missed window, unavailable
mechanism or absent output cannot count as a pass. Record exact platform/tool bytes
and limits of observation. No actual secret or unrelated host data is probe material.

Implement through distinct accepted concerns, with dependencies recorded explicitly:

1. Real policy and enforcement-evidence binding: define authentic receipt provenance,
   exact byte identities and consumer checks; preserve old declaration-only records
   as such. This must resolve accounting semantics before selecting a runtime.
2. Fixed file-digest verifier: bounded deterministic data processing and trusted
   instructions with real tool identity and mismatch/no-change tests.
3. VM launcher and supervisor: resolve all remaining mechanism blockers, pin the
   release/kernel/image, implement the table's limits and lifecycle with full tests.
4. Shadow consumer integration: use the real receipt and accepted policy/evaluator
   bindings, retain evaluator bytes and preserve source/incident identities. It
   depends on the previous concerns plus accepted trusted-parent resolver and
   input-assembler implementations. It does not absorb their source preparation.

Each concern needs its own intake/artifact/plan gates, exact paths, tests and restore
manifest entries. This spec approves no child code, current policy replacement or
live run. Contract/unit tests can land before native qualification. Documentation
must distinguish simulated proof, native synthetic qualification and real workflow
proof. New consumer behavior cannot reinterpret old declaration-only satisfaction.

## Out of scope

Runtime installation, starting services/VMs, capability probes, execution, network
acquisition, credentials, host configuration, profile selection or activation.
No model, candidate-code runner, generic orchestrator, publisher, target writes,
deployment or production action. No demonstration-policy mutation or new exception
to limits, duties or evidence requirements. No self-host run or workflow qualification
is performed here, and no default adapter is selected by a core contract.

## Areas of concern

Risk is high because this decision defines a security and identity boundary.
The current demonstration policy and available documentation do not establish an
implementable, fully proven ceiling. Aggregate CPU, memory overshoot, deadline
termination, combined output, scratch capacity, write-only evidence and authenticated
receipt provenance remain explicit blockers. This is an allowed blocked feasibility
outcome under the intent, not a weaker policy or an unrecorded workaround.

Local research observed Darwin/arm64 and no queried VM CLI on PATH, not a full
installation inventory. It performed no runtime probe. Current CI uses Linux
runners; do not assume nested virtualization or infer native Mac proof from CI.
An immutable runtime release, its host prerequisites and guest kernel features must
be inspected in the child design; moving-main documentation is research only.

All intent questions are addressed: the VM is the first candidate but is not yet
feasible under the complete ceiling; the process split defines who may access
source/candidate/evidence; real identities and controlled receipt origin replace
caller declarations; four child concerns and the input prerequisites precede use.

The operator-led program may advance in-scope repository artifact and review gates.
It still reserves installation/activation, new network scope and first real target
execution. Present a reviewed package naming exact runtime/kernel/image/tool bytes,
host changes, acquisition endpoints, offline configuration, synthetic probes,
cleanup/rollback and environment identity before requesting installation and native
qualification. Request the first real self-host execution only with the complete
accepted source/incident tuple and proven prerequisites. This artifact requests
neither permission now and grants neither action.
