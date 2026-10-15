---
spec-blob: 6760cc5f786aa794f1fce3784664e220769d7811
drafted: 2026-10-15
---
# Plan: scope-genuine-macos-proof

## Files that change

| Implementation path | Change |
| --- | --- |
| `.github/workflows/scope-genuine-macos.yml` | Supply the fixed runtime, authenticate it, run the original suites and clean owned objects. |
| `ci/required-files.txt` | Keep that workflow path exactly once. Preserve all other entries. |

For the implementation PR: `review_size: standard`.

This plan implements the high-risk spec and the directly approved conditional
supply recorded on #559 in comment 6180555883 and its existing-parent supplement
in comment 6189713897 (SHA-256
`d811e67bf53b8bcbd0417d5db686c297adbe325c47de3ab048d92bdfeead4880`).
It changes no product or test file.
The original #541 fixtures require their own accepted plan amendment before code.
The supplied runtime does not repair or inherit trust from the preinstalled tree.

## Fixed source and paths

| Object | Exact binding |
| --- | --- |
| Python | `https://www.python.org/ftp/python/3.14.7/python-3.14.7-macos11.pkg`; 78,557,763 bytes; SHA-256 `70c5239ad2d62925d2947e46921d0ddd3d35be3d2f0a2d50db33da507dbcb419` |
| jq | `https://github.com/jqlang/jq/releases/download/jq-1.6/jq-osx-amd64`; 864,040 bytes; SHA-256 `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef` |
| jq delivery | HTTPS host `release-assets.githubusercontent.com`; path `/github-production-release-asset/5101141/6387d980-de1f-11e8-9fee-7af0943ede86` |
| Existing ROOT | `/Library/Frameworks/Python.framework` |
| Existing version parent | `/Library/Frameworks/Python.framework/Versions` |
| New V | `/Library/Frameworks/Python.framework/Versions/3.14` |
| New T | `/Library/Frameworks/Python.framework/ystack-private-tools` |
| P | `/Library/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python` |
| Prefix | `/Library/Frameworks/Python.framework/Versions/3.14` |
| jq path | `/Library/Frameworks/Python.framework/ystack-private-tools/jq` |

Use only the standard `Python_Framework.pkg/Payload`. Its accepted source
manifest has 4,201 entries: 460 directories, 3,702 regular files and 39 links.
Regular file bytes total 124,901,627. Verify all source rows before selection.
Pin the canonical source manifest SHA-256
`34ab06f305b15a1772852ce9b814c2935f80917e9548d362fe43d36c0e1cf850`.
Use source cpio order and JSON with sorted keys, compact separators, ASCII escapes
and no final newline; map keys are sorted. Derive it through the reviewed bounded
parser. Check every row, type, size, file digest and link target.

Select only paths equal to `Versions/3.14` or starting with `Versions/3.14/`.
This retains 4,195 source entries: 458 directories, 3,702 files and 35 links,
including every regular-file byte. Add only T and the fixed jq. The exact supplied
set has 4,197 entries. Do not supply ROOT, Versions, top-level Current or root
aliases, and do not grant old siblings runtime authority.

| Canonical data | SHA-256 |
| --- | --- |
| Selected source subset | `4da2fbc7b543eb3d990f429c0fe972669105abdbf9ce2b7c962b404c94f7cc27` |
| Supply mode map | `a04635f441f9706f126986616fc0f648a757630aacd78fafb944bcc2166a8d19` |
| Exact runtime expectation table | `ac527b61d0d7475d20a6e329b0b5f31e68635c7a73c93031b2b208b18ccd9c56` |

Apply the new-object mode mapping below after this source binding. New objects
must have UID 0; files and links must have nlink 1. Source gid, directory nlink
and size are publisher records, not copied-host invariants. Capture actual gid,
directory nlink/size and nanosecond times in held identities and recheck them.
Do not embed or execute package scripts. Do not use another package component.

Fetch Python once with HTTPS verification and no redirect. Fetch the fixed jq
origin once. Accept only one HTTP302 with exactly one Location at the fixed
delivery host and path above. Require HTTPS, no credentials, fragment or custom
port. Preserve its nonempty query as opaque response data; never evaluate or edit
it. Fetch that location once, with no further redirect. Reject another host, path,
status or size. Add no Cookie, Authorization, retries, mirrors or fallback.
The old signed query is evidence of the delivery binding, not a reusable URL.

