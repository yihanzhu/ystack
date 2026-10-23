# Current Roadmap minimal CI decision

Status: accepted for the current operator-led Roadmap program. Risk: high.

## Direct decision and scope

On 2026-09-21 the operator directly said:

> 我们能直接把ci都关掉变到最小吗，我们应该有一个pr就很快就能决定是不是要merge了吧

The current manager, Codex session `01a09ae7-9bd4-77f3-8c15-966143bebff4`, resumed
under the operator's direct September 21 handback in this session. The manager
interprets the request as direction to minimize automatic CI for all current Roadmap
pull requests, including code, so merge decisions are not held by unrelated full-suite
runs. It is not a claim that the operator approved a future patch byte for byte.

This direct decision also authorizes one bounded PR for the workflow, proof, restore
manifest and matching working-rule text. It replaces the normal separate artifact and
plan stages for this concern only. Issue #384 and manager comment `5769091075` bind
the accepted intake and build claim. Independent preflight comment `5769098412`
returned `PROCEED`. Final exact-head/base review and required CI remain mandatory.

## Required CI meaning

Automatic pull-request and main-push CI runs the existing checks, the portable core
schema guard, the pending-stage guard and the minimal-gate proof. The full test matrix
runs only through manual `workflow_dispatch`. The sole required check remains `ci`.
A green automatic `ci` means those quick checks passed; it does not mean the full
suite ran.

Every implementation still needs the complete integration, identity, authorization
and safety proof relevant to its accepted plan. Moving the unrelated matrix to manual
CI cannot turn a known relevant failure into a pass. Existing exception regression
tests remain required whenever that exception is exercised and in dispatched full CI.

Run and record the full matrix at these runnable milestones before dependent work is
accepted:

- self-host component completion covered by issue #264 and PR #373; and
- candidate, materialization and delivery integration covered by issue #327's
  dependencies.

These milestones do not declare the whole Roadmap complete or authorize installation,
activation, release, deployment, credentials, real targets or production actions.

## Preserved work and boundaries

PRs #381 and #383, their branches and evidence stay preserved pending explicit
reconciliation after this policy lands. Their old workflow contract must not be
merged over this one, and this decision does not cancel or silently adopt them. The
abandoned artifact-only fast-lane proposal remains scratch history.

Required independent review, exact head/base evidence, protected merge, the rounds
cap, one-manager invariant, read-only reviewers and all existing authority boundaries
remain. No branch-protection, permission, live sync, installation or activation change
is included.
