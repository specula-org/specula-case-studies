# Modeling Brief v3: MongoDB Transaction Router & Resource Contention

## Scope Change

Previous briefs modeled 2PC **protocol correctness** — coordinator failover, abort races, ShardNotFound.
Result: 93M+ states, no new bugs. MongoDB's 2PC protocol logic is sound.

This brief targets **implementation-level concurrency bugs** — the areas where 52 historical bugs actually occurred. These bugs are NOT protocol-level; they are about wrong path selection, resource contention, and error misclassification.

## Source: analysis-report.md Patterns

| Pattern | Historical Bugs | % | TLA+ Coverage |
|---------|----------------|---|---------------|
| A: Deadlock/Ticket Starvation | 12 | 23% | None |
| B: Router Commit Path | 13 | 25% | None |
| E: Error Handling/Classification | 8 | 15% | None |
| I: Single-Write-Shard Optimization | 3 | 6% | None |

---

## Bug Family 1: Router Commit Type Selection (HIGH)

**Mechanism**: The router selects one of 5 commit types based on participant state. Wrong selection leads to partial commits, duplicate effects, or stuck transactions.

**Historical bugs** (13 total, 25% of all bugs):
- SERVER-40201: Read-only retry escalated to 2PC (wrong path)
- SERVER-39973: Empty participants triggered wrong path
- SERVER-48307: Single-write-shard retry returned "aborted" for committed txn
- SERVER-84796: Shard key update treated as read (wrong participant classification)
- SERVER-102481: `disallowSingleWriteShardCommit` flag stuck across reset
- SERVER-116284: Partial commit — some shards never received commit message

**Code location**: `transaction_router.cpp:1650-1810` (`_commitTransaction()`)

**Variables to add**:
- `commitType` — per-router per-txn: {none, singleShard, singleWriteShard, readOnly, twoPhaseCommit, recoverWithToken}
- `participantKind` — per-shard per-txn: {readOnly, write, notParticipant}
- `commitAttempt` — per-router per-txn: integer (0 = first attempt, >0 = retry)
- `commitMessagesSent` — per-shard per-txn: boolean (models SERVER-116284 partial send)

**Actions**:
- `RouterClassifyParticipants(r, txn)` — classify each participant as read/write based on ops performed (`transaction_router.cpp:1655-1690`)
- `RouterSelectCommitType(r, txn)` — select commit type based on participant classification (`transaction_router.cpp:1692-1750`)
- `RouterCommitSingleShard(r, txn)` — direct commit to single participant (`transaction_router.cpp:1752-1760`)
- `RouterCommitSingleWriteShard(r, txn)` — commit read-only first, then write shard (`transaction_router.cpp:1704-1746`)
- `RouterCommitReadOnly(r, txn)` — send commit to all read-only participants (`transaction_router.cpp:1760-1770`)
- `RouterCoordinateCommit(r, txn)` — hand off to 2PC coordinator (`transaction_router.cpp:1770-1790`)
- `RouterRetryCommit(r, txn)` — retry with recovery token (`transaction_router.cpp:1718-1731`)
- `SendCommitPartialFailure(r, txn, failedShard)` — models SERVER-116284: commit loop exits early on error, some shards never get commit

**Invariants**:
- `CommitTypeConsistency` — selected commit type matches actual participant classification
- `AllParticipantsReceiveCommit` — if commit type chosen, all relevant shards receive commit message (targets SERVER-116284)
- `RetryPreservesDecision` — retry of a committed transaction cannot produce abort
- `SingleWriteShardCorrectness` — single-write-shard path only used when exactly 1 write participant

**Suggested MC config**: MaxRetries=2, MaxTxns=2, 3 shards, 1 router. Bounded: RouterRetryCommit, SendCommitPartialFailure.

---

## Bug Family 2: Ticket/Resource Starvation Deadlock (CRITICAL)

**Mechanism**: WiredTiger uses a fixed pool of write tickets. Prepared transactions hold tickets. Coordinator needs a ticket to write the commit/abort decision. If all tickets are held by prepared txns waiting for the coordinator's decision → circular deadlock.

