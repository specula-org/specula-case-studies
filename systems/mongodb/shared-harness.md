# MongoDB Shared Harness Reference

All MongoDB case studies share the same instrumentation approach. Read this before writing harness code.

## Approach: Log Parsing, NOT C++ Instrumentation

MongoDB's LOGV2 structured logs already contain state transition events. We parse logs into NDJSON traces — no need to recompile MongoDB.

## Docker Compose Templates

### Sharding cluster (for MoveRange, TxnsMoveRange, TxnsCollectionIncarnation, RangeDeletions, Session, ChunkMigration)

Use `mongo:latest` (8.2.6). Minimal config:
- 1 configsvr (1-node RS)
- 2 shards (1-node RS each, or 2-node for stepdown tests)
- 1 mongos
- `--setParameter enableTestCommands=1`
- `--setParameter logComponentVerbosity='{sharding: {verbosity: 3}}'`

### Replica set (for RaftMongo, MongoRaftReconfig, RaftMongoReplTimestamp)

- 3-node RS (for election/stepdown tests)
- `--setParameter enableTestCommands=1`
- `--setParameter logComponentVerbosity='{replication: {verbosity: 3}}'`

## Log Parser Template

Reuse this pattern from `case-studies/mongodb-rangedeletion/harness/src/parse_resharding_logs.py`:

```python
import json, sys, os

LOG_IDS = {}  # Load from log_ids.json

def parse(log_file, output_file):
    events = []
    with open(log_file) as f:
        for line in f:
            obj = json.loads(line.strip())
            log_id = obj.get("id")
            if log_id in LOG_IDS:
                ts = obj.get("t", {}).get("$date", "")
                attr = obj.get("attr", {})
                event = {
                    "tag": "trace",
                    "ts": ts,
                    "event": {
                        "name": LOG_IDS[log_id]["event"],
                        "state": {k: attr.get(v, "unknown") for k, v in LOG_IDS[log_id]["fields"].items()}
                    }
                }
                events.append(event)
    with open(output_file, 'w') as f:
        for e in events:
            f.write(json.dumps(e) + '\n')
    return len(events)
```

Each module provides a `log_ids.json`:
```json
{
    "5343001": {
        "event": "CoordTransition",
        "fields": {"newState": "newState", "oldState": "oldState"}
    }
}
```

## How to Find Log IDs

```bash
grep -rn "LOGV2" src/mongo/db/s/<module>/ --include="*.cpp" | grep -i "transition\|state\|phase"
```

## Test Scenarios

Use `mongosh` commands via `docker exec`. Common patterns:
- `sh.moveChunk(...)` — trigger migration
- `sh.reshardCollection(...)` — trigger resharding
- `db.adminCommand({configureFailPoint: "...", mode: "alwaysOn"})` — pause at specific point
- `db.adminCommand({replSetStepDown: 5, force: true})` — trigger failover

## What the Pipeline Agent Needs to Produce

1. `harness/docker-compose.yml` — reuse sharding or repl template above
2. `harness/src/log_ids.json` — module-specific log ID mappings
3. `harness/src/test_scenarios.sh` — module-specific test commands
4. `harness/src/parse_logs.py` — copy template, load log_ids.json
5. `harness/run.sh` — orchestrate: start cluster, init, run scenarios, collect logs, parse
6. `spec/Trace.tla` + `spec/Trace.cfg` — generated from base.tla (not reusable)
