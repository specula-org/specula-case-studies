# MongoDB Logical Session Lifecycle - Modeling Brief

## 1. System Overview

**System**: MongoDB Logical Session Catalog and Cache  
**Language**: C++  
**Core Logic LOC**: ~2,500 (session_catalog.cpp, logical_session_cache_impl.cpp)  
**Category**: **Category A (Distributed / Message-Passing)** with concurrent state machine characteristics  

**Justification**: The system manages distributed session state across multiple nodes with cache consistency requirements, background refresh/reap tasks operating asynchronously, and coordination between in-memory catalog and persistent session collection. This is fundamentally a distributed state consistency problem, not a single-machine concurrency issue.

**Algorithm**: MongoDB's logical session lifecycle with parent-child transaction sessions, TTL-based expiration, and eager reaping. Sessions can be checked out, killed, and reaped with complex coordination between multiple concurrent operations.

**Key Architectural Choices**:
- **SessionCatalog**: In-memory map protected by single mutex holding SessionRuntimeInfo (parent + child sessions)
- **LogicalSessionCache**: Separate cache layer with async refresh/reap tasks touching persistent sessions collection
- **Kill Tokens**: Explicit token-based protocol for session killing with refcounting via `killsRequested` counter
- **Parent-Child Sessions**: Transaction sessions can be children of logical sessions; both share SessionRuntimeInfo but can be reaped independently
- **Async Refresh/Reap**: Background threads periodically refresh TTL and reap expired sessions, racing against foreground operations

---

## 2. Bug Families

### Family 1: Session Checkout-Kill-Release Race

**Mechanism**: The session checkout, kill, and release operations interact through shared state (checkoutOpCtx, killsRequested) without atomic multi-step transitions. A session can transition through multiple states (available → checked out → killing → released) with gaps where concurrent operations see inconsistent views.

**Evidence**:
- **Code Analysis**: 
  - `_checkOutSessionInner()` (session_catalog.cpp:105-154) - Waits for session to become available, sets checkoutOpCtx
  - `ObservableSession::kill()` (session_catalog.cpp:447-457) - Increments killsRequested, may interrupt running operation
  - `_releaseSession()` (session_catalog.cpp:354-417) - Decrements killsRequested, clears checkoutOpCtx, notifies waiters
  - Between these operations: checkoutOpCtx can be set, operation can start, kill can be called, but the ordering is not atomic
  
- **Critical Path**: When kill() is called while the session is being checked out (between acquiring mutex and setting checkoutOpCtx), the first killer might not find a running operation to interrupt, but the session could still be "dirty" with a pending operation.

- **Lock Interaction**: `_releaseSession()` acquires SessionCatalog mutex but then unlocks before calling `_onEagerlyReapedSessionsFn()`. Meanwhile, other operations hold the mutex at different points, creating potential for stale reads.

**Affected code paths**: 
- `_checkOutSessionInner()`
- `_releaseSession()`
- `ObservableSession::kill()`
- `_shouldBeReaped()` - checks `_sri->checkoutOpCtx` and `_sri->killsRequested` without holding lock

**Suggested modeling approach**:
- **Variables**: Track session state explicitly (AVAILABLE, CHECKED_OUT, KILLING, KILLED, RELEASED)
- **Actions**: Split checkout/kill/release into explicit state transitions, model the interaction between concurrent kill requests and checkout operations
- **Granularity**: Each state transition should be an atomic action with preconditions and postconditions

**Priority**: HIGH  
**Rationale**: Historical indication this is an error-prone area (session catalog goes through multiple bug-fix commits for checkout/kill logic), affects critical transaction guarantees.

---

### Family 2: Parent-Child Session Consistency During Reaping

**Mechanism**: Parent and child sessions share SessionRuntimeInfo but can be reaped independently with different policies. The reap operation must atomically decide whether to reap the parent and all children together or reap children individually based on `reapMode` (kExclusive vs kNonExclusive). A race between the reap decision and new child session creation could leave orphaned children or prematurely reaped parents.

**Evidence**:
- **Code Analysis**:
  - `scanSessionsForReap()` (session_catalog.cpp:234-286) - Iterates parent and child sessions, decides reap based on `_shouldBeReaped()`
  - Line 262-275: Child session iteration with potential for newly-created child sessions to appear after reap decision
  - Line 278-282: Parent reap decision based on ALL children's reap status, but children can be added by concurrent checkout operations
  
