---
intent-blob: 633ac30af807896e3550f9bf0eb098278213fc59
risk: high
drafted: 2026-10-14
---

# Spec: Publish the bounded macOS scope proof workflow

## Requirements

1. Publish the manual workflow for #541 without changing the product or its
   acceptance standard. Implementation changes only `.github/workflows/scope-genuine-macos.yml`
   and its entry in `ci/required-files.txt`. Preserve the meaning of the package
   [approved on 2026-10-14](https://github.com/yihanzhu/ystack/issues/541#issuecomment-6167260870):

   | Approved baseline artifact | SHA-256 |
   |---|---|
   | Decision | `1620fef70105e8b3a82fd4f906b8855d5cbe0026cfbfd994931ca50f48098fed` |
   | Workflow | `4135bf0a37fffb672e02ffeb436cd5dc5d5c7f02dd49aa1c2ef0a9074ea5cd4c` |
   | Two-path patch | `880fa41e85a8387280354c34a70a93a75604d2ac5030063c479d14263b903e2c` |

   The separately accepted plan pins the workflow bytes with the existing-runtime
   selector below. Preserve the baseline's remaining behavior and authority.

2. Keep dispatch closed to `yihanzhu/ystack`, repository ID `1270665750`, the manual
   event, actor and triggering actor `yihanzhu`, and
   `refs/heads/ystack/impl/scope-gate-hardening`. Keep the exact workflow path/ref,
   read-only contents permission, pinned checkout action, disabled persisted
   credentials, serial concurrency and no cancellation of another run. Expose no
   inputs for source, path, command, provider or credentials.

3. Select source from immutable `github.sha`. Before and after execution, require
   lowercase 40-hex source, event and workflow SHAs to agree with checkout HEAD;
   verify the checked-out workflow against its Git blob and require clean source.
   Preserve the approved minimum ancestry check. The manager separately binds the
   reviewed head H, then-current base X, artifact hashes and workflow blob to the
   actual run API, ref and checkout. A matching SHA or permitted actor is not approval.

4. Keep `macos-15-intel` as the unverified candidate host. Before fixture mutation,
   require the approved GitHub-hosted, Darwin and x86_64 guards, fixed physical
   tools, existing noninteractive sudo and absent fixture paths. Preserve physical
   Python 3.11+, loaded runtime/module and stdlib/include ancestor checks. Select
   Python in the unchanged native suite's order: executable
   `/opt/homebrew/bin/python3.14`, then `/usr/local/bin/python3.14`, then
   `python3.14` or `python3` on the fixed PATH. Resolve its physical path and report
   its actual version before checking the minimum. Before executing that candidate,
   use fixed system Python for a bounded read-only check of its physical installation
   and required load paths, using actual Darwin ACL and held identity checks. This
   private fixture boundary accepts only a closed, immutable installation layout;
   unknown layouts fail. Repeat it immediately before the first privileged Python
   execution. Candidate self-report and later root checks cannot supply this prior
   trust. Preserve the later complete runtime/module checks. A candidate that fails
   any check stops; do not try another runtime. The scope outer evaluator and
   privileged fixture must bind that same physical Python. The original harness still
   verifies its root-owned copied package; repository modules are not claimed to
   be root-owned in checkout. A missing tool, SDK or safe runtime closure fails.

5. Use only the existing physical `/usr/local/bin/jq`, with version `jq-1.6`,
   single-link ownership checks and SHA-256
   `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`.
   Fill the native suite's expected cache only inside a new job-owned temporary
   directory, verify copied bytes, and preserve identity-checked cache cleanup.
   No downloading, installation, runtime ownership repair or fallback is allowed.

6. Keep the original fixture's distinct writer and consumer, supplementary-only
   shared group membership, actual UUID/ACL checks, store, Git and evidence APIs.
   Derive TOKEN from H's first eight characters; use only `yscw_TOKEN`,
   `yscc_TOKEN`, `yscg_TOKEN`, `yscp_TOKEN`, the owned root
   `/usr/local/libexec/ystack-scope-fixture.TOKEN` and absent fixed anchor
   `/usr/local/libexec/ystack-sandbox/v1/supervisor`. Preserve original unused-ID
   selection within 56000–56999, absence checks, account transition journal,
   original missing-ancestor handling and verified reverse cleanup. Never replace
   an existing anchor. Cache cleanup cannot replace root fixture cleanup.

7. Run both complete original commands at H, in order:

   ```text
   /bin/bash scripts/test/scope-qualification.test.sh
   /bin/bash scripts/test/shadow-enforced.test.sh
   ```

   Keep the 100-minute job cap and approved step limits: checkout 5, preflight 5,
   scope 35, native 50, final source/cache closure 5 minutes. These are scheduling
   reservations, not measured completion guarantees. Preserve every assertion,
   product deadline, cancellation/reap rule and byte/row cap. Timeout, interruption,
   refusal, suite failure or incomplete cleanup gives no successful proof.

8. Accept workflow publication only after exact-base patch/manifest validation,
   workflow and embedded shell/Python static checks, required repository CI and
   independent review. Actual Mac proof is a later host execution at a freshly
   reviewed H/X. Read its complete results and cleanup evidence together with the
   exact-head complete Linux matrix before #541 G3. Publication does not close
   #541 or establish native/CPU-wall qualification; production identities stay empty.

## Design

| File | Responsibility |
|---|---|
| `.github/workflows/scope-genuine-macos.yml` | Publish the approved fixed manual workflow and its existing guards, suite steps and closure. |
| `ci/required-files.txt` | Add the workflow to the restore-critical manifest. |

For the implementation PR: `review_size: standard`.

The separately reviewed high-risk plan precedes implementation and pins the
workflow bytes. Preserve the approved baseline except for the fixed selector,
its version output and the prior trusted runtime check. Recheck patch context
against the actual publication base.
A further change to workflow meaning or permissions requires fresh artifact review.

Publish the stable workflow through its protected PR, producing main X. Normally
merge X into the same #541 implementation branch to produce H. Independently review
H/X, artifact hashes and the matching workflow blob, then freeze the branch for
Linux and Mac runs. The manager checks those bindings before and after dispatch.
Merge #541 through its protected PR only while the reviewed H and X still match.
Source SHA changes do not require publishing another literal into the workflow.
A changed main, source or workflow invalidates affected review and proof.

The job stays a repository-specific development fixture. It adds no portable-core
API, product debug path, live profile or general privileged execution service.

## Out of scope

This publication changes no product or test file. The scope fixture's matching
runtime selection and existing Darwin resolver wiring are repaired only under
#541's existing accepted plan and paths; they change no assertion or proof standard. No reduced controls, arbitrary dispatch
ref, alternative provider, runtime/tool installation, host repair, VM, real publisher, production
identity, real target or new credential scope. No #544 ref or sudoers execution is
inherited: that work still needs its own accepted gates and explicit reviewed
closed-ref/authority binding. This publication does not perform that future action.

## Areas of concern

Risk is high because this adds a workflow that can reach the separately approved
administrator fixture. The normal artifact chain, separate authors and reviewers,
required CI, rounds cap and protected publishing remain in force. The approval is
limited to this repository and manager; it does not authorize clones or live yshifu.

The intent's open provider and result questions remain evidence to obtain. Actual
label availability, physical runtime, exact jq, SDK, account lifecycle and complete
Mac results are unverified until the approved job runs. A failed prerequisite stays
a failure. The fixed native time cap has no measured completion guarantee; an
interruption cannot be reported as completed cleanup or positive qualification.

The host-specific job does not change the vendor-neutral core or its acceptance
standard. No conflict with the accepted intent or north star is identified.