Keep Python below 256 MiB, jq below 8 MiB and aggregate received bytes below
280 MiB. Require the exact lengths and hashes above before parsing or supply.
All requests, validation, staging and supply share the original five-minute
preflight budget. Do not restart its clock. Phase-one source fetching is closed.

Keep the accepted XAR signature/content and official release evidence. Validate
the fixed archive and complete signed content records before extraction. Do not
convert the recorded pkgSign EKU failure into a successful policy check. The
accepted offline basic chain and source digest do not claim online revocation,
Sigstore or notarization acceptance. Do not fetch new trust material in the job.
Use only the existing `/usr/bin/openssl` x509 public-key extraction and SHA-1
signature verification for the pinned XAR. Use `/usr/bin/security verify-cert
-L -R offline -N -p basic` with the pinned leaf and intermediate certificates.
Do not pass the package root certificate as a trust anchor. Keep these reads
non-privileged and bound to the fixed package data in the owned cache.

The parser may handle at most 16,384 entries, 128 path levels and 512 MiB expanded
bytes. Keep the 16 MiB per-file limit. Reject duplicate names, devices, hard
links, absolute extraction paths, parent traversal and escapes. Resolve each of
the 39 links within the fixed source manifest. Preserve all target text and file
bytes. Preserve the two unused dangling PrivateHeaders links without authorizing
their targets. No needed path may use a missing target.

## Supply and first execution

1. Preserve the fixed repository ID, operator, manual event, closed #541 ref,
   immutable dispatch SHA, workflow/checkout equality, ancestry, contents-read
   permission, pinned checkout, serial concurrency and original host/tool guards.
   There are no source, path, command, provider or credential inputs.
2. Use the existing fixed system Python only as the initial non-privileged
   trusted reader. Do not execute P or jq while fetching, parsing or staging.
   Do not require that reader to authenticate itself before its first start.
   Create only a new job-owned private staging directory. Capture its identity.
   Stage only the verified V subset, then add T and the fixed jq bytes.
   Set new staging directories to 0755, regular files with publisher execute bits
   to 0755, other regular files to 0644, and links themselves to 0755. Set jq to
   0755. This changes modes only, never source bytes or link text.
3. Authenticate existing ROOT, Versions and every physical ancestor. Hold
   NOFOLLOW directory descriptors and verify exact named identity, UID 0,
   non-group/other-writable modes and actual empty ACLs. Unknown ACLs fail.
   Do not create, chmod, chown or repair them. Require V and T both wholly absent,
   including files, links, dangling links and residual objects. Snapshot only
   bounded direct child names and lstat/link metadata of ROOT and Versions.
   Do not traverse old versions or use old Current or aliases as dependencies.
   These checks share the original object, depth, output and remaining time caps.
4. Use only the bounded administrator commands below. Recheck each root's absence
   immediately before its mkdir. Record that new root's actual identity at once.
   Its state then changes from absent to owned; later writes require that exact
   identity. Recheck the selected stage and empty owned destination before each
   copy. Recheck the journal, full held parent chain and recorded child sets
   before and after every command.

   Only direct mkdir/rmdir of V may change Versions; only direct mkdir/rmdir of T
   may change ROOT. Require exactly that fixed child-name addition or removal and
   unchanged dev/ino/type/uid/gid/mode/actual ACL. Only then record the actual new
   size, nlink, mtime_ns and ctime_ns plus the new child set. Failed or unknown
   actions cannot justify rebinding. Copy and link chmod grant no such parent
   exception. Other ancestors and old objects retain every checked field.
   New-tree internal parents keep their original exact per-operation updates.
   Never backdate timestamps. Every derived path comes from the fixed manifest
   inside V or T, never from input, old siblings or an unchecked link.

   | Program and arguments after `sudo -n` | Purpose |
   | --- | --- |
   | `/bin/mkdir -m 0755 V` | Create and journal the absent version root. |
   | `/bin/mkdir -m 0755 T` | Create and journal the absent tool root. |
   | `/bin/cp -R -P -n STAGE/Versions/3.14/. V` | Copy only the verified version bytes into empty owned V. |
   | `/bin/cp -R -P -n STAGE/ystack-private-tools/. T` | Copy only the fixed jq into empty owned T. |
   | `/bin/chmod -h 0755 LINK...` | Set only the 35 new manifest links themselves to the fixed mode. |
   | `/bin/rm -f -- LEAF...` | Remove only recorded owned regular files and links after identity checks. |
   | `/bin/rm -d -- DIRECTORY...` | Remove only recorded empty owned directories in reverse depth order. |

   ROOT, V and T are fixed literals, not inputs. STAGE is the single new private
   staging path recorded by this job. Never use `cp -p` or follow source links.
   Bound each manifest-derived argument batch to 128
   paths. Bound the private supply runner to 256 commands, 256 arguments and
   65,536 argument bytes per command. Enforce the combined 16 MiB stdout/stderr
   cap while reading, within the remaining deadline. Cancel and reap its exact
   child on failure. Unknown privileged descendants remain a failure; add no
   privilege or signal command to claim otherwise. Keep the later original
   runner limits unchanged. Set only these fixed child processes' umask to 022. Do not change the job mask, sudoers or host policy.
   Verify the resulting actual modes; the requested mask is not proof.
   No privileged shell, chown, installer, package script, compiler, relinker or
   package manager is permitted.
   Keep the original fixture's separately bounded account commands unchanged.
