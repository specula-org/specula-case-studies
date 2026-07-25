# Analysis Report: MongoDB Distributed Transactions (2PC Coordinator)

## 1. Reconnaissance Summary

### 1.1 Codebase Structure

**Repository**: mongodb/mongo (master, commit 1425a42)
**Target**: Distributed transaction coordinator (2PC) — cross-shard transactions

| Component | File | LOC | Role |
|-----------|------|-----|------|
| Coordinator state machine | `transaction_coordinator.cpp/.h` | 1050 | Future chain: persist → prepare → decide → commit/abort → cleanup |
| Coordinator utilities | `transaction_coordinator_util.cpp/.h` | 1274 | Persistence (upsert/update/delete), prepare/commit/abort send with retry |
| Coordinator service | `transaction_coordinator_service.cpp/.h` | 676 | Create/recover coordinators, step-up recovery, step-down interrupt |
| Coordinator catalog | `transaction_coordinator_catalog.cpp/.h` | 517 | In-memory coordinator lookup by lsid+txnNumber |
| Async work scheduler | `transaction_coordinator_futures_util.cpp/.h` | 811 | Thread pool, scheduling, cancellation |
| Transaction router | `transaction_router.cpp/.h` | 3593 | Router-side commit/abort logic, participant tracking, recovery token |
| Transaction participant | `transaction_participant.cpp/.h` | 5591 | Shard-side txn state machine (InProgress→Prepared→Committed/Aborted) |
| Reclaimed prepared tracker | `reclaimed_prepared_txn_tracker.cpp/.h` | 190 | NEW (2026): tracks prepared txns from precise checkpoints |
| 2PC command handlers | `txn_two_phase_commit_cmds.cpp` | 487 | prepareTransaction, coordinateCommitTransaction commands |
| **Total** | | **~14,200** | |

### 1.2 Concurrency Model

1. **Coordinator**: Async future chain on executor thread pool. Internal state protected by `_mutex`. Each step (persist, send, wait majority) is a separate future continuation.
2. **Router**: State split into `o()` (observable, requires Client lock) and `p()` (private, single-threaded access). Router is single-threaded per client request but participants may be added by response processing.
3. **Participant**: Uses Client lock for state transitions. Prepared transactions hold WT locks that block other operations.
4. **Key synchronization boundaries**:
   - Coordinator doc persistence is atomic (single MongoDB document upsert/update)
   - Majority wait for persistence is async (cancellable via step-down token)
   - Message sends are fire-and-forget with async retry loops

### 1.3 2PC Protocol Flow

```
Router → coordinateCommitTransaction(participants) → Coordinator Shard
                                                      ↓
                                              1. Persist participant list (w:majority)
                                              2. Send prepareTransaction to all participants
                                              3. Collect votes (commit/abort)
                                              4. Persist decision (w:majority)
                                              5. Send commitTransaction/abortTransaction to all participants
                                              6. Write endOfTransaction oplog (if feature-flagged)
                                              7. Delete coordinator doc (w:1 best-effort)
```

### 1.4 Existing TLA+ Spec Gaps

The existing `MultiShardTxn.tla` (594 LOC, from VLDB 2025 paper) has critical gaps:

| Gap | Impact |
|-----|--------|
| `Restart` action defined but NOT in Next | Coordinator/participant crash never explored |
| `MoveKey` action defined but NOT in Next | Catalog changes during transactions never explored |
| No abort decision path | Coordinator can't decide abort when participant fails to prepare |
| `RouterTxnAbort` commented out | Router abort path never explored |
| `stableTs`, `oldestTs`, `allDurableTs` initialized but never modified | Timestamp management is purely decorative |
| No message loss/network partition | All messages delivered reliably |
| No coordinator doc persistence | The upsert/update/delete lifecycle is not modeled |
| No recovery protocol | Step-up recovery from coordinator docs not modeled |
| `RouterTxnCommitSingleWriteShard` commented out | Single-write-shard optimization not explored |

## 2. Bug Archaeology