- **Race Window**: Between the parent reap decision at line 257 (`shouldReapRemaining`) and the actual erase at line 280, new child sessions can be created by `_getOrCreateSessionRuntimeInfo()` (line 331-352), invalidating the reap decision.

- **kExclusive vs kNonExclusive**: Line 267 erases children with kExclusive mode immediately during iteration, but if a reap attempt for the parent should fail (remaining non-exclusive children exist), those already-erased exclusive children cannot be recovered.

**Affected code paths**:
- `scanSessionsForReap()` - orchestrates the reap decision
- `_getOrCreateSessionRuntimeInfo()` - can create new child sessions during reap
- `ObservableSession::markForReap()` - sets _markedForReap flag
- `_shouldBeReaped()` - evaluates reap eligibility

**Suggested modeling approach**:
- **Variables**: Track which sessions are marked for reap, their reap mode, and whether any new children were added after the reap decision
- **Actions**: Model the full reap scan as atomic with respect to new session creation; capture the race where a new child session arrives after parent eligibility is evaluated
- **Granularity**: Make the reap scan's eligibility check and the actual erase a single action, or add explicit synchronization

**Priority**: HIGH  
**Rationale**: Parent-child reaping is a new feature area (internal transaction sessions) with complex interleaving semantics. The asymmetry between kExclusive (immediate erase) and kNonExclusive (conditional) creates multiple potential races.

---

### Family 3: Logical Session Cache Refresh-Reap Asynchronous Race

**Mechanism**: Two independent background threads (`_periodicRefresh` and `_periodicReap`) operate asynchronously on the same logical session data. The refresh thread updates TTL in persistent storage, while the reap thread removes expired sessions. A session can be added to `_activeSessions` by refresh after the reap thread has decided it should be reaped, causing a reap-update-reap loop with stale reads of expiration time.

**Evidence**:
- **Code Analysis**:
  - `_periodicRefresh()` (logical_session_cache_impl.cpp:184-198) - Runs periodically, calls `_refresh()`
  - `_refresh()` (logical_session_cache_impl.cpp:277-455) - Swaps out `_activeSessions`, refreshes in collection, then swaps back (line 327-331)
  - `_periodicReap()` (logical_session_cache_impl.cpp:200-207) - Runs periodically, calls `_reap()`
  - `_reap()` (logical_session_cache_impl.cpp:209-275) - Calls `_reapSessionsOlderThanFn()` with expired cutoff time (line 250-253)
  
- **Race Window**: 
  - Thread 1 (refresh): Swaps `_activeSessions` out to temp, refreshes with new TTL in DB (lines 327-371)
  - Thread 2 (reap): Concurrently reads expired sessions from DB using old cutoff time (line 250-253)
  - Thread 1: Swaps sessions back in, may re-add sessions that Thread 2 decided to reap (line 385-398)

- **Stale Reads**: Line 356 `getActiveOpSessions()` can race with the refresh/reap operations, returning sessions that are about to be reaped or have already been reaped in one thread but not the other.

**Affected code paths**:
- `_periodicRefresh()` / `_refresh()`
- `_periodicReap()` / `_reap()`
- `LogicalSessionCacheImpl::vivify()` - adds sessions while refresh/reap are running
- `LogicalSessionCacheImpl::endSessions()` - marks sessions for ending while refresh/reap run

**Suggested modeling approach**:
- **Variables**: Track session state in cache (ACTIVE, ENDING, EXPIRED), track the refresh/reap job counter, model the background job scheduling
- **Actions**: Model refresh and reap as concurrent background jobs with explicit ordering constraints; capture the race where a session is refreshed after being marked for reap
- **Granularity**: Each refresh/reap job should be a coarse-grained action that atomically reads cache state, performs DB operations, and updates cache

**Priority**: MEDIUM-HIGH  
**Rationale**: Sessions can bounce between cache and reaper, causing inconsistent state. The lack of coordination between refresh and reap is a known issue (TODO comment at line 114).

---

### Family 4: killsRequested Counter Ordering with Operation Interruption

