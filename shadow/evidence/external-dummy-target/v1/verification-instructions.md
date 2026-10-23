# Verification instructions: first external-target shadow run

This is the minimal, tool-free procedure for an independent reader to check the
one file-digest condition this evidence pair observes. It needs only Git and a
SHA-256 tool; it does not need jq, the shadow driver, or any other shipped
component. It is not the assembler's own `verification-instructions.txt`
output — see "Which reference serves which role" below.

## What is being checked

The failing check is `file-digest` at `src/greet.sh`, evaluated at two
revisions of the external dummy target repository `yihanzhu/ystack-dummy-target`
(repository id `repo.ystack-dummy-target`):

- Post-change revision: `e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e`
  ("Add -u uppercase option to greet.sh").
- Pre-change revision (its single parent, the baseline):
  `413a2f02a46ababa987039be65089e95c1916765`
  ("plan: greet-uppercase (round 2: Closes rationale, clean stderr capture)").

Both incident records name the same expected digest, the pre-change raw-byte
SHA-256 of `src/greet.sh`:

```
c5ddea8224ad2048d616968f37be42d3f59bcacf385464ca8ef559031274a41c
```

## Procedure

1. From any clone of `yihanzhu/ystack-dummy-target` containing both revisions
   above (both are reachable from `main` through the merge of pull request #4),
   read the raw blob bytes at each revision:

   ```sh
   git cat-file blob 413a2f02a46ababa987039be65089e95c1916765:src/greet.sh | shasum -a 256
   git cat-file blob e7da8f7b8f88c2a9cb4670dc453c5223a9c2d15e:src/greet.sh | shasum -a 256
   ```

   Do not check out the tree and hash the working-copy file: the check is over
   the exact committed bytes.

2. Compare each observed digest against the expected digest above.

## Interpreting the three outcomes

- **`reproduced`** (`check.failed-at-revision`): the observed digest at the
  named revision differs from the expected digest. This is the post-change
  case: the change rewrote the file, so the pre-change digest no longer
  matches (observed `9a3eecedc5f314cbc921ac8768b7651c3324afa355d42c90686ee8efb803dd90`).
- **`no-change`** (`check.passed-at-revision`): the observed digest at the
  named revision equals the expected digest. This is the pre-change control
  case, a control observation and not a second incident.
- **`inconclusive`**: neither of the above was established — for example the
  path could not be read at that revision, or the environment or duty
  evaluation did not reach a decidable state. An `inconclusive` result is
  retained for diagnosis only and never closes the intake.

Nothing in this procedure runs a sandbox, materializes a candidate, invokes a
model, or writes to the target repository.

## Which reference serves which role

This document is `shadow/evidence/external-dummy-target/v1/verification-instructions.md`,
written by hand for a human reader. Its exact bytes are what each case's
`qualified-identity.json` binds by digest as `verification_instructions_ref`.
It is distinct from each case's `assembled/verification-instructions.txt`,
the shipped assembler's own emitted text, which is retained unchanged for
provenance only; no `*_ref` field points at it.
