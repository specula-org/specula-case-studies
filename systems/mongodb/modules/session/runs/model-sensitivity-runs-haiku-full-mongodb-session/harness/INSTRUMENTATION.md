# Instrumentation Guide: MongoDB Session Catalog

## Overview

This harness generates NDJSON traces that validate the MongoDB session catalog implementation against the TLA+ spec. The current implementation uses simulated trace generation (test harness), but this guide explains how to integrate real instrumentation into the MongoDB source code.

## Current Architecture

### Files

- **`src/tla_trace.h`** — Trace emitter library (header)
- **`src/tla_trace.cpp`** — Trace emitter implementation
- **`src/test_harness.cpp`** — Test scenarios that generate traces
- **`src/CMakeLists.txt`** — Build configuration
- **`run.sh`** — Master build and trace generation script

### Trace Format

Each event is a JSON object (NDJSON format):

```json
{
  "event": "<event_name>",
  "timestamp": <nanoseconds_since_epoch>,
  "sessionId": "<session_id>",
  "state": {
    "sessionState": "<state>",
    "killsRequested": <count>,
    "markedForReap": <bool>,
    "reapMode": "<mode>",
    "checkoutOpCtx": "<opctx_id_or_NULL>",
    "cacheState": "<state>"
  }
}
```

Event-specific fields may be added as needed (e.g., `forKill` for CheckOutSession, `marked_for_reap` array for ScanSessionsForReap).

## How to Integrate Real Instrumentation

### Prerequisites

1. MongoDB source code available at: `artifact/mongo-src/`
2. Build tools: `cmake`, `g++`, `make`
3. Dependencies: `nlohmann/json` (header-only)

### Step 1: Add Trace Emitter to MongoDB Build

1. Copy `src/tla_trace.h` and `src/tla_trace.cpp` to MongoDB source tree (e.g., under `src/mongo/db/session/`)
2. Update MongoDB's build configuration (SConscript) to compile the trace module
3. Add initialization call in SessionCatalog constructor

### Step 2: Instrument Key Functions

#### Action 1: CheckOutSessionInner (session_catalog.cpp:105-154)

Insert trace call **after line 150** (after `sri->checkoutOpCtx = opCtx` assignment):

```cpp
if (g_trace_emitter) {
    std::string sessionState = (killToken ? "KILLING" : "CHECKED_OUT");
    std::string checkoutOpCtxStr = opCtx ? "opCtx_" + std::to_string(opCtx->getOpId()) : "NULL";
    g_trace_emitter->emitCheckOutSession(
        lsid.toBSON().toString(),
        killToken.has_value(),
        sessionState,
        sri->killsRequested,
        osession._markedForReap,
        osession._reapMode.has_value() ? "EXCLUSIVE" : "NONEXCLUSIVE",
        checkoutOpCtxStr,
        "ACTIVE"
    );
}
```

#### Action 2: ObservableSession::kill() (session_catalog.cpp:447-457)

Insert trace call **after line 449** (after `++_sri->killsRequested`):

```cpp
if (g_trace_emitter) {
    std::string sessionState = hasCurrentOperation() ? "KILLING" : "KILLED";
    std::string checkoutOpCtxStr = _sri->checkoutOpCtx ? "opCtx_" + std::to_string(...) : "NULL";
    g_trace_emitter->emitKill(
        getSessionId().toString(),
        sessionState,
        _sri->killsRequested,
        _markedForReap,
        _reapMode.has_value() ? "EXCLUSIVE" : "NONEXCLUSIVE",
        checkoutOpCtxStr,
        "ACTIVE"
    );
}
```

#### Action 3: _releaseSession() (session_catalog.cpp:354-417)

Insert trace call **after line 411** (after invariant check, before unlock):

```cpp
if (g_trace_emitter) {
    std::string sessionState = "AVAILABLE";
    g_trace_emitter->emitReleaseSession(
        session->getSessionId().toString(),
        sessionState,
        sri->killsRequested,
        false,  // markedForReap reset by release
        "NONEXCLUSIVE",
        "NULL",
        "ACTIVE"
    );
}
```

