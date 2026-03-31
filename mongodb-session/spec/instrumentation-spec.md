# Instrumentation Spec: MongoDB Session Lifecycle

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "session": "<session_id_string>",
  "thread": "<thread_id_string>",
  "txnState": "<none|inProgress|prepared|committed|aborted>",
  "sessionExists": true,
  "checkedOut": true,
  "ts": "<ISO8601 timestamp>"
}
```

### State Fields

| Implementation Getter | TLA+ Variable | Capture At |
|---|---|---|
| `TransactionParticipant::Observer::transactionStateDescriptor()` | `txnState` | Every event |
| `SessionRuntimeInfo::checkoutOpCtx != nullptr` | `checkedOut` (derived: `checkoutThread /= NilThread`) | Every event |
| `SessionCatalog::_sessions.count(lsid)` | `sessionExists` | Reaper/reap events |
| `killsRequested` field on `SessionRuntimeInfo` | `killsRequested` | Kill events |
| `nodeRole` via `ReplicationCoordinator::getMemberState()` | `nodeRole` | Step-down events |

### Message Fields

Not applicable — this system uses shared-memory (mutex + condition variable), not message passing.

## Section 2: Action-to-Code Mapping

### CheckOutSession

- **Spec action**: `CheckOutSession(t, s)`
- **Code location**: `session_catalog.cpp:150` — after `sri->checkoutOpCtx = opCtx`
- **Trigger point**: After successful checkout (after line 150)
- **Trace event name**: `CheckOutSession`
- **Fields**: `session`, `thread`, `txnState`, `checkedOut` (should be `true`)
- **Notes**: Emit after `sri->checkoutOpCtx = opCtx` but before returning ScopedCheckedOutSession. The thread ID is the current thread.

### CheckInSession

- **Spec action**: `CheckInSession(t)`
- **Code location**: `session_catalog.cpp:371` — after `sri->checkoutOpCtx = nullptr`
- **Trigger point**: After clearing checkoutOpCtx (line 371), before `notify_all` (line 372)
- **Trace event name**: `CheckInSession`
- **Fields**: `session`, `thread`, `txnState`, `checkedOut` (should be `false`)
- **Notes**: Session ID from the releasing session. Thread from current thread.

### BeginTransaction

- **Spec action**: `BeginTransaction(t)`
- **Code location**: `transaction_participant.cpp` — inside `beginOrContinue()`, after state transition to kInProgress
- **Trigger point**: After `transitionTo(kInProgress)` call
- **Trace event name**: `BeginTransaction`
- **Fields**: `session`, `thread`, `txnState` (should be `"inProgress"`)
- **Notes**: Only emit for new transactions (not continue). Check `TransactionActions::kStart`.

### PrepareTransaction

- **Spec action**: `PrepareTransaction(t)`
- **Code location**: `transaction_participant.cpp:2086` — after `transitionTo(kPrepared)` (line ~2070)
- **Trigger point**: After state transition to kPrepared, after RSTL drop (line 2086-2090)
- **Trace event name**: `PrepareTransaction`
- **Fields**: `session`, `thread`, `txnState` (should be `"prepared"`)
- **Notes**: Emit AFTER the RSTL is dropped (line 2090), since the spec models prepare as including RSTL release. This captures the post-prepare state faithfully.

### CommitPreparedTransaction

- **Spec action**: `CommitPreparedTransaction(t)`
- **Code location**: `transaction_participant.cpp:2264-2415` — after successful commit
- **Trigger point**: After `transitionTo(kCommitted)` (inside commitPreparedTransaction)
- **Trace event name**: `CommitPreparedTransaction`
- **Fields**: `session`, `thread`, `txnState` (should be `"committed"`)
- **Notes**: Emit after the state transition, not after disk writes.

### AbortTransaction

- **Spec action**: `AbortTransaction(t)`
- **Code location**: `transaction_participant.cpp:2651-2737` — `_abortActiveTransaction()`
- **Trigger point**: After `_abortTransactionOnSession()` determines next state
- **Trace event name**: `AbortTransaction`
- **Fields**: `session`, `thread`, `txnState` (should be `"aborted"`)
- **Notes**: For non-prepared aborts only. The state will be kAbortedWithoutPrepare — map both `kAbortedWithoutPrepare` and `kAbortedWithPrepare` to `"aborted"` in the trace.

### AbortPreparedTransaction

- **Spec action**: `AbortPreparedTransaction(t)`
- **Code location**: `transaction_participant.cpp:2617-2649` — `_abortActivePreparedTransaction()`
- **Trigger point**: After RSTL reacquired (line 2618-2619) and abort complete
- **Trace event name**: `AbortPreparedTransaction`
- **Fields**: `session`, `thread`, `txnState` (should be `"aborted"`)
- **Notes**: This is the prepared-transaction abort path. Differentiate from AbortTransaction by checking if state was kPrepared before abort.

### ResetTransactionState

- **Spec action**: `ResetTransactionState(t)`
- **Code location**: `transaction_participant.cpp:3664-3703` — `_resetTransactionStateAndUnlock()`
- **Trigger point**: After `transitionTo(kNone)` or equivalent state reset
- **Trace event name**: `ResetTransactionState`
- **Fields**: `session`, `thread`, `txnState` (should be `"none"`)
- **Notes**: May be omitted as a silent action if the reset happens atomically with abort/commit in the implementation. If omitted, add to silent actions list.

### KillSessionMark

- **Spec action**: `KillSessionMark(t, s)`
- **Code location**: `kill_sessions_local.cpp:97` — inside scanSessions callback, after `session.kill(reason)`
- **Trigger point**: After `session.kill()` returns KillToken
- **Trace event name**: `KillSessionMark`
- **Fields**: `session`, `thread`, `killsRequested` (post-increment value)
- **Notes**: Multiple sessions may be killed in one scan iteration.

### KillSessionCheckout

- **Spec action**: `KillSessionCheckout(t)`
- **Code location**: `kill_sessions_local.cpp:103` — after `checkOutSessionForKill()` returns
- **Trigger point**: After successful kill-checkout
- **Trace event name**: `KillSessionCheckout`
- **Fields**: `session`, `thread`, `checkedOut` (should be `true`)
- **Notes**: Checkout for kill has a deadline. On timeout, emit KillSessionTimeout instead.

### KillSessionFinish

- **Spec action**: `KillSessionFinish(t)`
- **Code location**: `kill_sessions_local.cpp:125` — after `killSessionFn(opCtx, session)` completes
- **Trigger point**: After kill function execution, during session release
- **Trace event name**: `KillSessionFinish`
- **Fields**: `session`, `thread`, `txnState`, `checkedOut` (should become `false` after release)
- **Notes**: The kill function varies by caller (abort unprepared, shutdown, etc.). Emit after the function completes but before the session is released.

### ReaperScanMemory

- **Spec action**: `ReaperScanMemory(t)`
- **Code location**: `session_catalog_mongod.cpp:218` — after `scanSessionsForReap()` completes
- **Trigger point**: After memory scan and removal of expired sessions
- **Trace event name**: `ReaperScanMemory`
- **Fields**: `thread`, `targets` (array of session IDs removed from memory)
- **Notes**: Emit one event per reaper scan, not per session. Include the list of reaped session IDs for validation.

### ReaperDeleteImages

- **Spec action**: `ReaperDeleteImages(t)`
- **Code location**: `session_catalog_mongod.cpp:253-270` — after image collection delete completes
- **Trigger point**: After `client.remove(imageDeleteOp)` succeeds
- **Trace event name**: `ReaperDeleteImages`
- **Fields**: `thread`, `targets` (array of session IDs whose images were deleted)
- **Notes**: This is the FIRST of two disk deletion steps.

### ReaperDeleteTxnRecords

- **Spec action**: `ReaperDeleteTxnRecords(t)`
- **Code location**: `session_catalog_mongod.cpp:272-294` — after transaction record delete completes
- **Trigger point**: After `client.remove(sessionDeleteOp)` succeeds
- **Trace event name**: `ReaperDeleteTxnRecords`
- **Fields**: `thread`, `targets` (array of session IDs whose txn records were deleted)
- **Notes**: This is the SECOND of two disk deletion steps. Must be separate from ReaperDeleteImages to capture the non-atomic window.

### EagerReapMark

- **Spec action**: `EagerReapMark(s)`
- **Code location**: `session_catalog.cpp:394` — inside `erase_if` callback
- **Trigger point**: When a child session is marked for eager reaping
- **Trace event name**: `EagerReapMark`
- **Fields**: `session` (the child session being reaped)
- **Notes**: Emit inside the `erase_if` lambda in `_releaseSession()`.

### EagerReapExecute

- **Spec action**: `EagerReapExecute`
- **Code location**: `internal_transactions_reap_service.cpp:150` — after `removeSessionsTransactionRecords()`
- **Trigger point**: After disk deletion completes
- **Trace event name**: `EagerReapExecute`
- **Fields**: `targets` (array of session IDs reaped), `numReaped`
- **Notes**: The buffer swap (line 139) and deletion (line 150) are instrumented as one event.

### StepDownBegin

- **Spec action**: `StepDownBegin(t)`
- **Code location**: Replication coordinator step-down entry point
- **Trigger point**: When step-down begins and checkouts are blocked
- **Trace event name**: `StepDownBegin`
- **Fields**: `thread`, `nodeRole` (should be `"stepping_down"`)
- **Notes**: Identify the replication coordinator's step-down entry function.

### StepDownKillSessions

- **Spec action**: `StepDownKillSessions(t)`
- **Code location**: `kill_sessions_local.cpp:148-177` — `killSessionsAbortUnpreparedTransactions()`
- **Trigger point**: When step-down kills a session
- **Trace event name**: `StepDownKillSessions`
- **Fields**: `thread`, `session` (the killed session)
- **Notes**: This is called during step-down to abort unprepared transactions.

### StepDownComplete

- **Spec action**: `StepDownComplete(t)`
- **Code location**: Replication coordinator after RSTL acquired exclusively
- **Trigger point**: After step-down finishes and node becomes secondary
- **Trace event name**: `StepDownComplete`
- **Fields**: `thread`, `nodeRole` (should be `"secondary"`)
- **Notes**: Pair with StepDownBegin.

### StepUp

- **Spec action**: `StepUp`
- **Code location**: `session_catalog_mongod.cpp:570-639` — `onStepUp()`
- **Trigger point**: When node becomes primary
- **Trace event name**: `StepUp`
- **Fields**: `nodeRole` (should be `"primary"`)
- **Notes**: Triggers recovery for prepared transactions.

### EndSession

- **Spec action**: `EndSession(s)`
- **Code location**: `logical_session_cache_impl.cpp:457-465` — `endSessions()`
- **Trigger point**: After session added to `_endingSessions`
- **Trace event name**: `EndSession`
- **Fields**: `session`
- **Notes**: endSessions does NOT check for prepared transactions — this is the bug mechanism for MC-3.

## Section 3: Special Considerations

### 1. Thread Identity Mapping

MongoDB uses OS thread IDs. Map these to TLA+ Thread constants using order of first appearance (like the CometBFT ServerOrder pattern). The preprocessor should assign `t1`, `t2`, etc. based on first trace event per thread.

### 2. Session Identity Mapping

LogicalSessionIds are UUIDs in MongoDB. Map to TLA+ Session constants using order of first appearance. Only map sessions that appear in the trace; unused Session constants can be assigned to non-appearing sessions.

### 3. Transaction State Mapping

| MongoDB TransactionState::StateFlag | TLA+ txnState |
|---|---|
| `kNone` | `"none"` |
| `kInProgress` | `"inProgress"` |
| `kPrepared` | `"prepared"` |
| `kCommitted` | `"committed"` |
| `kAbortedWithoutPrepare` | `"aborted"` |
| `kAbortedWithPrepare` | `"aborted"` |
| `kExecutedRetryableWrite` | `"none"` |

### 4. Concurrent Threads

Multiple threads interact with the session catalog concurrently. The trace must capture events in a total order. Use a centralized logging approach with a mutex or atomic counter to ensure ordering. MongoDB already has a logging infrastructure (`LOGV2`) that provides ordered output.

### 5. Bootstrap State

`TraceInit` assumes all sessions exist, all are idle, node is primary. If the trace starts from a non-default state, add a `TraceInit` event at the start of the trace with the initial state snapshot.

### 6. Silent Actions

The following base spec actions may not have corresponding trace events:
- `ReaperComplete` — internal state reset
- `EagerReapComplete` — async completion
- `ResetTransactionState` — may be bundled with abort/commit

These are handled as silent actions in `Trace.tla`.

### 7. Reaper Scan Targets

The reaper scans all sessions and identifies targets in one pass. The trace should capture the SET of targeted sessions (as a JSON array) so the trace spec can verify which sessions the reaper chose to reap.

### 8. Non-Atomic Disk Deletion

The two-step disk deletion (images first, then txn records) MUST be instrumented as two separate events. This is critical for validating the DiskConsistency invariant and catching failures between the steps.
