# Instrumentation Guide: MongoRaftReconfig

Log-based instrumentation — no source code patches needed. Traces are produced by
parsing MongoDB LOGV2 structured JSON logs from a 5-node replica set cluster.

## Architecture

```
Docker (mongo:8 x5)  -->  LOGV2 JSON logs  -->  parse_repl_logs.py  -->  NDJSON traces
test_scenarios.sh    -->  client events     -->  merged into traces
```

**Two-source model:**
1. **Server-side** (log parsing): WinElection, CompleteDrain, Reconfig, ForceReconfig,
   SendConfig, UpdateTerms, RollbackEntries, RemoveNewlyAdded
2. **Client-side** (test script): ShutDown (container pause/stop)

## Event Sources

| Event | Source | LOGV2 ID | Key Attributes |
|-------|--------|----------|----------------|
| WinElection | Server log | 21450 | `term` |
| CompleteDrain | Server log | 21331 | `term` |
| Reconfig | Server log | 21392 + 21352 | `config` (full BSON) |
| ForceReconfig | Server log | 21392 (configTerm=-1) | `config` |
| SendConfig | Server log | 21392 (no 21352) | `config` |
| UpdateTerms | Server log | 21320 | `term` |
| RollbackEntries | Server log | 21592 | (none) |
| RemoveNewlyAdded | Server log | 4634504 + 21392 | `memberId` |
| ShutDown | Client script | N/A | (emitted by test) |
| ClientRequest | Silent action | N/A | Not traced; handled by Trace.tla SilentClientRequest |
| CommitEntry | Silent action | N/A | Handled by Trace.tla SilentCommitEntry |
| GetEntry | Silent action | N/A | Handled by Trace.tla SilentGetEntry |

## Server ID Mapping

| Container | Hostname | TLA+ ID |
|-----------|----------|---------|
| mongo-rs0-1 | mongo1:27017 | s1 |
| mongo-rs0-2 | mongo2:27017 | s2 |
| mongo-rs0-3 | mongo3:27017 | s3 |
| mongo-rs0-4 | mongo4:27017 | s4 |
| mongo-rs0-5 | mongo5:27017 | s5 |

## Event Classification (21392 disambiguation)

LOGV2 21392 ("New replica set config in use") fires for ALL config changes. The parser
classifies each occurrence:

1. **RemoveNewlyAdded**: Preceded by LOGV2 4634504 on same node
2. **ForceReconfig**: Config has `term == -1`
3. **Reconfig**: Preceded by LOGV2 21352 ("replSetReconfig command") on same node
4. **SendConfig**: None of the above (heartbeat propagation)

## State Tracking

The parser maintains per-node state (currentTerm, state, configVersion, configTerm,
drainMode) and enriches each event with post-state. State is updated from:

- 21450 (election): term from attr, state=PRIMARY, drainMode=TRUE
- 21331 (drain complete): drainMode=FALSE, configTerm=currentTerm
- 21392 (config change): configVersion + configTerm from config BSON
- 21320 (term update): currentTerm from attr
- 21355/21475 (stepdown): state=SECONDARY, drainMode=FALSE

## How to Adjust Instrumentation

### Add a new field to an event

1. Edit `parse_repl_logs.py`, find the `log_id == NNNNN` block for the event
2. Extract the field from `attr` dict: `value = attr.get("fieldName", default)`
3. Add to the `make_event()` call's extra dict: `{"fieldName": value}`
4. Update `Trace.tla` to reference `logline.event.fieldName`

### Add a new event type

1. Find the LOGV2 ID: `grep -rn "LOGV2.*NNNNN" artifact/mongo-src/src/mongo/db/repl/`
2. Add a new `elif log_id == NNNNN:` block in `parse_node_log()`
3. Update state tracking as needed
4. Call `make_event(ts_ns, "EventName", node_id, ns.to_dict(), extra)`
5. Add `TraceEventName` wrapper in `Trace.tla`

### Move a capture point (before → after)

Log-based instrumentation captures at the point MongoDB emits the log. To change
timing, use a different LOGV2 ID that fires earlier/later in the same code path.

### Rebuild and re-run

```bash
cd case-studies/mongodb-raftreconfig
bash harness/run.sh
```

No compilation needed — just restart the cluster and re-run scenarios.

## Log Verbosity

The Docker Compose sets `replication: {verbosity: 3}, election: {verbosity: 3}`.
At verbosity 3, MongoDB logs detailed election and replication events including
individual oplog applications (51801). Increase to 4-5 for more granular events.

## Known Limitations

- **SendConfig sender**: The sender of heartbeat-based config propagation is inferred
  heuristically (first node to have that config version). Not always accurate.
- **UpdateTerms peer**: The peer that caused a term update is not directly logged.
  Logged as `"peer": "unknown"`. Could be resolved by correlating with heartbeat logs.
- **ClientRequest**: Not traced from logs. Handled as silent action in Trace.tla.
- **CommitEntry**: Commit point advances are not directly logged with useful state.
  Handled as silent action.
- **GetEntry**: Individual oplog replication is logged (51801) but at extremely high
  volume. Handled as silent action for now.
- **Clock skew**: Container clocks should be synchronized by Docker, but minor skew
  may cause ordering issues in merged traces.
- **SendConfig term mismatch**: The spec's SendConfig action computes receiver's
  post-state term via `Max(term_sender, term_receiver)`, but the trace approximates
  it from the config's configTerm. TraceSendConfig does NOT validate post-state terms.
  This is a known limitation of log-based instrumentation (heartbeat term exchange
  isn't explicitly logged).
