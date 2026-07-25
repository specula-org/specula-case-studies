# Instrumentation Guide: MongoDB Range Deletion Service

This guide explains how the trace instrumentation is implemented for the MongoDB range deletion service and how to adjust it if needed during Phase 3 (Trace Validation).

## System Overview

**System**: MongoDB Range Deletion Service  
**Category**: A (Distributed/Message-Passing)  
**Language**: C++  
**Key Files Instrumented**:
- `src/mongo/db/s/range_deleter_service.cpp` — Main service logic and recovery
- `src/mongo/db/s/tla_trace.h` — Trace emission library

## Instrumentation Architecture

### Trace Module: `tla_trace.h`

A thread-safe singleton that emits NDJSON trace events with the following interface:

```cpp
// Singleton accessor
tla_trace::Emitter::getInstance()

// Initialize trace file
.init(const std::string& filename)

// Emit trace event
.emit(const std::string& event_name,
      const std::string& node,
      int64_t term,
      const std::map<std::string, std::string>& fields = {})

// Close trace file
.close()
```

Each emitted event includes:
- `tag: "trace"` — Mandatory filter for trace validation
- `ts` — Real nanosecond timestamp (from `system_clock::now()`)
- `event` — Event name matching spec actions
- `node` — Node identifier (currently hardcoded as "n1")
- `term` — Replica set term
- Additional fields from the `fields` map

### Event Schema

Events are emitted as NDJSON with the following structure:

```json
{
  "tag": "trace",
  "ts": <nanosecond timestamp>,
  "event": "<action name>",
  "node": "<node id>",
  "term": <term number>,
  "<field1>": "<value1>",
  "<field2>": "<value2>"
}
```

## Instrumented Actions

### 1. OnStepUpComplete
**File**: `range_deleter_service.cpp:154-160`  
**Function**: `onStepUpComplete()`  
**Trigger**: After state transition to `READY_FOR_INIT`  
**Fields Emitted**:
- `service_state: "READY_FOR_INIT"`
- `recovery_started: true`

### 2. LaunchRangeDeletionRecoveryTask
**File**: `range_deleter_service.cpp:233-243`  
**Function**: `_launchRangeDeletionRecoveryTask()`  
**Trigger**: Before async recovery task launches on executor  
**Fields Emitted**:
- `service_state: "INITIALIZING"`

### 3. RecoveryCompletesFirstScan
**File**: `range_deleter_service.cpp:278-283`  
**Function**: `_launchRangeDeletionRecoveryTask()`  
**Trigger**: After completing first query for `{processing: true}` tasks  
**Fields Emitted**:
- `recovery_scan_state: "scanned_processing"`

### 4. RecoveryCompletesSecondScan
**File**: `range_deleter_service.cpp:311-316`  
**Function**: `_launchRangeDeletionRecoveryTask()`  
**Trigger**: After completing second query for non-pending tasks  
**Fields Emitted**:
- `recovery_scan_state: "scanned_all"`

### 5. RecoveryCompletes
**File**: `range_deleter_service.cpp:190-202`  
**Function**: `onStepUpComplete()` (in promise callback)  
**Trigger**: When recovery promise resolves and state transitions to `UP`  
**Fields Emitted**:
- `service_state: "UP"` or `"DOWN"` (depending on step-down)
- `recovery_outcome: "COMPLETE"` or `"INCOMPLETE"`

### 6. RegisterTask
**File**: `range_deleter_service.cpp:444-450`  
**Function**: `registerTask()`  
**Trigger**: After task is registered in `_rangeDeletionTasks`  
**Fields Emitted**:
- `task: <task UUID>`
- `registration_time: <time value>`
- `overlapping_with: []` (simplified, full list computed separately)

### 7. CompleteTask
**File**: `range_deleter_service.cpp:507-519`  
**Function**: `completeTask()`  
**Trigger**: After task is marked complete  
**Fields Emitted**:
- `task: <task UUID>`
- `task_completed: true`
- `service_state: "UP"`

### 8. OnStepDown
**File**: `range_deleter_service.cpp:373-378`  
**Function**: `_stopService()`  
**Trigger**: During service step-down  
**Fields Emitted**:
- `service_state: "DOWN"`

