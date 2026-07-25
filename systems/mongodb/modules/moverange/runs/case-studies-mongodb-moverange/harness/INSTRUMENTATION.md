# MoveRange Harness Instrumentation Guide

## Architecture

No C++ source code patching. We capture trace events by parsing MongoDB's built-in structured logs (logv2) at debug verbosity level 3 for the migration component. A Python preprocessor (`src/preprocess_trace.py`) converts the structured JSON logs to NDJSON for TLA+ trace validation.

## Log ID to Trace Event Mapping

| Log ID | Source File | Trace Event | Emitting Shard |
|--------|------------|-------------|----------------|
| 23889 | migration_coordinator.cpp:148 | StartMigration | donor |
| 22017 | migration_source_manager.cpp:587 | DonorEnterCriticalSection | donor |
| 5899114 | migration_destination_manager.cpp:1857 | RecipientEnterCriticalSection | recipient |
| 22018 | migration_source_manager.cpp:764 | CommitOnConfigServer | donor |
| 23894 | migration_coordinator.cpp:235 | PersistCommitDecision | donor |
| 23895 | migration_coordinator.cpp:244 | CommitBumpRecipientTxn | donor |
| 23896 | migration_coordinator.cpp:273 | CommitDeleteRecipientRangeDel | donor |
| 6555800 | migration_coordinator.cpp:313 | CommitMarkDonorRangeDelReady | donor |
| 23903 | migration_coordinator.cpp:390 | CommitForgetMigration / AbortForgetMigration | donor |
| 23891 | migration_coordinator.cpp:173 | DecideAbort (when decision=abort) | donor |
| 23899 | migration_coordinator.cpp:329 | AbortPersistDecision | donor |
| 23901 | migration_coordinator.cpp:342 | AbortDeleteDonorRangeDel | donor |
| 23900 | migration_coordinator.cpp:353 | AbortBumpRecipientTxn | donor |
| 23902 | migration_coordinator.cpp:377 | AbortMarkRecipientRangeDelReady | donor |
| 4798510 | migration_util.cpp:357 | StepUp | any shard |
| 4798502 | shard_filtering_metadata_refresh.cpp:533 | RecoverMigration | any shard |
| 6180601 | range_deletion_util.cpp:146 | DeleteRange | any shard |

## Events NOT Traced (Silent Actions in Trace.tla)

| Trace.tla Action | Reason |
|-----------------|--------|
| SilentCommitReleaseCritSec | 5899108 fires on recipient; cross-shard clock skew causes ordering issues |
| SilentAbortReleaseCritSec | Same as above |
| SilentMajorityReplicateForget | System-level event — w:1 write replication has no explicit log |
| SilentDeleteRange | Range deleter can run between observed events |

## How to Add a New Field to an Event

1. In `preprocess_trace.py`, find the `elif lid == <log_id>:` handler for the event
2. Add the new field to the `ev = OrderedDict(...)` constructor
3. Extract the value from `attr` (the log entry's attribute dict)
4. Example: `ev["newField"] = attr.get("someAttr", "default")`

## How to Add a New Event Type

1. Find the MongoDB LOGV2 ID: `grep -rn "LOGV2" src/mongo/db/s/<file>.cpp`
2. Add the log ID to `RELEVANT_IDS` set in `preprocess_trace.py`
3. Add a handler in `pass2_emit_events`:
   ```python
   elif lid == NEW_ID:
       ev = OrderedDict([
           ("event", "NewEventName"),
           ("shard", source_shard),
           ("ts", ts),
       ])
   ```
4. Add the corresponding `TraceNewEvent` action wrapper in `Trace.tla`

## How to Move a Capture Point

Most events are captured from MongoDB's existing log statements. To change when an event is captured:

1. If there's an alternative MongoDB log at the desired point, change the log ID in `RELEVANT_IDS`
2. If no existing log exists at the desired point, you would need to add a `LOGV2` call in the C++ source and rebuild MongoDB (not recommended for this harness approach)

## How to Rebuild and Re-run

```bash
# Re-run full harness (starts cluster, runs tests, collects traces)
cd case-studies/mongodb-moverange && bash harness/run.sh

# Re-preprocess only (uses stored logs, no Docker needed)
python3 harness/src/preprocess_trace.py \
    --donor harness/logs/shard0.log \
    --recipient harness/logs/shard1.log \
    --output traces/basic_commit_single.ndjson \
    --after "2026-03-27T02:42:10.000+00:00" --before "2026-03-27T02:42:15.000+00:00"

# Run trace validation
cd spec && java -cp ../../lib/tla2tools.jar:../../lib/CommunityModules-deps.jar \
    tlc2.TLC Trace.tla -config Trace.cfg -deadlock \
    -DJSON=../traces/basic_commit_single.ndjson
```

## Shard Mapping

| MongoDB RS Name | TLA+ Name |
|----------------|-----------|
| shard0rs | s1 |
| shard1rs | s2 |

## Validated Traces

| Trace | Events | Description |
|-------|--------|-------------|
| basic_commit_single.ndjson | 10 | Single migration s1→s2, full commit path |
| abort_migration.ndjson | 18 | Commit + abort (failMigrationOnRecipient failpoint) |
| stepdown_recovery.ndjson | 42 | 4 migrations + 1 stepdown/stepup cycle |

## Spec Fixes Applied During Harness Generation

1. **Critical section ordering**: Swapped DonorEnterCriticalSection and RecipientEnterCriticalSection in base.tla. Code enters donor critical section first (migration_source_manager.cpp:559), then recipient (migration_destination_manager.cpp:1857). Spec originally had recipient first.

2. **String constants**: Changed Trace.cfg from model values to strings (`Shard = {"s1", "s2"}`) so JSON trace strings match TLA+ constants directly.

3. **Constrained TraceInit**: Added `configOwner` constraint from first trace event's donor field to eliminate impossible initial states.

4. **Silent action anti-preemption**: Added `logline.event # "DeleteRange"` guard to SilentDeleteRange to prevent it from consuming the range deletion task before the trace-driven DeleteRange can fire.
