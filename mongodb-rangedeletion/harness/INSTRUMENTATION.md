# MongoDB Range Deletion Instrumentation Guide

## Architecture

This harness captures trace events from MongoDB's **built-in structured logging** (logv2) rather than patching source code. MongoDB already instruments all range deletion code paths with structured log entries at debug verbosity level 2.

**Approach**: Docker sharded cluster → verbose logging → log extraction → preprocessing to NDJSON

## How It Works

1. **Docker cluster** (`src/docker-compose.yml`): 2-shard + config server + mongos
2. **Verbose logging**: `logComponentVerbosity.sharding.rangeDeleter = 2`
3. **Test scenarios** (`src/test_*.js`): mongosh scripts that trigger `moveChunk` operations
4. **Log extraction**: `docker logs rd-shard0` captures structured JSON logs
5. **Preprocessor** (`src/preprocess_trace.py`): Maps MongoDB log IDs to TLA+ trace events

## Log ID → Trace Event Mapping

| MongoDB Log ID | Source File | Trace Event | Fields |
|---|---|---|---|
| 11420000 | `ready_range_deletions_processor.cpp:133` | StepUp / StepDown | processorState transition |
| 6834800 | `range_deleter_service.cpp:208` | RecoveryBegin | serviceState=kInitializing |
| 11079600 | `range_deleter_service.cpp:168` | RecoveryComplete | serviceState=kUp |
| 23890 | `migration_coordinator.cpp:152` | StartMigration | migrationId, namespace |
| 23893 | `migration_coordinator.cpp:198` | CommitMigration / AbortMigration | decision, migrationId |
| 6555800 | `migration_coordinator.cpp:313` | ClearPending | rangeDeletion (full task doc) |
| 11943500 | `range_deleter_service.cpp:407` | CheckOverlap | collectionUUID, range, overlapping_range |
| 7536601 | `range_deleter_service.cpp:438` | QueriesDrained | collectionUUID, range |
| 6872501 | `ready_range_deletions_processor.cpp:258` | ProcessorPickTask | collectionUUID, range |
| 6872504 | `ready_range_deletions_processor.cpp:350` | CompleteTask | collectionUUID, range |

## How to Add a New Field to an Event

1. Check if MongoDB already logs the field at the instrumentation point
2. If yes: update `extract_fields()` in `preprocess_trace.py` to extract it
3. If no: you must patch the MongoDB source code to add the field to the existing LOGV2 call

Example — adding `numOrphanDocs` to ProcessorPickTask:

```python
# In extract_fields(), add:
if "docsDeleted" in attr:
    fields["docs_deleted"] = attr["docsDeleted"]

# In pass2_emit_events(), in the 6872501 handler, add:
if "docs_deleted" in fields:
    ev["docsDeleted"] = fields["docs_deleted"]
```

## How to Add a New Event Type

1. Find the MongoDB log entry closest to the desired trigger point
2. Note the log ID (first argument to `LOGV2*` macro)
3. Add the log ID to `RELEVANT_IDS` set in `preprocess_trace.py`
4. Add a handler in `pass2_emit_events()` matching the log ID
5. Add the corresponding `Trace*` action wrapper in `Trace.tla`

## How to Move a Capture Point

The capture points are fixed by MongoDB's existing log statements. If you need to capture state at a different point:

1. **Check if another log entry exists** at the desired location (search for `LOGV2` in the source file)
2. **If yes**: Map to that log ID instead
3. **If no**: You must patch the MongoDB source to add a new `LOGV2` call:
   ```cpp
   LOGV2_DEBUG(99999999,  // Use a unique log ID
               2,
               "Custom trace point",
               "collectionUUID"_attr = collectionUuid,
               "range"_attr = redact(range.toString()),
               "customField"_attr = value);
   ```
   Then rebuild MongoDB and update the preprocessor.

## How to Rebuild and Re-run

```bash
# Re-run just the preprocessing (no cluster restart needed):
python3 harness/src/preprocess_trace.py harness/logs/shard0.log traces/basic_migration.ndjson \
    --after "2026-03-24T15:04:19" --before "2026-03-24T15:07:59"

# Re-run tests on existing cluster:
docker exec rd-mongos mongosh --port 27017 --file /scripts/test_basic_migration.js

# Full re-run:
cd case-studies/mongodb-rangedeletion && bash harness/run.sh

# Clean up Docker containers:
cd harness/src && docker compose down -v
```

## Events NOT Traced (Silent Actions in Trace.tla)

| Event | Reason | Silent Action |
|---|---|---|
| StartQuery / EndQuery | No range-deletion-specific log at query boundaries | SilentEndQuery |
| ClearMetadata / RefreshMetadata | No log in sharding runtime for these | SilentRefreshMetadata |
| TickClock | Clock is implicit in event timestamps | SilentTickClock |
| OverlapResolved | No distinct log; continuation of overlap wait | Inferred from CheckOverlap → QueriesDrained |

## ID Mapping

The preprocessor maps MongoDB UUIDs and ranges to TLA+ spec constants:

- **Migration IDs**: UUID → "M1", "M2", ... (order of first encounter)
- **Ranges**: Chunk ranges → "R1", "R2", ... (normalized from multiple log formats)
- **Task IDs**: (collectionUUID, range) → 1, 2, 3, ... (integer)

Range normalization handles two MongoDB log formats:
- String: `[{ _id: MinKey }, { _id: MaxKey })` → `MinKey..MaxKey`
- Dict: `{'min': {'_id': {'$minKey': 1}}, 'max': ...}` → `MinKey..MaxKey`

## Trace.cfg Constants

For trace validation, the Trace.cfg constants must be supersets of the IDs used in the trace:

```
CONSTANT
    Range = {"R1"}              \* Adjust to match trace
    Migration = {"M1"}          \* Adjust to match trace
    Task = {1}                  \* Adjust to match trace
    Query = {"Q1", "Q2"}        \* Not used in current traces
    Nil = Nil
    Overlap = {}
```

## Validated Traces

| Trace | Events | States | Invariants |
|---|---|---|---|
| basic_migration.ndjson | 10 | 11 | 7/7 pass |
| concurrent_migrations.ndjson | 17 | 18 | 7/7 pass |
