# TxnsMoveRange Instrumentation Guide

How to adjust trace instrumentation for Phase 3 (spec validation).

## Approach

No C++ instrumentation needed. All events come from two sources:

1. **Client-side (pymongo)**: `src/trace_emitter.py` emits router and shard-inferred events
2. **Server-side (LOGV2)**: `src/parse_logs.py` extracts migration events from mongod logs

## Event Sources

| Event | Source | File |
|-------|--------|------|
| RouterSendTxnStmt | Client | trace_emitter.py:router_send_txn_stmt() |
| RouterHandleOk | Client | trace_emitter.py:router_handle_ok() |
| RouterHandleAbort | Client | trace_emitter.py:router_handle_abort() |
| RouterRetryOnStale | Client | trace_emitter.py:router_retry_on_stale() |
| CreateDatabase | Client | trace_emitter.py:create_database() |
| ShardRespond | Client (inferred) | trace_emitter.py:shard_respond() |
| StartMigration | Server (log 22016) | parse_logs.py:parse_migration_logs() |
| ConfigCommit | Server (log 23894) | parse_logs.py:parse_migration_logs() |
| ConfigCommitFail | Server (log 23899) | parse_logs.py:parse_migration_logs() |
| ReleaseCriticalSection | Server (log 6107802) | parse_logs.py:parse_migration_logs() |
| DonorStepDown | Server (log 5089001/23892) | parse_logs.py:parse_migration_logs() |
| DonorStepUp | Client (admin command) | test_scenarios.py |
| DonorRecovery | Server (log 23893) | parse_logs.py:parse_migration_logs() |

## How to Add a New Field to an Event

1. **Client-side event**: Edit the corresponding method in `trace_emitter.py`.
   Add the field to the dict passed to `self._emit({...})`.

2. **Server-side event**: Edit the handler in `parse_logs.py`.
   Extract the value from `attr` dict: `attr.get("fieldName", default)`.

## How to Add a New Event Type

1. **Client-side**: Add a new method to `TraceEmitter` class in `trace_emitter.py`.
   Follow the pattern of existing methods (call `self._emit()`).

2. **Server-side**: Add a new `elif log_id == NNNNN:` block in
   `parse_migration_logs()` in `parse_logs.py`.

3. **In test scenarios**: Add the emit call at the right trigger point in
   `test_scenarios.py`.

## How to Move a Capture Point

Client-side events are emitted from Python test code, so moving a capture
point means moving the `emitter.xxx()` call relative to the pymongo operation.

For server-side events, the capture point is determined by the LOGV2 log ID.
To capture a different point, find the relevant LOGV2 entry:
```bash
grep -rn "LOGV2" artifact/mongo-src/src/mongo/db/s/migration_source_manager.cpp | head -20
```

## How to Find MongoDB LOGV2 IDs

```bash
grep -rn "LOGV2" artifact/mongo-src/src/mongo/db/s/ --include="*.cpp" | grep -i "critical\|migrat\|commit"
grep -rn "LOGV2" artifact/mongo-src/src/mongo/s/transaction_router.cpp | head -30
```

## How to Rebuild and Re-run

No build needed — we use the stock `mongo:8` Docker image.

```bash
# Re-run everything:
cd case-studies/mongodb-txnsmoverange
bash harness/run.sh

# Re-run just test scenarios (cluster already running):
export MONGOS_URI=mongodb://localhost:27217
export TRACE_DIR=$(pwd)/traces
export HARNESS_DIR=$(pwd)/harness
python3 harness/src/test_scenarios.py

# Re-parse logs only:
python3 harness/src/parse_logs.py
```

## Docker Containers

| Container | Role | Port |
|-----------|------|------|
| txnmr-mongos | Router | 27217 (mapped to host) |
| txnmr-shard1 | Shard1 (shard1RS) | 27017 (internal) |
| txnmr-shard2 | Shard2 (shard2RS) | 27017 (internal) |
| txnmr-configsvr | Config server (configRS) | 27017 (internal) |

## Failpoints

| Failpoint | Container | Effect |
|-----------|-----------|--------|
| moveChunkHangAtStep5 | donor shard | Pauses migration at CS, before config commit |
| moveChunkHangAtStep4 | donor shard | Pauses migration before CS entry |
| migrationCommitNetworkError | donor shard | Simulates config commit failure |

Set via mongosh:
```javascript
db.adminCommand({configureFailPoint: "moveChunkHangAtStep5", mode: "alwaysOn"})
db.adminCommand({configureFailPoint: "moveChunkHangAtStep5", mode: "off"})
```

## Shard Mapping

| MongoDB | TLA+ |
|---------|------|
| shard1RS | s1 |
| shard2RS | s2 |
| testdb.items | ns1 |
| k1, k2, k3, k4 | k1, k2 (mapped in spec) |

## Verbosity Settings

Sharding + transaction verbosity 3 captures all needed events.
Set in docker-compose.yml via `logComponentVerbosity`.
