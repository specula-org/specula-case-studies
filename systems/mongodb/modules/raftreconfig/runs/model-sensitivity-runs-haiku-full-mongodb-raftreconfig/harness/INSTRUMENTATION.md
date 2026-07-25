# Instrumentation Guide for MongoDB Replica Set Reconfig

## Overview

This document describes how to adjust instrumentation in the MongoDB replica set reconfiguration protocol for trace validation. The traces are collected from instrumented source code and validated against the TLA+ specification in `spec/Trace.tla`.

## Instrumentation Points

All instrumentation is located in the MongoDB replication module at:
```
src/mongo/db/repl/
├── replication_coordinator_impl.cpp  (primary reconfig logic)
├── check_quorum_for_config_change.cpp (quorum checking)
└── tla_trace.h                        (trace module)
```

### Key Code Locations

#### 1. ReConfigInitiate (Line 3626)
**File**: `replication_coordinator_impl.cpp`
**Code**: `_setConfigState(lk, kConfigReconfiguring);`
**Trace Event**: `ReConfigInitiate`
**Fields Captured**:
- `newVersion`: New configuration version
- `newTerm`: New configuration term (-1 for force reconfig)

**How to modify**: Add trace call after `_setConfigState`:
```cpp
mongo::tla_trace::emit_reconfig_initiate(
    "s1",  // node ID
    newConfig.getConfigVersion(),
    newConfig.getConfigTerm()
);
```

#### 2. QuorumStart (Line 3835)
**File**: `replication_coordinator_impl.cpp`
**Code**: `checkQuorumForReconfig(...)`
**Trace Event**: `QuorumStart`
**Fields Captured**:
- `configState`: Always "kConfigReconfiguring"

**How to modify**: Add trace call before quorum check:
```cpp
mongo::tla_trace::emit_quorum_start("s1");
```

#### 3. QuorumResponse (Lines 157-163, 238-322)
**File**: `check_quorum_for_config_change.cpp`
**Code**: `processResponse()` and `_tabulateHeartbeatResponse()`
**Trace Event**: `QuorumResponse`
**Fields Captured**:
- `voter`: Member ID who responded
- `votersResponded`: Count of voters who have responded

**How to modify**: Add trace call in `processResponse` for each response:
```cpp
mongo::tla_trace::emit_quorum_response(
    "s1",              // node conducting quorum check
    "s2",              // voter who responded
    _successfulVoterCount
);
```

#### 4. QuorumTimeout (timeout handler)
**File**: `check_quorum_for_config_change.cpp`
**Trace Event**: `QuorumTimeout`
**Fields Captured**:
- `configState`: Always "kConfigReconfiguring"

**How to modify**: Add trace call when quorum check times out:
```cpp
mongo::tla_trace::emit_quorum_timeout("s1");
```

#### 5. ReConfigPersist (Line 3842-3878)
**File**: `replication_coordinator_impl.cpp`
**Code**: `_externalState->storeLocalConfigDocument(...)`
**Trace Event**: `ReConfigPersist`
**Fields Captured**:
- `newVersion`: Configuration version being persisted
- `newTerm`: Configuration term being persisted

**How to modify**: Add trace call after disk write begins:
```cpp
mongo::tla_trace::emit_reconfig_persist(
    "s1",
    newConfig.getConfigVersion(),
    newConfig.getConfigTerm()
);
```

#### 6. JournalFlush (Line 3878)
**File**: `replication_coordinator_impl.cpp`
**Code**: `JournalFlusher::get(opCtx)->waitForJournalFlush();`
**Trace Event**: `JournalFlush`
**Fields Captured**:
- `persistedVersion`: Version now on disk
- `persistedTerm`: Term now on disk
- `inMemoryVersion`: In-memory version
- `inMemoryTerm`: In-memory term

**How to modify**: Add trace call after journal flush completes:
```cpp
mongo::tla_trace::emit_journal_flush(
    "s1",
    persistedVersion,
    persistedTerm,
    _rsConfig.configVersion(),
    _rsConfig.configTerm()
);
```

#### 7. ReConfigInstall (Line 3881-3882)
**File**: `replication_coordinator_impl.cpp`
**Code**: `_finishReplSetReconfig(...)`
**Trace Event**: `ReConfigInstall`
**Fields Captured**:
- `newVersion`: Version being installed in-memory
- `newTerm`: Term being installed in-memory

**How to modify**: Add trace call at the start of `_finishReplSetReconfig`:
```cpp
mongo::tla_trace::emit_reconfig_install(
    "s1",
    newConfig.getConfigVersion(),
    newConfig.getConfigTerm()
);
```

#### 8. CrashRecovery
**File**: `replication_coordinator_impl.cpp` (startup recovery path)
**Trace Event**: `CrashRecovery`
**Fields Captured**:
- `persistedVersion`: Version recovered from disk
- `persistedTerm`: Term recovered from disk
- `inMemoryVersion`: In-memory version after recovery
- `inMemoryTerm`: In-memory term after recovery

