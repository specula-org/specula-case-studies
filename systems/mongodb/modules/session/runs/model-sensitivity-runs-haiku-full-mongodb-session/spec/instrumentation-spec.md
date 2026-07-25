# Instrumentation Spec: MongoDB Session Catalog

**Target System**: MongoDB Logical Session Catalog (C++)  
**Reference Implementation**: MongoDB Community Edition  
**Trace Format**: NDJSON (newline-delimited JSON)  
**Trace Location**: `../traces/mongodb-session.ndjson`

---

## Section 1: Trace Event Schema

### Event Envelope (Common to All Events)

Every trace event is a JSON object with the following common structure:

```json
{
  "event": "<event_name>",
  "timestamp": <nanoseconds_since_epoch>,
  "sessionId": "<session_id>",
  "state": {
    "sessionState": "<AVAILABLE|CHECKED_OUT|KILLING|KILLED>",
    "killsRequested": <counter>,
    "markedForReap": <boolean>,
    "reapMode": "<EXCLUSIVE|NONEXCLUSIVE>",
    "checkoutOpCtx": "<opCtxId>",
    "cacheState": "<ACTIVE|ENDING|EXPIRED>"
  }
}
```

### State Field Mapping

| Trace Field (JSON) | Spec Variable | Implementation Source | Notes |
|---|---|---|---|
| `state.sessionState` | `sessionState[sessionId]` | Derived from `checkoutOpCtx != NULL` and `killsRequested > 0` | See implementation mapping below |
| `state.killsRequested` | `killsRequested[sessionId]` | `ObservableSession._sri->killsRequested` (line 449) | Counter of kill requests |
| `state.markedForReap` | `markedForReap[sessionId]` | `ObservableSession._markedForReap` | Boolean flag |
| `state.reapMode` | `reapMode[sessionId]` | Derived from reap operation context | Either EXCLUSIVE or NONEXCLUSIVE |
| `state.checkoutOpCtx` | `checkoutOpCtx[sessionId]` | `SessionRuntimeInfo.checkoutOpCtx` (line 83) | Unique operation context ID or NULL |
| `state.cacheState` | `cacheState[sessionId]` | Tracked via `LogicalSessionCacheImpl._activeSessions` | ACTIVE if in cache, EXPIRED if reaped |

### Session State Derivation

The spec's explicit `sessionState` is derived from implementation state:

| Implementation State | Spec sessionState |
|---|---|
| `checkoutOpCtx == NULL && killsRequested == 0` | `AVAILABLE` |
| `checkoutOpCtx != NULL && killsRequested == 0` | `CHECKED_OUT` |
| `checkoutOpCtx != NULL && killsRequested > 0` | `KILLING` |
| `checkoutOpCtx == NULL && killsRequested > 0` | `KILLED` |

---

## Section 2: Action-to-Code Mapping

### Action 1: CheckOutSessionInner

| Property | Value |
|----------|-------|
| **Spec Action** | `CheckOutSessionInner(sid, forKill)` |
| **Code Location** | `session_catalog.cpp:105-154` |
| **Function** | `SessionCatalog::_checkOutSessionInner()` |
| **Trigger Point** | **AFTER** mutex lock acquired at line 116, **BEFORE** operation context assignment |
| **Trace Event Name** | `CheckOutSession` |
| **Fields to Capture** | State fields (envelope) + `forKill` (boolean) |
| **Post-State Validation** | sessionState becomes CHECKED_OUT; checkoutOpCtx assigned non-NULL |

**Implementation Logic**:
- Line 130-135: Precondition checks (session not marked for reap)
- Line 140-142: Wait for not killed if `forKill = FALSE`
- Line 116-119: Transition available → checked out
- Allocate new operation context (state field)

**Capture at**: Line 145, after `_checkoutOpCtx = opCtx` assignment, while holding mutex.

---

### Action 2: ObservableSessionKill

| Property | Value |
|----------|-------|
| **Spec Action** | `ObservableSessionKill(sid)` |
| **Code Location** | `session_catalog.cpp:447-457` |
| **Function** | `ObservableSession::kill()` |
| **Trigger Point** | **AFTER** `killsRequested` increment (line 449) |
| **Trace Event Name** | `Kill` |
| **Fields to Capture** | State fields (envelope) |
| **Post-State Validation** | killsRequested incremented; if checkoutOpCtx != NULL, interrupt sent |