### 2.1 Git History Mining: 52 Bug-Fix Commits

Mining the git history of the 5 core transaction files via GitHub API yielded **52 bug-fix commits** (excluding refactors, logging, formatting).

**Component distribution:**

| Component | Bug-fix count | % |
|-----------|--------------|---|
| TransactionRouter | 21 | 40.4% |
| TransactionCoordinator | 15 | 28.8% |
| TransactionCoordinatorUtil | 7 | 13.5% |
| TransactionParticipant | 6 | 11.5% |
| TransactionCoordinatorService | 3 | 5.8% |

**Mechanism distribution:**

| Mechanism | Count | % |
|-----------|-------|---|
| Deadlock / Hang / Stall | 8 | 15.4% |
| Error handling / propagation | 8 | 15.4% |
| Race condition / Concurrency | 6 | 11.5% |
| State machine / State leak | 6 | 11.5% |
| Lifetime / Use-after-free | 5 | 9.6% |
| Wrong commit/abort path | 5 | 9.6% |
| Protocol correctness | 5 | 9.6% |
| Recovery / Step-up | 5 | 9.6% |
| Ticket / Admission control | 4 | 7.7% |

#### Pattern A: Deadlock / Ticket Starvation (8 bugs, 15.4%)
The most severe critical class. Circular dependency: coordinator needs storage ticket → all tickets held by prepared txns → prepared txns waiting for coordinator decision.
- **SERVER-60682**: Coordinator needs ticket but all held by prepared txns (deadlock)
- **SERVER-82883**: Recovery task blocks on ticket acquisition for prepared state
- **SERVER-92292**: Prepare blocked on ticket held by operation waiting for prepare
- **SERVER-115594**: Coordinator blocked on ticket for doc cleanup
- **SERVER-89413**: Lock ordering violation in router (deadlock)
- **SERVER-73915**: Coordinator hangs on step-up
- **SERVER-104103**: Unkillable coordinator thread blocks step-down
- **SERVER-80978**: TTLMonitor step-up blocks on prepared txn lock

#### Pattern B: Router Commit Path Bugs (13 bugs, 25%)
The router is the most bug-prone component. Concentrated in:
- **Wrong commit path selection**: SERVER-40201 (read-only retry escalated to 2PC), SERVER-39973 (empty participants triggered wrong path), SERVER-48307/84796 (single-write-shard optimization bugs)
- **Abort/commit coordination**: SERVER-38035 (abort sent after coordinateCommit), SERVER-39124 (cleared participants not aborted on retry), SERVER-116284 (partial commit — some shards not receiving commit on error)
- **State leaks**: SERVER-41032 (`_isRecoverCommit` not reset), SERVER-102481 (`disallowSingleWriteShardCommit` persists across reset), SERVER-80279 (continuing non-started transaction)
- **Thread safety**: SERVER-105384 (network thread accesses router without lock)

#### Pattern C: Coordinator Lifetime (5 bugs, 9.6%)
Recurring C++ lifetime issue — coordinator destroyed while async chains still running:
- **SERVER-91685**: Coordinator destroyed before future chains complete
- **SERVER-103481/103841**: Coordinator object lifetime issues
- **SERVER-116263**: Concurrent access of `_participants` in coordinator
- **SERVER-40554**: Lazy destruction caused dangling scheduler

#### Pattern D: Recovery / Step-up (5 bugs)
- **SERVER-82883**: Ticket acquisition during recovery of prepared txns
- **SERVER-37885**: Coordinator acts on stale data before majority confirmed
- **SERVER-67422**: Removal futures accessed before catalog recovered
- **SERVER-93078**: Service not properly initialized on step-up
- **SERVER-41615**: Missing recovery-complete flag

#### Pattern E: Error Handling (8 bugs)
- **SERVER-106138**: Incorrect error acknowledgment during 2PC
- **SERVER-50470**: Wrong error code exposed to client
- **SERVER-46796**: Prepare errors not reaching client
- **SERVER-41189**: Coordinator gave up too early on transient errors
- **SERVER-40127**: Abort decision converted to step-down error

