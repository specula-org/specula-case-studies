# Modeling Brief: MongoDB Session Lifecycle — Reaper + Prepared Transaction Interaction

## 1. System Overview

- **System**: MongoDB session lifecycle management — session catalog, reaper, kill-sessions, and prepared transaction interaction
- **Language**: C++, ~6000 LOC core logic across 7 key files
- **Protocol**: Session checkout/checkin with exclusive access, periodic reaping, 2PC prepared transactions, step-down coordination
- **Key architectural choices**:
  - Session catalog uses **single mutex + per-session condition variable** for checkout exclusivity (`session_catalog.cpp:105-154`)
  - Reaper runs as a **periodic background thread** (every 5 min) independent of transaction lifecycle (`logical_session_cache_impl.cpp:120-123`)
  - Eager reaping occurs **inside session release** path, during checkin (`session_catalog.cpp:386-397`)
  - Prepared transactions **drop RSTL after prepare** to allow step-down (`transaction_participant.cpp:2086-2090`)
  - Kill-sessions uses a **two-phase approach**: scan-and-mark under mutex, then checkout-for-kill without mutex (`kill_sessions_local.cpp:83-143`)
  - On-disk cleanup is **non-atomic**: image collection deleted before transaction records (`session_catalog_mongod.cpp:245-294`)
  - **12 concurrent actors** interact with sessions: client ops, 2 periodic reapers, refresh thread, kill-op thread, eager reap pool, step-up handler, step-down handler, cache pressure killer, direct-write observer, shutdown handler, invalidateAll
- **Concurrency model**: Multiple threads contend for session checkout; reaper, refresh, and kill threads run independently; step-down coordinates via RSTL and kill tokens. `TransactionParticipant` is a **decoration on Session** (`transaction_participant.cpp:157`), meaning txn state is always accessed through session checkout. `canBeReaped()` returns `!transactionIsOpen()` — false for both kInProgress and kPrepared.

## 2. Bug Families

### Family 1: Session Reaper Destroys Active/Prepared Transaction State (HIGH)

**Mechanism**: The reaper thread removes session state (in-memory or on-disk) without sufficient coordination with the prepared transaction lifecycle, causing NoSuchTransaction errors, torn transactions, or data loss.

