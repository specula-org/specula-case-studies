# Analysis Report: MongoDB Session Lifecycle — Reaper + Prepared Transaction Interaction

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git commits analyzed (session + transaction dirs) | 150+ |
| Jira tickets deeply read (full discussion) | 27 |
| Jira tickets confirmed bugs | 25 |
| Jira tickets disputed/gone-away | 2 |
| Source files deeply read | 12 |
| New findings from deep analysis | 15 |
| Bug families identified | 5 |

## Phase 1: Reconnaissance

### Core Modules

| Module | Key File | LOC | Purpose |
|--------|----------|-----|---------|
| Session Catalog | `session_catalog.cpp` / `.h` | 604 / 585 | In-memory session checkout/checkin with mutex + condition variable |
| Session Catalog (mongod) | `session_catalog_mongod.cpp` / `.h` | 831 / 209 | Mongod-specific: reaping, step-up, disk cleanup |
| Transaction Participant | `transaction_participant.cpp` / `.h` | 3730 / 1394 | Transaction state machine, prepare/commit/abort, stash/unstash |
| Kill Sessions Local | `kill_sessions_local.cpp` / `.h` | 411 / 45 | Session kill paths for step-down, expiry, cache pressure |
| Logical Session Cache | `logical_session_cache_impl.cpp` / `.h` | 496 / 135 | Cache with periodic refresh (5 min) and periodic reap (5 min) |
| Internal Reap Service | `internal_transactions_reap_service.cpp` / `.h` | 159 / 127 | Asynchronous eager reap of child sessions |
| Transaction Interface | `session_catalog_mongod_transaction_interface_impl.cpp` | 234 | Bridge between session catalog and transaction participant |

### Concurrency Model

**Threads and their roles:**

1. **Client operation threads** — Check out sessions via `OperationContextSession`, perform work, check in on destruction
2. **Reaper thread** — Periodic job (`LogicalSessionCacheReap`) every 5 minutes, scans for expired sessions, deletes from memory and disk
3. **Refresh thread** — Periodic job (`LogicalSessionCacheRefresh`) every 5 minutes, syncs cache to `config.system.sessions`, kills cursors for ended sessions
4. **Kill-op thread** — Spawned during step-down, scans and kills all checked-out sessions
5. **Eager reap thread pool** — Single-threaded pool in `InternalTransactionsReapService`, deletes disk records for eagerly-reaped child sessions
6. **Step-up thread** — Runs `onStepUp()`, restores prepared transaction locks, aborts in-progress transactions

**Synchronization primitives:**

| Primitive | Location | Protects |
|-----------|----------|----------|
| `SessionCatalog::_mutex` | `session_catalog.h:285` | `_sessions` map, all `SessionRuntimeInfo` fields |
| `SessionRuntimeInfo::availableCondVar` | `session_catalog.h:215` | Per-session checkout availability |
| `LogicalSessionCacheImpl::_mutex` | `logical_session_cache_impl.h:126` | `_activeSessions`, `_endingSessions`, `_stats` |
| Client lock (`stdx::lock_guard<Client>`) | Various | `TransactionParticipant::ObservableState` |
| RSTL (Replication State Transition Lock) | Various | Primary/secondary transitions, prepared txn commit/abort |
| `_exitPreparePromise` / `_completionPromise` | `transaction_participant.h:199-200` | Wait for prepared transaction to exit prepare state |
| `InternalTransactionsReapService::_mutex` | `internal_transactions_reap_service.h:122` | `_lsidsToEagerlyReap`, `_enabled` |

### Session Lifecycle State Machine

```
Session created (first checkout)
  → Available (checkoutOpCtx = null)
    → Checked Out (checkoutOpCtx = opCtx, lastCheckout updated)
      → Available (checkoutOpCtx = null, availableCondVar notified)

  → Kill Requested (killsRequested > 0, operation interrupted)
    → Checked Out For Kill (kill token passed to checkOutSessionForKill)
      → Available (killsRequested--, availableCondVar notified)

  → Marked For Reap (via scanSessionsForReap)
    → Erased from _sessions map (if _shouldBeReaped: !isCheckedOut && !_numWaitingToCheckOut && !_killed)
```

### Transaction State Machine

