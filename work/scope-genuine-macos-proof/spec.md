---
intent-blob: 7b38be231a975a16133d16a987539ac1061352da
risk: high
drafted: 2026-10-15
---

# Spec: Provide the bounded macOS scope proof environment

## Requirements

1. Provide the manual proof environment for #541 under the
   [directly approved conditional supply](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6180555883)
   and [existing-parent supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6189713897).
   Preserve the product and its acceptance standard. This implementation changes
   only `.github/workflows/scope-genuine-macos.yml` and its entry in
   `ci/required-files.txt`. The separately accepted high-risk plan pins the exact
   workflow, manifest, commands and cleanup before implementation.

   | Fixed source | Accepted SHA-256 |
   | --- | --- |
   | Conditional decision | `7206ddb285720163917b4f0c7a710ec278b9b1992f88436cff9fbda18404d4bd` |
   | Existing-parent supplement | `d811e67bf53b8bcbd0417d5db686c297adbe325c47de3ab048d92bdfeead4880` |
   | Python 3.14.7 official macOS pkg | `70c5239ad2d62925d2947e46921d0ddd3d35be3d2f0a2d50db33da507dbcb419` |
   | Original jq 1.6 Mac artifact | `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef` |

2. Keep dispatch closed to `yihanzhu/ystack`, repository ID `1270665750`, the manual
   event, actor and triggering actor `yihanzhu`, and
   `refs/heads/ystack/impl/scope-gate-hardening`. Keep the fixed workflow path/ref,
   read-only contents permission, pinned checkout action, disabled persisted
   credentials, serial concurrency and no cancellation of another run. Expose no
   inputs for source, path, command, provider or credentials.

3. Select source from immutable `github.sha`. Before and after execution, require
   lowercase 40-hex source, event and workflow SHAs to agree with checkout HEAD.
   Verify the checked-out workflow against its Git blob and require clean source.
   Preserve the approved minimum ancestry check. The manager separately binds the
   reviewed head H, current base X, artifacts and workflow blob to the actual run
   API, ref and checkout. A matching SHA or permitted actor is not approval.

4. Keep `macos-15-intel` as the candidate host. Before any mutation, require the
   approved GitHub-hosted, Darwin and x86_64 guards, fixed physical tools, existing
   noninteractive sudo and absent fixture paths. Use only the fixed official
   Python 3.14.7 and jq 1.6 bytes above. No version, source, runtime or provider
   fallback is allowed. No other dependency download or installation is allowed.

   Take only the standard Python_Framework payload. Preserve every supplied byte
   and publisher link. Do not run any package script or installer. Exclude the GUI,
   CLI, documentation, pip, profile and free-threaded components. Verify the source
   chain, complete signed content manifest and fixed hashes before supply. The
   accepted source evidence combines the official release digest, XAR signature
   and content hashes, PSF installer identity and offline OS basic trust chain.
   Do not call the recorded pkgSign EKU rejection a pass. Basic trust does not
   prove installer-policy, online revocation, Sigstore or notarization acceptance.

   Supply only two entirely absent trees under the existing physical root
   `/Library/Frameworks/Python.framework`: `Versions/3.14` and
   `ystack-private-tools`. Authenticate that root, its physical Versions directory
   and every physical ancestor with held NOFOLLOW descriptors, exact named identity,
   UID 0, non-group/other-writable modes and actual empty ACLs. Unknown ACLs fail.
   Do not create, chmod, chown or repair an existing parent. Require both targets
   absent before supply and each absent again before its root is created. Any
   existing object, including a dangling link, fails. After creation, authenticate
   its recorded owned identity before each write.

   Verify the full 4,201-entry source manifest first. Supply only its 4,195 entries
   at `Versions/3.14` or below, plus the private tools directory and jq: exactly
   4,197 entries. Preserve their bytes and link text. Scan these two new trees for
   an exact set match; do not ignore extras or admit old siblings to the runtime.
   The high-risk plan fixes the source subset, mode map and runtime expectation
   table. Keep old versions, top-level Current and root aliases unchanged.
   Do not traverse old version contents or use those old objects as dependencies.

   Read only bounded direct child names and lstat/link metadata of the existing
   parents to bind their original sets. Before every command, recheck the held
   parents and recorded sets. Only direct mkdir/rmdir of a fixed new root may change
   its parent's child set and size, nlink, mtime_ns or ctime_ns. Require the exact
   child delta and unchanged dev/ino/type/uid/gid/mode/actual ACL before recording
   the new set and actual fields. Failed or unknown actions cannot justify
   rebinding. Other ancestors remain unchanged. Never backdate metadata. These checks share
   the original object, depth, output and deadline limits.

   Use only the accepted manifest and bounded mkdir/cp/chmod/rm commands for new
   owned objects. Do not use chown, a privileged shell, a package manager, scripts,
   compilation, binary rewriting or relinking. Check copied bytes against the
   accepted source before execution. Root ownership alone is not provenance.

