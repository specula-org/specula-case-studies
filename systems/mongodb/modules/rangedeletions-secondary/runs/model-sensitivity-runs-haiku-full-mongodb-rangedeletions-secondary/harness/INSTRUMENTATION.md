# Instrumentation Guide: MongoDB Range Deletions on Secondaries

This guide documents the instrumentation harness for Phase 2.5 trace collection. Use this if trace validation reveals issues and you need to adjust the instrumentation.

---

## Overview

**System**: MongoDB Range Deletion Service (C++)
**Category**: Category A (Distributed system, ms-level I/O)
**Trace Strategy**: Single NDJSON file with mutex-protected writer
**Timestamps**: Microseconds since epoch (monotonic clock)

---

## File Locations

### Trace Module
- **Header**: `harness/src/tla_trace.h` — Trace event definitions and emitter interface
- **Implementation**: `harness/src/tla_trace.cpp` — NDJSON writer, mutex protection

### Instrumentation Points
- **range_deleter_service.h** — Add include for tla_trace.h
- **range_deleter_service.cpp** — Primary lifecycle events (step-up, recovery)
- **range_deletion_util.cpp** — Task state transitions (insert, mark ready, mark processing, remove)
- **ready_range_deletions_processor.cpp** — Deletion execution (start, dequeue, begin, complete, shutdown)
- **range_deletion_task_tracker.cpp** — In-memory task registration (register, detect overlaps)

### Test Scenarios
- **harness/src/tla_trace_test.cpp** — Integration tests that generate traces

### Scripts
- **harness/apply.sh** — Applies instrumentation patches
- **harness/run.sh** — Main execution script: build, test, collect traces

---

## Trace Event Schema

Every trace event is NDJSON with this envelope:

```json
{
  "tag": "trace",
  "ts": <microseconds_since_epoch>,
  "eventName": "<ActionName>",
  "node": "<node_id>",
  "currentTerm": <number>,
  "replicaRole": "primary" | "secondary",
  "processorState": "idle" | "running" | "stopped",
  "persistentTaskState": {<taskId>: <state>},
  "inMemoryTaskExists": [<taskId>, ...],
  "recoveryInFlight": <boolean>,
  "recoveryOutcome": "unknown" | "complete" | "incomplete",
  "taskId": <number>,           // for task-specific actions
  "overlappingTasks": [...],    // for DetectAndWaitForOverlaps
  "tasksRecoveredInTerm": [...],// for CompleteRecoverySuccessfully
  "deletionProgress": "<state>", // for deletion phase actions
  "invalidatedRanges": [...],   // for InvalidateRange* actions
  "taskBeingDeleted": <number>  // for ShutdownProcessor mid-deletion
}
```

State field values:
- `processorState`: "idle", "running", "stopped"
- Task states in `persistentTaskState`: "pending", "ready", "processing", "deleted"
- `recoveryOutcome`: "unknown", "complete", "incomplete"

---

## How to Adjust Instrumentation

### Adding a New Trace Event

1. **Define the event in Trace.tla** (if not already there):
   ```tla
   TraceMyNewEvent ==
       /\ IsEvent("MyNewEventName")
       /\ MyNewAction
       /\ ValidatePostState
       /\ l' = l + 1
   ```

2. **Add emit call in source code** (e.g., in `range_deleter_service.cpp`):
   ```cpp
   #include "mongo/db/s/tla_trace.h"

   // At the trigger point:
   tla_trace::TraceEvent event;
   event.eventName = "MyNewEventName";
   event.node = "primary";
   event.timestamp = tla_trace::TraceEmitter::now();
   event.currentTerm = currentTerm;  // from replica set
   event.replicaRole = replicaRole;  // from service state
   event.processorState = processorState;  // from processor
   // ... populate other fields ...
   tla_trace::emitTrace(event);
   ```

3. **Rebuild and re-run**:
   ```bash
   cd /path/to/project
   bash harness/run.sh
   ```

### Moving an Instrumentation Point

If validation shows events out of order (e.g., state change before event), move the emit call:

**Before action** (use this for pre-conditions):
```cpp
// Capture state BEFORE the action
tla_trace::emitTrace(event);
// Now do the action that changes state
action();
```

**After action** (use this for post-conditions):
```cpp
// Do the action first
action();
// Capture state AFTER the action
tla_trace::emitTrace(event);
```

Check `instrumentation-spec.md` Section 2 for each action's designated trigger point.

### Capturing Additional State

If ValidatePostState fails because a field is missing:

