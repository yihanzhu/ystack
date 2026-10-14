---
spec-blob: c6a1aff69d004e912801b04497a78c447dc318e8
drafted: 2026-10-14
---
# Plan: scope-genuine-macos-proof

## Files that change

| Implementation path | Change |
|---|---|
| `.github/workflows/scope-genuine-macos.yml` | Copy the exact approved workflow bytes. |
| `ci/required-files.txt` | Append that workflow path once; preserve existing entries. |

For the implementation PR: `review_size: standard`.

The accepted spec is high risk. This plan changes no product, test, runtime,
permission, provider or proof requirement. The approved package and its three
SHA-256 values are recorded in spec requirement 1 and the linked direct decision.

## Order of work

1. After independent plan review, required CI and protected plan merge, record
   fresh main as plan-base. Verify both artifact hash links and the unchanged high
   risk. Before first code, require that base or the normal fresh base acceptance.
   Create `ystack/impl/scope-genuine-macos-proof` from the accepted base; reconcile
   an existing attempt instead of replacing it.
2. Verify the approved package hashes. Copy its `workflow-candidate.yml` to the
   workflow path; require SHA-256
   `4135bf0a37fffb672e02ffeb436cd5dc5d5c7f02dd49aa1c2ef0a9074ea5cd4c`.
   Check the original two-path patch against the actual publication base with
   `git apply --check`. If only context moved, regenerate that patch context while
   preserving workflow bytes and all existing manifest entries. Append the one
   manifest entry. Do not apply the old patch blindly or change the workflow.
3. Run the static checks below. Open the two-path implementation PR with
   `Closes #559`. Preserve the exact source/base, artifact blobs, workflow blob,
   full diff and check outputs for independent publication review. Required CI and
   the manager's protected merge complete workflow publication, producing main X.
4. Keep #558 on its existing branch and PR. Normally merge X into it to obtain H;
   do not reset, rebase or force. Freshly review H/X, the full artifact chain and
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

For spec requirements 1–7, compare the complete workflow with the approved bytes
and verify its SHA-256 with `shasum -a 256`. Verify the manifest diff adds only its
single path. Run `git diff --check` and `git diff --name-only` against the exact
publication base; require only the two allowed paths. Preserve both artifact hash
links. Exact-byte comparison retains the original guards and two suite commands.

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
python_body = runs[0].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
compile(python_body, 'workflow-preflight', 'exec')
PY
```

For spec requirement 8, require the automatic repository `checks` and aggregate
`ci` on the publication PR's exact head/base, plus a separate full independent
review. Quick CI does not prove host execution. Preserve raw outputs and all
failures; a syntax pass does not prove provider availability or runtime safety.

After publication and fresh H/X review, the unchanged Mac workflow must run
`/bin/bash scripts/test/scope-qualification.test.sh` and then
`/bin/bash scripts/test/shadow-enforced.test.sh` in full. Keep its 100-minute job
cap and 5/5/35/50/5-minute steps, all product deadlines, controls and cleanup.
The manager also dispatches the original complete Linux matrix at H. Bind both
runs to H/X and read their full results for #541 G3; retain blocked or failed
qualification honestly. No fixture action or suite runs as part of this plan PR.