## How to Adjust Instrumentation

### Add a new field to an event

1. Locate the instrumentation point (file and line number above)
2. Find the `std::map<std::string, std::string> fields;` declaration
3. Add a new line: `fields["fieldname"] = "value";`
4. Rebuild: `bash harness/run.sh`

Example: To add `pending_flag` to RegisterTask:

```cpp
// In registerTask() around line 444
std::map<std::string, std::string> reg_fields;
reg_fields["task"] = rdt.getId().toString();
reg_fields["pending_flag"] = pending == TaskPending::kNotPending ? "false" : "true";  // ADD THIS
```

### Move a capture point

If a field is captured at the wrong time (before vs. after a state change):

1. Find the `emit()` call
2. Move it to the correct location (before/after the state change)
3. Verify the field values are captured correctly

Example: If `service_state` changes between capture and emit, move the `emit()` call:

```cpp
// WRONG: captured before state change
_state = kUp;
tla_trace::Emitter::getInstance().emit(...);

// CORRECT: captured after state change
_state = kUp;
tla_trace::Emitter::getInstance().emit(...);  // Correctly emits "UP"
```

### Add a new event type

1. Choose the trigger point in the code
2. Create a new event name (must match TLA+ spec action)
3. Insert emit call at that location:

```cpp
std::map<std::string, std::string> fields;
fields["key1"] = "value1";
fields["key2"] = std::to_string(numeric_value);
tla_trace::Emitter::getInstance().emit("NewEventName", "n1", term, fields);
```

### Handle concurrent threads

The trace module uses a `std::mutex` to serialize NDJSON writes. This works correctly for Category A systems (ms-level operations) where the mutex overhead is negligible.

If trace ordering becomes an issue, the INSTRUMENTATION spec in Phase 2 defines the expected ordering constraints. You may need to:

1. Capture timing information (intervals) instead of point events
2. Emit events in a deterministic order using timestamps
3. Use the timebox approach for concurrent sections

## Known Limitations

1. **Node ID**: Currently hardcoded as "n1" for single-node tests. For multi-node tests, update to use the actual node identifier from `repl::getMyHostName()`.

2. **Term parameter**: Some functions don't have direct access to the current term. Using `0` as a placeholder — ideally pass term through function parameters.

3. **Overlapping tasks**: The `overlapping_with` field is simplified to `[]`. A full implementation would need to iterate through `_rangeDeletionTasks.getOverlappingTasks()` and build the JSON array.

## Rebuilding After Changes

```bash
# Apply instrumentation (if reverted with clean.sh)
bash harness/apply.sh

# Run tests and collect traces
bash harness/run.sh

# Or rebuild MongoDB normally:
# (MongoDB build system details omitted for brevity)
```

## Trace Validation

Trace validation occurs in Phase 3 using the TLA+ spec at `spec/Trace.tla`. Each trace is validated for:

1. **Event format**: All events have required fields
2. **Event order**: Respects dependencies from the spec
3. **Post-state validation**: Captured state matches spec invariants

If validation fails, check:
- Event names match exactly (case-sensitive)
- Field names match the instrumentation spec (Section 2)
- Timestamps are real (epoch nanos, not sequential integers)
- Event order respects spec constraints

## Debugging Instrumentation Issues

### Trace file not created

```bash
# Check permissions
ls -la traces/
touch traces/test.ndjson  # Verify directory is writable

# Check emitter initialization
# Ensure emit() calls happen AFTER init()
```

### Missing events

- Verify the code path is executed (add logging before emit)
- Check for early returns or exceptions
- Ensure term value is correct

### Malformed JSON

- Verify field values don't contain unescaped quotes
- Check that map values are properly quoted (strings with `"`, numbers without)
- Use `jq` to validate: `cat traces/*.ndjson | jq . 2>&1 | head`

## References

- **Instrumentation Spec**: `spec/instrumentation-spec.md`
- **Trace Spec**: `spec/Trace.tla`
- **Base Spec**: `spec/base.tla`
- **Trace Module**: `harness/src/tla_trace.h`
