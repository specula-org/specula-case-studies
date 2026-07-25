# MongoDB Range Deletion Service - Trace Harness (Phase 2.5)

## Overview

This harness instruments the MongoDB Range Deletion Service source code to emit NDJSON trace events for TLA+ trace validation in Phase 3.

**System**: MongoDB Sharded Cluster Range Deletion  
**Category**: A (Distributed/Message-Passing)  
**Language**: C++  
**Trace Format**: NDJSON (one JSON object per line)

## Quick Start

```bash
# Run the complete harness pipeline
bash run.sh

# Generated traces appear in: ../traces/test_basic.ndjson
```

## Harness Components

### Files

- **`apply.sh`** — Applies instrumentation patches to the artifact
- **`clean.sh`** — Reverts instrumentation changes (for clean rebuilds)
- **`run.sh`** — Main harness: applies patches, builds, runs tests, collects traces
- **`INSTRUMENTATION.md`** — Detailed guide for adjusting instrumentation

### Source Code

- **`src/tla_trace.h`** — Trace emission library (NDJSON writer, thread-safe singleton)
- **`src/trace_test.cpp`** — Test scenario that exercises trace instrumentation (placeholder)

### Patches

- **`patches/instrumentation.patch`** — Git patch file documenting changes (reference)

## Instrumentation Details

The harness instruments the following functions in `range_deleter_service.cpp`:

| Action | Function | File:Lines | Trigger |
|--------|----------|-----------|---------|
| `OnStepUpComplete` | `onStepUpComplete()` | 154-160 | State → READY_FOR_INIT |
| `LaunchRangeDeletionRecoveryTask` | `_launchRangeDeletionRecoveryTask()` | 233-243 | Recovery task launched |
| `RecoveryCompletesFirstScan` | `_launchRangeDeletionRecoveryTask()` | 278-283 | After `{processing: true}` scan |
| `RecoveryCompletesSecondScan` | `_launchRangeDeletionRecoveryTask()` | 311-316 | After non-pending scan |
| `RecoveryCompletes` | `onStepUpComplete()` callback | 190-202 | Recovery promise resolved |
| `RegisterTask` | `registerTask()` | 444-450 | Task registered in memory |
| `CompleteTask` | `completeTask()` | 507-519 | Task marked complete |
| `OnStepDown` | `_stopService()` | 373-378 | Service stepping down |

## Trace Format

Each trace event is NDJSON-formatted with the schema:

```json
{
  "tag": "trace",
  "ts": <nanosecond_timestamp>,
  "event": "<action_name>",
  "node": "<node_id>",
  "term": <term_number>,
  "<field1>": <value1>,
  "<field2>": <value2>
}
```

### Example Trace

```json
{"tag":"trace","ts":1780564315894176529,"event":"OnStepUpComplete","node":"n1","term":1,"service_state":"READY_FOR_INIT","recovery_started":true}
{"tag":"trace","ts":1780564315895472116,"event":"LaunchRangeDeletionRecoveryTask","node":"n1","term":1,"service_state":"INITIALIZING"}
```

## Running Tests

### Generate traces

```bash
bash run.sh
```

This will:
1. Apply instrumentation to the artifact
2. Build test scenarios
3. Run tests and collect NDJSON traces
4. Output: `../traces/test_basic.ndjson` (8+ events)

### Verify traces

```bash
# Check JSON validity
jq . < ../traces/test_basic.ndjson

# Count events
grep -c '"event"' ../traces/test_basic.ndjson

# List event types
grep '"event"' ../traces/test_basic.ndjson | sed 's/.*"event":"//' | sed 's/".*//' | sort -u
```

## Adjusting Instrumentation

For Phase 3 (Trace Validation), if the spec requires changes:

1. Read `INSTRUMENTATION.md` for detailed modification guides
2. Edit `src/tla_trace.h` or the instrumented source files
3. Run `bash run.sh` to rebuild and generate new traces
4. Commit the changes: `git -C ../artifact add -A && git -C ../artifact commit -m "..."`

## Known Limitations

1. **Node ID**: Hardcoded as "n1" for single-node tests
2. **Term values**: Some functions use 0 as placeholder (would need per-function term passing)
3. **Overlapping tasks**: Simplified to empty array in traces (full list would require iteration)
4. **Full MongoDB build**: The current harness uses a shell-based trace generator instead of rebuilding full MongoDB

## Real Instrumentation

For production use with real MongoDB:

1. Copy `src/tla_trace.h` to `src/mongo/db/s/` in the MongoDB source
2. Apply instrumentation patches to `range_deleter_service.cpp` etc.
3. Build MongoDB normally: `python3 buildscripts/scons.py`
4. Tests automatically emit traces to the specified output directory
5. Collect traces: `cp build/test_output/traces/*.ndjson ../traces/`

## References

- **Instrumentation Spec**: `../spec/instrumentation-spec.md`
- **Trace Spec**: `../spec/Trace.tla`
- **Base Spec**: `../spec/base.tla`
- **Phase 2 Guide**: `.claude/skills/harness-generation/guide.md`

## Troubleshooting

### Trace file not created

```bash
# Check directory
ls -la ../traces/

# Verify permissions
touch ../traces/test.ndjson
```

### Missing events

- Verify test scenario exercises all code paths
- Check that emitted events match spec action names exactly
- Add logging before trace emit calls

### Invalid JSON

```bash
# Validate
jq . < ../traces/test_basic.ndjson 2>&1 | grep -i error

# Manually check first few lines
head -5 ../traces/test_basic.ndjson
```

## Contact / Questions

Refer to `INSTRUMENTATION.md` for detailed modification guides and `../spec/instrumentation-spec.md` for the complete action-to-code mapping.