#### Pattern F: Known Open Issues (from code TODOs)
- **SERVER-38918**: ShardNotFound during commit → `fassert` crash (open since 2018)
- **SERVER-120584**: w:1 coordinator doc delete under re-evaluation
- **SERVER-39704**: Stale version retry within transactions still behind fail point
- **SERVER-115178**: placementConflictTime migration (v9.0 target)
- **SERVER-113730/113735**: Prepared txn state checks and split txn abort uncertainty

#### Pattern G: Deadlock with Global Locks / Prepared Txns (11 bugs from JIRA)
The most severe bug class from JIRA mining. Prepared transactions hold locks for extended windows, creating deadlocks with any background task needing the same resource:
- **SERVER-60682** (P2/Critical): All WiredTiger write tickets exhausted — circular dependency between coordinator needing ticket and prepared txns holding tickets
- **SERVER-65821** (P2/Critical): Three-way deadlock: setFCV ← prepared txn ← coordinator ← setFCV
- **SERVER-66340**: Generalized fix via `MultiDocumentTransactionsBarrier` replacing FCV lock
- **SERVER-80978**: TTLMonitor step-up deadlocks with prepared txn lock restoration
- **SERVER-73915**: Coordinator hangs on step-up (WaitForMajorityService not interrupted)
- **SERVER-103744**: Three-way deadlock on secondary: renameCollection + dbHash + prepared txn commit
- **SERVER-57476**: Prepare conflict holds oplog slot, blocking all readers indefinitely

#### Pattern H: Very Recent Bugs (2025-2026, 8 bugs)
The bug rate has NOT decreased. Recent critical bugs:
- **SERVER-116284** (Feb 2026): Commit messages don't reach all shards — `AsyncRequestsSender` destroyed before all commits dispatched
- **SERVER-105751** (Jun 2025): Session reaper destroys prepared txn — coordinator interprets `NoSuchTransaction` as successful commit, creating **silent cross-shard data inconsistency**
- **SERVER-103841** (May 2025): Memory leak — CancellationSource accumulates futures from every coordinated transaction
- **SERVER-116263** (Jan 2026): Data race — `_participants` set without mutex in `runCommit()`, read with mutex in `reportState()`
- **SERVER-106075** (2025): Prepared txns with apiVersion fail after failover — apiParameters not preserved
- **SERVER-114045** (Nov 2025): Prepared txn killed during step-up — commit point hasn't advanced to include prepare timestamp

#### Pattern I: Single-Write-Shard Optimization Bugs (3 bugs)
This optimization alone produced 3 distinct bugs:
- **SERVER-48307**: Double execution — driver told transaction aborted, retries cause duplicate effects
- **SERVER-84796**: Shard key update retryability broken — noop update treated as read
- **SERVER-102481**: `disallowSingleWriteShardCommit` flag permanently stuck

#### Pattern J: Jepsen Findings (MongoDB 4.2.6)
- Retrocausal transactions (timestamps going backwards)
- Duplicate effects from transaction retry
- Partially addressed but retry logic remains complex

### 2.2 Active TODO/FIXME Items in Latest Code