**Historical bugs** (12 total, 23% of all bugs):
- SERVER-60682 (P2/Critical): All write tickets exhausted — coordinator can't write decision
- SERVER-65821 (P2/Critical): Three-way deadlock: setFCV ← prepared txn ← coordinator ← setFCV
- SERVER-82883: Recovery task blocks on ticket for prepared state
- SERVER-92292: Prepare blocked on ticket held by operation waiting for prepare
- SERVER-115594: Coordinator blocked on ticket for doc cleanup
- SERVER-80978: TTLMonitor step-up deadlocks with prepared txn lock restoration
- SERVER-73915: Coordinator hangs on step-up (WaitForMajorityService not interrupted)
- SERVER-103744: Three-way deadlock: renameCollection + dbHash + prepared txn commit

**Code location**:
- Ticket pool: WiredTiger storage engine (abstracted)
- Coordinator persistence: `transaction_coordinator_util.cpp:440-600` (upsert/update use write tickets)
- Prepared txn lock: `transaction_participant.cpp:2089` (RSTL released after prepare, but WT locks held)

**Variables to add**:
- `writeTickets` — global counter: number of available write tickets (starts at MaxTickets)
- `ticketHeldBy` — per-operation: which operation holds each ticket
- `waitingForTicket` — per-operation: boolean (blocked on ticket acquisition)
- `preparedTxnHoldsTicket` — per-shard per-txn: boolean
- `coordNeedsTicket` — per-txn: boolean (coordinator waiting to write decision)
- `backgroundTaskNeedsTicket` — per-shard: boolean (TTLMonitor, setFCV, etc.)

**Actions**:
- `AcquireTicket(op)` — acquire a write ticket if available, else block (`waitingForTicket = TRUE`)
- `ReleaseTicket(op)` — release a write ticket
- `PrepareTxnAcquireTicket(s, txn)` — prepared txn acquires ticket for prepare write
- `CoordWriteDecisionAcquireTicket(txn)` — coordinator tries to acquire ticket for decision persistence
- `BackgroundTaskAcquireTicket(s, task)` — background task (TTLMonitor, setFCV) tries to acquire ticket
- `DetectDeadlock` — check for circular wait (not an action, but used in invariant)

**Invariants**:
- `NoTicketDeadlock` — no circular dependency in ticket waiters (coordinator waits for ticket → all tickets held by prepared txns → prepared txns wait for coordinator decision)
- `TicketPoolNonNegative` — available tickets >= 0
- `CoordinatorEventuallyGetsTicket` — liveness: if coordinator needs ticket, it eventually gets one

**Suggested MC config**: MaxTickets=2, MaxTxns=2, 2 shards, MaxBackgroundTasks=1. Bounded: BackgroundTaskAcquireTicket.

---

## Bug Family 3: Error Code Misclassification (HIGH)

**Mechanism**: The coordinator classifies participant responses into categories. Misclassification causes the coordinator to treat errors as successes (premature cleanup) or successes as errors (unnecessary abort).

**Historical bugs** (8 total, 15%):
- SERVER-106075: `APIMismatchError` misclassified as acknowledgment → partial commit
- SERVER-105751: `NoSuchTransaction` from session reaper treated as ack → torn commit
- SERVER-50470: Wrong error code exposed to client
- SERVER-46796: Prepare errors not reaching client
- SERVER-41189: Coordinator gave up too early on transient errors

**Code location**: `transaction_coordinator_util.cpp:820-960`
- `isVoteAbortError()` — lines 820-835
- `isTwoPhaseDecisionAckError()` — lines 837-845

**Variables to add**:
- `shardResponse` — per-shard per-txn: {success, noSuchTransaction, transactionTooOld, apiVersionError, shardNotFound, networkError, writeConflict, prepareConflict, unknown}
- `coordClassification` — per-shard per-txn: {voteCommit, voteAbort, ack, retry, fatal}
- `actualShardState` — per-shard per-txn: {inProgress, prepared, committed, aborted, reaped} (ground truth)

