# Harness results

5 real traces, 3,543 events. All 36 mapped noninitial event types are exercised. Full replay consumed every event with all canonical Trace.cfg invariants and TraceMatched enabled.

| Trace | Events | Full replay | Observation-only predicates |
|---|---:|---|---|
| membership-snapshots.ndjson | 1584 | passed | passed |
| node-lifecycle.ndjson | 110 | passed | passed |
| partition-batching.ndjson | 734 | passed | passed |
| raw-elections-reads-recovery.ndjson | 762 | passed | passed |
| same-batch-replay.ndjson | 353 | passed | passed |

All six invalid copies passed structural preflight and were rejected at their changed event by full post-state correspondence. Five also violated the expected unchanged base predicate in the separate observation-only sensitivity check.

| Invalid copy | Changed line | Independent predicate result |
|---|---:|---|
| advance-endpoint.ndjson | 14 | AckPreservation |
| durable-entry-missing.ndjson | 6 | No targeted predicate violation; correspondence rejection only |
| applied-command.ndjson | 240 | AppliedAgreement |
| read-context.ndjson | 69 | ReadCorrelation |
| remote-match-evidence.ndjson | 136 | ReplicationEvidence |
| learner-read-ack.ndjson | 1076 | ReadBasis |

Ordinary Go tests and race scenarios are separate from the TLC result aggregation. The test runner disables Go test caching with `-count=1`; inspect the retained test logs for actual execution outcomes.

`results.json` binds each selected result to its exact trace and base/Trace/config hashes and links the TLC log. Explicit `--batch` patterns can restrict a report to one validation round. `coverage.json` records branch counts and entry-size mappings.

The validation driver permits at most six isolated TLC instances, each with 8 GiB heap, 1 GiB direct memory and two workers: 54 GiB and 12 workers total. Temporary/state directories are run-local. A finite replay is not exhaustive bounded model checking or a liveness proof.

Remaining interface/interleaving coverage and oracle limits are listed in `CORRESPONDENCE.md`. Harness completion does not establish initialization or researcher model-quality acceptance. No CI promotion pointer, verdict or canonical property was altered.