**Implementation Logic**:
- Line 448: Read killsRequested before incrementing
- Line 449: Increment killsRequested
- Line 451-454: Conditionally call interrupt if operation exists
- Separate `killsRequested_interrupted` flag from counter

**Capture at**: Line 450, after increment but before conditional interrupt.

---

### Action 3: ReleaseSession

| Property | Value |
|----------|-------|
| **Spec Action** | `ReleaseSession(sid)` |
| **Code Location** | `session_catalog.cpp:354-417` |
| **Function** | `SessionCatalog::_releaseSession()` |
| **Trigger Point** | **AFTER** state update (line 411), **BEFORE** unlock (line 412) |
| **Trace Event Name** | `ReleaseSession` |
| **Fields to Capture** | State fields (envelope) |
| **Post-State Validation** | sessionState → AVAILABLE; checkoutOpCtx → NULL; killsRequested decremented if > 0 |

**Implementation Logic**:
- Line 359: Acquire unique_lock
- Line 140-142: Decrement killsRequested if > 0
- Line 411: Check invariant
- Line 412: Unlock (explicit)
- Line 414-415: Call callback without lock

**Capture at**: Line 411, while still holding lock, after state updates.

---

### Action 4: ScanSessionsForReap

| Property | Value |
|----------|-------|
| **Spec Action** | `ScanSessionsForReap` |
| **Code Location** | `session_catalog.cpp:234-286` |
| **Function** | `SessionCatalog::scanSessionsForReap()` |
| **Trigger Point** | **AFTER** scan decision (line 280), **BEFORE** erase operations |
| **Trace Event Name** | `ScanSessionsForReap` |
| **Fields to Capture** | `marked_for_reap` (array of session IDs), state fields |
| **Post-State Validation** | All marked sessions have `markedForReap = TRUE`; reapRunning = TRUE |

**Implementation Logic**:
- Line 262-275: Iterate child sessions
- Line 278-282: Parent reap decision based on child status
- Line 280: Determine which sessions to erase
- Non-deterministic: which sessions actually marked for reap

**Capture at**: Line 275, after decisions finalized but before actual erase.

---

### Action 5: FinishReap

| Property | Value |
|----------|-------|
| **Spec Action** | `FinishReap` |
| **Code Location** | `session_catalog.cpp:234-286` (end of scanSessionsForReap) |
| **Function** | Completion marker after reap |
| **Trigger Point** | **AFTER** all erasures complete |
| **Trace Event Name** | `FinishReap` |
| **Fields to Capture** | State fields (envelope) |
| **Post-State Validation** | reapRunning = FALSE |

**Implementation Logic**:
- Marks end of reap scan operation
- Allows next reap to begin

**Capture at**: Synthetic event after erase loop completes.

---

### Action 6: PeriodicRefresh

| Property | Value |
|----------|-------|
| **Spec Action** | `PeriodicRefresh` |
| **Code Location** | `logical_session_cache_impl.cpp:277-455` |
| **Function** | `LogicalSessionCacheImpl::_refresh()` |
| **Trigger Point** | **AFTER** refresh begins (line 327), **BEFORE** back-swap completion |
| **Trace Event Name** | `PeriodicRefresh` |
| **Fields to Capture** | `refreshed_sessions` (array of session IDs), state fields |
| **Post-State Validation** | Refreshed sessions remain in activeSessions; refreshRunning = TRUE |

**Implementation Logic**:
- Line 327-331: Swap _activeSessions out, refresh in DB
- Line 385-398: Swap back in
- Non-deterministic: which sessions refreshed

**Capture at**: Line 330, after swap-out but before DB refresh.

---

### Action 7: FinishRefresh

| Property | Value |
|----------|-------|
| **Spec Action** | `FinishRefresh` |
| **Code Location** | `logical_session_cache_impl.cpp:277-455` (end of _refresh) |
| **Function** | Completion marker after refresh |
| **Trigger Point** | **AFTER** back-swap completion (line 398) |
| **Trace Event Name** | `FinishRefresh` |
| **Fields to Capture** | State fields (envelope) |
| **Post-State Validation** | refreshRunning = FALSE |