**Mechanism**: The `killsRequested` counter is incremented when a kill is initiated (line 449) and decremented when checked out for kill (line 146). The operation interruption happens only if an operation is currently running (line 451-454). However, there's a window where `killsRequested` is incremented but the operation hasn't been interrupted yet, and a concurrent operation might see the counter > 0 but the actual operation context has already exited.

**Evidence**:
- **Code Analysis**:
  - `ObservableSession::kill()` (session_catalog.cpp:447-457):
    - Line 448: reads killsRequested before incrementing
    - Line 449: increments killsRequested
    - Line 451-454: conditionally interrupts operation if one exists
    - Between 449 and 451: window where counter > 0 but not yet interrupted
  
  - `_checkOutSessionInner()` (session_catalog.cpp:105-154):
    - Line 140-142: Waits for `_isAvailableForCheckOut(forKill)` which checks `!_killed()` (line 511-513)
    - `_killed()` returns `_sri->killsRequested > 0` (line 479)
  
  - Between incrementing killsRequested and actually interrupting, a waiter might check _killed() and see true, but the operation won't actually be interrupted because it already finished.

- **Asymmetry**: First killer finds operation and interrupts (line 451), but subsequent killers don't do anything (line 449 just increments). This assumes the operation will check `_killed()` at some point, but there's no guarantee.

**Affected code paths**:
- `ObservableSession::kill()` - increments counter
- `_checkOutSessionInner()` - waits for availability check
- `_killed()` - reads counter
- `_shouldBeReaped()` - checks killed status
- Service context interrupt mechanism (not fully visible in this code)

**Suggested modeling approach**:
- **Variables**: Track killsRequested counter and interrupt request state separately
- **Actions**: Model kill as a two-step operation: (1) increment counter and request interrupt, (2) actually interrupt running operation
- **Granularity**: Make the actual interrupt an explicit action separate from the counter increment

**Priority**: MEDIUM  
**Rationale**: The interrupt mechanism is handled by external service context, which is black-box from session catalog perspective. The coupling between counter and actual interruption is implicit and fragile.

---

### Family 5: Session Release Unlock-Callback Race

**Mechanism**: In `_releaseSession()`, the mutex is unlocked at line 412 before calling the `_onEagerlyReapedSessionsFn()` callback at line 414-415. This allows another thread to modify the session state while the callback is executing. If the callback itself tries to reap additional sessions or modify catalog state, it can race with concurrent operations.

**Evidence**:
- **Code Analysis**:
  - `_releaseSession()` (session_catalog.cpp:354-417):
    - Line 359: acquires unique_lock
    - Line 411: checks invariant while holding lock
    - Line 412: explicitly unlocks
    - Line 414-415: calls callback WITHOUT lock
  
  - The comment at lines 546-548 acknowledges this pattern but doesn't explain why it's necessary
  - The callback `_onEagerlyReapedSessionsFn` is set at initialization (line 176-181), typically to a function that triggers session killing

- **Race Window**: Between unlock at 412 and callback execution, another thread can checkout the same session, modify its state, etc.

**Affected code paths**:
- `_releaseSession()` - releases lock before callback
- `_onEagerlyReapedSessionsFn` callback - executes without catalog lock
- Any concurrent checkout/kill/reap operation

**Suggested modeling approach**:
- **Variables**: Track which sessions have eager reap callbacks pending, model the callback execution timeline
- **Actions**: Model the unlock-to-callback window explicitly; show that the callback can race with concurrent operations
- **Granularity**: Release and callback should be separate actions with explicit interleaving

**Priority**: MEDIUM  
**Rationale**: This is a known pattern for avoiding deadlock (as noted in code comments), but it creates observable race windows. Verification should confirm no state corruption occurs due to the callback executing unlocked.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

**1. Session State Machine**: Model each session as having explicit states (AVAILABLE, CHECKED_OUT, KILLING, KILLED). Map these to the current code's implicit states derived from `checkoutOpCtx`, `killsRequested`, and `_markedForReap`.
   - **Why**: Families 1, 4 rely on understanding state transitions and invariants about what state a session can be in.
   - **How**: Add a TLA+ variable `sessionState` per session, transition it explicitly in each action.

**2. Kill Token Refcounting**: Model `killsRequested` as a counter with explicit preconditions for checkout/kill. Track separately whether the operation has been actually interrupted.
   - **Why**: Family 4 shows coupling between counter and actual interrupt that must be verified.
   - **How**: Separate `killsRequested_count` (counter) from `killsRequested_interrupted` (boolean) in the spec.