1. **Add the field to TraceEvent struct** in `tla_trace.h`:
   ```cpp
   struct TraceEvent {
       // ... existing fields ...
       std::string myNewField;  // Add here
   };
   ```

2. **Set it in the emit call**:
   ```cpp
   event.myNewField = "value";
   ```

3. **Add validation in Trace.tla**:
   ```tla
   ValidatePostState ==
       LET logline == TraceLog[l] IN
       /\ IF "myNewField" \in DOMAIN logline
          THEN myNewField = logline.myNewField
          ELSE TRUE
       /\ ...
   ```

4. **Rebuild and re-run tests**.

### Handling State That's Hard to Access

If a state variable is only available under a specific lock or deep in a call stack:

**Option 1**: Capture what you can and use weak validation
- Set only the available fields (e.g., `currentTerm` and `replicaRole` only)
- Document this in `capture level: Weak` in the spec
- Phase 3 agent uses `ValidatePostStateWeak` in Trace.tla

**Option 2**: Thread the state through a callback
```cpp
// In service initialization:
auto onTraceHook = [](const TraceEvent& e) {
    // This closure has access to `this` and all private state
    event.processorState = _processor->state();
    tla_trace::emitTrace(event);
};

// Call from deep in the call stack:
onTraceHook(event);
```

---

## Debugging Trace Issues

### Traces Not Appearing
- Check that `tla_trace::initTrace()` is called early in the service startup
- Verify `tla_trace::shutdownTrace()` is called on service shutdown
- Ensure the trace file path is writable: `traces/trace.ndjson`

### Invalid JSON in Trace File
- Check tla_trace.cpp's `eventToJson()` for quoting errors
- Verify all field names match Trace.tla event names exactly
- Test with `cat traces/trace.ndjson | jq .` to validate JSON

### Events Not Matching Spec Actions
- Event names must match `Trace.tla` action names exactly (case-sensitive)
- Check `TraceLog[l].eventName = name` in Trace.tla for the expected name
- Compare against `instrumentation-spec.md` Section 2

### Out-of-Order State
- If ValidatePostState fails but state looks correct, the event may be emitted before/after the wrong point
- Check `instrumentation-spec.md` "Trigger Point" for each action
- Move emit call earlier/later in the code path
- Add `UNCHANGED` clauses in Trace.tla for intermediate operations

### Missing or Sparse Events
- List which event types appear in your traces: `grep -o '"eventName":"[^"]*"' traces/trace.ndjson | sort | uniq -c`
- For each action in `instrumentation-spec.md` that doesn't appear, either:
  1. Write a test scenario that triggers it (e.g., fault injection test)
  2. Document why it can't be triggered (e.g., requires hardware fault)
- Uncovered actions mean their spec handling isn't tested—consider if that's acceptable

---

## Testing the Instrumentation

### Quick Validation
```bash
# Collect traces
bash harness/run.sh

# Check trace format
head -5 traces/trace.ndjson | python3 -m json.tool

# Count events by type
grep -o '"eventName":"[^"]*"' traces/trace.ndjson | sort | uniq -c

# List all field names used
jq 'keys[]' traces/trace.ndjson | sort | uniq
```

### Full Validation (Phase 3)
```bash
cd spec/
python3 /path/to/run_trace_validation.py \
    --spec-file base.tla \
    --trace-file ../traces/trace.ndjson \
    --work-dir .
```

If validation fails, check the error message:
- `Trace line N: unmatched event <name>` → Event not in TraceNext
- `Temporal properties violated` → Event ordering doesn't match spec
- `State mismatch at line N` → ValidatePostState failed

---

## Performance Considerations

**Mutex overhead**: For Category A systems (ms-level operations), mutex serialization is negligible. If tracing causes deadlocks or slowness, consider:
- Moving trace calls outside critical sections
- Capturing state asynchronously (for non-critical fields)
- Increasing TRACE_FLUSH_INTERVAL (currently set to flush on every emit for reliability)

**Trace file size**: With ~50 events per scenario and rich state capture, expect ~20-50 KB per trace. Current test suite generates ~30 KB per run.

---

## Reference

- **Instrumentation Spec**: `../spec/instrumentation-spec.md` — Action-to-code mapping
- **Trace Spec**: `../spec/Trace.tla` — Expected event schema and validation rules
- **Base Spec**: `../spec/base.tla` — System model and invariants
- **Harness Generation Guide**: `../.claude/skills/harness-generation/guide.md` — Full methodology
