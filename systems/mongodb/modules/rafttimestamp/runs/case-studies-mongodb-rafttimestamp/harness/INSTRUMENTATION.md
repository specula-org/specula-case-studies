# Instrumentation Guide: MongoDB RaftMongoReplTimestamp

## Approach

This harness uses **log parsing** (not C++ instrumentation). MongoDB's LOGV2
structured JSON logs already contain replication state transitions. We:

1. Run a 3-node replica set via Docker with `replication: {verbosity: 3}`
2. Execute test scenarios via mongosh
3. Parse structured JSON logs to extract trace events
4. Output NDJSON traces for TLA+ validation

## Event Sources

| Trace Event | LOGV2 ID | Source File | Log Message |
|-------------|----------|-------------|-------------|
| BecomePrimary | 21331 | replication_coordinator_impl.cpp:1542 | "Transition to primary complete" |
| BecomePrimary / Stepdown | 21358 | replication_coordinator_impl_catchup.cpp:346 | "Replica set state transition" |
| Stepdown | 21402 | replication_coordinator_impl.cpp:5578 | "Stepping down from primary, new term" |
| Stepdown | 21475 | replication_coordinator_impl_heartbeat.cpp:498 | "Stepping down in response to heartbeat" |
| UpdateTerm | 21320 | replication_coordinator_impl.cpp:815 | "Updated term" |
| UpdateTerm | 21827 | topology_coordinator.cpp:3308 | "Updating term" |
| AdvanceCommitPoint / LearnCommitPoint | 6795400 | topology_coordinator.cpp:3233 | "Advancing committed opTime to new term" |
| AdvanceCommitPoint / LearnCommitPoint | 21826 | topology_coordinator.cpp:3240 | "Updating _lastCommittedOpTime" (DEBUG 2) |
| RollbackOplog | 21600 | rollback_impl.cpp:734 | "Marking to truncate..." |
| RollbackOplog | 21607 | rollback_impl.cpp:1220 | "Rollback common point" |
| RecoverTruncateOplog | 21557 | replication_recovery.cpp:973 | "Removing unapplied oplog entries" |
| RecoverTruncateOplog | 21544 | replication_recovery.cpp:584 | "Recovering from stable timestamp" |
| RecoverReplayOplog | 21545 | replication_recovery.cpp:590 | "Starting recovery oplog application" |
| RecoverSetTimestamps | 21536 | replication_recovery.cpp:180 | "Completed oplog application for recovery" |

## Events NOT Captured by Logs

These events are **not directly logged** by MongoDB and require silent actions
in Trace.tla or future C++ instrumentation:

| Trace Event | Why Not Logged | Workaround |
|-------------|---------------|------------|
| ClientWrite | No LOGV2 for oplog slot reservation | Silent action in Trace.tla |
| AppendOplog | Batch-level log (21230) not per-entry | Silent action |
| PersistOplog | No LOGV2 in `_setMyLastDurableOpTimeAndWallTimeForward` | Silent action |
| ApplyOplog | No LOGV2 in `_setMyLastAppliedOpTimeAndWallTimeForward` | Silent action |
| CloseOplogHole | No LOGV2 for visibility thread | Silent action |
| JournalFlusherCapture | No LOGV2 at flusher read point | Silent action |
| JournalFlusherFlush | Shares code path with PersistOplog | Silent action |
| ClientWriteWithWC | No specific LOGV2 before awaitReplication | Silent action |
| WriteConcernSatisfied | No LOGV2 in `_doneWaitingForReplication` | Silent action |
| PrepareTransaction | 22521 is a fail-point handler, not actual event | Silent action |
| CommitPreparedTxn | 22522 is a fail-point handler, not actual event | Silent action |

## How to Add a New Event

To capture a currently-silent event via log parsing:

1. Find the relevant LOGV2 call (or add one if none exists)
2. Add the LOGV2 ID to `EVENT_HANDLERS` in `parse_repl_logs.py`
3. Write a handler function that extracts state and returns an event dict
4. Re-run: `bash harness/run.sh`

## How to Add a New State Field

1. Add the field to `NodeState.snapshot()` in `parse_repl_logs.py`
2. Add extraction logic in `update_state_from_attrs()` for the new field
3. Update `ValidatePostState` in `Trace.tla` to check the new field

## How to Move a Capture Point (before → after)

Most events are already captured at the "after" point (state after the action).
To change timing:
1. Find the handler in `parse_repl_logs.py`
2. Move the `update_state_from_attrs()` call before/after the handler
3. Note: for log parsing, "before" vs "after" depends on when MongoDB logs

## How to Rebuild and Re-run

```bash
# Full re-run (restart cluster + tests + parse):
cd case-studies/mongodb-rafttimestamp
bash harness/run.sh

# Re-parse only (skip cluster restart):
python3 harness/src/parse_repl_logs.py harness/logs/ traces/my_trace.ndjson

# Parse a specific time window:
python3 harness/src/parse_repl_logs.py harness/logs/ traces/basic.ndjson \
    --after "2024-01-01T00:00:00" --before "2024-01-01T00:05:00"
```

## State Capture Levels

| Level | Fields | Used By |
|-------|--------|---------|
| Full (snapshot) | term, state, lastApplied, lastDurable, lastWritten, commitPoint, logLen | UpdateTerm, PersistOplog, ApplyOplog, LearnCommitPoint, WriteConcernSatisfied |
| Weak (snapshot_weak) | term, state | BecomePrimary, Stepdown, ClientWrite, CloseOplogHole, AdvanceCommitPoint, all recovery events |

## OpTime Mapping

MongoDB OpTimes: `{ts: Timestamp(seconds, increment), t: term}`
Spec OpTimes: `{term: T, index: I}`

Current mapping: `term = t`, `index = Timestamp.increment`.
This is a simplification — Phase 3 may need to build a full
timestamp-to-oplog-position mapping for accurate validation.

## Docker Ports

| Container | Internal | External |
|-----------|----------|----------|
| rts-mongo1 | 27017 | 27117 |
| rts-mongo2 | 27017 | 27118 |
| rts-mongo3 | 27017 | 27119 |

## Cleanup

```bash
cd harness/src && docker compose down -v
```