**Implementation Logic**:
- Marks end of refresh operation
- Allows next refresh to begin

**Capture at**: Synthetic event after back-swap.

---

### Action 8: CreateChildSession

| Property | Value |
|----------|-------|
| **Spec Action** | `CreateChildSession(parentSid, childSid)` |
| **Code Location** | `session_catalog.cpp:331-352` |
| **Function** | `SessionCatalog::_getOrCreateSessionRuntimeInfo()` |
| **Trigger Point** | **AFTER** new child created and linked (line 342) |
| **Trace Event Name** | `CreateChildSession` |
| **Fields to Capture** | `parentSessionId`, `childSessionId`, state fields |
| **Post-State Validation** | `parentOf[childSid] = parentSid`; `childSid ∈ childrenOf[parentSid]` |

**Implementation Logic**:
- Line 331-352: Create new SessionRuntimeInfo
- Link child to parent
- Initialize child session state

**Capture at**: Line 345, after link is established but while holding lock.

---

### Action 9: ExecuteEagerReapCallback

| Property | Value |
|----------|-------|
| **Spec Action** | `ExecuteEagerReapCallback(sid)` |
| **Code Location** | `session_catalog.cpp:414-415` |
| **Function** | Callback execution in `_releaseSession()` |
| **Trigger Point** | **AFTER** unlock (line 412), **AT** callback invocation (line 415) |
| **Trace Event Name** | `ExecuteEagerReapCallback` |
| **Fields to Capture** | `sessionId`, state fields |
| **Post-State Validation** | callbackExecuting = TRUE |

**Implementation Logic**:
- Callback executes without holding mutex
- May race with concurrent operations
- Callback typically calls `killSession()` for marked sessions

**Capture at**: Line 415, at callback entry point (may require manual instrumentation if callback is function pointer).

---

### Action 10: CompleteEagerReapCallback

| Property | Value |
|----------|-------|
| **Spec Action** | `CompleteEagerReapCallback(sid)` |
| **Code Location** | `session_catalog.cpp:414-415` (completion) |
| **Function** | Callback completion |
| **Trigger Point** | **AFTER** callback returns |
| **Trace Event Name** | `CompleteEagerReapCallback` |
| **Fields to Capture** | `sessionId`, state fields |
| **Post-State Validation** | callbackExecuting = FALSE; `sid ∉ pendingCallbacks` |

**Implementation Logic**:
- Marks callback completion
- Allows state consistency to be re-established

**Capture at**: Synthetic event after callback returns or re-acquires lock.

---

## Section 3: Special Considerations

### 1. Concurrency and Lock Boundaries

**Mutex Protection**: Most operations in `SessionCatalog` are protected by the catalog mutex acquired at lines 116, 359, 234. Instrumentation must capture state while holding the lock to ensure consistency.

**Unlock-to-Callback Pattern** (Family 5): The release operation explicitly unlocks before calling the callback. Trace the callback separately to model the race.

**Background Jobs**: `PeriodicRefresh` and `PeriodicReap` run in separate threads with their own scheduling. Capture their start/end with synthetic events to bound concurrency.

### 2. State Aliasing and Shadowing

The spec uses explicit `sessionState` (AVAILABLE|CHECKED_OUT|KILLING|KILLED), but the implementation uses implicit state derived from `checkoutOpCtx` and `killsRequested`. **Harness must compute sessionState** from these fields for every event.

Example computation in C++:
```cpp
std::string deriveSessionState(
    const boost::optional<OperationContext*>& checkoutOpCtx,
    int killsRequested) {
  if (checkoutOpCtx && killsRequested > 0) return "KILLING";
  if (checkoutOpCtx && killsRequested == 0) return "CHECKED_OUT";
  if (!checkoutOpCtx && killsRequested > 0) return "KILLED";
  return "AVAILABLE";
}
```

### 3. Operation Context IDs

