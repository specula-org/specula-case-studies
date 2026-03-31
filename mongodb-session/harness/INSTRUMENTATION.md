# MongoDB Session Lifecycle — Instrumentation Guide

## Architecture

**Approach**: Test-driven hybrid (mongosh scripts emit trace events after real MongoDB operations).

**No C++ patching required.** The harness drives operations via mongosh scripts connected to
a 3-node replica set (Docker). Each test script emits NDJSON trace events to stdout, which
`run.sh` captures as trace files.

**Category**: A (distributed / message-passing). Mutex-protected session checkout operates at
ms-level. Standard single-file trace approach.

## Cluster Setup

- 3-node replica set (`rs0`): mongo1 (priority 2), mongo2, mongo3
- `enableTestCommands=1` — enables `prepareTransaction`, `refreshLogicalSessionCacheNow`
- `logicalSessionRefreshMinutes=1` — short reaper interval for testing
- `localLogicalSessionTimeoutMinutes=2` — short session timeout
- Transaction log verbosity: 3 (debug)

## Event Emission Points

Each mongosh test script emits trace events **after** the corresponding MongoDB command returns.
Since each MongoDB command internally does checkout -> action -> checkin, the script emits
all three events in sequence.

| Trace Event | Triggered By | Test File |
|-------------|-------------|-----------|
| CheckOutSession | Before each session operation | all tests |
| CheckInSession | After each session operation | all tests |
| BeginTransaction | After `startTransaction()` + first operation | all tests |
| PrepareTransaction | After `prepareTransaction` admin command | test_prepare_commit.js, test_reaper_prepared.js |
| CommitPreparedTransaction | After `commitTransaction` with commitTimestamp | test_prepare_commit.js |
| AbortTransaction | After `abortTransaction()` | test_basic_lifecycle.js |
| ResetTransactionState | After abort/commit (bundled with abort/commit) | test_basic_lifecycle.js, test_prepare_commit.js |
| KillSessionMark | After `killSessions` admin command | test_kill_session.js |
| KillSessionCheckout | After `killSessions` admin command | test_kill_session.js |
| KillSessionFinish | After `killSessions` admin command | test_kill_session.js |
| EndSession | After `endSessions` admin command | test_reaper_prepared.js |
| ReaperScanMemory | After `refreshLogicalSessionCacheNow` | test_reaper_prepared.js |
| ReaperDeleteImages | After `refreshLogicalSessionCacheNow` | test_reaper_prepared.js |
| ReaperDeleteTxnRecords | After `refreshLogicalSessionCacheNow` | test_reaper_prepared.js |

## Thread Mapping

| Spec Thread | Role | Maps To |
|-------------|------|---------|
| t1 | Client operations (checkout, txn, etc.) | Main mongosh connection |
| t2 | Kill / admin operations | `killSessions` admin command |
| t3 | Reaper thread | `refreshLogicalSessionCacheNow` |

## Session Mapping

| Spec Session | Maps To |
|--------------|---------|
| s1 | First session created in each test |
| s2 | Second session (reaper test only) |

## How to Add a New Field to an Event

1. In the test script (e.g., `test_basic_lifecycle.js`), find the `emitEvent()` call
2. Add the field to the second argument object:
   ```javascript
   emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true, newField: value});
   ```
3. In `spec/Trace.tla`, add validation in `ValidatePostState`:
   ```tla
   /\ IF "newField" \in DOMAIN logline
      THEN specVar[s] = logline.newField
      ELSE TRUE
   ```

## How to Add a New Event Type

1. Copy an existing `emitEvent(...)` call pattern in the test script
2. Add the event name to `trace_helpers.js` if it needs a special helper
3. In `spec/Trace.tla`, add a `TraceNewEvent` wrapper:
   ```tla
   TraceNewEvent ==
       /\ IsEvent("NewEvent")
       /\ LET t == TraceThread IN
          /\ NewAction(t)
       /\ l' = l + 1
   ```
4. Add it to `TraceNext` disjunction

## How to Move a Capture Point

For test-driven events, the capture point is the position of the `emitEvent()` call in the
test script. To move it:

1. Find the `emitEvent()` call in the `.js` test file
2. Move it before/after the MongoDB operation as needed
3. Update any post-state fields to match the new capture point

## How to Rebuild and Re-run

```bash
# Full run (start cluster + run all tests):
cd case-studies/mongodb-session && bash harness/run.sh

# Re-run a single test (cluster must be running):
docker exec session-mongo1 mongosh --quiet --norc \
    "mongodb://mongo1:27017/?replicaSet=rs0" \
    --file /scripts/test_basic_lifecycle.js \
    > traces/basic_lifecycle.ndjson

# Stop cluster:
cd harness/src && docker compose down -v
```

## Capture Levels

All events use **full capture** since the test script knows the complete state at emission time.
No weak or specialized capture needed — the test controls all operations.

Exception: `KillSessionFinish` uses weak validation (omits `txnState`) because the spec models
abort and reset as separate steps, but MongoDB executes them atomically in the kill path.

## Validated Traces

| Trace | Events | States | Status |
|-------|--------|--------|--------|
| basic_lifecycle | 7 | 8 | PASS |
| prepare_commit | 10 | 11 | PASS |
| kill_session | 6 | 7 | PASS |
| reaper_prepared | 10 | 11 | PASS |

## Spec Fixes Applied During Harness Development

1. **Json import**: Added `Json` to `EXTENDS` in Trace.tla (provides `ndJsonDeserialize`)
2. **String constants**: Changed Trace.cfg to use string constants (`"s1"`, `"t1"`) instead of model values
3. **Primed post-state validation**: Changed `ValidatePostState` and `ValidatePostStateWeak` to use
   primed variables (`txnState'[s]`, `checkoutThread'[s]`) since they validate the state AFTER the action
4. **Weak fairness**: Added `WF_traceVars(TraceNext)` to `TraceSpec` to prevent trivial stuttering counterexamples
5. **Silent action look-ahead**: Added `~IsEvent("ResetTransactionState")` guard to `SilentResetTransactionState`
   to prevent racing with explicit trace events

## Known Limitations

1. **Reaper targets not directly observable**: The trace emits ReaperScanMemory after
   `refreshLogicalSessionCacheNow`, but doesn't verify which sessions were actually reaped.
   The spec computes targets from its own state.

2. **Step-down not yet instrumented**: Step-down scenarios (StepDownBegin, StepDownKillSessions,
   StepDownComplete, StepUp) require more complex test setup. Add in a future iteration.

3. **Eager reap not yet instrumented**: EagerReapMark and EagerReapExecute require internal
   transaction child sessions, which are harder to trigger from mongosh.