5. Bind P to the fixed inner image
   `/Library/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python`.
   Bind its runtime prefix separately to
   `/Library/Frameworks/Python.framework/Versions/3.14`.
   This fixed mapping replaces the old bin/name-derived prefix only at the private
   fixture boundary. It adds no arbitrary path input or runtime selection service.

   The existing fixed system Python remains the initial non-privileged trusted
   reader. Before executing P, authenticate the supplied physical installation,
   outer image, inner image, shared Python library and every required load target.
   Candidate self-report, a new root owner and later privileged checks cannot
   establish this prior trust. Do not add a circular requirement for the initial
   trusted reader to authenticate itself before its first non-privileged start.

   Keep the original held descriptors, NOFOLLOW physical opens, regular-file and
   single-link checks, full identity, root owner, non-writable modes and actual
   Darwin ACL checks. Preserve the entry's refusal of nonempty or unknown ACLs
   before a real UUID resolver exists. Do not fake or bypass UUID results.
   Authenticate each used logical link step's owner, metadata, target and actual
   ACL while holding its physical parent. Bind its canonical target to the fixed
   manifest, then apply the original physical checks. Reject loops, escapes,
   missing required targets, unlisted paths and changed identities. Never use
   resolve alone as authentication. Preserve the two unused dangling PrivateHeaders
   links without granting them read or execution authority.

   Keep the complete lib/include scan, all required native-image closure checks,
   original system cache boundaries and final source/identity rechecks. Preserve
   all byte, object and command caps and the shared 120-second entry/guard deadline.
   Repeat authentication immediately before the first privileged P execution.
   Preserve the later complete loaded-runtime/module and stdlib/include checks.

   The fixed entry must preserve PID and isolated flags. After entry, require the
   actual physical `sys.executable` to equal P, actual version to equal 3.14.7 and
   remain at least 3.11, and `sys.prefix == sys.base_prefix` to equal the fixed
   framework prefix. Require the original closed startup-path checks against that
   prefix. Never assign `sys.executable` or inject `__PYVENV_LAUNCHER__`. Any actual
   mismatch fails; static source acceptance does not predict a passing execution.
   Scope's outer evaluator and privileged fixture, and the native suite, must bind
   this same P through their separately accepted #541 artifact changes.

6. Put only the fixed jq bytes at
   `/Library/Frameworks/Python.framework/ystack-private-tools/jq`.
   Preserve physical single-link ownership, actual version `jq-1.6` and fixed
   digest checks. Prefill the native suite cache only in a new job-owned temporary
   directory. Verify copied bytes and preserve identity-checked cache cleanup.
   Do not follow the preinstalled jq link or select another tool path.

   Keep the original distinct writer and consumer, supplementary-only shared
   group, actual UUID/ACL, store, Git and evidence APIs. Derive TOKEN from H's first
   eight characters. Use only `yscw_TOKEN`, `yscc_TOKEN`, `yscg_TOKEN`, `yscp_TOKEN`,
   the owned `/usr/local/libexec/ystack-scope-fixture.TOKEN` and absent anchor
   `/usr/local/libexec/ystack-sandbox/v1/supervisor`. Keep unused-ID selection within
   56000–56999, absence checks, account journal and verified reverse cleanup.
   Never replace an existing anchor. Cache cleanup cannot prove fixture cleanup.
   Every required anchor, fixture, tool, cache and cleanup predicate must reject
   failure in every shell control-flow position. Do not rely on `set -e` in an
   AND-list or conditional to enforce a mandatory check.

