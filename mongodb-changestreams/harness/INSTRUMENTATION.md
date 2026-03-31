# Instrumentation Guide: MongoDB Change Streams

## Architecture

This harness uses a **test-harness-driven** approach (not C++ source instrumentation):
- A Docker sharded cluster (`mongo:8`) provides the real MongoDB implementation
- Python test scripts drive operations via `pymongo` and observe change stream events
- The `TraceEmitter` class emits NDJSON trace events matching the TLA+ `Trace.tla` schema

No MongoDB source code modifications are needed.

## File Layout

```
harness/
  docker-compose.yml      # 2-shard MongoDB cluster (configsvr, shard1, shard2, mongos)
  apply.sh                # Start + initialize cluster
  run.sh                  # Full pipeline: start, test, collect, validate
  validate.cfg            # TLC config with string constants for trace validation
  src/
    trace_emitter.py      # Core: NDJSON trace emission + spec clock tracking
    helpers.py             # Shared: connection, shard setup, shard identification
    test_basic_insert.py   # Scenario 1: cross-shard inserts + merge
    test_invalidation.py   # Scenario 2: drop → invalidation sequence
    test_resume.py         # Scenario 3: resume from saved token
```

## Instrumentation Points

### Per change stream event (from `cursor.next()`)

| Event Type | Trace Actions | Source |
|---|---|---|
| insert/update/delete | `GenerateEvent` + `AdvanceShardClock(others)` + `MergeNextNormal` | `test_*.py` via `emitter.generate_and_merge()` |
| drop/rename | `GenerateInvalidatingEvent` + `AdvanceShardClock(others)` + `MergeNextInvalidating` | `test_*.py` via `emitter.invalidate_and_merge()` |
| invalidate (synthetic) | `DeliverInvalidation` | `test_*.py` via `emitter.emit_deliver_invalidation()` |

### Test-harness-driven events

| Action | When | Code |
|---|---|---|
| `InitiateResume` | After closing and reopening cursor with `resume_after` | `emitter.emit_initiate_resume()` |
| `AdvanceShardClock` | Auto-emitted to advance idle shards past the merge point | `emitter._advance_others_past()` |

## How to Add a New Field to an Event

1. Open `trace_emitter.py`
2. Find the `emit_*` method for the event type
3. Add the field to the `state` or top-level dict in `self._emit()`
4. Example: to add `tokenVersion` to `GenerateEvent`:
   ```python
   self._emit("GenerateEvent", shard=shard, opType=op_type,
              state={"clusterTime": ct, "numEvents": ..., "tokenVersion": 2})
   ```

## How to Add a New Event Type

1. Add a new `emit_*` method to `TraceEmitter` in `trace_emitter.py`
2. Follow the pattern of existing methods (use `self._emit(event_name, ...)`)
3. Call it from the appropriate test scenario
4. Add the corresponding `Trace*` wrapper in `Trace.tla` if needed

## How to Move a Capture Point

The trace events are emitted from Python test scripts, not from MongoDB internals.
To change *when* an event is captured:
1. Move the `emitter.emit_*()` call in the test script
2. For "before" state: emit before the MongoDB operation
3. For "after" state: emit after the operation (current default)

## Shard Identification

Shards are identified by the document's shard key value:
- `x < 1000` → `s1` (shard1RS)
- `x >= 1000` → `s2` (shard2RS)
- Drop/rename events → `s1` (primary shard)

To change the split point: edit `SPLIT_POINT` in `helpers.py`.

## Clock Model

The emitter tracks TLA+ spec-internal clock state:
- `spec_clocks[s]` mirrors `shardClock[s]` after each traced action
- `SilentAdvanceShardClock` in `Trace.tla` is NOT needed when clocks are tracked correctly
- Before each `MergeNextNormal`, idle shards are advanced via `AdvanceShardClock` events
  so their HWM tokens don't block the merge

## Rebuild and Re-run

```bash
# From case-studies/mongodb-changestreams/
bash harness/run.sh              # Full pipeline
# Or individual steps:
bash harness/apply.sh            # Start cluster only
python3 harness/src/test_basic_insert.py  # Run one test
```

## Cleanup

```bash
docker compose -p cs-trace -f harness/docker-compose.yml down -v
```