#### Action 4: scanSessionsForReap() (session_catalog.cpp:234-286)

Insert two trace calls:

1. **After line 275** (after decisions finalized):
```cpp
std::vector<std::string> markedSessions;
// Collect marked sessions into vector
if (g_trace_emitter) {
    g_trace_emitter->emitScanSessionsForReap(
        parentLsid.toString(),
        markedSessions
    );
}
```

2. **After line 285** (after erase operations complete):
```cpp
if (g_trace_emitter) {
    g_trace_emitter->emitFinishReap(parentLsid.toString());
}
```

#### Action 5: _getOrCreateSessionRuntimeInfo() (session_catalog.cpp:262-263)

Insert trace call **after child session creation** (approximate line 345):

```cpp
if (g_trace_emitter && !isParentSessionId(lsid)) {
    auto parentLsid = getParentSessionId(lsid);
    g_trace_emitter->emitCreateChildSession(
        parentLsid.toString(),
        lsid.toString()
    );
}
```

### Step 3: Helper Functions for State Derivation

Create a utility function to derive sessionState from implementation state:

```cpp
std::string deriveSessionState(OperationContext* checkoutOpCtx, int killsRequested) {
    if (checkoutOpCtx && killsRequested > 0) return "KILLING";
    if (checkoutOpCtx && killsRequested == 0) return "CHECKED_OUT";
    if (!checkoutOpCtx && killsRequested > 0) return "KILLED";
    return "AVAILABLE";
}
```

### Step 4: Operation Context ID Mapping

The trace uses stable integer IDs for operation contexts (not pointers). Maintain a global map:

```cpp
static std::map<OperationContext*, int> opctx_id_map;
static int next_opctx_id = 0;

int getStableOpCtxId(OperationContext* opCtx) {
    if (!opCtx) return -1;  // NULL representation
    auto it = opctx_id_map.find(opCtx);
    if (it != opctx_id_map.end()) return it->second;
    opctx_id_map[opCtx] = next_opctx_id++;
    return opctx_id_map[opCtx];
}
```

## Testing Integration

After instrumenting MongoDB source:

1. **Build MongoDB** with instrumentation:
   ```bash
   cd artifact/mongo-src
   scons variant_dir=test mongodb
   ```

2. **Run integration tests** that exercise session catalog:
   ```bash
   ./build/test/core/session_catalog_test
   ```

3. **Collect traces** in tests:
   - Start trace emitter before test suite
   - Each test run writes to a separate `.ndjson` file
   - Flush emitter on test completion

## Validation Against Spec

Once real traces are generated:

1. Run **trace validation**:
   ```bash
   /validation-workflow --spec spec/Trace.tla \
                       --config spec/Trace.cfg \
                       --trace traces/<scenario>.ndjson
   ```

2. If validation fails, check:
   - Event field names match spec exactly (case-sensitive)
   - Timestamps are real (not sequential integers)
   - State fields are consistent with implementation state at emit point
   - sessionState derivation matches spec transitions

## Common Issues and Fixes

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Validation fails: "Unknown event type" | Event name typo | Check spec event names: CheckOutSession, Kill, ReleaseSession, ScanSessionsForReap, FinishReap, CreateChildSession, ExecuteEagerReapCallback, CompleteEagerReapCallback |
| State validation fails | Captured state inconsistent with action | Re-check capture point (before/after) in instrumentation-spec.md |
| Missing events | Code path not exercised in tests | Add test scenarios covering that code path |
| Race conditions in trace | Events from different threads not ordered | If concurrent, ensure trace captures with real timestamps and allows partial-order validation |

## Next Steps

1. Instrument real MongoDB source code following this guide
2. Run MongoDB integration tests with instrumentation enabled
3. Validate generated traces against Trace.tla spec
4. Iterate on instrumentation until validation passes
5. Use Phase 3 (validation-workflow) to identify and fix any remaining bugs

See the phase-2.5 skill guide (`harness-generation/guide.md`) for more context.