| Location | Ticket | Description |
|----------|--------|-------------|
| `transaction_coordinator_util.cpp:652` | SERVER-120584 | Re-evaluate w:1 delete of coordinator doc |
| `transaction_coordinator_util.cpp:729` | SERVER-38307 | Try/catch around coordinator doc parsing during recovery |
| `transaction_coordinator_util.cpp:952` | SERVER-38918 | No safe handling of ShardNotFound during commit/abort |
| `transaction_coordinator_service.cpp:137,222` | SERVER-82965 | Remove early return when sharding not enabled |
| `transaction_router.cpp:94` | SERVER-39704 | Remove fail point for stale version retry |
| `transaction_router.cpp:332,351,668,677,688` | SERVER-115178 | Remove placementConflictTime legacy code |
| `transaction_router.cpp:1832` | SERVER-104090 | Replace abort response aggregation |
| `transaction_router.cpp:2005` | SERVER-37115 | Parse statement ids from client |
| `transaction_participant.cpp:470` | SERVER-58243 | Evaluate safety of lock acquisition on timestamped UoW |
| `transaction_participant.cpp:2241` | SERVER-41165 | Snapshot read concern should wait on read timestamp |
| `transaction_participant.cpp:2568` | SERVER-106429 | Revisit API parameters for prepared transactions |
| `transaction_participant.cpp:2618` | SERVER-58243 | (duplicate) lock acquisition safety |
| `transaction_participant.cpp:2657` | SLS-2079 | Handle split prepared transactions during abort |
| `transaction_participant.cpp:2683` | SERVER-113730 | State check for prepared txns during abort |
| `transaction_participant.cpp:2687` | SERVER-113735 | Split transactions aborting after step up |

### 2.3 Code Hotspots

Files with most bug-fix activity (based on TODO density and historical tickets):
1. `transaction_coordinator_util.cpp` — 3 active TODOs, 2 critical (SERVER-38918, SERVER-120584)
2. `transaction_router.cpp` — 7 active TODOs, complex stale-version retry logic
3. `transaction_participant.cpp` — 6 active TODOs, split/prepared transaction uncertainty

## 3. Deep Analysis Findings

### 3.0 Decision Promise Timing

A subtle but important detail: `setDecisionPromise` is called at `transaction_coordinator.cpp:356` — **after** `persistDecision()` returns the OpTime but **before** the majority write concern completes. This means the `_decisionPromise` (returned by `getDecision()`) is resolved when the decision is locally durable but not yet majority-replicated.

If `coordinateCommitReturnImmediatelyAfterPersistingDecision` is true (checked at `txn_two_phase_commit_cmds.cpp:192,213`), the `coordinateCommitTransaction` command returns the decision to the router at this point — before majority durability. A failover before majority could roll back the decision, but the router has already been told "commit". This is a known design trade-off for latency, not a bug, but it's important for modeling: the spec should distinguish between "decision returned to client" and "decision majority-durable".

### 3.1 Coordinator Doc Persistence Model

The coordinator uses MongoDB documents in `config.transaction_coordinators` collection:

```
Document lifecycle:
  1. Upsert: {_id: {lsid, txnNumber}, participants: [...]}           (w:majority)
  2. Update: add decision field {decision: "commit"|"abort", commitTimestamp: ...}  (w:majority)
  3. Delete: remove document                                          (w:1 !!)
```

**Key finding**: The delete uses w:1 (best-effort). If the delete succeeds locally but the primary steps down before replication, the document reappears on the new primary. The new primary's recovery will re-create the coordinator and re-drive the commit/abort protocol.

This is acknowledged (SERVER-120584) but has a subtle implication: participants may receive duplicate commit messages. The commit command is idempotent (if already committed, returns success), so this is safe. BUT: if the participant has already cleaned up the transaction state (e.g., garbage collected), re-sending commit would get `NoSuchTransaction`, which is treated as `TwoPhaseDecisionAckError` (i.e., success). So this path appears safe in practice.

**Potential issue**: What if the coordinator doc reappears with a DECISION (because the delete was w:1) and the new primary starts recovery, but meanwhile a NEW transaction with the same lsid but higher txnNumber has started? The catalog's `insert` for recovery uses `forStepUp = true` which has different semantics. Need to verify this doesn't conflict.

### 3.2 The fassert(51068) Problem

At `transaction_coordinator_util.cpp:955`:
```cpp
.onError<ErrorCodes::ShardNotFound>([isLocalShard](const Status& s) {
    invariant(!isLocalShard);
    // TODO (SERVER-38918): Unlike for prepare, there is no pessimistic way to
    // handle ShardNotFound. It's not safe to treat ShardNotFound as an ack, because
    // this node may have refreshed its ShardRegistry from a stale config secondary.
    fassert(51068, false);
});
```

