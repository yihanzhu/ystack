# Verification instructions: first self-host shadow run

This is the minimal, tool-free procedure for an independent reader to check the
one file-digest condition this evidence pair observes. It needs only Git and a
SHA-256 tool; it does not need jq, the shadow driver, or any other shipped
component. It is not the assembler's own `verification-instructions.txt`
output — see "Which reference serves which role" below.

## What is being checked

The failing check is `file-digest` at `config/construction-mode.json`,
evaluated at two revisions of this repository's own history:

- Post-transition revision: `0427390224c25147650f1bd3b6e43ed6911b97a7`
  ("Retire construction mode: the operating-mode transition (#261)").
- Pre-transition revision (its first parent, the baseline):
  `d3f6d525328838b9c2de819699e53d8909ab7a3f`
  ("Add the operator kit for the operating-mode transition (#260)").

Both incident records name the same expected digest, the pre-transition
raw-byte SHA-256 of `config/construction-mode.json`:

```
b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93
```

## Procedure

1. From a checkout of this repository (any clone containing both revisions
   above — the objects are ordinary reachable commits on `main`), read the raw
   blob bytes at each revision:

   ```sh
   git cat-file blob d3f6d525328838b9c2de819699e53d8909ab7a3f:config/construction-mode.json \
     | shasum -a 256
   git cat-file blob 0427390224c25147650f1bd3b6e43ed6911b97a7:config/construction-mode.json \
     | shasum -a 256
   ```

   Do not check out the tree and hash the working-copy file, and do not
   re-serialize or reformat the JSON before hashing: the check is over the
   exact committed bytes, whatever they are.

2. Compare each observed digest against the expected digest above.

## Interpreting the three outcomes

- **`reproduced`** (`check.failed-at-revision`): the observed digest at the
  named revision differs from the expected digest. This is the post-transition
  case: the transition changed the file, so the pre-transition digest no
  longer matches.
- **`no-change`** (`check.passed-at-revision`): the observed digest at the
  named revision equals the expected digest. This is the pre-transition
  control case: the file is exactly as it was when the digest was recorded.
- **`inconclusive`**: neither of the above was established — for example the
  path could not be read at that revision, the check kind has no runner, or
  the environment or duty evaluation did not reach a decidable state. An
  `inconclusive` result is retained for diagnosis only; it is never read as
  either of the two outcomes above and never closes the intake.

Nothing in this procedure runs a sandbox, materializes a candidate, or invokes
a model. It only reads two already-committed Git objects and compares two
SHA-256 digests.

## Which reference serves which role

This document is `shadow/evidence/self-host-transition/v1/verification-instructions.md`,
written by hand for a human reader who wants to check the one changed-file
condition without any of the shipped tooling. It is a new, freestanding
document; it is not read by any shipped script and no shipped schema names it.

It is distinct from each case's own `assembled/verification-instructions.txt`,
which is the shipped `shadow/v1/assemble-materialization-input.sh`'s own
emitted decision text for that run, retained unchanged in
`{pre,post}/assembled/`. That per-case file, not this one, is what each case's
`qualified-identity.json` binds by digest as `verification_instructions_ref`:
that field names the assembler's own accepted output, and rewriting it with
this document's bytes would misstate what the identity was resolved under.
This document has no `*_ref` field pointing at it and is not a shape any
shipped validator checks; it is retained here, and listed in
`checksums.json`, purely as human-readable, independently verifiable
documentation of the one condition the pair observes.
