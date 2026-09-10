# Intent: resolver trusted parent
Author: Yihan Zhu (operator). Status: draft.

## Problem

The profile resolver will only run when a trusted parent process starts it with a
fixed path, a clean environment, exactly the dependencies it was built against, and
the resource limits it was proven under. It refuses everything else on purpose. The
only parent that does this today lives inside a test, and the resolver's own accepted
spec says a production one is not implemented. So no real profile can be resolved
outside a test run. Step 7 of the roadmap, the first real self-host shadow run, needs
a real resolved profile, and the operator decided on DR-1 of #262 that the input
assembler must not fake one. That makes this the blocker in front of the step-7 run.
The operator feels it as: the resolver is built but unusable.

## Proposed outcome

ystack ships a supported way to resolve a profile through the real resolver, under
exactly the boundary the resolver's accepted spec already demands. It produces the
same bytes the test parent produces for the same request. It refuses, with a clear
reason, on any deviation: a helper or a jq that is not the pinned one, a runtime file
that has been made executable, or any environment value leaking in from the caller.

## Affected users and systems

The operator, who wants the step-7 run. The resolver and its bound dependencies, used
unchanged. The shadow input assembler and the shadow driver downstream, which need a
real resolved profile. This repository first, and any target repository later.

## Constraints

- The resolver runtime and its rules do not change. This adds the missing parent, not
  a new resolver behaviour.
- The launch boundary is a security control, so the change is high risk: plan-only
  pull request, merged by the operator.
- No network, no credentials, no writes outside the caller's own output. One
  accepted exception, decided as DR-2 on #271: on Darwin the resolver runtime,
  which this initiative leaves unchanged, itself runs `/usr/bin/git`
  (`scripts/lib/profile-resolution.sh:313-323` and `:711-714`), and that binary is
  the xcrun shim, which may write its `xcrun_db` cache in the per-user temp
  directory outside the caller's output. That write belongs to the unchanged
  runtime, not to the parent this initiative adds; the parent, the entry, the
  compiler, the helper and the copies write only inside the caller's output on
  both platforms, and on Linux the runtime does too. A later intake may move the
  runtime off `/usr/bin/git` on Darwin.
- Nothing in the shipped component may depend on the test tree.
- The pinned jq 1.6 and the native snapshot helper stay pinned by digest.
- Follow the component conventions: a focused test, a documentation section, an index
  row, a restore note, and manifest entries appended at the end.

## Open questions

- Should the parent accept only the default profile request shape, or any request the
  resolver accepts?
- How is the compiled parent distributed: built on first use, or a committed build
  recipe only?
- Should the shadow driver exercise the parent later, or does it stay a separate
  step the operator runs?
