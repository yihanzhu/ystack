# Delivery loop first plan

This PR adds one inactive offline replay slice. It owns only these paths:

- `delivery/v1/replay.py`
- `scripts/test/delivery-replay.test.sh` and its test-owned fixtures
- `work/delivery-loop-first/plan.md`
- `README.md`, `RESTORE.md`, and `ci/required-files.txt`

The replay accepts an existing canonical local-materialization input and
caller-owned source, candidate, scratch, and private state directories. It calls
the existing local materializer, verifies one repo-relative candidate blob against
one supplied SHA-256, and journals identities and phase atomically. It never runs
candidate code or a user command string.

States are `materializing`, `verifying`, `review-wait`, `publish-wait`, `failed`,
and `completed-offline`. Review and publisher records are supplied offline test
observations. They name the exact request digest, candidate tree, and candidate
commit plus an actor, but do not authenticate anyone or authorize publication. The
commit is required because one tree can belong to two candidate commits. Missing
review remains waiting.

The slice is not profile selection, qualification, model execution, target access,
deployment, release, install, merge, or production publication. It is not the
whole delivery loop.
