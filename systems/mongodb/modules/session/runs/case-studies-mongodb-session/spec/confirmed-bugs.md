# Confirmed Bug Report — mongodb-session

## Summary
- Total findings reviewed: 12 (1 MC-confirmed new bug, 1 known design limitation, 7 MC-tested-no-violation, 3 code-review-only)
- Reproduced: 1
- Historical (known JIRA): 20+ (SERVER-105751, SERVER-67723, SERVER-52564, etc.)
- False positives: 0
- Inconclusive: 0

The single MC-confirmed NEW bug was successfully reproduced on MongoDB 8.x. All other MC hunting configs (5 configs, up to 193M states) found no additional violations. Historical bugs are classified but not re-reproduced per the bug confirmation guide.

---

## Bug 1: endSessions() Removes Session with Prepared Transaction

- **Source**: Model Checking (TLC BFS, 5-state counterexample)
- **Status**: REPRODUCED
- **Severity**: Medium-High
- **Location**: `logical_session_cache_impl.cpp:457-465` (endSessions), `logical_session_cache_impl.cpp:348-406` (_refresh)
- **MC Config**: MC_hunt_endsession.cfg
- **MC Output**: output/MC_hunt_endsession_bfs_r2.out
- **Invariant violated**: EndSessionSafety

### Description

`LogicalSessionCacheImpl::endSessions()` accepts any parent session ID for ending without checking transaction state. The only validation is `isParentSessionId()`. When a session with a prepared (or in-progress) transaction is passed to `endSessions`, the session is unconditionally marked for removal from `config.system.sessions`.

During the next `_refresh()` cycle:
1. `_endingSessions` is swapped to `explicitlyEndingSessions` (line 329)
2. The session is removed from `activeSessions` (line 349-351)
3. Running operation sessions that are in `explicitlyEndingSessions` are **skipped** (line 360-362), even if they have active prepared transactions
4. `removeRecords()` unconditionally deletes the session from `config.system.sessions` (line 406)

This contrasts with `killOldestTransaction()` (`kill_sessions_local.cpp:248`) which explicitly filters out prepared transactions with `transactionIsPrepared()`.

### MC Counterexample (5 states)

| State | Action | Key Change |
|-------|--------|------------|
| 1 | Initial | All sessions idle, in cache, node is primary |
| 2 | CheckOutSession(t1, s1) | Thread t1 checks out session s1 |
| 3 | EndSession(s1) | s1 added to endingSessions, removed from cache |
| 4 | BeginTransaction(t1) | Transaction started (txnState = "inProgress") |
| 5 | PrepareTransaction(t1) | **txnState = "prepared" but sessionInCache = FALSE** |

At state 5: `sessionInCache[s1] = FALSE` but `txnState[s1] = "prepared"` — EndSessionSafety violated.

### Trigger Scenario

1. Client A starts session s1 and checks it out
2. Admin/monitoring/other client calls `endSessions([s1])` (e.g., during session cleanup)
3. Client A starts and prepares a distributed transaction on s1
4. Periodic `_refresh()` runs: session removed from `config.system.sessions`
5. Result: session has a prepared transaction but is no longer tracked

In a sharded cluster, the router or coordinator may call `endSessions` independently from the transaction lifecycle. The `endSessions` command is also callable by any authenticated user, not just the session owner.

### Impact

- **Tracking inconsistency**: `config.transactions` still has the prepared transaction record, but `config.system.sessions` no longer tracks the session
- **Defense-in-depth violation**: The only remaining guard against reaping the prepared transaction is `canBeReaped()` (returns `!transactionIsOpen()`). This is exactly the single-layer defense pattern that failed in SERVER-105751
- **Session appears orphaned**: Monitoring tools that query `config.system.sessions` will not see this session, even though it holds a prepared transaction with locks
- **Future risk**: If any reaper code path bypasses `canBeReaped()` (as happened in SERVER-105751 with the router reaper), this becomes a data loss vector — the coordinator may misinterpret NoSuchTransaction as commit success, creating torn transactions

### Reproduction Test

- **File**: `repro/test_bug1_endsession_prepared.sh`
- **Requires**: Docker
- **MongoDB version**: 8.x (tested with `mongo:8` image)
- **Result**: BUG REPRODUCED — session removed from `config.system.sessions` while prepared transaction is active

**Steps**:
1. Start single-node replica set with `enableTestCommands=1`
2. Create session, vivify with a non-transactional insert
3. Force refresh — verify session is in `config.system.sessions` (count=1)
4. Start transaction, insert, prepare
5. Call `endSessions` with the session ID — succeeds (no txn state check)
6. Force refresh — `_refresh()` processes `_endingSessions`
7. Query `config.system.sessions` — **session is GONE** (count=0)
8. Query `config.transactions` — **prepared txn record still exists** (count=1)

**Output**:
```
Sessions in config.system.sessions BEFORE: 1
Sessions in config.system.sessions AFTER:  0
Prepared txn record in config.transactions:  1
RESULT: *** BUG REPRODUCED ***
```

### Developer Intent Investigation

- No existing JIRA ticket found for this specific scenario
- `endSessions` was designed as a lightweight cleanup command (no transaction awareness)
- The `_refresh()` code at line 360-362 deliberately skips running ops in `explicitlyEndingSessions` — this means MongoDB's designers intended ended sessions to be removed unconditionally
- However, `killOldestTransaction()` at line 248 shows awareness that prepared transactions need special handling — this guard is missing from `endSessions`
- The SERVER-105751 fix added guards in the reaper but did not add guards to the `endSessions` path

