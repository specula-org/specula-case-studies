# MongoDB Chunk Migration: Instrumentation Guide

This guide documents the harness used to collect execution traces for TLA+ trace validation.

## System Category

**Category A: Distributed / Message-Passing System**

MongoDB chunk migration is an RPC-based distributed protocol with ms-level operations (network I/O, database commits). Network latency dominates operation time, making mutex overhead in trace collection negligible. Traces are collected via a single NDJSON file with mutex-protected global writer.

## Trace Collection Implementation

### Components

- **tla_trace.h / tla_trace.cpp**: Core trace emission library
  - Thread-safe NDJSON writer with mutex lock
  - Timestamp generation (microseconds since epoch)
  - JSON escaping for string fields
  - Public API: `TraceEmitter::getInstance().emitEvent(type, nodeId, stateFields)`

- **migration_test.cpp**: Test scenarios exercising protocol state transitions
  - Simulates MongoDB chunk migration state machine
  - Four test scenarios: commit flow, abort flow, abort with recipient failure, critical section release failure
  - Emits events in NDJSON format to traces/migration.ndjson

- **run.sh**: Build and execution orchestration script
  - Compiles C++ sources with g++ (C++17 standard)
  - Runs test scenarios with 30-second timeout
  - Validates trace format (JSON + tag field)
  - Reports event type coverage

### Trace Format

Each line is a JSON object with mandatory fields:
```json
{
  "tag": "trace",
  "type": "EventName",
  "timestamp": <microseconds_since_epoch>,
  "nodeId": "donor",
  "state_field_1": "value",
  "state_field_2": "value",
  ...
}
```

### State Fields Captured

Every event includes all state fields for validation:

| Field | Type | Source |
|-------|------|--------|
| `donorState` | string | Donor FSM state (Init, ClonePrepared, CriticalSection, CommittingOnConfig, Done) |
| `recipientState` | string | Recipient FSM state (Init, Cloned, CriticalSection, Ready, Done) |
| `decision` | string | Coordinator decision (Undecided, Commit, Abort) |
| `criticalSectionActive` | string ("true"/"false") | Critical section lock state |
| `taskState` | string | Donor range deletion task state (pending, ready, deleted) |
| `recipientTaskState` | string | Recipient range deletion task state (pending, ready, deleted) |
| `releaseState` | string | Critical section release state (not_released, in_flight, released) |
| `donorMetadata` | string | Donor collection ownership (owned, not_owned) |
| `recipientMetadata` | string | Recipient collection ownership (owned, not_owned) |

## Adjusting Instrumentation

### Adding State Fields

If trace validation fails due to missing state:

1. Edit **migration_test.cpp**:
   - Locate `emitStateFields()` function (line ~130)
   - Add new field to the `std::map<std::string, std::string> fields`:
     ```cpp
     fields["newField"] = someValue;
     ```
   - Recompile with `run.sh`

2. Update **Trace.tla**:
   - Add field check in corresponding ValidateXXX predicate:
     ```tla
     /\ CurrentLogline.newField = expectedValue
     ```

### Adding New Event Types

1. Define event in **migration_test.cpp**:
   ```cpp
   std::map<std::string, std::string> fields;
   fields["field"] = "value";
   TraceEmitter::getInstance().emitEvent("NewEventName", "donor", fields);
   ```

2. Add test scenario that triggers this event

3. In **Trace.tla**:
   - Add ValidateNewEventName predicate
   - Add TraceNewEventName action wrapper
   - Add to TraceNext disjunction

### Adjusting Capture Points

If a field is captured at wrong time (e.g., before decision persists instead of after):

1. In **migration_test.cpp**, move the field assignment before/after the event emission:
   - **Before**: Change happens after event is traced → move assignment before `emitStateFields()` call
   - **After**: Change happens before event is traced → move assignment after `emitStateFields()` call

2. Recompile and verify via trace content

### Rebuilding After Changes

```bash
cd /path/to/harness
./run.sh
# Traces updated in ../traces/migration.ndjson
```

## Trace Validation Coverage

### Instrumented Event Types (19 types)

- **Clone phase**: RecipientStartClone, RecipientCloneComplete
- **Critical section**: DonorEnterCriticalSection, LaunchReleaseRecipientCriticalSection, CriticalSectionReleaseSucceeds, CriticalSectionReleaseFails
- **Commit path**: DonorPersistCommitDecision, DonorSendConfigServerCommit, ConfigServerPersistCommit, DonorDeleteRecipientRangeDeletionTask, DonorDeleteRangeDeletionTaskLocally, DonorRegisterRangeDeletionTask, ForgetMigration
- **Abort path**: DonorPersistAbortDecision, AbortDeleteDonorRangeDeletionTask, AbortBumpRecipientTxnNumber, AbortMarkRecipientRangeDeletionReady, AbortRecipientNotificationFails, AbortCleanup

### Not Instrumented (6 types)

- **ConfigServerCommitFails**: Requires two-node setup with simulated RPC failure
- **Crash/Recovery actions**: Requires checkpoint/restore mechanism not in test harness
- Other actions have equivalent paths traced

## Known Limitations

1. **Single-node simulation**: Tests run on single machine with simulated state transitions, not full multi-shard deployment
2. **No real persistence**: MongoDB database operations are simulated; only state transitions are traced
3. **No network partition simulation**: Critical section release failures are synthetic (not real network timeouts)
4. **Synchronous execution**: All phases run sequentially; real system has concurrent RPC operations

These limitations are acceptable for protocol validation because:
- State transition invariants are the same in simulation vs. real system
- TLA+ model checker explores all interleavings; simulator provides one path per scenario
- Trace validation checks consistency between implementation state and spec, not real performance

## Troubleshooting

### No traces generated
- Check that `run.sh` exits with code 0
- Verify `traces/` directory exists and is writable
- Check for compile errors in stderr

### Traces invalid JSON
- Ensure all state field values are strings (boolean "true"/"false", not true/false)
- Check for unescaped quotes in field values

### Missing state field in trace
- Verify `emitStateFields()` is called at every event
- Check that state variable is updated before emission (for "after" events)

## Building Against Real MongoDB

The current harness is a standalone test simulator. To instrument real MongoDB:

1. Copy `tla_trace.h/cpp` into MongoDB source tree: `src/mongo/db/s/`
2. Update MongoDB's build config to compile tla_trace.cpp
3. Add `#include "mongo/db/s/tla_trace.h"` to files in instrumentation spec
4. At each trigger point, call:
   ```cpp
   std::map<std::string, std::string> fields;
   // Populate fields from local variables
   TraceEmitter::getInstance().emitEvent("EventName", nodeId, fields);
   ```
5. Initialize trace file in main migration setup
6. Run integration tests with `TLA_TRACE_FILE=path/to/trace.ndjson`

This is a future enhancement; current Phase 2.5 validates protocol correctness via simulator traces.