```
kNone → kInProgress → kPrepared → kCommitted
                    → kAbortedWithoutPrepare
                    → kPrepared → kAbortedWithPrepare
kNone → kExecutedRetryableWrite
```

Legal transitions (from `transaction_participant.cpp:3020-3088`):
- kNone → {kNone, kInProgress, kExecutedRetryableWrite}
- kInProgress → {kNone, kPrepared, kCommitted, kAbortedWithoutPrepare}
- kPrepared → {kAbortedWithPrepare, kCommitted}
- kCommitted → {kNone}
- kAbortedWithoutPrepare → {kNone, kInProgress}
- kAbortedWithPrepare → {kNone}
- kExecutedRetryableWrite → {kNone}

---

## Phase 2: Bug Archaeology

### Historical Bugs — Complete Catalog

#### Reaper / Session Lifecycle Bugs

| Ticket | Severity | Summary | Fixed |
|--------|----------|---------|-------|
| SERVER-105751 | Critical | Router reaper destroys prepared txn; NoSuchTransaction misinterpreted as commit → torn transactions | 8.2.0, 8.0.13 |
| SERVER-67723 | Major | Reaper deletes on-disk state before logical session expires, interrupting active operations | 6.0.1 |
| SERVER-61816 | Major | Race between transaction reaper and coordinator; coordinator hangs trying to handle reaped session | 4.2.19, 5.0.6 |
| SERVER-37837 | Major | Read-only TransactionParticipant never cleaned up (invisible to reaper) | 4.0.13 |
| SERVER-37348 | Major | TransactionReaper aborts transactions on secondaries (should only come from oplog) | 4.1.9 |
| SERVER-34810 | Major | Session cache refresh kills cursors still in use (race between write and cursor scan) | 3.6.6 |
| SERVER-34833 | Major | Deadlock between session reaper and MMAP V1 durability thread | 3.6.6 |
| SERVER-37511 | Major | Reaper/refresh setup with createIndexes blocks replication | 3.6.10 |

#### Step-Down / Session Deadlocks

| Ticket | Severity | Summary | Fixed |
|--------|----------|---------|-------|
| SERVER-75205 | Blocker P1 | Read ticket exhaustion during lock restore blocks step-down | 4.4.20, 5.0.16, 6.0.6 |
| SERVER-59226 | Critical P2 | Uninterruptible profile session blocks step-down | 4.4.11, 5.0.4 |
| SERVER-52564 | Major | Classic deadlock: step-down vs session checkout | 4.4.6 |
| SERVER-55007 | Major | Same deadlock from `_stepDownFinish` | 4.4.6 |
| SERVER-48641 | Major | Migration holds session during awaitReplication → deadlock | 4.4.1 |
| SERVER-48689 | Major | Migration waits for thread join with session checked out → deadlock | 4.4.1 |
| SERVER-55573 | Major | Chunk migration session escapes killSessions during step-down | 4.4.7 |
| SERVER-117908 | Major | Kill-op thread hangs indefinitely; fix crashes node on timeout | 8.2+ |

#### Prepared Transaction + Lock Hierarchy Deadlocks

| Ticket | Severity | Summary | Fixed |
|--------|----------|---------|-------|
| SERVER-65821 | Critical P2 | setFCV deadlock with prepared txns | 4.4.15, 5.0.10 |
| SERVER-66340 | Major | Introduced MultiDocumentTransactionsBarrier to prevent entire deadlock class | 5.0+ |
| SERVER-71191 | Major | Index build + prepared txn + step-down three-way deadlock | 4.4.19, 6.0.4 |
| SERVER-48531 | Major | Chunk splitter + prepared txn + step-down | 4.4.1 |
| SERVER-57476 | Major | Oplog slot held during prepare-conflict stalls replication entirely | 4.2.15, 4.4.7 |
| SERVER-40700 | Major | Range deleter in prepare-conflict retry loop blocks step-down | 4.1.12 |
| SERVER-103744 | Major | renameCollection + dbHash + prepared txn deadlock | 8.2.0 |
| SERVER-40594 | Major | Range deleter prepare conflict blocks step down | 4.1.12 |

#### Failover / State Race Bugs

