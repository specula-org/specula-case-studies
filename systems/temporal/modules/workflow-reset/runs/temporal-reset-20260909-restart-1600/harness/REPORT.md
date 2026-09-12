# Trace harness validation report

Source: temporalio/temporal 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025, with the instrumentation recorded in evidence/manifest.json. Status: **8/8 functional scenarios and 8/8 complete traces pass**. This is trace acceptance and execution evidence, not exhaustive correctness.

Reproduce from .specula-output with: bash harness/run.sh

There are **619 tagged records, 53/64 base action types, and 42/42 matching durable-readback checkpoints**. TraceMatched and full post-state equality remain enabled. A negative control corrupting the last observed current pointer fails at that final record. No model-generated trace is counted as an implementation trace.

| Scenario | Records | Durable checkpoints | Result |
|---|---:|---:|---|
| base-commit-lost | 86 | 6 | Test and full trace pass |
| base-rejected | 82 | 6 | Test and full trace pass |
| can-chain | 51 | 4 | Test and full trace pass |
| competing-start | 90 | 6 | Test and full trace pass |
| missing-commit-lost | 88 | 6 | Test and full trace pass |
| missing-rejected | 95 | 6 | Test and full trace pass |
| response-loss | 63 | 4 | Test and full trace pass |
| same-replay | 64 | 4 | Test and full trace pass |

## Questions and actual outcomes

| Priority | Path checked | Observation | Remaining boundary |
|---|---|---|---|
| Q1 | Supported Start/CAN/public Delete creates missing current. Base and candidate writes each receive a definite rejection or a committed-but-response-lost injection; exact retry and shard reload follow. | Faults fire at the recorded SQL boundaries. Eventual healthy retry restores/retains a current run and the worker completes. The intentional base-first intermediate link is accepted. | OS process loss and remotely delayed completion are modeled but not trace-tested. |
| Q2 | Public exact replay after delivered or discarded success; CreateRequestId, Start-map entry, callback source argument and server/client response boundaries. | The original Start identity reaches Reset creation. Exact replay creates another run and terminates the previous Reset run; the response-loss hook fires once. | Callback delivery has zero configured callbacks; only its source argument is observed. |
| Q3 | A Start commits between base Update and candidate Create with I/O capacity 1; the first Create receives a real conditional rejection. | Retried Reset intentionally terminates/replaces the acknowledged competitor and completes. | Different-base concurrent resets and I/O=2 are model-only here. |
| Q4 | Explicit base through a surviving CAN successor with a public Signal; original source tokens and event provenance; final public history. | Eligible Signal is included exactly once. The independent source oracle and actual final history agree. | Update collision/control tests are separate code-analysis regression evidence; accepted-without-request, multiple pages and termination-buffer producers remain gaps. |
| Q5 | Public deletion of the newer current; later deletion of the original base after successful recovery; physical branch reference ranges; reload and worker completion. | The surviving Reset prefix remains available. Failed candidate registrations remain observable. | Cassandra row/range effects and ordinary-age scanner expiration are not trace-tested. Separate short-age probes show configuration-sensitive history loss; default age controls pass. |

## Model and observer corrections

The original complete traces all failed at the first Start commit. Validation corrected stored record versions, fork ancestry visibility, first-CAN-WFT scheduling, closed-run deletion versions, post-Reset WFT enablement, absent-successor frontiers, empty write slots, local event numbering after reapplication, partial-deletion descriptors, and shard renewal boundaries. The second round separates datastore request issuance from completion, preserves newer committed history against stale appends, and adds an independent CAN source oracle. All changes and source evidence are in spec/changelog.md.

The recorder self-blocking failure at the first pre-COMMIT probe and the rejected capture-only RangeID fix are preserved in the evidence. They are harness/model failures, not Temporal findings.

## Limits and upstream

File SQLite WAL/synchronous=normal, one shard and I/O=1; explicit test workers; real shard/cache reload, not an OS process restart. The raw traces and exact source/binary/config hashes are retained; testcore removes temporary database files after each run. Source entry points and updated capture details are in INSTRUMENTATION.md.

Current read-only upstream snapshots are in spec/output/validation-20260909/upstream and upstream-10926.json. PR 10926 documents intentional missing-current base-first behavior. PR 10673 is replication context. Issues 6375/6952, PR 6513 and issue 11958 remain distinct Update, Activity and callback context. No novelty or maintainer-confirmation claim is made.

Formal hunting results belong to spec/bug-report.md and spec/findings.json.