### Recommendation

Add a prepared transaction guard. Two options:

**Option A — Guard in `endSessions()`**: Check `SessionCatalog` for prepared transactions before accepting the session for ending. Reject or silently skip sessions with open transactions.

**Option B — Guard in `_refresh()`**: Before calling `removeRecords()` at line 406, filter `explicitlyEndingSessions` to exclude sessions that have active prepared transactions (requires checking `TransactionParticipant` state via `SessionCatalog::scanSessions()`).

Option B is lower risk (doesn't change the `endSessions` API contract) and mirrors how the reaper uses `canBeReaped()`.

---

## Design Limitation: Non-Atomic Disk Deletion (F1)

- **Source**: Model Checking (fault injection)
- **Status**: KNOWN DESIGN CHOICE (not a new bug)
- **Severity**: Low
- **Location**: `session_catalog_mongod.cpp:253-294`

The reaper deletes session records in two steps: image records first (lines 253-270), then transaction records (lines 272-294). If the node fails between these two operations, image records are deleted but transaction records persist. This is self-healing: the next successful reaper run cleans up both.

The `DiskConsistency` invariant was intentionally weakened to only check during idle state (`reaperPhase = "idle"`).

---

## Not Reproduced (MC Hunting Results)

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| F1: Reaper destroys prepared txn (normal path) | MC_hunt_reaper_nofault.cfg | 3,930 BFS + 150M sim | No violation — `canBeReaped()` guard effective |
| F1: Reaper via bypass (SERVER-105751 pattern) | MC_hunt_reaper.cfg | 323 BFS | Confirmed by fault injection (expected, known pattern) |
| F1: Non-atomic disk deletion | MC_hunt_disk.cfg | ~300 BFS | DiskConsistency weakened to tolerate known design |
| F2: Step-down deadlock / killsRequested leak | MC_hunt_stepdown.cfg | 10,939 BFS + 193M sim | No violation |
| F3: Lock hierarchy deadlock | — | — | Not testable (lock hierarchy not modeled per brief) |
| F4: Failover state races | — | — | Not testable (resource stash/unstash not modeled) |

---

## Historical Bugs (Known JIRA Tickets)

These bugs have existing JIRA tickets and do not require reproduction per the bug confirmation guide. They informed the spec design and hunting strategies.

### Family 1: Session Reaper Destroys Active/Prepared Transaction State
- **SERVER-105751** (Critical): Router reaper bypassed prepared txn check → data loss
- **SERVER-67723**: Reaper interrupted expired internal transaction sessions
- **SERVER-92607**: Eager reaping removed sessions with yielded TransactionRouter
- **SERVER-37837**: Read-only TransactionParticipant never cleaned up
- **SERVER-36483**: Transaction reaper removed prepared transaction records
- **SERVER-78187**: Killing child session interrupted sibling sessions

### Family 2: Step-Down / Session Checkout Deadlock
- **SERVER-52564** (P2): Step-down waits for session, session blocked on RSTL
- **SERVER-48641**: Migration destination manager deadlock
- **SERVER-59226** (P2): Uninterruptible profile session blocks step-down
- **SERVER-117908**: Kill-op thread hangs indefinitely during step-down
- **SERVER-75205** (P1): Read ticket exhaustion blocks step-down
- **SERVER-55573**: Chunk migration worker threads miss kill signal
- **SERVER-55007**: Variant of SERVER-52564

### Family 3: Prepared Transaction + Lock Hierarchy Deadlock
- **SERVER-65821** (P2): setFCV vs prepared txn vs coordinator commit
- **SERVER-66340**: MultiDocumentTransactionsBarrier introduced
- **SERVER-71191**: Index build + prepared txn + step-down
- **SERVER-48531**: Chunk splitter prepare-conflict + step-down
- **SERVER-57476**: Oplog slot held during prepare-conflict
- **SERVER-40700**: Range deleter prepare-conflict + step-down

### Family 4: Session/Transaction State Races During Failover
- **SERVER-106075** (Critical): apiVersion not preserved during failover → torn txns
- **SERVER-66110**: FCV downgrade changes txnNumber between yield/unyield
- **SERVER-59108**: Race between adding op to ServiceContext and interrupt flag
- **SERVER-46238**: Race between commit and periodic abort

### Family 5: Kill/Reap Accounting
- **SERVER-106318**: killOldestTransaction undercounted kills
- **SERVER-34810**: _refresh() killed cursors for newly-created sessions

---

## Code Review Findings (Not Bugs)

These were identified during modeling and code analysis but are not actionable bugs:

| ID | Description | Disposition |
|----|-------------|-------------|
| CR-1 | TODO SERVER-58243: Lock acquisition on timestamped WUOW | Open question in code, not a current bug |
| CR-2 | TODO SERVER-106429: Prepared txns use opCtx API params | Related to SERVER-106075 fix, tracked |
| CR-3 | Commented-out destructor invariant (transaction_participant.cpp:591) | Intentionally disabled |
| CR-4 | TODO SLS-2079: Split prepared transaction handling | Tracked in ticket |
| CR-5 | Dead code: _isDead() declared but never defined | Minor cleanup |