| Ticket | Severity | Summary | Fixed |
|--------|----------|---------|-------|
| SERVER-106075 | Major | apiVersion not preserved across failover → torn transactions | 7.0.26, 8.0.16, 8.2.2 |
| SERVER-71219 | Critical P2 | Migration misses writes from prepared transactions (data loss) | 4.4.19, 6.0.5 |
| SERVER-66110 | Major | FCV downgrade changes active txnNumber between yield/unyield | 6.0.0 |
| SERVER-46238 | Major | Race between commitTransaction and periodic abort thread | 4.0.17 |
| SERVER-59108 | Major | Transaction not killed after step-down (flag-setting race) | 4.4.11, 5.0.4 |
| SERVER-44260 | Major | Transaction conflicts due to held-back all-committed point | 4.2.4 |

#### Kill Session / Accounting Bugs

| Ticket | Severity | Summary | Fixed |
|--------|----------|---------|-------|
| SERVER-106318 | Major | killOldestTransaction undercounts kills (abort happens during kill-checkout) | 8.0+ |
| SERVER-92607 | Major | Eager reaping corrupts yielded TransactionRouter state | 7.0+ |
| SERVER-78187 | Major | Killing child session doesn't propagate interrupt to parent | 6.0+ |
| SERVER-36485 | Major | killSessions should return PreparedTransactionInProgress | 4.1.7 |

### Bug Hotspot Analysis

Files most frequently touched in bug-fix commits:

1. `session_catalog_mongod.cpp` — 12 bug-fix commits
2. `transaction_participant.cpp` — 11 bug-fix commits
3. `kill_sessions_local.cpp` — 9 bug-fix commits
4. `session_catalog.cpp` — 5 bug-fix commits
5. `logical_session_cache_impl.cpp` — 4 bug-fix commits
6. `internal_transactions_reap_service.cpp` — 3 bug-fix commits

---

## Phase 3: Deep Analysis — New Findings

### Finding 1: killsRequested Leak on Interrupt During checkOutSessionForKill

**Location**: `session_catalog.cpp:136-148`

**Description**: In `_checkOutSessionInner`, if `waitForConditionOrInterruptUntil` at line 136 **throws** (as opposed to timing out by returning false), the `killsRequested` counter is never decremented when a `killToken` is present. The `ON_BLOCK_EXIT` at line 129 only decrements `_numWaitingToCheckOut`, not `killsRequested`.

**Consequence**: The session permanently has `killsRequested > 0`, blocking all normal checkouts (`_isAvailableForCheckOut` requires `!_killed()`) and all reaping (`_shouldBeReaped` requires `!_killed()`). The session becomes a permanent zombie.

**Trigger**: The opCtx passed to `checkOutSessionForKill` is interrupted while waiting (via `killOp`, shutdown, or `maxTimeMS`). The caller in `kill_sessions_local.cpp:126` only catches `ExceededTimeLimit`, so `Interrupted` exceptions propagate without cleanup.

**Compensating mechanisms**: The `checkOutSessionForKill` now has an explicit deadline (SERVER-77172 fix) which causes timeout (returns false, decrements correctly) rather than interrupt for most cases. However, external interrupts (shutdown, killOp) can still cause throws.

**Severity**: Medium — requires specific interrupt timing during kill checkout, but creates permanent state corruption.

**Classification**: Model-checkable (MC-2).

### Finding 2: Eager Reap tassert Allows markForReap to Proceed in Production

**Location**: `session_catalog_mongod_transaction_interface_impl.cpp:227-230`

**Description**: The `tassert(9260700, ...)` checking `txnParticipant.canBeReaped()` is a tripwire assertion — non-fatal in production builds. If it fires, the code continues to `markForReap()` at line 230, potentially marking a non-reapable session for reaping.

**Compensating mechanism**: The subsequent `_shouldBeReaped()` check in `scanSessionsForReap` prevents actual removal if the session is checked out or killed. But if the session is idle (not checked out, not killed, not waiting), it could be reaped despite `canBeReaped()` returning false.

**Severity**: Low — requires the tassert to fire AND the session to be idle simultaneously.

### Finding 3: InternalTransactionsReapService Loses Sessions on Step-Down

**Location**: `internal_transactions_reap_service.cpp:138-158`