**Evidence**:
- Historical: SERVER-105751 — Router reaper path bypassed the prepared transaction check entirely, destroying sessions with active prepared transactions. On primaries: coordinator misinterprets NoSuchTransaction as commit success, creating torn transactions across shards. Critical data loss.
- Historical: SERVER-67723 — Reaper deleted `config.transactions` entries for internal retryable-write sessions before their parent logical session expired, interrupting active operations.
- Historical: SERVER-92607 — Eager reaping removed sessions with yielded TransactionRouter, corrupting router state. Fix added `txnRouter.canBeReaped()` guard.
- Historical: SERVER-37837 — Read-only TransactionParticipant never cleaned up because reaper only examines `config.transactions` entries (read-only txns don't write there).
- Historical: SERVER-36483 — Transaction reaper removed `config.transactions` entries for sessions with active prepared transactions.
- Historical: SERVER-78187 — Killing child session during reap interrupted unrelated sibling sessions.
- Code analysis: `internal_transactions_reap_service.cpp:139` — Eagerly reaped sessions are swapped out of the retry buffer BEFORE the disk deletion attempt. If deletion fails (e.g., step-down), sessions are permanently lost from the eager-reap pipeline. Error swallowed at line 154-158.
- Code analysis: `internal_transactions_reap_service.h:65-66` — Service comment: "does not verify they have actually expired, so callers must guarantee they are safe to remove." This trust boundary is the root cause of SERVER-105751.
- Code analysis: `session_catalog_mongod_transaction_interface_impl.cpp:227-229` — `tassert` in production allows `markForReap` to proceed even when `canBeReaped()` returns false (tripwire assertion is non-fatal in production).

**Affected code paths**:
- `MongoDSessionCatalog::reapSessionsOlderThan()` (`session_catalog_mongod.cpp:707-724`)
- `removeExpiredTransactionSessionsNotInUseFromMemory()` (`session_catalog_mongod.cpp:186-232`)
- `removeExpiredTransactionSessionsFromDisk()` (`session_catalog_mongod.cpp:341-378`)
- `InternalTransactionsReapService::_reapInternalTransactions()` (`internal_transactions_reap_service.cpp:129-159`)
- `_releaseSession()` eager reap path (`session_catalog.cpp:386-397`)

**Suggested modeling approach**:
- Variables: `sessionState [Session -> {idle, checkedOut, killed, reaped}]`, `txnState [Session -> {none, inProgress, prepared, committed, aborted}]`, `diskRecordExists [Session -> BOOLEAN]`, `imageRecordExists [Session -> BOOLEAN]`
- Actions: `ReaperScanMemory`, `ReaperDeleteDisk` (two-step: delete images, then delete transactions), `EagerReap` (inside release path), `CoordinatorCommit`, `CoordinatorAbort`
- Key: Model reaper as a separate process that can interleave between the two disk deletion steps
- Fault injection: `ReaperBypassPreparedCheck` (models the SERVER-105751 pattern), `DiskDeletePartialFailure`

**Priority**: High
**Rationale**: 6 historical bugs including critical data loss (SERVER-105751). The reaper operates outside the session checkout mechanism and relies on best-effort checks. Multiple reaper entry points (periodic, eager, step-up) with inconsistent guards. The `InternalTransactionsReapService` trust boundary is the most dangerous design element — callers must guarantee safety, but the guarantee is not enforced.

---

### Family 2: Step-Down / Session Checkout Deadlock Cycle (HIGH)

**Mechanism**: Step-down requires killing all checked-out sessions (to acquire RSTL in exclusive mode), but session holders may themselves be blocked waiting for locks held by the step-down thread or by prepared transactions, creating circular wait.

**Evidence**:
- Historical: SERVER-52564 — Classic deadlock: step-down waits for session checkout, session holder blocked on RSTL. Three-way circular wait.
- Historical: SERVER-48641 — Migration destination manager holds session while waiting for write concern. Write concern blocked by RSTL. Step-down holds RSTL, waits for session.
- Historical: SERVER-59226 — Profile session marked uninterruptible blocks step-down indefinitely. Critical P2.
- Historical: SERVER-117908 — Kill-op thread for step-down hangs indefinitely. Fix: crash node on configurable timeout.
- Historical: SERVER-75205 — Read ticket exhaustion during lock restore after yield blocks step-down. Blocker P1.
- Historical: SERVER-55573 — Chunk migration dispatches work to unrelated worker threads; step-down kills session but worker threads don't receive kill signal.
- Historical: SERVER-55007 — Variant of SERVER-52564 from `_stepDownFinish` path.
- Code analysis: `session_catalog.cpp:129-148` — `killsRequested` can leak if `waitForConditionOrInterruptUntil` throws (not times out). The `ON_BLOCK_EXIT` at line 129 only decrements `_numWaitingToCheckOut`, NOT `killsRequested`. A leaked counter permanently blocks normal checkout AND reaping.
- Code analysis: `kill_sessions_local.cpp:100-143` — In `killSessionsAction`, if `killSessionFn` throws an uncaught exception mid-iteration, remaining `KillToken`s in the vector are destroyed without decrementing `killsRequested` (KillToken has no RAII cleanup). All remaining sessions become permanently blocked.
- Code analysis: `logical_session_cache_impl.cpp:114,121` — Both refresh and reap periodic jobs are non-killable by step-down (`isKillableByStepdown = false`), TODO SERVER-74659.

**Affected code paths**:
- `_checkOutSessionInner()` (`session_catalog.cpp:105-154`)
- `killSessionsAbortUnpreparedTransactions()` (`kill_sessions_local.cpp:148-177`)
- `yieldLocksForPreparedTransactions()` (`kill_sessions_local.cpp:347-389`)
- `invalidateSessionsForStepdown()` (`kill_sessions_local.cpp:391-411`)
- `_releaseSession()` (`session_catalog.cpp:354-417`)

**Suggested modeling approach**:
- Variables: `rstlState [Server -> {none, enqueued, held}]`, `checkoutAllowed [Server -> BOOLEAN]`, `killsRequested [Session -> Nat]`, `numWaitingToCheckOut [Session -> Nat]`
- Actions: `StepDownBegin` (enqueue RSTL, block checkouts), `StepDownKillSessions` (scan and kill), `StepDownAcquireRSTL` (wait for all sessions released), `CheckOutSession` (blocks if not allowed), `CheckInSession`
- Key: Model the kill-and-wait cycle; step-down must wait for ALL sessions to check in, but killed sessions may be blocked

**Priority**: High
**Rationale**: 7+ historical bugs, including P1 blocker and P2 critical. The step-down/session coordination is the most deadlock-prone area in MongoDB's session system. The `killsRequested` leak finding suggests the problem isn't fully solved.

---

### Family 3: Prepared Transaction + Lock Hierarchy Three-Way Deadlock (HIGH)

**Mechanism**: Prepared transactions hold intent locks indefinitely until commit/abort. Operations requiring exclusive locks (step-down, setFCV, index build, renameCollection) block behind them. If the commit/abort path itself requires a lock held by the exclusive-lock requester, circular deadlock forms.

**Evidence**:
- Historical: SERVER-65821 — setFCV (global S lock) vs prepared txn (intent lock) vs coordinator commit (IX on config.transaction_coordinators). Critical P2.
- Historical: SERVER-66340 — Generalized this class of deadlocks with `MultiDocumentTransactionsBarrier` that drains prepared txns before granting strong global locks.
- Historical: SERVER-71191 — Index build setup + prepared txn + step-down. Three-way deadlock. Backported across 4 version lines.
- Historical: SERVER-48531 — Chunk splitter in prepare-conflict retry loop vs prepared txn vs step-down.
- Historical: SERVER-57476 — Operation holds oplog slot during prepare-conflict, stalling replication entirely.
- Historical: SERVER-40700 — Range deleter in prepare-conflict retry loop blocks step-down.
- Code analysis: `transaction_participant.cpp:470,2618` — TODO SERVER-58243: "evaluate whether this is safe or whether acquiring the lock can block" — open question about lock acquisition on timestamped WUOW in prepared transaction paths.

**Affected code paths**:
- `prepareTransaction()` (`transaction_participant.cpp:1924-2114`) — drops RSTL after prepare
- `commitPreparedTransaction()` (`transaction_participant.cpp:2264-2415`) — reacquires RSTL
- `_abortActivePreparedTransaction()` (`transaction_participant.cpp:2617-2649`) — reacquires RSTL
- Lock acquisition via `AllowLockAcquisitionOnTimestampedUnitOfWork` (`transaction_participant.cpp:470,2618`)

**Suggested modeling approach**:
- Variables: `globalLockMode [Server -> {none, IS, IX, S, X}]`, `rstlMode [Thread -> {none, IS, IX, S, X}]`, `preparedLocks [Session -> SUBSET Lock]`, `txnBarrier [Server -> {open, draining, drained}]`
- Actions: `AcquireGlobalLock`, `PrepareTransaction` (acquires intent locks, drops RSTL), `CommitPreparedTransaction` (reacquires RSTL), `DrainTransactionBarrier`
- Key: Model the `MultiDocumentTransactionsBarrier` mechanism and test whether it eliminates ALL three-way deadlocks

**Priority**: High
**Rationale**: 7+ historical bugs across all major versions. The `MultiDocumentTransactionsBarrier` (SERVER-66340) was introduced as a generalized fix, but new lock-ordering issues continue to appear (SERVER-103744 in 2024). The open TODO SERVER-58243 suggests uncertainty about the current approach.

---

### Family 4: Session/Transaction State Races During Failover (MEDIUM)

**Mechanism**: During primary-to-secondary transitions, transaction state can be observed in intermediate/inconsistent states because state transitions (on the TransactionParticipant) and session lifecycle operations (kill, invalidate, reap) are not fully atomic.

**Evidence**:
- Historical: SERVER-106075 — apiVersion not preserved during failover; coordinator misinterprets version-mismatch error as success, creating torn transactions. Affected all versions 5.0-8.2.1.
- Historical: SERVER-66110 — FCV downgrade changes active txnNumber between session yield and unyield, causing stale refreshes.
- Historical: SERVER-59108 — Race between adding operation to ServiceContext and setting interrupt flag; step-down misses the operation.
- Historical: SERVER-46238 — Race between commitTransaction and periodic abort thread; both modify state on same session (pre-4.2 architecture).
- Code analysis: `transaction_participant.cpp:3696-3703` — Client lock released BEFORE TxnResources destruction in `_resetTransactionStateAndUnlock`. Observable window where session is in new state (kAborted/kNone) but old RecoveryUnit is still performing rollback.
- Code analysis: `transaction_participant.cpp:3090-3125` — `_exitPreparePromise` and `_completionPromise` fulfilled while holding Client lock. Any continuation that tries to re-acquire the same Client lock would deadlock.
- Code analysis: `transaction_participant.cpp:2568` — TODO SERVER-106429: prepared transactions use opCtx API parameters instead of stashed ones, potential API version mismatch.

**Affected code paths**:
- `_resetTransactionStateAndUnlock()` (`transaction_participant.cpp:3664-3703`)
- `onStepUp()` (`session_catalog_mongod.cpp:570-639`)
- `stashTransactionResources()` / `unstashTransactionResources()` (`transaction_participant.cpp:1670-1815`)

**Suggested modeling approach**:
- Variables: `nodeRole [Server -> {primary, secondary, stepping_down}]`, `resourcesStashed [Session -> BOOLEAN]`, `promiseFulfilled [Session -> BOOLEAN]`
- Actions: `StepDown`, `StepUp`, `StashResources`, `UnstashResources`, `InvalidateSession`
- Key: Model the window between state transition and resource destruction

**Priority**: Medium
**Rationale**: SERVER-106075 was extremely severe (torn transactions across all versions), but most other bugs in this family have been fixed. The resource-destruction window finding is low-risk due to session checkout exclusivity.

---

### Family 5: Kill/Reap Accounting and Lifecycle Ordering Bugs (MEDIUM)

**Mechanism**: The multi-step kill/reap lifecycle (mark-for-kill, checkout-for-kill, abort, invalidate, reap-from-memory, reap-from-disk) has accounting errors and ordering dependencies that can cause leaked state, missed kills, or incorrect metrics.

**Evidence**:
- Historical: SERVER-106318 — `killOldestTransaction` undercounted kills because the kill-checkout itself could abort the transaction before the explicit abort.
- Historical: SERVER-92607 — Eager reaping removed sessions with yielded TransactionRouter, corrupting router state.
- Historical: SERVER-78187 — Killing a child session did not propagate to interrupt the parent session's operation.
- Historical: SERVER-34810 — `_refresh()` killed cursors for sessions that were created between the collection write and the cursor scan.
- Code analysis: `logical_session_cache_impl.cpp:457-465` — `endSessions()` does NOT check for prepared transactions. A session with a prepared transaction can be ended, removing it from `config.system.sessions`, leaving the prepared transaction in limbo.
- Code analysis: `logical_session_cache_impl.cpp:326-331` — `_refresh()` swaps `_activeSessions` to a local, making the cache empty. Concurrent `vivify()` creates duplicate entries.
- Code analysis: `session_catalog.cpp:371-397` — If the eager reap `workerFn` callback throws during `erase_if`, partially-erased child sessions are lost without notification to `InternalTransactionsReapService`.

**Affected code paths**:
- `endSessions()` (`logical_session_cache_impl.cpp:457-465`)
- `_refresh()` (`logical_session_cache_impl.cpp:277-455`)
- `killOldestTransaction()` (`kill_sessions_local.cpp:228-310`)
- `_releaseSession()` eager reap (`session_catalog.cpp:386-397`)

**Suggested modeling approach**:
- Variables: `cacheContains [Session -> BOOLEAN]`, `diskContains [Session -> BOOLEAN]`, `endingSet [SUBSET Session]`
- Actions: `EndSession`, `RefreshCache`, `ReapFromMemory`, `ReapFromDisk`
- Key: Model the ordering between end, refresh, and reap; verify no session with a prepared transaction can have its disk record removed

**Priority**: Medium
**Rationale**: Multiple bugs but mostly accounting/lifecycle issues. The `endSessions()` finding (no prepared txn check) is the most interesting for model checking.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Session checkout/checkin with kill token mechanism | Family 1,2: Central coordination point for all deadlocks. killsRequested leak finding. | Model checkout as blocking, with killsRequested counter and condition variable semantics |
| Periodic reaper thread | Family 1: 4 bugs from reaper operating outside checkout. Core modeling target. | Separate process: scan sessions, check prepared state, delete disk records in two steps |
| Prepared transaction lifecycle (prepare, commit, abort) | Family 1,3: Prepared txns hold locks and block reaping. | State machine: none -> inProgress -> prepared -> committed/aborted, with RSTL drop/reacquire |
| Step-down coordination | Family 2: 7+ deadlocks from step-down/session interaction | Model RSTL modes, ScopedBlockSessionCheckouts, kill-op thread |
| Two-step disk deletion | Family 1: Non-atomic image/transaction deletion with failure window | Two separate actions with crash/failure between them |
| Eager reaping (inside session release) | Family 1,5: Eager reap has exception-safety and accounting issues | Model as part of CheckInSession action, with child session inspection |
| endSessions with no prepared txn check | Family 5: New finding — can remove session from config.system.sessions while prepared txn active | Model endSessions removing from sessions collection but not checking txn state |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| WiredTiger storage engine internals | WT-8005, WT-4351, WT-5387 are storage-engine bugs below the abstraction boundary |
| Lock hierarchy details (global lock modes, collection locks) | Family 3 requires too many lock types; better tested via dedicated lock-ordering analysis |
| `MultiDocumentTransactionsBarrier` mechanism | Family 3: Complex lock-draining protocol better verified by the existing MongoDB test suite |
| Cursor management | SERVER-34810 is a refresh/cursor race; cursors are below our abstraction level |
| APIParameters preservation | SERVER-106075: Implementation detail of oplog application, not protocol logic |
| Transaction operations / oplog writing | Below the session lifecycle abstraction level |
| Split prepared transactions | Niche feature with its own complexity (SLS-2079 TODO still open) |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Kill token tracking | `killsRequested`, `numWaitingToCheckOut` | Model checkout blocking and kill lifecycle | Family 1,2 |
| Disk record lifecycle | `diskRecordExists`, `imageRecordExists` | Model non-atomic two-step disk deletion | Family 1 |
| Step-down state | `rstlState`, `checkoutAllowed`, `nodeRole` | Model step-down coordination with session checkout | Family 2 |
| Reaper process | (separate thread modeling) | Model periodic reaper scanning and deleting independently | Family 1 |
| Eager reap callback | (within release action) | Model reaping of child sessions during checkin | Family 1,5 |
| Session ending | `endingSet` | Model endSessions without prepared txn check | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| PreparedTxnSafety | Safety | A session with a prepared transaction must not have its in-memory state or disk records removed | Family 1 |
| NoTornTransaction | Safety | If coordinator receives NoSuchTransaction for a participant, the transaction was never prepared on that participant | Family 1 |
| StepDownTermination | Liveness | Step-down eventually completes (RSTL acquired in exclusive mode) | Family 2 |
| NoKillsRequestedLeak | Safety | After all kill operations complete, killsRequested == 0 for all sessions | Family 2 |
| SessionCheckoutExclusive | Safety | At most one thread holds checkout for any session at any time | Standard |
| DiskConsistency | Safety | If a transaction record exists in config.transactions, its image record exists in config.image_collection (or both are absent) | Family 1 |
| EndSessionSafety | Safety | A session removed from config.system.sessions has no prepared transaction | Family 5 |
| ReaperIdempotency | Safety | Running the reaper multiple times does not change any observable state beyond what a single run would | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|----|-------------|-------------------|--------|
| MC-1 | Reaper deletes disk record for session with prepared txn (SERVER-105751 pattern, may exist on new reaper paths) | PreparedTxnSafety | 1 |
| MC-2 | killsRequested leak when checkOutSessionForKill is interrupted (not timed out) | NoKillsRequestedLeak | 2 |
| MC-3 | endSessions() removes session from config.system.sessions while prepared txn active | EndSessionSafety | 5 |
| MC-4 | Non-atomic disk deletion: image deleted but txn record persists after failure | DiskConsistency | 1 |
| MC-5 | Eager reap during release + concurrent reaper scan = double-reap or missed reap | ReaperIdempotency | 1 |
| MC-6 | Step-down with non-killable refresh/reap job + session checkout = potential deadlock | StepDownTermination | 2 |
| MC-7 | Coordinator receives NoSuchTransaction for a prepared participant (torn txn) | NoTornTransaction | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | InternalTransactionsReapService loses sessions on step-down between swap and delete | Integration test: trigger step-down during reap, verify records persist |
| TV-2 | tassert in eager reap allows markForReap to proceed in production | Unit test: mock canBeReaped() returning false, verify session not reaped |
| TV-3 | _refresh() evicts successfully refreshed sessions from cache | Unit test: call peekCached() after refresh, verify session still accessible |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | TODO SERVER-58243: Lock acquisition on timestamped WUOW may block (2 locations) | Review whether this creates priority inversion with prepared txns |
| CR-2 | TODO SERVER-106429: Prepared transactions use opCtx API params instead of stashed | Confirm whether this is related to SERVER-106075 fix |
| CR-3 | Commented-out destructor invariant (`transaction_participant.cpp:591`) | Determine if it should be re-enabled or if lifecycle issue persists |
| CR-4 | TODO SLS-2079: Split prepared transaction handling not fully determined | Review abort path completeness |
| CR-5 | Dead code: `_isDead()` declared but never defined (`logical_session_cache_impl.h:118`) | Remove declaration |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb-session/analysis-report.md`
- **Key source files**:
  - `artifact/mongo-src/src/mongo/db/session/session_catalog.cpp` (core checkout/checkin, 604 lines)
  - `artifact/mongo-src/src/mongo/db/session/session_catalog_mongod.cpp` (reaping, step-up, 831 lines)
  - `artifact/mongo-src/src/mongo/db/session/kill_sessions_local.cpp` (kill paths, 411 lines)
  - `artifact/mongo-src/src/mongo/db/transaction/transaction_participant.cpp` (txn state machine, 3730 lines)
  - `artifact/mongo-src/src/mongo/db/session/logical_session_cache_impl.cpp` (cache refresh/reap, 496 lines)
  - `artifact/mongo-src/src/mongo/db/session/internal_transactions_reap_service.cpp` (eager reap, 159 lines)
- **Jira tickets**: SERVER-105751, SERVER-67723, SERVER-52564, SERVER-48641, SERVER-65821, SERVER-66340, SERVER-71191, SERVER-117908, SERVER-106075, SERVER-92607, SERVER-106318
- **Shared harness**: `case-studies/mongodb-shared-harness.md` (Docker compose, log parsing)