5. After each successful copy, scan its destination within the same caps and
   journal every confirmed new identity before another write. Verify the exact
   subtree set, bytes, types, UID 0, nlink and actual ACLs; capture actual modes.
   After both copies, require exactly all 4,197 entries. Existing parents remain
   separately authenticated and never enter the owned set. These scans record
   copy results, not runtime acceptance. A new manifest link may have a
   copy-created mode before chmod. Before changing it, require its held immutable
   physical parent, UID0, nlink1, exact target, full identity and actual empty ACL.
   After chmod, require 0755 and unchanged identity fields/target except the
   expected mode and ctime changes. Rebind its owned record. Never apply this
   transition to an old object or treat it as a weaker execution check.
6. Before the first P execution, authenticate the exact V/T installation with
   the existing metadata-only entry rule, including actual empty ACL checks.
   There is no prior UUID resolver at this stage. Keep held physical NOFOLLOW
   opens, regular/nlink checks, complete identities, root owner and non-root
   non-writable modes. No fake UUID, candidate self-report or new root owner can
   substitute for this verification. Reject every unknown or nonempty ACL here.
7. Authenticate each used logical link step while holding its physical parent.
   Accept only the 35 fixed new links; bind owner, metadata, target and actual ACL
   to the selected manifest. Resolve only within V, including its internal Tcl/Tk
   Current links; top-level Current and old aliases grant no runtime authority.
   Then pass its canonical physical target to the original physical checks.
   Reject loops, escapes, unlisted paths, changed identities and missing required
   targets. Keep the full lib/include scan, both startup images, shared Python
   library, all 90 native images and every required load target. Preserve the
   original native parser, system cache boundaries, size/count limits and final
   source/identity rechecks. A path resolve alone grants no authority.
8. Enter the exact P with `-I -S -B` by the existing same-PID entry mechanism.
   Preserve the shared 120-second entry/guard deadline across this transition.
   Require actual physical `sys.executable == P`, exact version 3.14.7 and at
   least 3.11, unchanged PID, isolated flags, the fixed prefix/base_prefix and
   original closed startup paths. Never assign `sys.executable` or inject
   `__PYVENV_LAUNCHER__`. A mismatch remains a failure.
9. Under this now-authenticated P, create the real existing Darwin child owner
   and UUID resolver. Repeat the complete original runtime/module/stdlib/include
   checks. Repeat full authentication immediately before first privileged P
   execution in the separately planned scope fixture. Preserve real queries,
   child ownership, bounded cancellation, exact reap and failure classification.
   Workflow and scope share the same fixed entry/guard bytes, apart from an
   explicitly retained failure-only diagnostic block. No product API changes.
10. Verify the fixed jq bytes, physical identity and actual `jq-1.6` version.
    Prefill only the new owned native cache, using those same bytes. Preserve
    identity-checked cache cleanup. Do not inspect or run the preinstalled jq.
    Every mandatory anchor, fixture, tool, cache and cleanup check must propagate
    failure in every shell position. Use explicit failure handling; an AND-list
    or conditional must not suppress a required failure through `set -e`.

## Cleanup and proof

Journal staging, each successful V/T mkdir and every confirmed copied object by
actual identity. Hold and recheck physical parents before each new write. A failure
between the root creations still cleans the already recorded owned objects.
Record the exact boundary of a failed or interrupted copy. Never infer ownership
from a name or root UID. An unrecorded partial-copy object blocks wider deletion
and leaves cleanup UNKNOWN. A batch copy cannot promise cleanup on every interrupt.

