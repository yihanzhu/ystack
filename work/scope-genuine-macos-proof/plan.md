---
spec-blob: d17c985b9651ff46c259997fb54d8fc214293357
drafted: 2026-10-15
---
# Plan: scope-genuine-macos-proof

## Files that change

| Implementation path | Change |
| --- | --- |
| `.github/workflows/scope-genuine-macos.yml` | Supply the fixed runtime, authenticate it, run the original suites and clean owned objects. |
| `ci/required-files.txt` | Keep that workflow path exactly once. Preserve all other entries. |

For the implementation PR: `review_size: accepted-exception`, 600–1,400 net lines.
This one concern adds the fixed parent-mode boundary, durable recovery integration
and its CI controls. Reuse the existing bounded executor and owned-tree cleanup.
The range is an estimate, not an implementation target or permission to cut proof.
Measure the final patch; an unexplained overrun returns through the plan gate.

This plan implements the high-risk spec and the directly approved conditional
supply recorded on #559 in comment 6180555883 and its existing-parent supplement
in comment 6189713897 (SHA-256
`d811e67bf53b8bcbd0417d5db686c297adbe325c47de3ab048d92bdfeead4880`).
Apply the [approved fixed 3.15 supplement and accepted source review](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6203606687).
Apply the [fixed Versions-mode approval](https://github.com/yihanzhu/ystack/issues/559#issuecomment-6205434290),
decision SHA-256 `399d3a10cac7add2bf2e77da613235fac353e7f9473f1d3cdbdff303ad9afa93`.
It changes no product or test file.
The original #541 fixtures require their own accepted plan amendment before code.
The supplied runtime does not repair or inherit trust from the preinstalled tree.

## Fixed source and paths

| Object | Exact binding |
| --- | --- |
| Python | `https://www.python.org/ftp/python/3.15.0/python-3.15.0-macos11.pkg`; 89,032,014 bytes; SHA-256 `7c7e7eca61cbfa5f0c6f80cd594cddbfd492f4e8b3fb87e3d9fa1efebaec43ed` |
| Decompressed XAR TOC | SHA-256 `72a73d8e5b05959f062df93f21e5829a5aac4526c833dd24cba4941462a29924` |
| jq | `https://github.com/jqlang/jq/releases/download/jq-1.6/jq-osx-amd64`; 864,040 bytes; SHA-256 `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef` |
| jq delivery | HTTPS host `release-assets.githubusercontent.com`; path `/github-production-release-asset/5101141/6387d980-de1f-11e8-9fee-7af0943ede86` |
| Existing ROOT | `/Library/Frameworks/Python.framework` |
| Existing version parent | `/Library/Frameworks/Python.framework/Versions` |
| New V | `/Library/Frameworks/Python.framework/Versions/3.15` |
| New T | `/Library/Frameworks/Python.framework/ystack-private-tools` |
| P | `/Library/Frameworks/Python.framework/Versions/3.15/Resources/Python.app/Contents/MacOS/Python`; SHA-256 `23a6212221922087dafd5a0e59631efa00b75b5f2e47945ba404c67be2c54c0b` |
| Prefix | `/Library/Frameworks/Python.framework/Versions/3.15` |
| jq path | `/Library/Frameworks/Python.framework/ystack-private-tools/jq` |

Use only the standard `Python_Framework.pkg/Payload`. Its accepted source
manifest has 4,502 entries: 529 directories, 3,934 regular files and 39 links.
Regular file bytes total 131,786,038. Verify all source rows before selection.
Pin the canonical source manifest SHA-256
`e0d204e2827885c5f2f4278e709981b7fc1e02424d3bfa5ae2ff2af789789d26`.
Use source cpio order and JSON with sorted keys, compact separators, ASCII escapes
and no final newline; map keys are sorted. Derive it through the reviewed bounded
parser. Each row has path, kind, mode, uid, gid, nlink and size; regular files
add sha256, and links add link text. Check every row, type, size, digest and target.

Select only paths equal to `Versions/3.15` or starting with `Versions/3.15/`.
This retains 4,496 source entries: 527 directories, 3,934 files and 35 links,
including every regular-file byte. Add only T and the fixed jq. The exact supplied
set has 4,498 entries. Do not supply ROOT, Versions, top-level Current or root
aliases, and do not grant old siblings runtime authority.

| Canonical data | SHA-256 |
| --- | --- |
| Selected source subset | `3176a7d3551aaa719fa8ed26964237d0d1771184c6ce7a5159bbf039e7816572` |
| Supply mode map | `9184f6976c2be2e1430594adbb406293168c0201c849e31bfd671f2c8e83fb9e` |
| Exact runtime expectation table | `d6a212cf50fd2593c75e8e011c321e65fa8609cce7add72e69d16ff0e78252c4` |

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
preflight budget. Do not restart its clock. Both source-verification fetch phases
are closed.

Keep the accepted XAR signature/content and official release evidence. Validate
the exact compressed TOC RSA signature, decompressed TOC hash and all 28 XAR
entries' archived and extracted checksums before parsing the standard payload. Do not
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

## Fixed Versions mode boundary

Keep this exception in one private `VersionsParentMode` boundary in the embedded
provision reader. D is the literal existing version parent in the table above.
The approved CI image can expose D as UID 0 with mode 0775. Changing that image or
repairing other parents is outside this scope. Do not add a general unsafe-path
option, weaken `physical()` or `recheck_one()`, or copy this boundary into fixtures.
Remove the exception when an independently accepted host binding no longer needs
it and complete exact-head Mac proof passes through the unchanged zero-write path.
A runner README or one assumed image property is insufficient for removal.

Before the first `open_parents()`, use unchanged `physical(ROOT, True)` to hold
ROOT and its safe ancestors. Open only the literal `Versions` child relative to
that held ROOT with DIRECTORY and NOFOLLOW. Compare its full named/fstat identity
and check its actual ACL with the existing ACL reader. Keep this private D handle
out of `shared_components`; it cannot authorize ordinary supply operations.

| Observed D | Action |
| --- | --- |
| Passes all original parent checks | Use the original path, with no mode preparation or restoration. |
| Physical UID 0, exact full mode 040775, actual empty ACL; safe ancestors; V/T wholly absent | Save the original record, then attempt the sole tightening command. |
| Any other owner, mode, ACL, link, identity or absence failure | Refuse without repair or runtime execution. |

Snapshot bounded direct child names and lstat/link metadata of ROOT and D without
traversing old contents. Reuse the original identity fields, ACL reader, canonical
encoding and object/depth limits. The private D snapshot must apply the same
identity and ACL checks without routing its eligible 0775 state through a shared
function that rejects it. No source fetch or staging precedes this decision.

Keep three records with distinct purposes in the original job-owned cache:

| Fixed record | Purpose |
| --- | --- |
| `versions-mode-original.json` | Immutable version-1 baseline, created only for eligible mode preparation. |
| `provision-actions.jsonl` | Bounded write-ahead command reservations, results and fixed phase outcomes. |
| `owned.json` | Existing mutable runtime ownership and known parent-delta journal. |

Create the baseline exclusively with NOFOLLOW, mode 0600 and one link; require
job ownership and the held cache identity. Limit it to 4 MiB. Store D's complete
dev/ino/type/uid/gid/mode/nlink/size/mtime_ns/ctime_ns, safe ancestor identities and
empty ACL results, original ROOT/D direct child records, H, workflow SHA, run ID,
run attempt and job name. Bind the cache's dev/ino/uid/gid/type/mode. Use exact keys
and types, reject duplicate JSON keys, and never rewrite the baseline.
Fsync, read back and recheck the record. Before chmod, publish its SHA-256 and
cache/file identity through fixed single-line `GITHUB_ENV` records, flush/fsync
that output and verify the written bytes. Keep matching current-process bindings.
A failed, missing or uncertain publication prohibits the mode command.

The action record uses the same exclusive owner/mode/link checks and a 4 MiB cap.
Each canonical row binds a sequence and previous-row digest. Permit only command
issued/result rows and the fixed supply/scope/native/closure phase outcomes.
There are at most 256 issued rows, one result per issued row and eight phase rows.
Recheck the held/named file before every append. After each append, fsync and
publish its length, identity and digest. A reserved command may launch only after
that publication succeeds. Reopen in cleanup against those published values. Missing, truncated, duplicate, reordered,
oversized, stale or unpublished state fails closed. Cache timestamps may reflect
only this job's known fixed-record writes; cache identity and safety fields stay
fixed. No new journal is a source of runtime ownership.

Persist a command reservation and its count before execution. A reservation
consumes the allowance even if launch or exit is unknown. Record actual completion
and cancellation/reap status separately; absence of a result never means success.
Use this counter for the existing supply/cleanup `run()` calls and the two mode
commands across processes. It never resets on cleanup entry. The original
256-command pool and all argument/output/deadline caps remain; this does not place
a new aggregate cap on the fixtures' separately bounded administrator actions.
No repeated mode attempt is allowed in finally or a later cleanup process.

| Phase | Sole added argv, at most once per job |
| --- | --- |
| Tighten | `/usr/bin/sudo -n /bin/chmod 0755 /Library/Frameworks/Python.framework/Versions` |
| Restore | `/usr/bin/sudo -n /bin/chmod 0775 /Library/Frameworks/Python.framework/Versions` |

Use the existing `bounded_command()` for these two literal commands, with the
same argument checks and durable counter as `run()`. Keep their private pre/post
checks outside `mutation_names()`; that function must not accept arbitrary old
paths. Reuse its existing cancellation/reap behavior. Unknown privileged children
remain unknown; add no privileged signal command or process-discovery permission.

Before and after tightening, recheck held/named D, safe ancestors, empty ACLs and
old direct child sets. Successful exit plus exact 040755 permits only mode and
actual ctime to differ; every other D field remains equal. Update ROOT's recorded
Versions child identity only for that verified change. Close the private D and
ROOT holds before the unchanged ordinary `open_parents()` authenticates 0755.
A failed or uncertain action never proceeds to source, supply, guard or suites.

The immutable baseline stays unchanged. Connect it to the existing runtime
journal through the verified tightening result. After each original successful
mkdir/rmdir, persist only the already checked fixed child delta, resulting parent
identities and current owned-journal digest. Do not rebase from an arbitrary fresh
stat. Copy, link chmod, failed or unknown actions grant no parent-delta permission.
For restoration, require the final runtime journal to match this chain and the
baseline's stable identities and old child records. Close ordinary physical holds
before reopening private D for the final chmod; do not weaken shared rechecks or
silently rewrite shared identities to accommodate 0775.

| State or event | Required result |
| --- | --- |
| Original safe D | No mode command; original supply and cleanup remain required. |
| Prepared baseline, no tightening reservation | No permission change; no restore command. |
| Tightening reserved, failed or unknown | Stop further launches; authenticate recovery from the baseline and action record, never retry tightening. |
| Confirmed 0755 | Original supply, guard and suites may run only after all their unchanged gates. |
| Original 0775 still fully matches after an ineffective attempt | Record no change; no restore command; preserve the failure. |
| Safe cleanup and exact restore preconditions | Reserve the sole restore command, run it, then verify exact 0775. |
| Restore already reserved | Never repeat it; only verify its recorded result and actual state. |
| Unsafe, unknown or failed recovery | Fail and retain evidence; do not broaden deletion or restoration authority. |

Normal supply leaves D at 0755 for the two suites. On supply failure, finally uses
the same recovery decision as the separate always-cleanup step. The latter must
also handle a mode record with no `owned.json`, since preparation can fail before
runtime journaling. Recheck the actual provision digest before every invocation.
Do not restore on a successful preflight before the tests have run.

Before recovery, prohibit later guard/P/suite starts. Record phase entry and exact
child completion under the existing cancellation/reap rules. Keep the original
suite commands and their deadlines; their wrappers record actual wait/cleanup
outcomes, not a success inferred from step color. Unknown or unreaped test/runtime
children, interrupted phase records or privileged-subcommand uncertainty block
restoration. For quiescence, add no administrator process or signal command.

Clean V/T only through the original owned journal and cleanup routine. If supply
never created a journal, prove both targets absent. Partial-copy extras still
block wider deletion. Before restoring, require both targets absent, original
ROOT/D child sets and old Current/versions/aliases preserved, the same D
identity/UID/GID/type, exact 0755, safe ancestors and actual empty ACL. Permit only
the previously verified mode/ctime and known child-delta changes. If cleanup failed,
still stop/reap and check these conditions; restore only if every condition holds.
An unknown chmod exit may support authenticated recovery, never continued testing.

After restore, verify exact 0775, unchanged safety fields/old children and the
actual ctime change. Preserve any earlier failure. Failed restoration is not
retried or reported as success. If restoration is unsafe, leave hardened 0755 and
fail; if drift makes even that state unknown, record the actual observation rather
than claim 0755. Never backdate timestamps or claim complete metadata restoration.
Retain unresolved journals and failure evidence; cache deletion or disposal of the
CI host is not restoration proof. Keep source-closure checks active even when
recovery fails, without replacing the original failure.

## Supply and first execution

1. Preserve the fixed repository ID, operator, manual event, closed #541 ref,
   immutable dispatch SHA, workflow/checkout equality, ancestry, contents-read
   permission, pinned checkout, serial concurrency and original host/tool guards.
   There are no source, path, command, provider or credential inputs.
2. Use the existing fixed system Python only as the initial non-privileged
   trusted reader. Do not execute P or jq while fetching, parsing or staging.
   Do not require that reader to authenticate itself before its first start.
   Complete the mode boundary and original parent checks before fetching or
   staging. Create only a new job-owned staging directory. Capture its identity.
   Stage only the verified V subset, then add T and the fixed jq bytes.
   Set new staging directories to 0755, regular files with publisher execute bits
   to 0755, other regular files to 0644, and links themselves to 0755. Set jq to
   0755. This changes modes only, never source bytes or link text.
3. Authenticate existing ROOT, Versions and every physical ancestor. Hold
   NOFOLLOW directory descriptors and verify exact named identity, UID 0,
   non-group/other-writable modes and actual empty ACLs. Unknown ACLs fail.
   Only the fixed D boundary may change an existing parent mode. Do not create,
   chown or otherwise repair parents. Require V and T both wholly absent,
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

   Apart from the two verified D mode/ctime transitions, only direct mkdir/rmdir
   of V may change Versions; only direct mkdir/rmdir of T may change ROOT. Require
   exactly that fixed child-name addition or removal and
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
   | `/bin/cp -R -P -n STAGE/Versions/3.15/. V` | Copy only the verified version bytes into empty owned V. |
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
   The two fixed D commands are the only added administrator permission.
   No privileged shell, chown, installer, package script, compiler, relinker or
   package manager is permitted for runtime supply. Keep the original fixture's
   separately bounded account commands and approved `/usr/bin/cc` helper/native
   builds unchanged. Add no compiler, SDK, source or administrator scope.
5. After each successful copy, scan its destination within the same caps and
   journal every confirmed new identity before another write. Verify the exact
   subtree set, bytes, types, UID 0, nlink and actual ACLs; capture actual modes.
   After both copies, require exactly all 4,498 entries. Existing parents remain
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
   library, all 91 loadable x86_64 Mach-O images and every required load target.
   The fixed inventory contains 90 x86_64/arm64 images and one x86_64-only image:
   three executables, ten dylibs and 78 bundles. Keep x86_64 as the only execution
   architecture. Require all 17 internal load edges within V, plus 117 system-library
   edges and three `/usr/lib/dyld` edges. Preserve the original bounded native
   parser controls, system cache boundaries and final source/identity rechecks.
   A path resolve alone grants no authority.

   Classify these three exact manifest-bound files as retained static data:

   | Path relative to V | Required container |
   | --- | --- |
   | `Frameworks/Tcl.framework/Versions/9.0/libtclstub.a` | Fat x86_64/arm64 ar archives; two symbol indexes and ten MH_OBJECT members total. |
   | `Frameworks/Tk.framework/Versions/9.0/libtkstub.a` | Fat x86_64/arm64 ar archives; two symbol indexes and four MH_OBJECT members total. |
   | `lib/python3.15/config-3.15-darwin/python.o` | Fat x86_64/arm64 slices containing wrapped LLVM bitcode. |

   Require exact file digests from the selected manifest before classification.
   Check fat headers, unique declared architectures, nonoverlapping in-bounds
   slices, ar headers and member bounds. Permit only the recorded symbol indexes
   and MH_OBJECT members with no dynamic load commands. For the bitcode object,
   check wrapper magic/version, payload bounds and bitcode magic in each slice.
   Keep all parsing within the original file/object/depth/time caps. These data
   files gain no load or execution authority. Unknown or malformed native images,
   containers, slices or member kinds fail. Never bypass classification because a
   name ends in `.a` or `.o`, and never treat a loadable image as static data.
8. Enter the exact P with `-I -S -B` by the existing same-PID entry mechanism.
   Preserve the shared 120-second entry/guard deadline across this transition.
   Require actual physical `sys.executable == P`, exact version 3.15.0 and at
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
unknown objects block broader deletion. Never pass ROOT, Current, old versions or
root aliases to cp, chmod or rm. Versions permits only its two fixed mode commands.
Use no wildcard or `rm -rf` on V/T. Keep the job-owned cache's original
identity-checked `/bin/rm -rf` cleanup only after recovery is resolved and required
evidence retained; never delete its sole unresolved mode/action records.

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
digests. Keep the shared 480-line guard and entry bytes unchanged: SHA-256
`e6fb867d4cd7e0092fe5cc61050be3286f14279b8541f82d156dbd10f1b065b6`
and `e11560926ec9ab0188cd448a723a9c2eee5bef4064cc3445d7a25cd5e4377229`.
After implementation, record the actual workflow Git blob and SHA-256
and the extracted shared entry/guard SHA-256s against the exact candidate head/base.
The separate publication reviewer reads those exact bytes and full validation
outputs before protected merge. Do not reuse an old workflow or guard digest as
the new binding. The #541 high-risk plan then pins these existing shared bytes
before fixture code changes; compare the resulting copies before the real run.
Save full outputs and the exact workflow. Run `git diff --check`.

Run mechanical mode-boundary regressions in CI within the existing preflight
budget, before any production-mode action. Exercise the exact private boundary
with owned-data metadata/ACL and recording-executor adapters. Production always
uses literal D and real reads; no environment, workflow input or arbitrary root
can select test adapters. Keep these controls embedded in the workflow. A fixed
test-only fresh-process entry may reopen owned test records with that adapter;
it must never construct production I/O, call sudo or execute a supplied runtime.
Use the existing system reader and bounded child handling; add no tool or host
permission. Do not mutate actual D to manufacture negative cases.

| CI control | Required observation |
| --- | --- |
| Original safe parent; exact eligible parent | Zero mode commands on the normal path; exactly the two fixed commands on successful preparation/recovery. |
| Wrong UID/mode/ACL/link/identity, unsafe ancestor or existing V/T | Refusal before any mode command or later runtime launch. |
| Missing, changed, unpublished, malformed, oversized or stale baseline/actions; cache replacement; failed fsync/publication | Refusal, without inventing a baseline or resetting attempts. |
| Unknown exit, cancellation, unreaped child or unknown privileged child | No later tests; no unsafe restoration; original failure retained. |
| Interruption before/after reservation and result; finally then fresh cleanup process | Each chmod at most once, including uncertain launches; durable count and state survive reopening. |
| Shared command budget exhausted | Neither mode command nor a new cleanup process bypasses the original cap. |
| Source/suite failure, known child deltas, partial copy, residual/changed objects, old-child drift, restore failure | Only authenticated owned cleanup; restore only with all conditions; no retry or false success. |

Assert command sequences, state transitions, preserved old records and failure
outputs. These controls do not prove real UID/ACL behavior. When mode preparation
is used, the actual approved Mac job must reopen its published journals in the
separate cleanup step, clean V/T and verify restoration after the full suites.
A same-process simulation cannot replace that proof. The normal safe-parent path
still requires the original actual proof with no permission changes.

Use owned fixture controls for unsafe/changed parents, either pre-existing V/T,
wrong source bytes, extra/missing manifest paths, changed or escaping links,
wrong parent child-set deltas, partial copy and unrecorded cleanup objects.
Prove old versions, Current and aliases remain unchanged and outside dependency
and cleanup sets. Cover failure between root creations and actual metadata records.
Retain changed-held-identity, writable/ACL-path and bad startup identity/version/
prefix/flags controls. Force each mandatory shell predicate to fail; test the tool
predicate in all three positions of its AND-list, not just the final command.
Cover unknown or malformed native containers and static data offered as a loaded
image. Keep the original cancellation and cleanup controls. Static models do not prove
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
not amend the core product or waive that gate. The D-mode approval also covers
#544's already approved complete Mac validation and bounded revisions, but #544
still needs its own accepted closed-ref/authority binding. It cannot borrow this
workflow's #541 ref or inherit sudoers execution. Add no rounds, diagnostic runs,
dispatches or rerun allowance. All other #544 requirements remain.

Keep every old Mac refusal, Linux UNKNOWN and incomplete proof. Actual parent
trust, V/T absence, startup identity, timing, SDK, account lifecycle and
cleanup remain real-job checks. Native stays BLOCKED, CPU/wall NONE and production
identities empty until their own requirements are met.