**Description**: Sessions are swapped out of `_lsidsToEagerlyReap` at line 139 (under mutex) BEFORE the disk deletion at line 150. If the deletion fails (e.g., step-down interrupt), the catch block at line 154-158 silently logs and ignores the error. The sessions were already removed from the buffer and are not re-queued.

**Compensating mechanism**: The periodic reaper will eventually clean these records from disk. But until then, the "eager" reap promise is violated — session records persist longer than expected.

**Severity**: Low — compensated by periodic reaper, but introduces latency in cleanup.

### Finding 4: endSessions() Does Not Check for Prepared Transactions

**Location**: `logical_session_cache_impl.cpp:457-465`

**Description**: `endSessions()` only validates that IDs are parent sessions (line 459-461) and adds them to `_endingSessions` (line 464). No check for prepared transactions, active transactions, or any session state. During the next `_refresh()`, the session record is removed from `config.system.sessions` (line 406), and its cursors are killed (line 448). But transactions are not checked.

**Consequence**: A session with a prepared transaction can have its `config.system.sessions` entry removed. This puts the session in a state where the reaper's `findRemovedSessions()` returns it as "removed", potentially triggering disk record deletion. However, the in-memory reaper checks `canBeReaped()` which returns false for prepared transactions.

**Risk**: The gap is between the in-memory check (which correctly blocks) and the disk reaper's `removeExpiredTransactionSessionsFromDisk()` which only checks `findRemovedSessions()`. On the current code, the disk reaper also calls `removeSessionsTransactionRecordsIfExpired()` which re-checks `findRemovedSessions()` but does NOT check the transaction state. It relies on the in-memory scan having already filtered out prepared sessions.

**Severity**: Medium — requires endSessions on a session with a prepared txn, followed by a reaper cycle that reaches the disk-deletion path.

**Classification**: Model-checkable (MC-3).

### Finding 5: _resetTransactionStateAndUnlock Observable Window

**Location**: `transaction_participant.cpp:3696-3703`

**Description**: Client lock is released at line 3696, then TxnResources are destroyed at line 3703. Between these lines, another thread can observe the session in its new state (kAborted/kNone) while the old RecoveryUnit is still performing rollback on the original thread's stack.

**Compensating mechanism**: The session checkout mechanism prevents another thread from checking out the session until the release completes (which happens after resource destruction). But the promises (`_exitPreparePromise`, `_completionPromise`) are already fulfilled before line 3696, so any thread waiting on those promises can proceed and observe the intermediate state.

**Severity**: Low — the promise waiters don't re-acquire the session.

### Finding 6: Promise Fulfillment Under Client Lock

**Location**: `transaction_participant.cpp:3090-3125`

**Description**: `_exitPreparePromise` and `_completionPromise` are fulfilled in `transitionTo()` while the Client lock is held by the caller (`_resetTransactionStateAndUnlock`). If any continuation attached to these promises runs synchronously and attempts to acquire the same Client lock, it would deadlock.

**Compensating mechanism**: The comment at `transaction_participant.h:624-626` warns against waiting on the future with the session checked out. MongoDB's promise/future implementation (`future_impl.h`) runs ready callbacks inline, so this concern is real if any continuation tries to access the same Client.

**Severity**: Low — the current codebase appears to only use these futures across different Clients.

### Finding 7: TODO SERVER-58243 — Lock Acquisition on Timestamped WUOW May Block

**Location**: `transaction_participant.cpp:470` and `transaction_participant.cpp:2618`

**Description**: Two locations use `AllowLockAcquisitionOnTimestampedUnitOfWork` to override a safety check. The TODO acknowledges uncertainty about whether this lock acquisition can block. If it can, it would create priority inversion with prepared transactions.

**Severity**: Medium — acknowledged by developers as an open question. Appears in both `updateSessionEntry()` (session record update during commit) and `_abortActivePreparedTransaction()` (abort path).

### Finding 8: Commented-Out Destructor Invariant

**Location**: `transaction_participant.cpp:591`

**Description**: `invariant(!_o.txnState.isInProgress())` is commented out in the TransactionParticipant destructor. This means a participant can be destroyed while a transaction is still in-progress without triggering an assertion.

