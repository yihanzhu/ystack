# Intent: Prepare exact candidate file content for the fixed verifier
Author: Codex (intent author). Status: draft.

## Problem

The materializer produces a checked candidate in a bare Git repository. The
separate fixed verifier needs candidate file content without access to source Git
storage. The existing repository snapshot, object inventory and single-blob check
do not supply that complete content view.

A checkout can apply filters, and an archive can change the represented content
through attributes. Neither proves an exact raw export merely by succeeding. A
caller-supplied digest or a same-owner chmod also cannot prove trusted preparation
or enforced immutability. This leaves a concrete dependency in Roadmap steps 2 and 7.

## Proposed outcome

Provide one inactive preparation component that takes a checked candidate through
an explicit trusted input boundary and exports its complete admitted regular blob
content into one fresh root owned by the preparation operation. Bind the actual
approved input and materializer result to the source and candidate identities,
every admitted path and mode, and the bytes really exported.

The output contains no Git metadata. Preparation executes no candidate content and
applies no filters, attributes, text conversion or submodules. It supplies a clear
preparation record and ownership handoff for the later supervisor. That record
states what this component actually checked and who produced it.

Prove the result with genuine exported files, independent expected byte and mode
identities, a complete output inventory and unchanged source. Malformed or
unsupported trees, real I/O failures and interruption before and after publication
must produce honest failure or completion evidence while preserving usable state.
Constructed JSON alone cannot satisfy this outcome.

## Affected users and systems

This serves the maintainers connecting the local Git materializer to the fixed
verifier in #314 and the accepted real sandbox boundary. It adds candidate-content
preparation and its restoration documentation. It does not complete the shadow
workflow, qualify an execution environment or close the separate verifier work.

Tracks #327. The current manager accepted its exact intake under the user-directed
continuing Roadmap program in comment 5667953460. This local draft is preparation
for independent G1 review, not an accepted design or implementation.

## Constraints

Keep the fixed verifier invocation, parent sandbox separation and resource
requirements, and original materializer and nofollow contracts unchanged. Reuse
supported operations where they fit; do not copy private nofollow, hashing or
exception code into a generic library to avoid defining the preparation boundary.

The design must bound the complete expanded content and admitted paths, modes and
entries. The verifier's one-file 1 MiB ceiling and existing tree-scan byte limits
are not whole-export budgets. Require exclusive output ownership and refuse
incomplete or mismatched results. Preserve all original usable state on refusal;
do not silently clean unrelated files, old attempts or missing evidence.

Local export establishes the candidate-to-files relation. Only the later real
supervisor handoff can establish read-only isolation, source inaccessibility and
protected execution receipts. Do not label this component's mutable local output
immutable or qualified, or treat untrusted declarations as provenance or authority.

Work stays in owned disposable local fixtures and existing development/CI. No VM
acquisition, installation, privileged setup, live runtime selection, credentials,
network expansion, real target, model invocation, deployment or activation is
included. Do not adopt #271, frozen #183, another dirty attempt or the old delivery
loop plan. A parent-contract conflict or newly privileged prerequisite must be
recorded as a dependency rather than bypassed. G2 and a separately accepted
high-risk plan precede implementation.

## Open questions

- What exact trusted input and preparation record bind the approved input,
  materializer result, checked candidate and complete exported content?
- How will paths, case collisions and aliases, executable modes, final and
  intermediate links, and existing output roots be handled without silent changes?
- What complete-tree limits and failure rules cover source changes, including
  same-inode mutation, real I/O errors, interruption and incomplete output?
- What publication and ownership handoff let the later supervisor enforce its
  separate boundary, and what evidence remains available when preparation fails?
