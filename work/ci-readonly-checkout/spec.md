---
intent-blob: f8cacc6bf48def691fb27e47e17b81ebe889d714
risk: high
drafted: 2026-10-24
allowed-paths:
  - work/ci-readonly-checkout/spec.md
---
# Spec: do not retain checkout credentials for read-only CI tests

Tracks #709. G1 is PR #710. This G2 permits planning only. A separately accepted
high-risk plan must land before workflow code changes.

## Requirements

| ID | Required outcome |
| --- | --- |
| R1 | The existing test checkout does not retain its authentication when tests start. |
| R2 | Preserve the checkout identity and the complete existing CI behavior. |
| R3 | Preserve the provenance reader's strict input and object-read boundaries. |
| R4 | Prove the candidate checkout effect and full test results from actual CI evidence. |
| R5 | Keep #701's resumed source proof and all final acceptance debts separate. |

## Design

### One checkout input

After the plan gate, the implementation changes only `.github/workflows/ci.yml`.
Add the following two lines to the existing `jobs.test.steps` checkout step:

```yaml
        with:
          persist-credentials: false
```

Keep `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` and its existing
comment unchanged. Keep the existing default shallow checkout and repository/ref
selection. Do not add another checkout, alter the `checks` job, or change another
workflow. No other implementation path or behavior belongs to this concern.

The triggers, `contents: read`, test-job condition, runner, fail-fast setting, six
shards, `run-all.sh` command, all test files and required `ci` aggregate remain
byte-identical. Removing the two added lines must reproduce the accepted base's
workflow bytes exactly. A different action version or checkout setting needs a
separate accepted change.

The setting asks the pinned action to stop retaining its checkout authentication.
Its actual behavior is an acceptance requirement, not an established fact here.
The same setting in a private macOS proposal is neither execution evidence nor
permission to dispatch that workflow.

### Preserve the safety boundary

The original #701 run `40076448634`, attempt 1, at head
`1a04df91eac6cad16ff372d41fefaca3d72c375e` remains failed. Its shard 6 checkout
retained credential includeIf entries; the accepted reader refused them before
object inspection or fetch. Keep that refusal and its raw evidence.

Do not change the include/includeIf refusal, origin identity, single bounded read,
actual object/tree/byte checks, or their tests. Do not read credential config or
tokens, replace HOME, construct another Git view, manually unset configuration,
whitelist include names, add a downloader/fallback or mask a failing test. The
pinned checkout's normal handling of its own authentication is the chosen owner.

The existing public same-origin read needs no new token model. If actual proof
needs new credentials, a new host/remote or wider access, stop that dependency.
Do not infer permission from a workflow result or from this setting.

## Acceptance evidence

The later plan must bind the exact candidate head/base and the existing
`ci.yml` workflow_dispatch run. Use the existing checkout/test logs and existing
predicates. Add no diagnostic framework, workflow step, test instrumentation or
permission. Retain full raw logs, exits, run/attempt/job IDs and hashes; summaries
or aggregate status alone cannot supply the following evidence.

| ID | Required actual evidence |
| --- | --- |
| E1 | Exact two-line workflow diff and unchanged remainder, including the pinned action and all six shard commands. |
| E2 | For each test job, the checkout log records the pinned action, `persist-credentials: false`, the intended repository/ref and actual checked-out candidate commit. |
| E3 | For each checkout, actual fetch/checkout records retain the original shallow depth and source identity. No alternate view, new remote or auth-bearing URL is introduced. |
| E4 | Before that job's Test suite step starts, the action's actual authentication lifecycle records show authentication was not retained. If temporary authentication was configured, its cleanup must finish before tests. Post-job cleanup alone is too late. |
| E5 | All six actual test jobs execute the unchanged suite and succeed. Preserve every applicable suite's complete output and status. The existing `checks` and required `ci` aggregate also succeed on that same candidate. |
| E6 | Every job's evidence is bound to its own checkout and ordering. One job's cleanup or pass cannot prove another job's state. No older failed run is relabelled as success. |

E4 must use affirmative lifecycle evidence available in the existing logs and any
applicable existing predicate output. A declared input, an absent error message or
the absence of a printed include name alone is insufficient. Record only existing
masked lifecycle commands and key names; never inspect or expose credential file
contents. If these sources do not establish the state, mark the proof incomplete
and return to the plan/evidence gate. Do not invent a pass or broaden this patch.

Automatic PR/main quick CI skips `jobs.test`; it cannot satisfy E2–E6. A local
workflow diff or syntax check cannot prove the action's runtime effect. Missing,
skipped, timed-out, failed or incomplete required evidence stays NOTRUN/failed and
blocks acceptance. Keep all original raw failures and their scope.

This concern's dispatched CI proves only its own exact checkout and existing
tests. It does not prove #701 P07, shared admission or that source checkpoint.
After the protected repair merge, preserve the original #701 branch/worktree and
normally merge fresh main. Rebind its source/artifact pins and head/base, obtain
fresh independent review, then run its separately authorized complete CI. Each
of its actual provenance readers still needs its own unchanged contract proof.
Do not reset, rebase, recreate the attempt, reuse a consumed GO or reset rounds.

## Out of scope

This G2 writes only its frontmatter path. It writes no plan or workflow code and
dispatches no CI. Independent plan, source review, exact-head required CI and
protected merge remain gates. The intended implementation is two added lines;
this size does not lower its high risk or remove any evidence requirement.

Keep #681's separate sandbox-receipt policy-set failure outside this concern.
Do not change #701's allowed paths, finish its G3 or close its intake. Preserve
#558/#541/#544/#681, I1, final caller, final-head Mac and same-head Linux proof,
restoration, native/recording, G3 and protected-foundation obligations. Existing
fixture CI grants no new genuine/native recording or #558 window.

No product installation, activation, real target, new network/credential scope,
admin action or production write. Preserve all old attempts, including the dirty
credential-export plan, frozen PR #183 and parked PR #412. CPU wall stays `NONE`,
native qualification `BLOCKED`, production `EMPTY`, automation `PAUSED`.

## Areas of concern

Risk is high because the change touches a workflow and checkout authentication.
The main risk is mistaking a configuration value or post-job cleanup for the state
when tests actually run. E2–E6 require that timing and the unchanged test behavior
to be proved on the candidate. No author accepts their own artifact or evidence.