Before cleanup, require each created tree's exact journal set and actual identities;
an uncreated tree must remain absent. Recheck each object before deleting it. Remove
recorded files and links without following links, then identity-matched empty
directories in reverse depth order, stopping after V and T. Extra, changed or
unknown objects block broader deletion. Never pass ROOT, Versions, Current, old
versions or root aliases to cp, chmod or rm. Use no wildcard or `rm -rf` on V/T.
Keep the separate job-owned cache's original identity-checked `/bin/rm -rf` cleanup.

Successful supply cleanup proves V/T absent, original direct child sets restored
and existing parents' stable safety fields unchanged. Record their actual dynamic
metadata after each known rmdir; do not claim all metadata returned to its old value.
Preserve the original refusal when cleanup also fails. A vanished host or ephemeral
runner is not cleanup evidence.

Preserve the original account journal, four derived principals, unused-ID range,
supplementary-only group, fixed anchor, closed store/Git/evidence paths, actual
UUID/ACL checks and verified reverse cleanup. No production identity is added.

Run both complete original commands in order:

```text
/bin/bash scripts/test/scope-qualification.test.sh
/bin/bash scripts/test/shadow-enforced.test.sh
```

Keep the 100-minute job and 5/5/35/50/5-minute step limits. Supply stays in the
original preflight step. Keep all original assertions, native 149 controls,
product deadlines, cancellation/reap rules and output caps. No failed prerequisite
permits a skip, replacement runtime, provider or alternate proof. An intentional-stop
diagnostic path must not replace or interrupt these suites.

Before publication, check exact-base patch context, the sole manifest entry,
artifact hash links and allowed paths. Parse YAML with the existing Ruby library.
Run `/bin/bash -n` on every decoded shell body. Compile all embedded Python
strings and heredocs without executing them. Check the fixed source/manifest
digests. After implementation, record the actual workflow Git blob and SHA-256
and the extracted shared entry/guard SHA-256s against the exact candidate head/base.
The separate publication reviewer reads those exact bytes and full validation
outputs before protected merge. Do not reuse an old workflow or guard digest as
the new binding. The #541 high-risk plan then pins these existing shared bytes
before fixture code changes; compare the resulting copies before the real run.
Save full outputs and the exact workflow. Run `git diff --check`.

Use owned fixture controls for unsafe/changed parents, either pre-existing V/T,
wrong source bytes, extra/missing manifest paths, changed or escaping links,
wrong parent child-set deltas, partial copy and unrecorded cleanup objects.
Prove old versions, Current and aliases remain unchanged and outside dependency
and cleanup sets. Cover failure between root creations and actual metadata records.
Retain changed-held-identity, writable/ACL-path and bad startup identity/version/
prefix/flags controls. Force each mandatory shell predicate to fail; test the tool
predicate in all three positions of its AND-list, not just the final command.
Keep the original cancellation and cleanup controls. Static models do not prove
Darwin ACL behavior or a real same-PID positive. Those require the actual approved
Mac job and the unchanged complete suites. Preserve all failed controls.

Require automatic repository checks/ci and separate full independent publication
review at the exact head/base. Quick CI is not the full matrix. The manager then
publishes through the protected PR. Normal merge of that main into the existing
#558 branch produces H. Freshly review H/X, artifacts and workflow. Bind actual
run API, ref, actor, event and checkout before and after the unique Mac run.
Read its complete results and cleanup with the complete same-H Linux matrix.
Only then may the separate #541 G3 and protected merge proceed.

## Order and limits

After independent high-plan acceptance and protected merge, record fresh main as
plan-base. Reconcile the existing deterministic implementation attempt. Require
that base or the normal fresh base acceptance before first code. Never reset,
rebase or force an existing branch. Implementation uses `Closes #559`; this plan
PR uses `Tracks #559` and changes only this plan path.

The separately authored #541 plan must bind its two fixed test fixtures to this
P, prefix, jq, bootstrap entry and guard before those files change. This plan does
not amend the core product or waive that gate. It grants no #544 ref, sudoers or
execution authority. #544 retains its original sequence and full requirements.

Keep every old Mac refusal, Linux UNKNOWN and incomplete proof. Actual parent
trust, V/T absence, startup identity, timing, SDK, account lifecycle and
cleanup remain real-job checks. Native stays BLOCKED, CPU/wall NONE and production
identities empty until their own requirements are met.
