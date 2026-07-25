# Instrumentation Guide: RangeDeletionsSecondaryNodes

## Approach

**Log parsing + test orchestration** (NOT C++ instrumentation).

Trace events come from two sources:
1. **Test orchestration markers** — the test script emits `TRACE:` lines at known state transitions
2. **MongoDB LOGV2 logs** — cross-checked for events that have dedicated log IDs

No MongoDB source code modifications are needed. The `mongo:latest` Docker image is used as-is.

## Trace Event Sources

| Trace Event | Source | Evidence |
|---|---|---|
| `init` | Test script — synthesized from test setup parameters | Test config |
| `SignalUpdate` | Test script — emitted after moveChunk completes | moveChunk triggers processing=true → op observer → invalidation |
| `BatchCommitted` | Test script — emitted after replication delay | Oplog batch commit inferred from moveChunk + replication wait |
| `QueryAdvanceSnapshot` | Test script — emitted before cursor.next() | getMore triggers acquireLocalCollectionOrView |
| `QueryKilled` | Test script + **Log 10016300** | `shard_role.cpp:1963-1968` — "Read has been terminated due to orphan range cleanup" |
| `QueryProceed` | Test script — emitted when cursor completes without error | Absence of log 10016300 |
| `StepUp` | **Log 11079600** | `range_deleter_service.cpp:168` — "Range deleter service is now up" |
| `RecoverTask` | **Log 7536600** | `range_deleter_service.cpp:368-373` — "Registering range deletion task" |

## Where to Adjust

### Test scenario: `harness/src/test_basic_kill.js`

- **Timing**: `sleep()` calls control replication delay. Increase if events arrive out of order.
- **Init values**: `trackerShardV`, `rdPreMigShardV`, `queryTracker` in the init TRACE line. Must match `spec/Trace.cfg` constants.
- **Batch size**: `cursor.batchSize(1)` ensures every `next()` triggers getMore → kill check. Increase if cursor pre-fetches prevent kill.
- **Feature flags**: `terminateSecondaryReadsOnOrphanCleanup` and `enableQueryKilledByRangeDeletionLog` set on the secondary via setParameter.

### Log cross-checker: `harness/src/parse_logs.py`

- **Add log IDs**: Edit the `LOG_IDS` dict. Format: `{log_id_int: "EventName"}`.
- **Adjust cross-check logic**: The `main()` function checks each trace event type. Add new `elif` blocks for new events.
- **Log file**: Collected from `rdsec-shard0sec` container logs (secondary).

### Docker cluster: `harness/src/docker-compose.yml`

- **Verbosity**: `logComponentVerbosity` in shard0 member command lines. Current: sharding.rangeDeleter=3, replication=2.
- **Members**: shard0 has 2-node RS (primary + secondary). Add more members by adding services.
- **Image**: `mongo:latest` (requires 8.2+ for `terminateSecondaryReadsOnOrphanCleanup`).

## How to Rebuild and Re-run

No build step needed (log parsing approach). To re-run:

```bash
cd case-studies/mongodb-rangedeletions-secondary
bash harness/run.sh
```

To re-run just the test (cluster already up):

```bash
docker cp harness/src/test_basic_kill.js rdsec-mongos:/tmp/test.js
docker exec rdsec-mongos mongosh --quiet --file /tmp/test.js 2>&1 | \
    grep '^TRACE:' | sed 's/^TRACE://' > traces/basic_kill.ndjson
```

## How to Add a New Event Type

1. Add a `print("TRACE:" + JSON.stringify({event: "NewEvent", ...}))` line in the test script at the right point
2. Add the event name to `spec/Trace.tla` as a new trace action wrapper
3. If the event has a MongoDB log ID, add it to `parse_logs.py:LOG_IDS`
4. Re-run the harness

## How to Move a Capture Point

Some events are timing-sensitive (e.g., QueryAdvanceSnapshot must be emitted before the getMore, not after). To adjust:

1. Move the `print("TRACE:...")` line in the test script
2. Verify the trace still passes validation:
   ```bash
   cd spec && java -jar ../../lib/tla2tools.jar -config Trace.cfg Trace.tla \
       -DJSON=../traces/basic_kill.ndjson
   ```

## Key MongoDB Source Locations

| File | Lines | What |
|---|---|---|
| `range_deleter_service_op_observer.cpp` | 164-168 | processing=true → invalidateRangePreservers |
| `metadata_manager.cpp` | 273-295 | Invalidation loop (early-break on shardPlacementVersion) |
| `shard_role.cpp` | 1939-1979 | Kill check at restore point (checkOrphanRangePreserverIsStillValid) |
| `range_deleter_service.cpp` | 127-133 | onStepUpBegin (step-up) |
| `range_deleter_service.cpp` | 206-256 | Recovery (_launchRangeDeletionRecoveryTask) |
| `collection_sharding_runtime.cpp` | 221-242 | UUID check + routing to metadata_manager |