The spec uses symbolic operation context IDs (`opCtxId`), but the implementation uses pointer addresses or indices. **Harness must map opCtx addresses to stable IDs** across events. Example:

```cpp
static std::map<OperationContext*, int> opCtxIdMap;
static int nextOpCtxId = 0;

int getStableOpCtxId(OperationContext* opCtx) {
  if (opCtxIdMap.find(opCtx) == opCtxIdMap.end()) {
    opCtxIdMap[opCtx] = nextOpCtxId++;
  }
  return opCtxIdMap[opCtx];
}
```

### 4. Bootstrap State

The trace must begin with a valid base state. If sessions are pre-created or pre-killed, record this as initial state in the first event's `state` field rather than as synthetic events. The Trace spec's `TraceInit` must match.

### 5. Multi-Threaded Interleaving

Events from different threads may interleave. The global total order of trace events should preserve causality where mutex-protected sections enforce ordering, but allow arbitrary interleaving of concurrent background jobs.

If background jobs run asynchronously:
- Capture their boundaries as synthetic events (FinishRefresh, FinishReap)
- Allow events from foreground operations to interleave between job start/end
- Do not enforce strict alternation

### 6. Kill Token Refcounting (Family 4)

The spec separates `killsRequested` (counter) from `killsRequested_interrupted` (boolean). The harness must track both:

```cpp
struct KillState {
  int counter = 0;           // Incremented at line 449
  bool interrupted = false;  // Set at line 453 if operation exists
};
```

### 7. Parent-Child Reaping (Family 2)

When `CreateChildSession` events occur, capture the parent-child link. When `ScanSessionsForReap` occurs, capture which parent/child pairs are marked for reap. Do not skip child creation events — they are key to triggering Family 2 bugs.

### 8. Cache State Transitions (Family 3)

Track `cacheState` per session:
- ACTIVE: session is in `_activeSessions` (logical_session_cache_impl.cpp:85)
- ENDING: session marked for ending (endSessions call, line 108)
- EXPIRED: session removed from cache (reaped, line 262)

### 9. Serialization Notes

All JSON values must be valid. Use lowercase for booleans (`true`, `false`). OpCtx pointers are represented as decimal integers (stable IDs). Session IDs are strings (match spec constants).

Example valid event:
```json
{
  "event": "Kill",
  "timestamp": 1234567890123456,
  "sessionId": "s1",
  "state": {
    "sessionState": "CHECKED_OUT",
    "killsRequested": 1,
    "markedForReap": false,
    "reapMode": "NONEXCLUSIVE",
    "checkoutOpCtx": "opCtx_0",
    "cacheState": "ACTIVE"
  }
}
```

---

## Section 4: Harness Implementation Checklist

- [ ] Mutex lock instrumentation at line 116, 359, 234
- [ ] State capture after each action while holding lock
- [ ] Operation context ID mapping (pointer → stable int)
- [ ] Session state derivation (checkoutOpCtx + killsRequested → state)
- [ ] Background job synthetic event generation (FinishRefresh, FinishReap)
- [ ] Parent-child link tracking for all CreateChildSession calls
- [ ] Cache state transitions (ACTIVE → EXPIRED on reap)
- [ ] Kill token refcounting (counter separate from interrupt flag)
- [ ] Bootstrap state in first event
- [ ] Causal ordering preservation (mutex-protected sections → ordered events)
- [ ] Arbitrary interleaving allowed for concurrent background jobs

---

## Section 5: References

| File | Lines | Purpose |
|------|-------|---------|
| session_catalog.h | 69-531 | SessionCatalog, ObservableSession, OperationContextSession classes |
| session_catalog.cpp | All | Core implementation |
| logical_session_cache.h | 57-129 | LogicalSessionCache interface |
| logical_session_cache_impl.h | 71-135 | Implementation declaration |
| logical_session_cache_impl.cpp | All | Background refresh/reap implementation |

---

## Next Steps (Harness Generation - Phase 2.5)

Use this instrumentation spec to:
1. Instrument MongoDB source code with trace-generation hooks
2. Collect traces from running session catalog operations
3. Validate collected traces against `Trace.tla`
4. Iterate until traces pass validation

See the harness-generation skill guide for instrumentation patterns.
