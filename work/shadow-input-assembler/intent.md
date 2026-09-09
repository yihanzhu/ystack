# Intent: shadow input assembler
Author: Yihan Zhu (operator). Status: draft.

## Problem

The shadow reproduction driver cannot start a run without one materialization
input: the profile, the resolved profile, the manifests, and a stage request that
asks for the exact revision with no patch and no network.

Today the only thing that builds one is a test fixture builder, wired to fixture
ids and a fixture target. Everything it produces describes the fixture, not a
real repository, so there is no way to hand the driver an input for a real
revision.

The operator feels this now. Step 7 of the roadmap is a real self-host shadow
run, and this is the first thing in the way: the driver, the materializer, and
the validators are all in place, and the run still cannot begin.

## Proposed outcome

ystack ships a supported way to assemble that input for any real repository
revision, using the real default profile rather than fixture stand-ins. The input
is read-only by construction: no patch content, network denied, no paths opened
up. The same inputs always produce the same bytes, so a run can be re-checked
later. Bad inputs are refused with a clear reason instead of producing something
the driver rejects or, worse, quietly accepts.

## Affected users and systems

The operator, who wants the step-7 run. The shadow driver and the local Git
materializer, which consume the input unchanged. The default profile and its
manifests, read as data. This repository as the first real target, and any target
repository later.

## Constraints

- Portable shell on the pinned jq 1.6. No network, no credentials, no model
  calls. Everything is read as data.
- The output must pass the driver's read-only check and the materializer's own
  protocol, and be accepted by the core stage-request rules.
- Neither the driver nor the materializer changes. This adds a producer of their
  existing input, nothing more.
- Follow the component conventions: a focused test, a documentation section, an
  index row, a restore note, and manifest entries appended at the end of the
  required-files list.
- Keep it small — roughly three hundred lines is the soft target.

## Open questions

- Is the attempt timestamp supplied by the caller, or fixed?
- Should the assembler accept a profile other than the default?
- Should the profile be resolved fresh on every run, or pinned once?