**3. Parent-Child Session Relationship**: When modeling reaping, explicitly track parent-child links and ensure all children are considered before reaping the parent.
   - **Why**: Family 2 race window depends on understanding that children can be added during reap.
   - **How**: Model SessionRuntimeInfo with explicit parent/child relationships; make reap decision atomic with respect to child creation.

**4. Background Job Scheduling**: Model the refresh and reap background tasks as non-deterministic concurrent jobs that can interleave with foreground operations.
   - **Why**: Family 3 depends on showing how refresh and reap can race.
   - **How**: Add explicit background jobs with their own timelines; allow them to execute concurrently with foreground operations.

**5. Lock-Unlock-Callback Pattern**: Model the unlock-to-callback window explicitly to verify that concurrent operations don't corrupt state.
   - **Why**: Family 5 shows a callback executing outside the lock.
   - **How**: Make callback execution a separate action that can interleave with other operations; verify invariants still hold.

### 3.2 Do Not Model (with rationale)

**1. Persistent Storage Details**: Don't model the actual sessions collection database operations (refreshSessions, removeRecords, etc.). Model them as atomic black-box operations with success/failure.
   - **Why**: Session catalog safety doesn't depend on database implementation details; would bloat the spec without adding value.

**2. Sharding Migration**: Don't model session catalog migration between shards (session_catalog_migration*.cpp files). Focus on single-node session lifecycle.
   - **Why**: Out of scope for session catalog's core concurrent access patterns; migration is a higher-level concern.

**3. Network RPC Details**: Don't model RPC message ordering or network delays. Assume all inter-node communication is atomic.
   - **Why**: Session catalog itself doesn't handle network; messaging is handled by upper layers.

**4. Metrics/Logging**: Don't model the stats updates and log messages throughout the code.
   - **Why**: Observable metrics don't affect correctness; would clutter the spec with non-essential detail.

**5. Memory Management**: Don't model the unique_ptr ownership and deletion of SessionRuntimeInfo.
   - **Why**: C++ memory management is not a concurrency bug source in this code (mutex already protects the map). TLA+ doesn't model memory ownership anyway.

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| SessionStatePerSession | sessionState: SessionId → {AVAILABLE, CHECKED_OUT, KILLING, KILLED} | Explicit state tracking for each session to verify transition invariants | Family 1 |
| KillRequestTracking | killCount: SessionId → int, interruptPending: SessionId → bool | Separate counter from actual interrupt request to verify coupling | Family 4 |
| ParentChildTracking | parentOf: SessionId → SessionId, childrenOf: SessionId → Set[SessionId] | Track parent-child relationships explicitly for reap verification | Family 2 |
| BackgroundJobModel | refreshRunning: bool, reapRunning: bool, lastRefreshTime: time, lastReapTime: time | Model background refresh/reap jobs as concurrent with foreground operations | Family 3 |
| ReapMarking | markedForReap: SessionId → bool, reapMode: SessionId → {EXCLUSIVE, NONEXCLUSIVE} | Track reap decisions separately from actual reaping | Family 2 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| KillCountNonNegative | Safety | ∀s: killsRequested[s] ≥ 0 | Family 4 |
| CheckedOutXorKilled | Safety | ∀s: ¬(sessionState[s] = CHECKED_OUT ∧ killsRequested[s] > 0) | Family 1 |
| ParentNotReapedWithChildren | Safety | ∀p: markedForReap[p] ∧ reapMode[p] ≠ EXCLUSIVE ⟹ ∃c ∈ childrenOf[p]: markedForReap[c] | Family 2 |
| NoOrphanedChildren | Safety | ∀c: c is a child ⟹ parentOf[c] is in catalog | Family 2 |
| InterruptSentBeforeCheckoutWait | Safety | If kill() increments killsRequested[s], then before any checkout waits on s, interrupt() must have been called | Family 4 |
| RefreshReapOrdering | Liveness | Refresh job and reap job must eventually complete; sessions must not remain permanently un-reaped if expired | Family 3 |
| SessionEventuallyAvailable | Liveness | If a session is killed, it must eventually be available for killing again (no permanent locks) | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | Can a session be simultaneously checked out and killed by two threads? | CheckedOutXorKilled violation | Family 1 |
| MC2 | Can killsRequested > 0 for a session that never gets interrupted? | No interrupt sent but counter > 0 | Family 4 |
| MC3 | Can a parent session be reaped while new children are being created? | NoOrphanedChildren violation | Family 2 |
| MC4 | Can refresh add a session back to cache after reap removes it? | Session appears in both cache and reap list | Family 3 |
| MC5 | Can two killers race to interrupt the same operation, leaving one with stale opCtx pointer? | Use-after-free or double-interrupt | Family 1 |
| MC6 | Can _shouldBeReaped() return true for a session that is actually being checked out concurrently? | Session reaped while operation running | Family 1, 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV1 | Verify that kill() always interrupts running operations synchronously | Insert breakpoint in interrupt handler, verify it's called for all killed sessions with operations |
| TV2 | Verify that a session with killsRequested > 0 can never be checked out except via checkOutSessionForKill | Add assertion in _checkOutSessionInner that forKill is true if session is killed |
| TV3 | Verify refresh and reap don't create duplicate session entries | Add uniqueness assertion to the sessions collection after refresh/reap cycle |
| TV4 | Verify no orphaned child sessions exist after reap completion | Scan all parent-child relationships after reap, assert all children have valid parents |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | The unlock-to-callback pattern in _releaseSession (line 412-415) assumes the callback won't modify session state. Document this invariant. | Add comment explaining callback must not access catalog without re-acquiring lock |
| CR2 | The backSwap pattern in _refresh (lines 336-346) is complex and error-prone. Consider using a cleaner transactional pattern. | Refactor to make the refresh atomicity more explicit |
| CR3 | Parent-child reap logic uses different reap modes (EXCLUSIVE vs NONEXCLUSIVE) but the design isn't clearly documented. | Add design doc explaining parent-child reap semantics |
| CR4 | The _isDead() method (logical_session_cache.h:118) isn't shown in provided code; verify it correctly compares expiration times | Review _isDead implementation for off-by-one errors in time comparison |

