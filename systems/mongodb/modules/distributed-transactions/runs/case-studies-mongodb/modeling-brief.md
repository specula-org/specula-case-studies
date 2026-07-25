# Modeling Brief: MongoDB Distributed Transactions (2PC Coordinator)

## 1. System Overview

- **System**: MongoDB distributed transactions — cross-shard two-phase commit protocol
- **Language**: C++, ~14K LOC core logic across coordinator, router, participant
- **Protocol**: Two-phase commit (2PC) with coordinator-per-transaction, router-initiated
- **Key architectural choices**:
  - Coordinator state persisted via MongoDB documents (upserts with conditional matching)
  - Recovery via document scan on step-up + majority wait before recovery starts
  - Coordinator doc delete uses w:1 (best-effort) — relies on next primary to clean up
  - Router picks coordinator shard (first write participant); recovery shard = coordinator
  - Multiple commit optimizations: single-shard (direct), single-write-shard, read-only, full 2PC
  - `ShardNotFound` during commit/abort phase triggers `fassert` (crash) — SERVER-38918 still open
  - Sub-router pattern for shard-to-shard transaction forwarding (additional participants)
  - `endOfTransaction` oplog entry (feature-flagged, off by default) added between decision acks and doc deletion
  - `ReclaimedPreparedTxnTracker` (brand new, 2026 copyright) tracks prepared txns from precise checkpoints
- **Concurrency model**: Async futures chain for coordinator; per-shard retry loops; Client lock for router state; `_mutex` for coordinator internal state

## 2. Bug Families

### Family 1: Coordinator Failover Atomicity Gaps (HIGH)

**Mechanism**: The coordinator's 2PC state machine has crash windows between writing the participant list, persisting the decision, and sending commit/abort. Recovery on step-up recreates coordinators from persisted documents but cannot restore in-flight prepare votes, sub-router state, or partial commit acknowledgments.