This means: if during the commit/abort phase, a shard lookup returns `ShardNotFound`, the coordinator crashes the mongod process. This is catastrophic:
- The prepared transactions on other shards are now stuck until the coordinator recovers
- If the shard was genuinely removed, recovery will hit the same error and crash again (livelock)
- If the config server was stale, recovery may succeed (the shard reappears in the registry)

The prepare phase handles this safely (treats as abort vote). The asymmetry is because during prepare, aborting is always safe. During commit, treating ShardNotFound as an ack could mean a committed transaction's effects are lost on a shard that still exists.

### 3.3 Router Commit Type Selection

The router has 5 commit types:
1. **kNoShards**: Empty participant list → return OK immediately
2. **kSingleShard**: 1 participant → send commitTransaction directly
3. **kSingleWriteShard**: 1 write shard + N read-only → commit read-only first, then write shard
4. **kReadOnly**: All participants read-only → send commitTransaction to all
5. **kTwoPhaseCommit**: Multiple write shards → hand off to coordinator

**Key finding**: The single-write-shard optimization (type 3) has a critical retry path at `transaction_router.cpp:1718-1731`:

```cpp
if (!isFirstCommitAttempt) {
    // For a retried single write shard commit, fall back to the recovery token protocol
    tassert(4834000, "Expected to have a recovery shard", p().recoveryShardId);
    tassert(4834001, "Expected recovery shard to equal the single write shard",
            p().recoveryShardId == writeShards[0]);
    TxnRecoveryToken syntheticRecoveryToken;
    syntheticRecoveryToken.setRecoveryShardId(writeShards[0]);
    return _commitWithRecoveryToken(opCtx, syntheticRecoveryToken);
}
```

On retry, it creates a synthetic recovery token pointing to the write shard and uses the recovery commit protocol. This sends `coordinateCommitTransaction` with an EMPTY participant list to the write shard, which triggers the `recoverCommit` path. The `recoverCommit` path looks up the coordinator in the catalog — but for a single-write-shard transaction, no coordinator was ever created (it was a direct commit). So `recoverCommit` returns `boost::none`, and the command handler falls through to the local participant recovery path (check if committed locally).

This is correct IF the direct commitTransaction to the write shard succeeded before the retry. But what if it failed with an unknown error? The local participant check will find the transaction still in-progress and abort it. This converts a potentially-committed transaction to aborted.

### 3.3b No Distributed Router Coordination

There is no distributed lock between routers for the same session. The only protection is session affinity at the client level (client sends all requests for a session to the same mongos). If two routers somehow operate on the same session concurrently (e.g., client reconnection during commit), they could make conflicting decisions. The recovery token mechanism is the only safety net: a second router recovering a commit sends `coordinateCommitTransaction` with empty participants to the recovery shard, which returns the persisted decision.

If no coordinator doc exists (e.g., single-shard optimization was used), the second router falls through to checking the local participant state (`txn_two_phase_commit_cmds.cpp:400-438`). If the transaction is still in-progress, it gets aborted. This means a concurrent router could abort a transaction that the original router's commit hasn't reached yet.

### 3.3c Single-Write-Shard Commit Ordering

The single-write-shard optimization (`transaction_router.cpp:1704-1746`) commits read-only shards first, then the write shard:
1. Send `commitTransaction` to all read-only shards (line 1734)
2. If any read-only shard fails (including write concern error), return error without committing write shard (lines 1738-1744)
3. Only if all read-only shards succeed, send `commitTransaction` to the write shard (line 1745)

On retry, this path is abandoned and replaced with the recovery token protocol (lines 1718-1731), using a synthetic token pointing to the write shard.

**Risk**: If step 1 succeeds (read-only shards committed) but step 3 fails with an unknown error (network timeout), the router doesn't know if the write shard committed. On retry, the recovery token protocol checks the write shard's local participant state. If the commit hadn't reached the write shard, it gets aborted — even though read-only shards already "committed" (released their snapshots). Since read-only shards do no writes, this is safe for data consistency, but it means the transaction's reads may have been visible to other transactions briefly.