**Implication**: There exist code paths where a TransactionParticipant is destroyed (e.g., session eviction, catalog reset) while its transaction is still in-progress. The developers chose to suppress the assertion rather than fix the lifecycle issue.

### Finding 9: _refresh() Evicts Successfully Refreshed Sessions from Cache

**Location**: `logical_session_cache_impl.cpp:372, 386-403`

**Description**: After `activeSessionsBackSwapper.dismiss()` at line 372, `_activeSessions` contains only sessions added by concurrent `vivify()`/`startSession()` calls during the refresh window, plus failed sessions put back at lines 394-398. All successfully refreshed sessions are evicted from the in-memory cache.

**Consequence**: `peekCached()` returns `boost::none` for sessions that were just successfully persisted. This is by design (the cache is ephemeral and sessions re-vivify on use), but it means the cache is unreliable for session existence checks.

### Finding 10: Non-Atomic Image/Transaction Deletion (Design Choice)

**Location**: `session_catalog_mongod.cpp:245-294`

**Description**: Image records are deleted from `config.image_collection` (lines 253-270) before transaction records from `config.transactions` (lines 273-291). If image deletion succeeds but transaction deletion fails, the transaction record has a dangling reference to a non-existent image.

**Documentation**: The comment at lines 245-249 explicitly acknowledges this: "we'll only be left with sessions that have a dangling reference to an image." The next reap cycle will retry.

**Risk**: Code that reads a transaction record and expects a corresponding image will see inconsistent state. This is documented and accepted.

### Finding 11: TOCTOU in On-Disk Reaping

**Location**: `session_catalog_mongod.cpp:301-334`

**Description**: Between `findRemovedSessions()` at line 320 and `removeSessionsTransactionRecordsFromDisk()` at line 333, a session could be re-added to `config.system.sessions` via a `refreshSessions` command. The deletion would then remove transaction state for a now-live session.

**Severity**: Low — requires session re-activation in a very narrow window.

### Finding 12: Dead Code in LogicalSessionCacheImpl

**Location**: `logical_session_cache_impl.h:118,132`

- `_isDead()` declared but never defined or used
- `_lastRefreshTime` declared but never written or read

These are leftover from a prior implementation.

### Finding 13: Step-Up Lock Restoration Has No Per-Session Error Handling

**Location**: `session_catalog_mongod.cpp:597-629`

**Description**: The loop restoring locks for prepared transactions during step-up has no try-catch around individual sessions. If lock restoration fails for one session, the entire `onStepUp()` throws, leaving subsequent prepared transactions without restored locks.

**Design**: This is documented as intentional — failure to restore locks for a prepared transaction is considered fatal to step-up.

### Finding 14: Reap and Refresh Run Concurrently Without Coordination

**Location**: `logical_session_cache_impl.cpp:110-123`

**Description**: Both periodic jobs run on separate threads with no mutual exclusion beyond brief mutex grabs. They can perform concurrent reads and writes to `config.system.sessions`, leading to stale-read races where the reaper incorrectly determines a session is alive (or dead).

**Severity**: Low — self-heals on next cycle.

### Finding 15: endSessions + vivify Race

**Location**: `logical_session_cache_impl.cpp:457-465, 140-153`

**Description**: `endSessions()` adds to `_endingSessions` but doesn't remove from `_activeSessions`. A concurrent `vivify()` can update the session's `lastUse` time in `_activeSessions`. During `_refresh()`, the session is first refreshed (upserted to `config.system.sessions`) then removed — a wasted write.

**Severity**: Very low — performance issue, no correctness impact.

---

## Phase 4: Bug Family Summary

See `modeling-brief.md` for the organized Bug Families, modeling recommendations, proposed extensions, proposed invariants, and findings pending verification.

### Key Modeling Priority Order

1. **Reaper + Prepared Transaction Safety** (Family 1) — Most severe historical bugs, most new findings
2. **Step-Down Session Deadlock Cycle** (Family 2) — Most numerous historical bugs, includes P1 blocker
3. **endSessions + Reaper Interaction** (Family 5) — New finding MC-3 is the most promising for discovery
4. **Failover State Races** (Family 4) — Medium priority, most bugs already fixed
5. **Lock Hierarchy Deadlocks** (Family 3) — Important but requires too many lock types for practical TLA+ modeling
