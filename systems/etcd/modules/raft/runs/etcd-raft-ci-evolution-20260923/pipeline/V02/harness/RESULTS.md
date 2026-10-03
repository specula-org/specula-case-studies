# Harness results — incremental V02

Eleven fresh source scenarios emitted 5,778 events. All mapped event types and
required update witnesses were exercised; exact per-trace counts, hashes, and
branch witnesses are in `coverage.json`.

| Trace | Events | Result |
|---|---:|---|
| joint-autoleave.ndjson | 415 | full correspondence and normal invariants passed |
| joint-explicit.ndjson | 447 | full correspondence and normal invariants passed |
| joint-snapshot-recovery.ndjson | 399 | full correspondence and normal invariants passed |
| learner-vote.ndjson | 561 | full correspondence and normal invariants passed |
| membership-snapshots.ndjson | 1,575 | full correspondence and normal invariants passed |
| node-lifecycle.ndjson | 101 | full correspondence and normal invariants passed |
| outgoing-snapshot-restore.ndjson | 299 | strict correspondence passed; candidate property reproduced |
| partition-batching.ndjson | 734 | full correspondence and normal invariants passed |
| raw-elections-reads-recovery.ndjson | 762 | full correspondence and normal invariants passed |
| ready-intervening-output.ndjson | 132 | full correspondence and normal invariants passed |
| same-batch-replay.ndjson | 353 | full correspondence and normal invariants passed |

The outgoing-snapshot trace consumed all 299 states under
`TraceCorrespondence.cfg`. Under the normal property configuration it violated
only `JointSnapshotMemberAcceptance`, because a fresh snapshot names the
receiver only in `VotersOutgoing` while the live source guard checks only
incoming voters and current learners. This was handed to source confirmation as
MC-2.

Six `UpdateWitness` replays call the complete reference Actions and preserve
exact post-state equality. They reached the joint entry, automatic leave,
complete joint recovery, learner vote grant, post-Ready output preservation,
and outgoing-only snapshot rejection canaries with empty queues.

The observational patch was reversed after validation. The uninstrumented
`go test -count=1 ./...` suite passed; see
`logs/final-clean-tests.log`. Finite replay establishes correspondence for the
observed executions, not exhaustive safety or liveness.