### 3.3d clearPendingParticipants Stale Error Handling

When `_errorAllowsRetryOnStaleShardOrDb` returns true (`transaction_router.cpp:1122-1124`), `_clearPendingParticipants` intentionally does NOT send abort to pending participants. This avoids racing with retried commands. But those shards may have an in-progress transaction that will either be overwritten by the retry (via `startTransaction` flag) or will eventually timeout. If the retry targets different shards (due to routing change), the original shards' in-progress transactions are orphaned until the transaction lifetime limit expires.

### 3.35 writeEndOfTransaction Failure Path

The `writeEndOfTransaction` step (between decision acks and doc deletion) is NOT wrapped in a retry loop — it's a single `scheduleWork` call (`transaction_coordinator_util.cpp:973`). If it fails, the error propagates to `_done()`. Since `_participantsDurable` is true at this point, a non-shutdown/non-NotPrimary error triggers `LOGV2_FATAL` at `transaction_coordinator.cpp:632`. This means a transient storage error during endOfTransaction oplog write crashes the node.

This is mitigated by the feature flag (`gFeatureFlagEndOfTransactionChangeEvent`, off by default). But when enabled, it adds a new crash window that didn't exist before.

### 3.36 Malformed Coordinator Doc Blocks Recovery

At `transaction_coordinator_util.cpp:729`: `readAllCoordinatorDocs()` parses all coordinator documents during step-up recovery. If ANY document fails to parse (e.g., corrupted by a bug or manual edit), the entire recovery crashes. The TODO (SERVER-38307) acknowledges this but no try/catch has been added. A single bad document blocks all coordinator recovery on the new primary.

### 3.4 Recovery Path Analysis

When a new primary steps up (`TransactionCoordinatorService::_scheduleRecoveryTask`):

1. Wait for last op to become majority committed
2. Read ALL coordinator docs from `config.transaction_coordinators`
3. For each doc, create a new `TransactionCoordinator` and call `continueCommit(doc)`
4. `continueCommit` sets `_participants`, `_participantsDurable = true`, and `_decision` (if present)
5. The future chain in `start()` skips already-completed steps based on these flags

**Blocking mechanism**: The catalog has `_waitForStepUpToComplete()` which blocks ALL non-recovery operations (`get()`, non-step-up `insert()`, `getLatestOnSession()`) until `exitStepUp()` is called after recovery finishes. This means incoming `coordinateCommit` requests block in `catalog.get()` until recovery completes. If a recovered coordinator exists for the same `(lsid, txnNumber)`, the `coordinateCommit` will find it and deliver the participant list.

This blocking mechanism prevents the recovery-vs-new-commit race — but it also means recovery latency directly impacts all new transaction commits. If the executor pool is saturated, recovery could be delayed, blocking all incoming commits.

**Catalog invariant on retries**: `catalog.insert()` invariant-checks that for the same txnNumber but different retryCounter, the existing coordinator's decision is ready and was NOT a commit (`transaction_coordinator_catalog.cpp:139-148`). This prevents retrying a committed transaction with a different retryCounter.

**Coordinator lifetime**: A coordinator is removed from the catalog by its `onCompletion()` continuation, which runs `shutdown()` then `_remove()` on the executor pool (`transaction_coordinator_catalog.cpp:159-165`). The `_activeTransactionCoordinators` set in the service tracks coordinators via weak_ptrs and is cleaned up by `notifyCoordinatorFinished()`.

**Minor leak**: If `catalog.insert()` throws during `createCoordinator` (line 119), the coordinator's weak_ptr remains in `_activeTransactionCoordinators` until the next `interruptForStepDown` — a benign leak of a dead weak_ptr.

### 3.45 Prepared Transaction State Machine Details

The participant's state machine has 7 states with strict transition rules (`transaction_participant.cpp:3020-3088`):

```
kNone → kInProgress → kPrepared → kCommitted
                   ↘ kAbortedWithoutPrepare    ↘ kAbortedWithPrepare
```

Key properties relevant to 2PC modeling:

