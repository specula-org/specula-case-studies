# Instrumentation Guide (v3 Spec)

Guide for Phase 3 agent to adjust instrumentation when trace validation reveals issues.

## Architecture

Two-source tracing model — no source code patches:

1. **Client-side** (`src/trace_emitter.py`): Router events emitted from pymongo test code
2. **Server-side** (`src/parse_logs.py`): Coordinator events parsed from MongoDB LOGV2 logs

Events are merged in `parse_logs.py` with causal ordering correction.

## Event Sources

| Event | Source | Trigger |
|-------|--------|---------|
| `RouterStartTxn` | Client | After `session.start_transaction()` + operations |
| `RouterCommitTxn` | Client | Before `session.commit_transaction()`, commit type inferred |
| `DirectCommit` | Client | After single-shard or read-only commit returns |
| `SWSCommitReadOnly` | Client | After SWS commit returns (inferred) |
| `SWSCommitWrite` | Client | After SWS commit returns (inferred) |
| `RouterReceive2PCResult` | Client | After 2PC commit returns |
| `CoordDecideCommit` | Server log 22467 | "Going to write decision" with decision=commit |
| `CoordDecideAbort` | Server log 22467 | "Going to write decision" with decision=abort |
| `CoordPersistAndSend` | Server log 22469 | "Wrote decision" |
| `CoordSendDecisionToShard` | Server log 22481 | Per-shard "Coordinator going to send command" |
| `CoordFinish` | Server log 22474 | "Deleted coordinator doc" |

## ID Mapping

| MongoDB | TLA+ |
|---------|------|
| shard1RS | s1 |
| shard2RS | s2 |
| mongos | r1 |
| lsid+txnNumber | t1, t2, ... (sequential) |

## How to Add a New Field to an Event

### Client-side event
1. Edit `src/trace_emitter.py` — find the method (e.g., `router_commit_txn`)
2. Add the field to the `_emit({...})` dict
3. Pass the value from `src/test_scenarios.py` where the method is called

### Server-side event
1. Edit `src/parse_logs.py` — find the `log_id ==` block
2. Add the field to the `extra` dict in `make_event()`
3. Extract the value from `attr` (the LOGV2 attr dict)

## How to Add a New Event Type

1. In `src/trace_emitter.py`: add a new method following the pattern of existing ones
2. In `src/test_scenarios.py`: call the new method at the right point
3. In `src/parse_logs.py`: add a new `elif log_id == XXXX:` block if server-side
4. In `Trace.tla`: add `TraceNewEvent` action wrapper + add to `TraceNext`

## How to Move a Capture Point

Client events are emitted from `test_scenarios.py`. Moving them means changing which
line in the scenario function emits the event (e.g., before vs after `commit_transaction()`).

Server events are tied to LOGV2 log IDs. To move a capture point, change the `log_id`
matched in `parse_logs.py`. MongoDB LOGV2 IDs are stable across minor versions.

## Key LOGV2 IDs (MongoDB 8.x TXN component)

| ID | Message | Used for |
|----|---------|----------|
| 22465 | "Wrote participant list" | (not used in v3) |
| 22467 | "Going to write decision" | CoordDecideCommit/Abort |
| 22469 | "Wrote decision" | CoordPersistAndSend |
| 22474 | "Deleted coordinator doc" | CoordFinish |
| 22476 | "Coordinator going to send command" (prepare) | (not used in v3) |
| 22478 | "Received a vote to commit" | (not used in v3) |
| 22481 | "Coordinator going to send command" (decision) | CoordSendDecisionToShard |
| 22482 | "Coordinator received response from shard" | (not used, could replace 22481) |
| 51802 | Transaction summary | (not used in v3) |

## How to Rebuild and Re-run

```bash
cd case-studies/mongodb
bash harness/run.sh
```

No compilation needed — the harness is pure Python + Docker.

## Known Limitations

1. **SWS events are inferred**: SWSCommitReadOnly/SWSCommitWrite happen inside mongos.
   We emit them from the client after commit returns. Timestamps are client-side.
2. **Ticket counts not captured**: WiredTiger ticket counts would require
   `db.serverStatus()` calls. Currently omitted; ValidateTickets is optional.
3. **Single-member replica sets**: Majority commit is trivial (1 of 1).
4. **Clock skew**: Client (host) and server (Docker container) clocks may differ
   by a few ms. Causal fixup in `merge_and_write()` corrects ordering.
5. **CoordSendDecisionToShard uses 22481** (send), not 22482 (response received).
   The spec action models send+receive atomically, so either works.
