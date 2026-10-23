---
intent-blob: 336c520dcdc7dacb6bbf3b52d34ab07f12b50f0d
risk: high
drafted: 2026-10-15
---

# Spec: Provide the bounded macOS scope proof environment

## Requirements

1. Provide the manual proof environment for #541 under the
   [directly approved conditional supply](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6180555883)
   and [existing-parent supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6189713897),
   with the [approved 3.15 supplement and accepted source review](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6203606687)
   and [fixed Versions-mode supplement](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6205434290).
   Preserve the product and its acceptance standard. This implementation changes
   only `.github/workflows/scope-genuine-macos.yml` and its entry in
   `ci/required-files.txt`. The separately accepted high-risk plan fixes all
   normative supply and proof requirements before implementation.

   | Fixed source | Accepted SHA-256 |
   | --- | --- |
   | Conditional decision | `7206ddb285720163917b4f0c7a710ec278b9b1992f88436cff9fbda18404d4bd` |
   | Existing-parent supplement | `d811e67bf53b8bcbd0417d5db686c297adbe325c47de3ab048d92bdfeead4880` |
   | Fixed 3.15 supplement | `6cbb39e4a5bcc391913e98de09bc95dac7a78e4c7585424777bd149dfdf0fca8` |
   | Accepted 3.15 source review | `22a69d7721afa114fc9780e024c97f9f323318ac854a18794b4ec3be4041340d` |
   | Fixed Versions-mode supplement | `399d3a10cac7add2bf2e77da613235fac353e7f9473f1d3cdbdff303ad9afa93` |
   | [Python 3.15.0 official macOS pkg](https://www.python.org/ftp/python/3.15.0/python-3.15.0-macos11.pkg) | `7c7e7eca61cbfa5f0c6f80cd594cddbfd492f4e8b3fb87e3d9fa1efebaec43ed` |
   | Decompressed XAR TOC | `72a73d8e5b05959f062df93f21e5829a5aac4526c833dd24cba4941462a29924` |
   | Inner P image | `23a6212221922087dafd5a0e59631efa00b75b5f2e47945ba404c67be2c54c0b` |
   | Original jq 1.6 Mac artifact | `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef` |

2. Keep dispatch closed to `yihanzhu/ystack`, repository ID `1270665750`, the manual
   event, actor and triggering actor `yihanzhu`, and
   `refs/heads/ystack/impl/scope-gate-hardening`. Keep the fixed workflow path/ref,
   read-only contents permission, pinned checkout action, disabled persisted
   credentials, serial concurrency and no cancellation of another run. Expose no
   inputs for source, path, command, provider or credentials. The mode supplement
   covers only already approved #541/#559 and #544 complete Mac proof and original
   bounded revisions. It adds no rounds, diagnostic runs, dispatches or rerun
   allowance. #544 needs its own independently accepted closed-ref and authority
   binding; this workflow keeps its sole #541 ref.

3. Select source from immutable `github.sha`. Before and after execution, require
   lowercase 40-hex source, event and workflow SHAs to agree with checkout HEAD.
   Verify the checked-out workflow against its Git blob and require clean source.
   Preserve the approved minimum ancestry check. The manager separately binds the
   reviewed head H, current base X, artifacts and workflow blob to the actual run
   API, ref and checkout. A matching SHA or permitted actor is not approval.

4. Keep `macos-15-intel` as the candidate host. Before any mutation, require the
   approved GitHub-hosted, Darwin and x86_64 guards, fixed physical tools, existing
   noninteractive sudo and absent fixture paths. Use only the fixed official
   Python 3.15.0 and jq 1.6 bytes above. No version, source, runtime or provider
   fallback is allowed. No other dependency download or installation is allowed.

   Take only the standard Python_Framework payload. Preserve every supplied byte
   and publisher link. Do not run any package script or installer. Exclude the GUI,
   CLI, documentation, pip, profile and free-threaded components. Verify the source
   chain, complete signed content manifest and fixed hashes before supply. Require
   exactly 89,032,014 package bytes. Verify RSA over the compressed XAR TOC.
   Verify every archived and extracted checksum for all 28 XAR entries, then the
   complete standard payload.
   The accepted source evidence combines the official release digest, XAR
   signature and content hashes, PSF installer identity and offline OS basic chain.
   Do not call the recorded pkgSign EKU rejection a pass. Basic trust does not
   prove installer-policy, online revocation, Sigstore or notarization acceptance.

   Supply only two entirely absent trees under the existing physical root
   `/Library/Frameworks/Python.framework`: `Versions/3.15` and
   `ystack-private-tools`. Authenticate that root and every physical ancestor with
   held NOFOLLOW descriptors, exact named identity, UID 0, non-group/other-writable
   modes and actual empty ACLs. Unknown ACLs fail. The sole mode preparation below
   applies only to `/Library/Frameworks/Python.framework/Versions`, called D.
   If D passes the original parent checks, keep the original path without mode
   preparation or restoration. The added write exception requires a physical D
   with UID 0, exact mode 0775 and actual empty ACL, safe held ancestors and both
   targets wholly absent. No link, changed identity or other failing owner, mode
   or ACL is eligible. Do not repair any other parent or old object.

   Before preparation, exclusively create an immutable, bounded mode journal in
   the original job-owned cache with NOFOLLOW, one link and mode 0600. Record D's
   dev/ino/uid/gid/full mode/nlink/size/mtime_ns/ctime_ns, safe ancestor identities
   and empty ACL evidence, original direct child/link sets and exact H/job identity.
   Fsync it and publish its digest and cache/journal identity to the cleanup step
   before mutation. Recheck it in the current process. This original record is
   distinct from the mutable owned-runtime journal; record action results separately.
   Missing, changed, unauthenticated or non-durable records prohibit mutation.

   Permit only `/usr/bin/sudo -n /bin/chmod 0755 /Library/Frameworks/Python.framework/Versions`
   and restoration with `/usr/bin/sudo -n /bin/chmod 0775 /Library/Frameworks/Python.framework/Versions`.
   Each argv may launch at most once per job, including uncertain exits. Persist
   action state before launch; never retry an uncertain action or reset its count
   in another process. Both commands count within the original runtime supply
   and cleanup runner's 256-command pool; a new process grants no extra allowance.
   Keep all original argument, output and time caps. This pool does not add a new
   total limit to the original fixtures' separately bounded administrator actions.
   Recheck held/named identity, ancestors, ACLs and old direct child sets before
   and after preparation. Only mode and the actual chmod ctime change may differ.
   After this preparation, require exact 0755 before source fetch, supply, guard
   or tests. An uncertain or failed action stops them; only authenticated recovery
   may follow. Keep preparation private to D; do not weaken shared physical or
   runtime checks.

   After preparation, authenticate D under the original parent rules. Require both
   targets absent before supply and each absent again before its root is created.
   Any existing object, including a dangling link, fails. After creation,
   authenticate its recorded owned identity before each write.

   Verify the full 4,502-entry source manifest first. Supply only its 4,496 entries
   at `Versions/3.15` or below, plus the private tools directory and jq: exactly
   4,498 entries. Preserve their bytes and all 35 link texts. Scan these two new
   trees for an exact set match; do not ignore extras or admit old siblings.

   | Fixed manifest | SHA-256 |
   | --- | --- |
   | Complete standard source | `e0d204e2827885c5f2f4278e709981b7fc1e02424d3bfa5ae2ff2af789789d26` |
   | Complete V3.15 subset | `3176a7d3551aaa719fa8ed26964237d0d1771184c6ce7a5159bbf039e7816572` |
   | V3.15 and T/jq mode map | `9184f6976c2be2e1430594adbb406293168c0201c849e31bfd671f2c8e83fb9e` |
   | V3.15 and T/jq runtime map | `d6a212cf50fd2593c75e8e011c321e65fa8609cce7add72e69d16ff0e78252c4` |

   The high-risk plan binds these maps to fixed commands and guards. Source modes
   and UID/GID are archive data, not host proof. With umask 022, require new
   directories/executable files and the 35 new links to be 0755; other files must
   be 0644. Authenticate actual UID 0, mode and empty ACL after creation.
   Keep old versions, top-level Current and root aliases unchanged.
   Do not traverse old version contents or use those old objects as dependencies.

   Read only bounded direct child names and lstat/link metadata of the existing
   parents to bind their original sets. Before every command, recheck the held
   parents and recorded sets. Apart from D's two mode/ctime transitions, only direct
   mkdir/rmdir of a fixed new root may change its parent's child set and size,
   nlink, mtime_ns or ctime_ns. Require the exact child delta and unchanged
   dev/ino/type/uid/gid/mode/actual ACL before recording the new set and fields.
   Failed or unknown tree actions cannot justify rebinding. D's mode journal may
   support safe restoration after an uncertain chmod, never continued supply.
   Other ancestors remain unchanged. Never backdate metadata. These checks share
   the original object, depth, output and deadline limits.

   Apart from the two fixed D commands, use only the accepted manifest and bounded
   mkdir/cp/chmod/rm commands for new owned objects. Runtime supply must not use
   chown, a privileged shell, package managers, scripts, compilation, binary
   rewriting or relinking. Preserve the approved fixture `/usr/bin/cc` helper/native
   builds. Add no compiler, SDK or source scope. Only the fixed D permission adds
   administrator scope. Check copied bytes against the accepted source before
   execution. Root ownership alone is not provenance.

5. Bind P to the fixed inner image
   `/Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python`.
   Bind its runtime prefix separately to
   `/Library/Frameworks/Python.framework/Versions/3.15`.
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

   Bind the source inventory's 91 loadable x86_64 Mach-O images: 90 also contain
   arm64 and one is x86_64-only. Require the 17 internal load edges to stay within
   V3.15, plus the 117 system-library edges and three `/usr/lib/dyld` edges.
   Classify the two fat static archives and one wrapped LLVM bitcode object as
   retained data, not loadable images. Authenticate their exact bytes and container
   structure against the fixed inventory. Do not skip unknown native formats by
   filename or extension; unknown or malformed native containers and images fail.
   Keep the complete lib/include scan, all required native-image closure checks,
   original system cache boundaries and final source/identity rechecks. Preserve
   all byte, object and command caps and the shared 120-second entry/guard deadline.
   Repeat authentication immediately before the first privileged P execution.
   Preserve the later complete loaded-runtime/module and stdlib/include checks.

   The fixed entry must preserve PID and isolated flags. After entry, require the
   actual physical `sys.executable` to equal P, actual version to equal 3.15.0 and
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
   source change or added time is permitted. Both source-verification fetch phases
   are closed.
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

   On normal exit, failure or cancellation, first prevent later guard/P/suite
   starts and apply the original cancellation/reap rules to this job's test and
   runtime children. Unknown or unreaped processes forbid restoration; add no
   administrator signal command. If mode preparation was entered, both same-process
   finally and the separate cleanup step must use the authenticated mode journal
   and durable action state.
   Retain both through mode cleanup and preserve failure evidence before removing
   the cache; cache deletion must not discard an unresolved restoration record.

   Delete recorded leaves, then empty directories, stopping at the two new roots.
   Never delete an existing parent, old version, Current or root alias. Do not use
   recursive force deletion on either supply tree. Successful cleanup proves both
   absent and the original child sets and stable safety fields preserved. Record the existing
   parents' real metadata after known cleanup; do not claim it all returned to its
   original values. Before restoring D, require both new trees absent, original
   direct child sets and old Current/versions/aliases preserved, the same held
   dev/ino/uid/gid/type, actual empty ACL and exact 0755, with only the previously
   authenticated chmod and child-delta changes. Then attempt the fixed restore
   once and verify 0775 with all other safety fields intact. Restore permission
   bits, not the entire original metadata: both chmod operations change ctime.
   Record actual differences and never backdate them. If preparation did not take
   effect and the original 0775 state still matches, record no change and do not
   run restoration chmod.

   A prior failure remains a failure even if restoration succeeds. After cleanup
   failure, still stop/reap and check restoration conditions. Residual V/T,
   unknown objects or processes, identity/ACL drift or an untrusted journal forbid
   the restore write. Leave the hardened 0755 state and fail; do not claim that
   destruction of the disposable host proves restoration. A failed restore is not
   retried or reported as success. Preserve its actual observed state and records.
   Timeout, interruption, refusal, suite failure or incomplete cleanup gives no
   successful proof. An ephemeral host does not prove cleanup.

8. Accept publication only after exact-base patch/manifest validation, workflow
   and embedded shell/Python static checks, required repository CI and independent
   review. Regression checks cover unsafe or changed parents, existing targets,
   wrong sets, preserved old objects, partial copy/cleanup and required shell
   predicate failures. Preserve the normal safe-parent path with no mode change.
   Add CI regression checks for that path and the exact eligible 0775-to-0755
   preparation and safe 0775 restore; owner/mode/ACL/link/identity refusal; absent,
   altered or unpublished mode journals; unknown exit, interruption and cancellation;
   per-job max-once and shared command-budget enforcement; and unsafe-restoration
   refusal. Use owned test data for negative controls, never extra mutations of D.
   Verify that neither failure nor a fresh cleanup process permits repeated chmod
   or renewed testing. When mode preparation is used, the actual Mac job must
   prove durable journal reopening, runtime cleanup and mode restoration across
   separate steps; a same-process test is insufficient. Actual Mac proof follows
   at freshly reviewed H/X. Read complete results
   and cleanup with the same-head complete Linux matrix before #541 G3.
   Publication or source review does not close #541 or establish native/CPU-wall
   qualification. Production identities stay empty.

## Design

| File | Responsibility |
| --- | --- |
| `.github/workflows/scope-genuine-macos.yml` | Fixed temporary supply, original guards, suites and closure. |
| `ci/required-files.txt` | Keep the workflow in the restore-critical manifest. |

For the implementation PR: `review_size: standard`.

The separately reviewed high-risk plan fixes all normative inputs before code:
complete source and runtime manifests, startup binding, immutable modes, permitted
command paths/argv, source validation, state transitions, deadlines, cleanup,
workflow behavior and proof requirements. Recheck patch context at the actual
base. Do not implement before these items and their independent review are complete.

After implementation and before publication, independent review binds the actual
workflow Git blob and SHA-256, plus the shared bootstrap entry/guard SHA-256s, to
the exact candidate head and base. The separately accepted #541 high-risk plan
must bind those exact shared bytes before either test fixture changes. Both
artifact chains and the original exact-source proof gates remain required before
the real Mac run.

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
