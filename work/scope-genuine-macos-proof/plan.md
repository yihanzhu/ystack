---
spec-blob: f74d4716908f0668bfac462bcfefe6b79ec8a4ad
drafted: 2026-10-14
---
# Plan: scope-genuine-macos-proof

## Files that change

| Implementation path | Change |
|---|---|
| `.github/workflows/scope-genuine-macos.yml` | Publish the exact workflow bytes pinned below. |
| `ci/required-files.txt` | Keep that workflow path exactly once; preserve existing entries. |

For the implementation PR: `review_size: standard`.

The accepted spec is high risk. This publication changes no product or test file,
permission, provider or proof requirement. It selects the existing physical runtime
already supported by the native suite. The approved baseline package and its three
SHA-256 values remain in spec requirement 1 and the linked direct decision.

## Order of work

1. After independent plan review, required CI and protected plan merge, record
   fresh main as plan-base. Verify both artifact hash links and the unchanged high
   risk. Before first code, require that base or the normal fresh base acceptance.
   Create `ystack/impl/scope-genuine-macos-proof` from the accepted base; reconcile
   an existing attempt instead of replacing it.
2. Preserve the approved baseline, using the native suite's fixed existing-runtime
   selector for the preflight Python and reporting its path/version before the
   unchanged minimum-version assertion. Before the first candidate execution, use
   fixed system Python and the existing held/ACL/UUID machinery to authenticate
   the physical installation and required native dependencies. Keep the bounded
   private prefix guard, refusal of unknown layouts, and repeat it before privilege
   in the separately repaired scope fixture. Keep equality with the native selection
   and every original physical runtime/module check. At this private fixture
   boundary, enter the same fixed system Python once by its authenticated physical
   path before the guard or its test observer starts. Keep the PID, isolated flags
   and closed arguments. Never assign a replacement value to `sys.executable`.
   Hold its physical file and ancestors with the original no-follow, regular-file,
   single-link and full identity checks. Require root ownership, no non-root mode
   write bits, and actual ACL absence. Check each logical symlink's ownership,
   target, metadata and ACL, with its physical parent held. Recheck held bytes and
   names immediately before exec. A nonempty ACL or failed ACL query refuses at
   this entry: no prior UUID resolver exists there. Do not interpret or fake UUIDs.
   This uses the already trusted fixed system runtime as its starting point; it
   does not claim that ACL absence authenticates all of that runtime's startup
   modules. After actual re-entry, require the same version, canonical prefixes
   and startup paths, plus physical `sys.executable`. Keep one shared 120-second
   deadline across entry and guard. Record bounded stage/path/exception-chain
   diagnostics before re-raising an error. After entry refusal, allow one private,
   non-privileged read-only inventory using that same fixed system Python and only
   the remaining shared deadline. Keep synchronous budget checks; add no signal
   timer or new hard-interruption guarantee. Preserve the original refusal and cleanup even
   if inventory fails. Never execute P, a UUID/helper child or a privileged command.
   Read only the fixed bootstrap, the already selected P, fixed jq and the objects
   their existing checks would inspect. Do not read file contents outside those
   objects or list unrelated directories. For P, admit only its one physical
   installation prefix beneath `/usr/local/Cellar/`, `/opt/homebrew/Cellar/` or
   `/Library/Frameworks/Python.framework/Versions/`; unknown layouts give GAP.
   Bound reads to that prefix, the same system Python framework root, `/usr/lib/`
   and `/System/Library/`. Read only originally named system objects and their
   ancestors, not recursive system scans. Check each symlink step against these
   roots before following it; an outside edge gives GAP, not another read.
   Record symlink ACL as GAP; do not make absolute-path link ACL queries.
   Mach-O closure discovery gives a fixed GAP; do not add a parser or follow its
   load edges here. This inventory cannot claim complete closure or a host repair
   ready to execute. Collect metadata, raw ACL fields, layout and byte digests without
   interpreting UUIDs or claiming authentication. Keep the original traversal,
   object, file and ACL caps. Limit all inventory output to 16 MiB, each JSONL row
   and its final summary to 16 KiB within that total. Any error, change or exhausted
   cap marks the inventory incomplete. No host repair, fallback, qualification or
   altered acceptance follows from this diagnostic. The existing owner and all
   later real ACL/UUID/runtime checks remain unchanged. Require workflow SHA-256
   `95ae79c25bb5f89036793ef0f4017d1cf058c2fc0b167adca2440437688a9709`.
   Check its patch against the actual publication base with `git apply --check`.
   Keep the manifest entry exactly once; an existing correct entry needs no edit.
   Reconcile and continue the existing deterministic implementation branch.
3. Run the static checks below. Open the implementation amendment PR with
   `Closes #559`. Preserve the exact source/base, artifact blobs, workflow blob,
   full diff and check outputs for independent publication review. Required CI and
   the manager's protected merge complete workflow publication, producing main X.
4. Keep #558 on its existing branch and PR. Its existing plan covers the scope
   fixture repairs that authenticate the same physical Python and wire the existing
   concrete Darwin resolver into the assembler closure checks; no test change
   belongs in this publication. Normally merge X into #558 to obtain H; do not
   reset, rebase or force. Freshly review H/X, the full artifact chain and
   matching workflow blob, then freeze that source for full Linux and Mac proof.
   The manager binds actual run API, ref, event, actor, checkout and workflow before
   and after dispatch. The event SHA selects H; it is not approval.