**No timeout for prepared transactions**: `expiredAsOf()` at `transaction_participant.cpp:2586-2588` only checks `kInProgress`. Prepared transactions survive indefinitely until committed/aborted. A stuck coordinator means prepared transactions hold locks and pin the oldest timestamp indefinitely. This is by design for correctness but creates a liveness hazard.

**`std::terminate()` on post-point-of-no-return failure**: Both `commitPreparedTransaction` (line 2411) and `_abortActiveTransaction` (line 2722) call `std::terminate()` (not just `fassert`) if an exception occurs after the storage transaction state has been changed but before the oplog entry is written. This is the ultimate safety net — crash rather than risk inconsistency.

**RSTL explicitly unlocked after prepare**: At `transaction_participant.cpp:2089`, the Replication State Transition Lock is released so prepared transactions survive failovers. This means a step-down can occur immediately after prepare returns — the prepared state is preserved through the step-down.

**Prepared transaction blocks new txnNumber**: At `transaction_participant.cpp:3240-3242`, starting a new transaction on the same session while a prepared transaction exists throws `PreparedTransactionInProgress`. The session is effectively locked until the prepared transaction resolves.

**Relaxed transition during rollback**: At `transaction_participant.cpp:3672-3674`, the `kPrepared → kNone` transition is allowed during rollback with `kRelaxTransitionValidation`, bypassing normal state machine invariants. This is used when a secondary's state must be reset during replication rollback.

**Promise-based exit notification**: `_exitPreparePromise` is initialized when entering `kPrepared` and fulfilled on exit. The `onExitPrepare()` method returns this promise's future, which is how `ReclaimedPreparedTxnTracker` and the coordinator's recovery path (`txn_two_phase_commit_cmds.cpp:415-419`) wait for prepared transactions to resolve.

### 3.5 The `isTwoPhaseDecisionAckError` Classification

Error codes treated as successful commit/abort acknowledgment:
- `NoSuchTransaction` (481) — participant already forgot the transaction
- `TransactionTooOld` (526) — participant already moved past this txnNumber
- `APIVersionError` (758) — (surprising inclusion?)

Error codes treated as vote-to-abort during prepare:
- All of the above PLUS
- `TransactionExceededLifetimeLimitSeconds` (374)
- `InternalTransactionNotSupported` (546)

This classification determines whether the coordinator treats an error as "participant is done" vs "need to retry". A misclassification could lead to the coordinator prematurely deleting its doc while a participant still has a prepared transaction.

### 3.6 Implicit Abort Guard Gap

`transaction_router.cpp:1885-1897`:
```cpp
if (o().commitType == CommitType::kTwoPhaseCommit ||
    o().commitType == CommitType::kRecoverWithToken) {
    // Don't send implicit abort...
    return;
}
```

This guard prevents sending abort AFTER the commit has been handed to the coordinator. But `commitType` is only set inside `_commitTransaction()` (which is called from `commitTransaction()`). If `implicitlyAbortTransaction()` is called before `commitTransaction()` completes (e.g., due to a timeout on the router side), the `commitType` might not be set yet.

However, examining the code more carefully: `implicitlyAbortTransaction` is called in destructor/cleanup paths, and `commitTransaction` is a synchronous call on the same thread. So the race would require the router timeout to fire on a different thread while commitTransaction is in progress. The `terminationInitiated` flag provides some protection, but it's not atomic with the commit type setting.

## 4. Coverage Statistics

### 4.1 Files Analyzed

