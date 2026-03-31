# MongoDB Trace Instrumentation Guide

## Architecture

MongoDB's source code is too large to instrument directly (~280K LOC C++). Instead, this harness uses a **real sharded MongoDB cluster via Docker** with verbose LOGV2 transaction logging, combined with client-side event emission from pymongo.

### Two event sources

1. **Client-side (router events)**: Emitted from `src/test_scenarios.py` via pymongo. These capture when the Python driver starts transactions, routes operations to shards, and commits/aborts. Since pymongo talks to mongos which does the actual routing, this captures real routing decisions.

2. **Server-side (shard events)**: Extracted from mongod LOGV2 structured JSON logs (verbosity 4 on TXN component). These capture transaction lifecycle on each shard: start, prepare, commit/abort, and 2PC coordinator events (participant list, votes, decision, doc lifecycle).

### ID Mapping

| MongoDB ID | TLA+ ID | Source |
|-----------|---------|--------|
| `shard1RS` | `s1` | Fixed in `GLOBAL_SHARD_MAP` |
| `shard2RS` | `s2` | Fixed in `GLOBAL_SHARD_MAP` |
| mongos | `r1` | Fixed |
| `lsid:txnNumber` | `t1`, `t2` | Per-scenario sequential |
| `key0..key99` | `k1`, `k2` | Mapped to which shard they route to |

## Instrumentation Points

### Client-side events (src/test_scenarios.py)

| Event | Trigger | File:Line |
|-------|---------|-----------|
| `RouterTxnStart` | After `session.start_transaction()` | test_scenarios.py:~253 |
| `RouterTxnOp` | After each `find_one`/`update_one` in transaction | test_scenarios.py:~265,~275 |
| `RouterTxnCoordinateCommit` | Before `session.commit_transaction()` (multi-shard) | test_scenarios.py:~281 |
| `RouterTxnCommitSingleShard` | Before `session.commit_transaction()` (single-shard) | test_scenarios.py:~331 |
| `RouterTxnAbort` | Before `session.abort_transaction()` | test_scenarios.py:~379 |

### Server-side events (parsed from mongod logs by src/parse_logs.py)

| Event | MongoDB Log ID | Log Message |
|-------|---------------|-------------|
| `ShardTxnStart` | 23984 (D4) | "New transaction started" |
| `ShardTxnCoordinateCommit` | 22465 (D3) | "Wrote participant list" |
| `RecvCommitVote` | 22478 (D3) | "Coordinator shard received a vote to commit from participant shard" |
| `WriteCommitDecision` | 22469 (D3) | "Wrote decision" (commit branch) |
| `WriteAbortDecision` | 22469/5047001 (D3/I) | "Wrote decision" (abort) / "Coordinator made abort decision" |
| `SendCommit` | 22474 (D3) | "Deleted coordinator doc" (inferred — commit delivery has no specific log) |
| `SendAbort` | 22474 (D3) | "Deleted coordinator doc" (inferred — abort delivery) |
| `ShardTxnPrepare` | 51802 (I) | "transaction" summary with `wasPrepared=true` |
| `ShardTxnCommit` | 51802 (I) | "transaction" summary with `terminationCause=committed` |
| `ShardTxnAbort` | 51802 (I) | "transaction" summary with `terminationCause=aborted` |

## How to Add a New Field to an Event

### Client-side
In `src/test_scenarios.py`, find the relevant `emitter.router_txn_*()` call and add the field to the `_emit()` dict in the `TraceEmitter` class.

### Server-side
In `src/parse_logs.py`, find the `log_id == XXXX` branch and extract the field from `attr`. Use `attr.get("fieldName")` to safely extract.

## How to Add a New Event Type

1. Add a new `elif log_id == XXXX:` branch in `parse_shard_logs()` in `parse_logs.py`
2. Call `_make_event()` with the new event name matching `Trace.tla`
3. If it's a client-side event, add a new method to `TraceEmitter` following the existing pattern

## How to Move a Capture Point

For server events, adjust the log ID mapping in `parse_logs.py`. MongoDB log IDs are stable across versions. Use `db.adminCommand({setParameter: 1, logComponentVerbosity: {transaction: {verbosity: 5}}})` to see all available log messages.

## How to Rebuild and Re-run

```bash
cd case-studies/mongodb
bash harness/run.sh
```

Or step by step:
```bash
cd case-studies/mongodb/harness
docker compose up -d          # Start cluster
bash init_cluster.sh          # Initialize replsets + sharding
cd ..
python3 harness/src/test_scenarios.py   # Run tests
docker cp mongo-shard1:/var/log/mongodb/mongod.log harness/logs/shard1.log
docker cp mongo-shard2:/var/log/mongodb/mongod.log harness/logs/shard2.log
python3 harness/src/parse_logs.py       # Parse logs -> traces
docker compose -f harness/docker-compose.yml down -v  # Cleanup
```

## Known Limitations

1. **Transaction ID reuse**: pymongo pools server sessions, so all scenarios in a single run share one `lsid` with different `txnNumber`. The parser handles this correctly.

2. **Cross-process timestamp ordering**: Server events and client events use different clocks. The merge logic uses causal ordering (RouterTxnOp before ShardTxnStart) rather than strict timestamp sorting.

3. **SendCommit/SendAbort inference**: MongoDB doesn't log a specific event when the coordinator sends commit/abort to participants. We infer this from the coordinator doc deletion (log ID 22474).

4. **ShardTxnPrepare/ShardTxnCommit from summaries**: These are extracted from the transaction summary log (51802), which fires at transaction completion. The exact moment of prepare within the 2PC flow is not separately logged at the participant level.

5. **Single-member replica sets**: The Docker cluster uses 1-member replica sets per shard (for simplicity). This means some 2PC behaviors (like vote delays, prepare acking) may differ from production multi-member replsets.