7. Run both complete original commands at H, in order:

   ```text
   /bin/bash scripts/test/scope-qualification.test.sh
   /bin/bash scripts/test/shadow-enforced.test.sh
   ```

   Keep the 100-minute job cap and step limits: checkout 5, preflight 5, scope 35,
   native 50 and final closure 5 minutes. Fetch each fixed artifact at most once
   through its accepted source/delivery binding, within the original preflight
   budget. Preserve the approved single-file and aggregate limits. No retry,
   source change or added time is permitted. Phase-one fetching is closed.
   Preserve every assertion, product deadline, cancellation/reap rule and byte/row
   cap. The temporary supply and cleanup fit these original budgets.

   Journal each created root and confirmed new directory, file and link by its
   accepted manifest and actual owned identity. Recheck the journal and held
   parents before each write. Clean owned objects and the original fixture/cache
   on success or failure, including failure between the two root creations.
   Before cleanup, require the exact set and identities in each created tree;
   an uncreated tree must remain absent. Partial copies with unrecorded objects,
   extras or changed/unknown identity forbid broader deletion and keep cleanup
   UNKNOWN. Never infer ownership from a path or UID alone.

   Delete recorded leaves, then empty directories, stopping at the two new roots.
   Never delete an existing parent, old version, Current or root alias. Do not use
   recursive force deletion on either supply tree. Successful cleanup proves both
   absent and the original child sets and stable safety fields preserved. Record the existing
   parents' real metadata after known cleanup; do not claim it all returned to its
   original values. Timeout, interruption, refusal, suite failure or incomplete
   cleanup gives no successful proof. An ephemeral host does not prove cleanup.

8. Accept publication only after exact-base patch/manifest validation, workflow
   and embedded shell/Python static checks, required repository CI and independent
   review. Regression checks cover unsafe or changed parents, existing targets,
   wrong sets, preserved old objects, partial copy/cleanup and required shell
   predicate failures. Actual Mac proof follows at freshly reviewed H/X. Read complete results
   and cleanup with the same-head complete Linux matrix before #541 G3.
   Publication or source review does not close #541 or establish native/CPU-wall
   qualification. Production identities stay empty.

## Design

| File | Responsibility |
| --- | --- |
| `.github/workflows/scope-genuine-macos.yml` | Fixed temporary supply, original guards, suites and closure. |
| `ci/required-files.txt` | Keep the workflow in the restore-critical manifest. |

For the implementation PR: `review_size: standard`.

The separately reviewed high-risk plan fixes the complete manifest, startup
binding, immutable modes, permitted command paths/argv, source validation,
deadline, cleanup and workflow bytes. Recheck patch context at the actual base.
Do not implement before these items and their independent review are complete.

Protected publication produces main X. Merge X normally into the same #541
implementation branch to produce H. Independently review H/X and all artifact and
workflow hashes, then freeze the branch for Linux and Mac runs. The manager checks
these bindings before and after dispatch. Merge #541 only while reviewed H/X match.
Source changes do not require another literal SHA in the workflow. Changed main,
source or workflow invalidates the affected review and proof.

## Out of scope

No product or test file changes in this publication. Necessary fixed fixture
bindings pass #541's own affected artifact gates within its original allowed paths.
No reduced controls, arbitrary dispatch ref, alternative provider, preinstalled
runtime repair, other supply root, VM, real publisher, production identity, real
target or new credential scope. No #544 ref or sudoers execution is inherited.
It still needs its own gates and reviewed closed-ref/authority binding.

## Areas of concern

Risk is high because the workflow can reach the approved temporary administrator
actions. Keep the artifact chain, separate authors/reviewers, required CI, rounds
cap and protected publishing. Authority remains limited to this repository,
manager, fixed source and disposable job.

The source review accepts static feasibility only. Both new trees' absence, parent
trust, actual startup identity, loaded closure, supply timing, SDK, account lifecycle
and complete Mac results remain actual-job checks. Keep every old refusal and unknown
failure. Native remains BLOCKED and CPU/wall remains NONE until their separate
requirements are met. #544's first-code gate does not advance from this publication.