5. Read the complete actual proof and cleanup, then obtain separate #541 G3.
   Protected merge requires the same reviewed H/X and green required CI. A base,
   source or workflow move needs fresh affected review and proof. #544 retains its
   own gates and explicit closed-ref/authority binding; it inherits no dispatch.

## Risks

The riskiest action is the later real root fixture. Preserve every approved host,
physical tool/runtime, source, account/UUID, supplementary-group, absence and
cleanup guard. Preserve the no-install boundary, contents-read permission, fixed
operator/ref and all limits. Host unavailability or unsafe prerequisites fail;
there is no replacement runtime, provider or weakened check.

A source literal in the published workflow would move main whenever H changes.
The approved immutable dispatch-SHA design avoids that cycle while requiring
fresh manager binding. It adds no arbitrary ref or command input.

The 100-minute cap is a scheduling reservation, not measured completion proof.
Timeout or cancellation can leave root cleanup incomplete. Record failure; cache
cleanup cannot establish root cleanup. Publication and fixtures cannot establish
native/CPU-wall qualification or admit production identities.

## Proof

For spec requirements 1–7, compare the complete workflow with the pinned bytes
and verify its SHA-256 with `shasum -a 256`. Compare with the approved baseline:
only the fixed selector, version output and prior trusted runtime check may
differ. That check includes the same system runtime's physical re-entry and its
bounded failure inventory.
Verify the manifest has exactly one entry and no unrelated edit. Run `git diff --check` and
`git diff --name-only` against the exact publication base; changes must stay within
the two allowed paths. Preserve both artifact hash links and both suite commands.

Parse YAML using the existing Ruby YAML library, then check every decoded shell
body and the embedded Python without executing them. Set `proof_dir` to an owned
private evidence directory; these files do not enter the repository:

```sh
ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' \
  .github/workflows/scope-genuine-macos.yml > "$proof_dir/workflow.json"
python3 - "$proof_dir/workflow.json" <<'PY'
import json, pathlib, subprocess, sys
workflow = json.loads(pathlib.Path(sys.argv[1]).read_text())
runs = [step['run'] for step in workflow['jobs']['genuine-scope']['steps']
        if 'run' in step]
assert len(runs) == 4
for body in runs:
    subprocess.run(['/bin/bash', '-n'], input=body, text=True, check=True)
for marker in ('PY_MAC_BOOTSTRAP', 'PY'):
    python_body = runs[0].split("<<'" + marker + "'\n", 1)[1].split('\n' + marker + '\n', 1)[0]
    compile(python_body, 'workflow-' + marker, 'exec')
entry = runs[0].split("mac_bootstrap_entry='", 1)[1].split("\n'\n", 1)[0]
compile(entry, 'workflow-system-bootstrap-entry', 'exec')
identity_body = runs[0].split("-c '", 1)[1].split("')\n", 1)[0]
compile(identity_body, 'workflow-selected-identity', 'exec')
PY
```

Prepare private guard controls for a non-root write ACL on P,
its ancestor and a startup module; changed held identity; an escaping or unknown
load path; and an unchanged safe layout. Refusal must occur before candidate
execution, including before sudo. Check those controls at the real Darwin boundary
when the approved host runs; synthetic syntax checks cannot prove ACL behavior.
Keep the guard byte-identical in the workflow and scope fixture. The workflow may
prefix its existing Python string with only the fixed private `failure_inventory`
definition. Keep the same `/usr/bin/python3 -I -S -B -c` invocation and inputs.
Only these four lines may differ inside entry, after its original refusal diagnostic
handler and before its unchanged bare `raise`:

```python
    try:
        failure_inventory()
    except BaseException:
        pass
```

Remove that one exact block and require byte equality with the scope entry.
Preserve its normal path, authentication predicates, original diagnostics and
`finally` cleanup. Do not copy the inventory into scope or expand its source for
this workflow-only diagnostic. In the owned guard controls, physical re-entry must
precede observer installation and keep the same owned PID. Preserve their
cancellation, wait, pipe and pending
cleanup checks. Check entry metadata refusal on owned fixtures for a write ACL,
changed held identity and an ACL query error before any candidate execution.
The actual fixed system runtime must also pass physical re-entry; a refusal
cannot count as the unchanged-layout positive. Preserve the complete original
two suites, their assertions and the native 149 controls.
Check the private inventory's outside-root and symlink rejection, byte/time/count
caps, original refusal preservation, no child execution, owned-fd cleanup and
stderr flag restoration.
These diagnostic controls do not replace the real entry positive or qualify a host.

For spec requirement 8, require the automatic repository `checks` and aggregate
`ci` on the publication PR's exact head/base, plus a separate full independent
review. Quick CI does not prove host execution. Preserve raw outputs and all
failures; a syntax pass does not prove provider availability or runtime safety.

After publication and fresh H/X review, the reviewed Mac workflow must run
`/bin/bash scripts/test/scope-qualification.test.sh` and then
`/bin/bash scripts/test/shadow-enforced.test.sh` in full. Keep its 100-minute job
cap and 5/5/35/50/5-minute steps, all product deadlines, controls and cleanup.
The manager also dispatches the original complete Linux matrix at H. Bind both
runs to H/X and read their full results for #541 G3; retain blocked or failed
qualification honestly. No fixture action or suite runs as part of this plan PR.