| File | Lines Read | Completeness |
|------|-----------|--------------|
| `transaction_coordinator.cpp` | 782/782 | 100% |
| `transaction_coordinator.h` | 268/268 | 100% |
| `transaction_coordinator_util.cpp` | 993/993 | 100% |
| `transaction_coordinator_util.h` | 281/281 | 100% |
| `transaction_coordinator_service.cpp` | 448/448 | 100% |
| `transaction_coordinator_service.h` | 228/228 | 100% |
| `transaction_coordinator_catalog.cpp` | 325/325 | 100% |
| `transaction_coordinator_catalog.h` | 192/192 | 100% |
| `transaction_coordinator_futures_util.cpp` | 371/371 | 100% |
| `transaction_coordinator_futures_util.h` | 440/440 | 100% |
| `transaction_router.cpp` | 2651/2651 | 100% |
| `transaction_router.h` | 942/942 | 100% |
| `transaction_participant.cpp` | 4067/4067 | ~60% (focused on 2PC-relevant sections) |
| `transaction_participant.h` | 1524/1524 | ~50% |
| `reclaimed_prepared_txn_tracker.cpp` | 103/103 | 100% |
| `reclaimed_prepared_txn_tracker.h` | 87/87 | 100% |
| `txn_two_phase_commit_cmds.cpp` | 487/487 | 100% |
| `kill_sessions_local.cpp` | ~50 lines | Focused on `killSessionsAbortUnpreparedTransactions` |
| `auto_get_rstl_for_stepup_stepdown.cpp` | ~15 lines | Focused on step-down interaction |
| `error_codes.yml` | ~20 lines | Focused on `VoteAbortError` and `TwoPhaseDecisionAckError` |

### 4.2 TODOs/FIXMEs Found

- Total TODO/FIXME items found: **16** across core transaction files
- With active SERVER tickets: **14** (all but 2 have ticket references)
- Critical (safety-relevant): **3** (SERVER-38918, SERVER-120584, SERVER-113730/113735)

### 4.3 Existing TLA+ Spec Analysis

- `MultiShardTxn.tla`: 594 LOC, 22 variables, 15 actions in Next (2 defined-but-excluded)
- `Storage.tla`: 446 LOC, 7 variables, 11 actions (4 disabled in cfg: SetStableTimestamp, RollbackToStable, AbortTransaction, TransactionRemove)
- `ClientCentric.tla`: 228 LOC — isolation level definitions from Crooks et al.
- `MCMultiShardTxn.tla`: 23 LOC — MC wrapper with symmetry on TxId, Keys, Shard, Router
- Dead code in MultiShardTxn: `Restart` (defined lines 184-198, not in Next), `MoveKey` (defined lines 535-538, not in Next), `RouterTxnAbort` (commented out lines 336-349), `RouterTxnCommitSingleWriteShard` (commented out in Next line 548), `ShardTxnWriteConflict` (commented out lines 406-425)
- Dead code in Storage: `WriteReadConflictExists` helper (lines 144-153, never called), `TxnCanStart` (line 221, never called)
- `IgnorePrepareOptions` restricted to `{"false"}` in Storage.cfg — prepare blocking is always on
- Isolation properties checked: ReadUncommitted, ReadCommitted, RepeatableRead, SnapshotIsolation, Serializability (via ClientCentric module)
- MC config: 2 keys, 2 txns, 2 shards, 1 router, RC="snapshot", MaxOpsPerTxn=2

## 5. Recommendations for Spec Design

### 5.1 Abstraction Level

Model at the **protocol level** — abstract away storage engine, oplog replication, and WiredTiger internals. Each shard is a single node with crash/recovery capability. Focus on:
- Message passing between router, coordinator, and participants
- Coordinator doc persistence lifecycle
- Crash/recovery at the coordinator and participant level

### 5.2 State Space Management

- Use **counter-bounded fault injection** (max N crashes, M message losses, K shard removals)
- Use **symmetry reduction** on participant shards (but NOT on the coordinator shard)
- Start with 2 shards + 1 router, 1 transaction — verify invariants pass
- Scale to 3 shards + 2 routers, 2 transactions for bug hunting

### 5.3 Priority Order for Spec Development

1. **Core 2PC** without faults — verify correctness of the happy path
2. **Add coordinator crash/recovery** — target Family 1
3. **Add router abort/commit race** — target Family 2
4. **Add ShardNotFound fault** — target Family 3
5. **Add catalog staleness** — target Family 4
6. **Add prepared txn state tracking** — target Family 5