**Actions**:
- `ParticipantRespond(s, txn, response)` — participant sends response to coordinator
- `CoordClassifyResponse(txn, s, response)` — coordinator classifies the response
- `CoordActOnClassification(txn)` — coordinator acts based on collected classifications
- `SessionReaperFire(s, txn)` — session reaper destroys a session (changes actualShardState to "reaped" but participant still sends NoSuchTransaction)

**Invariants**:
- `ClassificationMatchesReality` — if coordinator classifies response as "ack", the shard has actually committed/aborted
- `NoSilentDataLoss` — if coordinator deletes its doc (cleanup), all participants are in terminal state (committed or aborted, not inProgress or prepared)
- `ReaperSafetyV2` — session reaper cannot fire on a prepared transaction (targets SERVER-105751)

**Suggested MC config**: 2 shards, 2 txns, 1 router, MaxReaperFires=1. Bounded: SessionReaperFire.

---

## Bug Family 4: Single-Write-Shard Retry Safety (MEDIUM)

**Mechanism**: The single-write-shard optimization commits read-only shards first, then the write shard. On retry, it falls back to recovery token protocol. The fallback can misclassify the outcome.

**Historical bugs** (3 total):
- SERVER-48307: Retry returns "definitive abort" for a transaction that actually committed on the write shard
- SERVER-84796: Shard key update retryability broken — noop update treated as read, wrong commit path selected
- SERVER-102481: `disallowSingleWriteShardCommit` flag permanently stuck after reset

**Code location**: `transaction_router.cpp:1704-1731`

**Variables to add**:
- `readOnlyShardsCommitted` — per-txn: SUBSET Shard (which read-only shards got commit)
- `writeShard` — per-txn: Shard
- `writeShardCommitted` — per-txn: boolean
- `recoveryTokenUsed` — per-txn: boolean (retry fell back to recovery token)
- `disallowSingleWriteShard` — per-router per-txn: boolean (the sticky flag)

**Actions**:
- `CommitReadOnlyShards(r, txn)` — send commit to read-only participants
- `CommitWriteShard(r, txn)` — send commit to write shard (only if read-only all succeeded)
- `ReadOnlyShardFail(r, txn, s)` — a read-only shard returns error during commit
- `RetryWithRecoveryToken(r, txn)` — retry using synthetic recovery token
- `RecoverFromWriteShard(txn)` — write shard checks local participant state
- `StickyFlagBug(r, txn)` — models SERVER-102481: flag not reset

**Invariants**:
- `RetryNeverContradictsOriginal` — if original commit succeeded on write shard, retry cannot return abort
- `StickyFlagCleared` — `disallowSingleWriteShardCommit` is cleared on transaction reset

**Suggested MC config**: 3 shards (2 read-only + 1 write), 1 txn, MaxRetries=2, MaxReadOnlyFails=1.

---

## Implementation Notes

### Abstraction Level

This spec operates at a HIGHER abstraction level than the previous 2PC spec — it models **decision logic and resource contention**, not message-by-message protocol exchange. Each "action" represents a code path in the router/coordinator, not a network message.

### State Space Management

The main state space concern is the ticket pool (Family 2). Use symmetry on shards and limit MaxTickets to 2-3. The router path selection (Family 1) has moderate state space due to the 5 commit types × retry logic.

### What NOT to Model

- WiredTiger internals (storage engine)
- Oplog replication (already verified)
- 2PC message exchange (already verified — 93M states, no bugs)
- LeaseGuard / read concern (separate concern)

### Priority

1. **Family 1 (Router Path)** — highest historical frequency, most likely to find bugs
2. **Family 2 (Ticket Deadlock)** — highest severity, most complex to model
3. **Family 3 (Error Classification)** — moderate, but SESSION-105751 pattern is recent (2025)
4. **Family 4 (Single-Write-Shard)** — smallest, but concentrated bugs
