# TxnsCollectionIncarnation Instrumentation Guide

## Architecture

This harness uses **log parsing + client-side trace emission** (no C++ instrumentation needed).

- **DDL phase events**: Parsed from MongoDB LOGV2 structured logs (log ID `5390501`)
- **Router/Shard events**: Emitted by Python test code (`test_scenarios.py`)
- **Merge**: `parse_logs.py` combines both sources into final NDJSON traces

## Event Sources

### From Server Logs (DDL Phase Transitions)

Log ID `5390501` fires on every DDL coordinator phase transition (all coordinator types).
Found in: configsvr logs, shard logs (wherever the coordinator runs).

| Coordinator Type | Detected via `ctx` field containing | Phases mapped |
|---|---|---|
| CreateCollectionCoordinator | "CreateCollection" | enterWriteCriticalSectionOnCoordinator → AcquireLock, enterCriticalSection → EnterCS, commitOnShardingCatalog → CommitMetadata, exitCriticalSection → ExitCS |
| DropCollectionCoordinator | "DropCollection" | freezeCollection → AcquireLock, enterCriticalSection → EnterCS, dropCollection → CommitMetadata, releaseCriticalSection → ExitCS |
| RenameCollectionCoordinator | "RenameCollection" | checkPreconditions → AcquireLock, blockCrudAndRename → EnterCS, renameMetadata → CommitMetadata, unblockCRUD → ExitCS |
| MovePrimaryCoordinator | "MovePrimary" | clone → AcquireLock, enterCriticalSection → EnterCS, commit → CommitMetadata, exitCriticalSection → ExitCS |

**Required log verbosity**: `{sharding: {verbosity: 2}}` minimum (debug level 2).

### From Client-Side (test_scenarios.py)

| Event | Trigger | Fields |
|---|---|---|
| RouterSendTxnStmt | Before each pymongo operation in a transaction | txn, ns |
| ShardResponse | After each pymongo operation returns | shard, txn, responseStatus |
| RouterHandleOK | After all shard responses collected (OK) | txn, stmt |
| RouterHandleAbort | After error response detected | txn, stmt, responseStatus |
| RouterSendCommit | Before `session.commit_transaction()` | txn |
| RouterReceiveStaleError | On stale version error from shard | txn, responseStatus |
| RouterRetryFirstStatement | On retry after stale error | txn, ns, placementConflictTime |
| RouterAnnotateCreatedDatabase | After creating a database in txn | txn, dbName |

## How to Add a New Event

### Adding a new client-side event

1. In `test_scenarios.py`, call `emitter.emit("EventName", field1=val, field2=val)`
2. Place the call at the appropriate trigger point (before/after the operation)
3. Ensure field names match `Trace.tla`'s `logline.fieldName` references

### Adding a new DDL phase mapping

1. In `parse_logs.py`, add entry to `DDL_PHASE_MAP`:
   ```python
   ("coordinator_type", "phaseName"): ("TLAEventName", "ddlPhaseValue"),
   ```
2. The coordinator type comes from the `ctx` field of the log entry
3. The phase name comes from the `newPhase` attribute

### Adding a new log ID source

1. In `parse_logs.py`, add to `SUPPLEMENTARY_LOG_IDS` dict
2. Add parsing logic in the `parse_ddl_events()` function

## How to Rebuild and Re-run

```bash
# Full pipeline (start cluster, run tests, parse logs, produce traces):
cd case-studies/mongodb-txnscollincarnation
bash harness/run.sh

# Just re-run tests (cluster already up):
export MONGOS_URI="mongodb://localhost:27217"
export TRACE_DIR="$(pwd)/traces"
python3 harness/src/test_scenarios.py

# Just re-parse logs (logs already collected):
python3 harness/src/parse_logs.py

# Stop cluster:
cd harness && docker compose down -v
```

## Trace Format

Each NDJSON line is a flat JSON object:
```json
{"event": "RouterSendTxnStmt", "ts": "2024-01-01T12:00:00Z", "txn": "txn0", "ns": "test.coll1"}
```

The first event in the trace should be the first DDL phase (CreateTrackedAcquireLock).
The `Trace.tla` defaults handle ID mapping:
- `Shards = {s1, s2}` → `s1 = "shard0000"`, `s2 = "shard0001"`
- `NameSpaces = {ns1, ns2}` → `ns1 = "test.coll1"`, `ns2 = "test.coll2"`
- `Txns = {t1}` → `t1 = "txn0"`

## Debugging

### No DDL events found

1. Check log verbosity: `docker exec tci-configsvr mongosh --eval "db.adminCommand({getParameter: 1, logComponentVerbosity: 1})"`
2. Search raw logs: `grep 5390501 harness/logs/configsvr.log | head`
3. DDL coordinators may run on shard servers, not configsvr — check all log files

### Wrong namespace in DDL events

The namespace is extracted from the `ctx` field (e.g., `"CreateCollectionCoordinator-test.coll1"`).
If the format changes, update `get_namespace_from_ctx()` in `parse_logs.py`.

### Missing client events

Check that `test_scenarios.py` emits events at the right points. The `_client.ndjson` files
contain raw client-side events before merging with server-side DDL events.
