# Intent: first read-only self-host shadow run
Author: Yihan Zhu (operator). Status: draft.

## Problem

Every part of the shadow reproduction slice has only ever run on fixtures we
wrote for it. Step 7 of the roadmap asks for something else: take one real
ystack incident, reproduce it on ystack itself, read-only, and record what
happened. Nothing has done that. So we still do not know whether the slice
works on real history.

There is a real incident to use. At the operating-mode transition the mode
record changed, and the digest three tests had pinned for it drifted. That is a
plain file-digest incident: a known expected digest (the content before the
transition) at a known revision. I watched it happen.

## Proposed outcome

The first real self-host run happens on my own machine, and the repo keeps
durable evidence of it. Two outcomes are recorded: the incident reproduces at
the revision after the transition, and does not at the revision before it.
Every reference in the recorded identity is real — the real producer config,
the real model settings, the real prompt text, and a real minimal document
saying how a file-digest reproduction is verified, which has to be written
because none exists today. The evidence lands in a shape the later step-8 scope
evaluator and the maintenance loop can read as-is.

## Affected users and systems

Me, as the person who runs it and the person who reported the incident. The
ystack repo, both as the thing examined and as the place the evidence lives.
The shadow slice's read-only workflow and the local Git materializer. The two
later consumers of the evidence: the workflow-scope evaluator and the
maintenance loop.

## Constraints

Read-only throughout: the driver's read-only and no-network checks must hold.
No credentials. No model calls. No change to the driver, the materializer, or
the environment registry — registering an environment is its own change, and
assembling the materialization input is another. The source repository handed to
the run must be a scrubbed bare mirror the materializer accepts. Evidence is
committed under a new path the design stage names. Normal component conventions
apply. This will land near the ~300-line soft target because the evidence JSON
is committed; the spec should state the expected range.

## Open questions

Where should the committed evidence live, and does it become a required
manifest entry? Is the pre-transition no-change run worth committing, or is one
record enough? Who is the reporter in the incident record — me, or a
maintenance actor?