---

## 7. Reference Pointers

- **Core Files**:
  - `src/mongo/db/session/session_catalog.h` (lines 69-531) - SessionCatalog, ObservableSession, OperationContextSession classes
  - `src/mongo/db/session/session_catalog.cpp` (all lines) - Implementation of checkout, kill, reap, release operations
  - `src/mongo/db/session/logical_session_cache.h` (lines 57-129) - LogicalSessionCache interface
  - `src/mongo/db/session/logical_session_cache_impl.h` (lines 71-135) - LogicalSessionCacheImpl declaration
  - `src/mongo/db/session/logical_session_cache_impl.cpp` (all lines) - Background refresh/reap job implementation

- **Key Functions**:
  - Session checkout: `SessionCatalog::_checkOutSessionInner()` (session_catalog.cpp:105)
  - Session kill: `ObservableSession::kill()` (session_catalog.cpp:447)
  - Session release: `SessionCatalog::_releaseSession()` (session_catalog.cpp:354)
  - Session reap: `SessionCatalog::scanSessionsForReap()` (session_catalog.cpp:234)
  - Cache refresh: `LogicalSessionCacheImpl::_refresh()` (logical_session_cache_impl.cpp:277)
  - Cache reap: `LogicalSessionCacheImpl::_reap()` (logical_session_cache_impl.cpp:209)

- **Related MongoDB Issues** (example patterns, not specific URLs):
  - Search MongoDB/mongo GitHub issues for keywords: "session", "race", "deadlock", "checkout", "kill", "reap"
  - Review PRs modifying session_catalog.cpp or logical_session_cache_impl.cpp for historical bug context

- **Reference Implementation**: None (MongoDB is canonical for logical session lifecycle)

---

## Verification Strategy

**Phase 1 (Trace Validation)**: Collect traces from running MongoDB with session operations (checkout, kill, reap, refresh) and validate against the spec.

**Phase 2 (Model Checking)**: Run TLC on the spec focusing on the families identified above, with error injection for race conditions (e.g., forcing kill during checkout).

**Phase 3 (Invariant Confirmation)**: Verify that no trace violates the proposed invariants, especially CheckedOutXorKilled, ParentNotReapedWithChildren, and NoOrphanedChildren.