**Evidence**:
- Historical: SERVER-106075 — coordinator failover atomicity gap during recovery
- Historical: SERVER-60682/82883 — deadlock from ticket acquisition during coordinator recovery of prepared transactions
- Code analysis: `transaction_coordinator.cpp:233-234` — if `_participantsDurable` is already true (recovery), skips writing participants but still sends prepare. However, if the original primary had already received prepare votes but crashed before persisting the decision, the new primary re-sends prepare (idempotent but with timing gap)
- Code analysis: `transaction_coordinator.cpp:276-277` — if `_decision` is already set (recovered from doc), skips prepare entirely. But the doc decision may have been committed with w:majority on old primary and not replicated yet (the recovery waits for majority, but there's a window)
- Code analysis: `transaction_coordinator_util.cpp:648-656` — coordinator doc deletion uses w:1, so it can be rolled back on failover. TODO SERVER-120584 acknowledges this is under re-evaluation.
- Code analysis: `transaction_coordinator.cpp:625-637` — unexpected errors after `_participantsDurable` trigger `LOGV2_FATAL` (intentional crash for safety), but this means transient errors like network blips in the right window cause node crash
- Code analysis: `transaction_coordinator_catalog.cpp:289-296` — catalog blocks all operations during step-up recovery via `_waitForStepUpToComplete()`. This serializes recovery with new commits but means recovery latency impacts all transactions.
- Code analysis: `transaction_coordinator_service.h:195-199` — `_catalogAndSchedulerToCleanup` synchronization relies on assumption that step-up/step-down are always sequential. Comment: "there is no need to explicitly synchronize it." A violation of this assumption causes a data race.

**Affected code paths**:
- `TransactionCoordinator::start()` (the future chain: persist participants → wait majority → send prepare → persist decision → wait majority → send commit/abort → write endOfTxn → delete doc)
- `TransactionCoordinator::continueCommit()` (recovery entry point)
- `TransactionCoordinatorService::_scheduleRecoveryTask()` (step-up recovery)

**Suggested modeling approach**:
- Variables: `coordinatorDoc[lsid] ∈ {None, ParticipantsWritten, DecisionCommit, DecisionAbort}`, `coordinatorDocDurable[lsid] ∈ BOOLEAN` (majority committed)
- Actions: Split coordinator lifecycle into: `PersistParticipants`, `WaitMajorityParticipants`, `SendPrepare`, `ReceivePrepareVote`, `PersistDecision`, `WaitMajorityDecision`, `SendCommitToParticipant`, `SendAbortToParticipant`, `DeleteCoordinatorDoc`
- Add `CoordinatorCrash` action that can fire between any two steps; `CoordinatorRecover` reads back from persisted state
- Model w:1 delete as potentially rolled back (doc reappears after failover)

**Priority**: High
**Rationale**: 15 of 52 bug-fix commits (28.8%) in coordinator + 5 lifetime fixes + 5 recovery/step-up bugs. The persistence model (MongoDB documents with conditional upserts) has inherent crash windows. Recovery is the most safety-critical path and has known TODO items.

---

### Family 2: Router Abort vs Commit Race (HIGH)

**Mechanism**: The router and coordinator can make conflicting decisions when the router implicitly aborts (due to error/timeout) while the coordinator is already processing a commit. The router's `implicitlyAbortTransaction` explicitly skips sending aborts when `commitType == kTwoPhaseCommit`, but this guard only protects after the commit type is set — there's a window between the first statement error and commitTransaction where the type isn't set yet.

**Evidence**:
- Historical: SERVER-66067 — router abort races with commit
- Code analysis: `transaction_router.cpp:1885-1897` — `implicitlyAbortTransaction` checks `commitType == kTwoPhaseCommit || kRecoverWithToken` and skips abort. But `commitType` is only set when `commitTransaction` is called, not when the transaction starts.
- Code analysis: `transaction_router.cpp:1807` — explicit `abortTransaction` does NOT check `commitType` at all — it sends abort to ALL participants regardless
- Code analysis: `transaction_router.cpp:1113-1148` — `_clearPendingParticipants` sends abort to pending participants on stale version retry, but only if `!o().subRouter && (!optStatus || !_errorAllowsRetryOnStaleShardOrDb(*optStatus))`. Sub-routers never abort pending participants.
- Code analysis: `transaction_router.cpp:1604-1606` — `terminationInitiated` flag prevents double-commit but is a per-invocation flag, not a durable guard

**Affected code paths**:
- `Router::abortTransaction()` — sends abort to all participants
- `Router::implicitlyAbortTransaction()` — skips if 2PC commit already handed off
- `Router::_clearPendingParticipants()` — aborts pending participants on retry
- `Router::commitTransaction()` → `_commitTransaction()` → `_handOffCommitToCoordinator()`

**Suggested modeling approach**:
- Variables: `routerState[r][t] ∈ {Active, Committing, Aborting, Done}`, `routerCommitType[r][t]`
- Actions: `RouterImplicitAbort`, `RouterExplicitAbort`, `RouterCommit` (with sub-actions for each commit type)
- Model the race: router sends abort to participants WHILE coordinator is sending prepare/commit
- Key invariant: once coordinator persists commit decision, all participants must eventually commit (even if router sends abort)
- Model two routers for the same session: no distributed lock exists — only session affinity at client level. Recovery token is the only safety net.
- Model single-write-shard commit ordering: read-only shards first, then write shard. On retry, synthetic recovery token falls back to coordinator protocol.

**Priority**: High
**Rationale**: 21 of 52 bug-fix commits (40.4%) in the router — most bug-prone component. 13 bugs in commit path selection alone. SERVER-38035 (abort after commit) directly demonstrated this pattern. No distributed router coordination. The code's reliance on `commitType` being set correctly is fragile.

---

### Family 3: ShardNotFound Crash During 2PC Phase 2 (HIGH)

**Mechanism**: If a shard is removed from the cluster topology (or the config server returns stale data) during the commit/abort phase of 2PC, the coordinator calls `fassert(51068, false)` — intentional crash. This is acknowledged as an open problem (SERVER-38918 TODO comment) with no safe resolution.

**Evidence**:
- Code analysis: `transaction_coordinator_util.cpp:950-956` — `sendDecisionToShard` calls `fassert(51068, false)` on `ShardNotFound` error during commit/abort phase
- Code analysis: `transaction_coordinator_util.cpp:848-859` — `sendPrepareToShard` treats `ShardNotFound` as vote-to-abort (safe pessimistic handling) during prepare phase
- The asymmetry is the bug: during prepare, `ShardNotFound` is safely handled (abort). During commit/abort, there is NO safe handling — the code crashes.
- TODO comment: "Unlike for prepare, there is no pessimistic way to handle ShardNotFound. It's not safe to treat ShardNotFound as an ack, because this node may have refreshed its ShardRegistry from a stale config secondary."

**Affected code paths**:
- `sendDecisionToShard()` in `transaction_coordinator_util.cpp`

**Suggested modeling approach**:
- Variables: `shardExists[s] ∈ BOOLEAN`, `configServerStale ∈ BOOLEAN`
- Actions: `RemoveShard(s)`, `StaleConfigRefresh` (coordinator sees removed shard as non-existent)
- Fault injection: allow `ShardNotFound` during commit phase
- Invariant: `CommitDecisionPersisted ∧ ParticipantNotReached → ¬ServerCrash` (the coordinator should handle this gracefully, not crash)

**Priority**: High
**Rationale**: This is a known, unfixed issue (SERVER-38918, open since 2018). A topology change during 2PC phase 2 crashes the coordinator, potentially leaving prepared transactions stuck on surviving shards until timeout or manual intervention.

---

### Family 4: Stale Routing and Placement Conflict (MEDIUM)

**Mechanism**: The router's cached catalog may be stale, causing transactions to be routed to the wrong shard. The `placementConflictTime` mechanism was added to detect this, but it has multiple TODO markers (SERVER-115178) suggesting incomplete migration, and the existing TLA+ spec does not model catalog staleness at all.

**Evidence**:
- Historical: SERVER-71219/78050/89529 — stale routing bugs in transactions
- Code analysis: `transaction_router.cpp:668-692` — multiple TODO SERVER-115178 comments about `placementConflictTime` being attached in legacy mode
- Code analysis: `transaction_router.cpp:94-96` — TODO SERVER-39704 about removing fail point once router can safely retry on stale version within transactions
- Code analysis: `transaction_router.cpp:1181-1199` — `canContinueOnStaleShardOrDbError` is behind a fail point (`enableStaleVersionAndSnapshotRetriesWithinTransactions`), suggesting the retry-on-stale-version feature is not fully production-ready
- Code analysis: `MultiShardTxn.tla:535-538` — `MoveKey` is defined but NOT in Next relation — catalog changes during transactions are never explored

**Affected code paths**:
- `Router::_attachVersionedFieldsIfNeeded()` — attaches version/placement info
- `Router::canContinueOnStaleShardOrDbError()` — decides if retry is safe
- `Router::_clearPendingParticipants()` — cleans up after stale version error

**Suggested modeling approach**:
- Variables: `catalog[k] ∈ Shard` (ground truth), `routerCatalog[r][k] ∈ Shard` (possibly stale)
- Actions: `MoveKey(k, sfrom, sto)` (changes catalog but not routerCatalog), `RouterRefreshCatalog(r)` (updates routerCatalog)
- Model: router sends operation to wrong shard due to stale catalog; shard rejects with StaleConfig; router retries
- Key: what happens if key moves DURING an active transaction?

**Priority**: Medium
**Rationale**: Multiple historical bugs. The fail point and TODO markers suggest the stale-routing-within-transaction handling is still evolving. Model checking could find edge cases in the retry logic.

---

### Family 5: Prepared Transaction Lifecycle Races (MEDIUM)

**Mechanism**: Prepared transactions hold locks and block reads. Multiple background tasks can interact with prepared transactions in unexpected ways: session reaper, cursor cleanup, step-down kill-sessions. The new `ReclaimedPreparedTxnTracker` (2026 copyright) suggests this area is actively being reworked.

**Evidence**:
- Historical: SERVER-105751 — session reaper destroys prepared transaction
- Code analysis: `reclaimed_prepared_txn_tracker.cpp` — brand new (2026), tracks prepared txns reclaimed during precise checkpoint recovery
- Code analysis: `transaction_participant.cpp:2586-2588` — `expiredAsOf()` only checks `kInProgress`, NOT `kPrepared`. Prepared transactions have **no timeout** — a stuck coordinator means indefinitely held locks and pinned oldest timestamp.
- Code analysis: `transaction_participant.cpp:2411` — `std::terminate()` on any exception after commit point-of-no-return. Same at line 2722 for abort. More aggressive than `fassert`.
- Code analysis: `transaction_participant.cpp:2089` — RSTL explicitly unlocked after prepare, allowing failovers while transaction is prepared. Immediate state transition can occur.
- Code analysis: `transaction_participant.cpp:3240-3242` — prepared transaction blocks new txnNumber on same session (`PreparedTransactionInProgress`). Cannot start new transaction while old one is prepared.
- Code analysis: `transaction_participant.cpp:2568` — TODO SERVER-106429: "Revisit the decision for prepared transactions" re: API parameters
- Code analysis: `transaction_participant.cpp:2657` — TODO SLS-2079: "Determine how to handle split prepared transactions" during abort
- Code analysis: `transaction_participant.cpp:2683-2687` — TODO SERVER-113730/113735: uncertainty about state checks and split transactions aborting after step up
- Code analysis: `auto_get_rstl_for_stepup_stepdown.cpp:270-271` — step-down calls `killSessionsAbortUnpreparedTransactions` which aborts in-progress (unprepared) transactions but leaves prepared ones alone
- Code analysis: `txn_two_phase_commit_cmds.cpp:411-413` — coordinator recovery path aborts in-progress transactions on the local participant (if not yet prepared)
- Code analysis: `transaction_participant.cpp:3672-3674` — relaxed `kPrepared → kNone` transition allowed during rollback, bypassing normal validation

**Affected code paths**:
- `TransactionParticipant::prepareTransaction()`
- `TransactionParticipant::commitPreparedTransaction()`
- `TransactionParticipant::abortTransaction()`
- `ReclaimedPreparedTxnTracker` (startup recovery)
- `killSessionsAbortUnpreparedTransactions()` (step-down)

**Suggested modeling approach**:
- Variables: `txnState[s][t] ∈ {None, InProgress, Prepared, Committed, Aborted}`
- Actions: `PrepareTransaction`, `CommitPreparedTransaction`, `AbortPreparedTransaction`, `ShardStepDown` (aborts unprepared, leaves prepared), `SessionReaper` (should skip prepared but historically didn't)
- Invariant: `txnState[s][t] = Prepared ⇒ ¬(txnState[s][t]' = None)` (prepared txn must not disappear)

**Priority**: Medium
**Rationale**: Active development area (multiple 2026 TODOs). Historical bug (SERVER-105751). The prepared transaction state is the most critical 2PC state — if lost, the entire protocol breaks.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Coordinator doc lifecycle | Family 1: crash windows between persist/majority/send | State variable for doc state + separate durable flag |
| Coordinator failover + recovery | Family 1: recovery reads doc, recreates coordinator | `CoordinatorCrash` + `CoordinatorRecover` actions |
| w:1 coordinator doc delete rollback | Family 1: SERVER-120584 acknowledged risk | Delete transitions doc to None, but crash can restore it |
| Router abort vs commit race | Family 2: conflicting decisions from router vs coordinator | Separate router and coordinator state machines, interleave |
| Message loss / network partition | Family 2,3: commit/abort messages may not reach participant | Messages as sets with `LoseMessage` action |
| Shard removal during 2PC | Family 3: SERVER-38918 fassert crash | `RemoveShard` action + `ShardNotFound` response |
| Catalog staleness | Family 4: stale routing causes wrong-shard operations | Separate ground truth catalog from router's view |
| Prepared transaction state | Family 5: most critical 2PC participant state | Explicit state machine with step-down behavior |
| Multiple commit optimizations | Family 2: single-shard, single-write-shard, read-only, full 2PC | Model commit type selection in router |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Storage engine (WiredTiger) internals | Too low-level; the MVCC/snapshot semantics are extensively tested |
| Oplog replication within a replica set | Abstract each shard as a single node with crash/recovery |
| `endOfTransaction` change stream event | Feature-flagged, off by default, does not affect safety |
| Sub-router (shard-to-shard) forwarding | Adds significant complexity; model as direct participant registration |
| Metrics/logging/curOp tracking | Not protocol logic |
| `placementConflictTime` details | Too implementation-specific; model catalog staleness abstractly |
| Transaction retry counter | Adds state space without targeting known bug families |
| Split prepared transactions (SLS-2079) | Very new, not yet well-defined; monitor but don't model yet |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Coordinator doc state | `coordDoc`, `coordDocDurable` | Track persistence lifecycle with crash windows | Family 1 |
| Coordinator crash/recover | `coordAlive`, `recoveredCoords` | Model failover and recovery from persisted state | Family 1 |
| Router state machine | `routerState`, `routerCommitType` | Model commit type selection and abort/commit race | Family 2 |
| Message model | `messages` (set of in-flight msgs) | Model message loss, enabling abort-commit race | Family 2, 3 |
| Shard topology | `shardAlive`, `shardVisible` | Model shard removal and ShardNotFound | Family 3 |
| Catalog staleness | `catalog`, `routerCatalog` | Model stale routing with key migration | Family 4 |
| Prepared txn tracking | `txnState` with Prepared | Model step-down behavior with prepared txns | Family 5 |
| Counter-bounded faults | `crashCount`, `msgLossCount`, `shardRemoveCount` | Bound state space while enabling fault injection | All |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| CommitDecisionAgreement | Safety | All participants that commit have the same commitTimestamp | Standard |
| NoPartialCommit | Safety | If coordinator decides commit, all participants eventually commit | Family 1, 2 |
| AbortSafety | Safety | If any participant aborted before prepare, coordinator must decide abort | Standard |
| PreparedTxnPersistence | Safety | Prepared transaction state survives step-down (not silently lost) | Family 5 |
| NoConflictingDecisions | Safety | Router cannot successfully abort a participant that coordinator has committed | Family 2 |
| ShardNotFoundNoFassert | Safety | ShardNotFound during commit phase is handled without crashing | Family 3 |
| RecoveryCompleteness | Safety | After coordinator failover, all committed txns are eventually completed | Family 1 |
| CatalogConsistency | Safety | Transaction operations reach the correct shard for each key | Family 4 |
| CoordinatorDocCleanup | Liveness | Coordinator doc is eventually deleted after decision is acknowledged | Family 1 |
| DecisionBeforeMajority | Safety | If `coordinateCommitReturnImmediatelyAfterPersistingDecision` is true, router may learn decision before majority durability — failover can roll back decision | Family 1 |
| NoInfiniteRetry | Liveness | Coordinator does not retry prepare/commit to a permanently unreachable shard forever (bounded by step-down or deadline) | Family 1, 3 |
| PreparedTxnEventuallyResolves | Liveness | Every prepared transaction is eventually committed or aborted (no indefinite lock-holding) | Family 5 |
| PreparedBlocksNewTxn | Safety | New txnNumber on same session is rejected while prepared txn exists | Family 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | Coordinator crash after w:1 doc delete, before commit ack to all participants — doc reappears, recovery re-sends commit, but some participants already cleaned up | RecoveryCompleteness | 1 |
| MC-2 | Router explicit abort reaches participant after coordinator persists commit decision | NoConflictingDecisions | 2 |
| MC-3 | Shard removed from topology during commit phase — coordinator fasserts, prepared txns stuck | ShardNotFoundNoFassert, CoordinatorDocCleanup | 3 |
| MC-4 | Key migrates during active transaction — router sends to old shard, new shard doesn't have the data | CatalogConsistency | 4 |
| MC-5 | Coordinator step-down during WaitingForVotes — new primary recovers with participants but no decision — re-sends prepare to already-committed participants | NoPartialCommit | 1 |
| MC-6 | Two routers (via recovery token) send conflicting commit/abort to coordinator shard | NoConflictingDecisions | 2 |
| MC-7 | Router learns commit decision (via `coordinateCommitReturnImmediatelyAfterPersistingDecision`) before majority — coordinator fails over, decision rolled back, router retries and gets abort | DecisionBeforeMajority | 1 |
| MC-8 | `writeEndOfTransaction` fails with transient error after commit acks — triggers LOGV2_FATAL crash, coordinator doc still exists, recovery re-drives already-committed txn | RecoveryCompleteness | 1 |
| MC-9 | Session reaper destroys prepared txn on participant — coordinator gets `NoSuchTransaction` during commit phase, interprets as ack → silent cross-shard inconsistency (SERVER-105751 pattern) | NoPartialCommit | 5 |
| MC-10 | Commit sender destroyed before all commit messages dispatched (SERVER-116284 pattern) — some participants never receive commit | NoPartialCommit | 1, 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `fassert(51068)` triggered by `ShardNotFound` during commit — verify with `removeShard` + `configureFailPoint` | Docker test: start txn, hang at `hangBeforeSendingCommit`, remove shard, resume |
| TV-2 | Coordinator doc with w:1 delete rolled back after failover | Docker test: hang at `hangAfterDeletingCoordinatorDoc`, step down primary, verify doc reappears |
| TV-3 | `ReclaimedPreparedTxnTracker` correctly tracks all prepared txns after precise checkpoint | Unit test with mocked checkpoint |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | TODO SERVER-120584: coordinator doc delete should re-evaluate w:1 | Review with MongoDB team — should this be w:majority? |
| CR-2 | TODO SERVER-38918: no safe handling of ShardNotFound during commit | Design review: should treat as "unknown" and retry indefinitely? |
| CR-3 | TODO SERVER-113730/113735: prepared txn state checks and split txn abort after step-up | Monitor — these TODOs suggest active uncertainty |
| CR-4 | TODO SLS-2079: split prepared transaction handling during abort | Monitor — new feature under development |
| CR-5 | `enableStaleVersionAndSnapshotRetriesWithinTransactions` still behind fail point (SERVER-39704) | Review: is this safe to enable by default? |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/mongodb/analysis-report.md`
- **Key source files** (relative to `mongo-src/`):
  - `src/mongo/db/s/transaction_coordinator.cpp` (782 lines) — coordinator state machine
  - `src/mongo/db/s/transaction_coordinator_util.cpp` (993 lines) — persistence, prepare/commit/abort send
  - `src/mongo/db/s/transaction_coordinator_service.cpp` (448 lines) — coordinator creation, recovery
  - `src/mongo/db/s/transaction_coordinator_catalog.cpp` (325 lines) — coordinator lookup/lifecycle
  - `src/mongo/s/transaction_router.cpp` (2651 lines) — router commit/abort logic
  - `src/mongo/db/transaction/transaction_participant.cpp` (4067 lines) — participant state machine
  - `src/mongo/db/s/txn_two_phase_commit_cmds.cpp` (487 lines) — prepare/coordinateCommit handlers
- **Existing TLA+ specs**: `artifact/vldb25-dist-txns/MultiShardTxn.tla` (594 lines) — dead Restart/MoveKey actions
- **Key SERVER tickets**: SERVER-38918 (ShardNotFound), SERVER-120584 (w:1 delete), SERVER-106075 (failover atomicity), SERVER-66067 (abort/commit race), SERVER-105751 (session reaper — silent cross-shard inconsistency), SERVER-116284 (commit not reaching all shards, Feb 2026), SERVER-116263 (data race on _participants, Jan 2026), SERVER-60682 (ticket deadlock), SERVER-65821 (3-way deadlock), SERVER-48307 (single-write-shard double execution), SERVER-39704 (stale version retry), SERVER-113730/113735 (prepared txn state)
- **JIRA mining**: 42+ distinct bugs found, 8 in 2025-2026 alone — bug rate has NOT decreased
- **Jepsen findings**: MongoDB 4.2.6 — retrocausal transactions, duplicate effects (retry/recovery anomalies)