**How to modify**: Add trace call after crash recovery completes:
```cpp
mongo::tla_trace::emit_crash_recovery(
    "s1",
    persistedVersion,
    persistedTerm,
    inMemoryVersion,
    inMemoryTerm
);
```

#### 9. Heartbeat (Line 4000-4100)
**File**: `replication_coordinator_impl.cpp`
**Trace Event**: `Heartbeat`
**Fields Captured**:
- `dest`: Destination server ID
- `inMemoryVersion`: Current config version
- `inMemoryTerm`: Current config term

**How to modify**: Add trace call when sending heartbeat:
```cpp
mongo::tla_trace::emit_heartbeat(
    "s1",
    "s2",  // destination
    _rsConfig.configVersion(),
    _rsConfig.configTerm()
);
```

#### 10. AdvanceCommit
**File**: `replication_coordinator_impl.cpp`
**Trace Event**: `AdvanceCommit`
**Fields Captured**:
- `optime`: Committed optime value
- `inMemoryVersion`: Current config version
- `inMemoryTerm`: Current config term

**How to modify**: Add trace call when advancing committed optime:
```cpp
mongo::tla_trace::emit_advance_commit(
    "s1",
    optimeValue,
    _rsConfig.configVersion(),
    _rsConfig.configTerm()
);
```

## Adding a New Event Type

If you need to add a new event type for a previously untested code path:

1. **Update Trace.tla**: Add a new action wrapper in the `TraceEvent_*` section
2. **Update instrumentation-spec.md**: Document the new action, code location, and trigger point
3. **Add to tla_trace.h**: Implement `emit_*_event()` function following the existing pattern
4. **Instrument code**: Call the new emit function at the trigger point in the source code
5. **Test**: Run `harness/run.sh` to generate traces and verify the event appears

## Modifying a Capture Point

To move an instrumentation point from before to after an action (or vice versa):

1. **Update instrumentation-spec.md**: Change the "Trigger point" note
2. **Locate the code**: Find the function in `replication_coordinator_impl.cpp` or `check_quorum_for_config_change.cpp`
3. **Move the trace call**: Remove from current location, add to new location
4. **Verify state capture**: Ensure all fields are still accessible at the new location
5. **Rebuild and test**: Run tests and verify the new trace structure is valid

### Example: Moving ReConfigPersist before disk write

Before:
```cpp
status = _externalState->storeLocalConfigDocument(...);  // Line 3859
mongo::tla_trace::emit_reconfig_persist(...);            // Trace call after
```

After:
```cpp
mongo::tla_trace::emit_reconfig_persist(...);            // Trace call before
status = _externalState->storeLocalConfigDocument(...);  // Line 3859
```

## Rebuilding After Changes

After modifying instrumentation:

1. **Apply patches**: `bash harness/apply.sh`
2. **Build MongoDB**: Follow the MongoDB build process (typically `scons`)
3. **Run tests**: `bash harness/run.sh` to collect new traces
4. **Validate traces**: Check that trace files have the expected format and events

## Server ID Mapping

Current implementation uses node IDs like "s1", "s2", "s3". If you need to change the mapping:

1. **Update tla_trace.h**: Modify `normalize_server_id()` function to use a different mapping strategy
2. **Test**: Run `harness/run.sh` and verify trace `nid` fields match expectations
3. **Update Trace.tla**: If node names change, update the `Server` constant in the spec

## Trace Format Validation

Each trace event must:
- Include `"tag": "trace"` (required by Trace.tla)
- Include `"ts"`: Real timestamp (epoch milliseconds)
- Include `"event"` object with:
  - `"name"`: Event type matching Trace.tla action name (e.g., "ReConfigInitiate")
  - `"nid"`: Node ID (e.g., "s1")
  - Additional fields as specified in instrumentation-spec.md

Example valid event:
```json
{"tag": "trace", "ts": 1780566059040, "event": {"name": "ReConfigInitiate", "nid": "s1", "newVersion": 2, "newTerm": 0}}
```

## Debugging Trace Validation Failures

If trace validation fails (Trace.tla reports invariant violations or action mismatches):

1. **Check event names**: Verify they match exactly (case-sensitive)
2. **Check required fields**: Ensure all fields specified in ValidatePostState are present
3. **Check field types**: Numbers should be numbers, not strings
4. **Check state values**: Verify post-action state matches the validation predicate
5. **Check event order**: Trace events must follow legal action sequences in the spec
6. **Check state capture timing**: For multi-step actions, capture pre-state or post-state as specified

For each failure, update the instrumentation point and re-run tests.

## Performance Considerations

- Trace emission uses a global mutex to ensure thread safety
- Timestamps are captured at emit time (overhead < 1ms per event)
- File I/O is buffered to minimize impact on system behavior
- For high-frequency events (heartbeats), consider sampling or batching

## References

- **Instrumentation Spec**: `spec/instrumentation-spec.md` — Details on each code location
- **Trace Spec**: `spec/Trace.tla` — TLA+ specification and validation predicates
- **Base Spec**: `spec/base.tla` — Protocol semantics and invariants
- **Harness Guide**: `../.claude/skills/harness-generation/guide.md` — General methodology
