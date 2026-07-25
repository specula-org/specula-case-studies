# Instrumentation Spec: MongoDB Transaction Router & Resource Contention

Maps TLA+ spec actions to MongoDB source code locations for trace generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "txn": "<lsid_txnNumber>",
  "router": "<mongos_host:port>",
  "shard": "<shardId>",
  "commitType": "<CT_none|CT_single|CT_sws|CT_readOnly|CT_2pc|CT_recover>",
  "rPhase": "<RP_idle|RP_started|RP_committing|RP_done|RP_aborted|RP_failed>",
  "sState": "<SS_none|SS_inProg|SS_prepared|SS_committed|SS_aborted|SS_reaped>",
  "cPhase": "<CP_none|CP_preparing|CP_decided|CP_sending|CP_done>",
  "cDecision": "<D_none|D_commit|D_abort>",
  "tickets": <integer>,
  "participants": {"shard1": "PK_ro", "shard2": "PK_wr"},
  "attempt": <integer>,
  "response": "<R_ok|R_noSuchTxn|R_txnTooOld|R_apiMismatch>",
  "ts": <unix_epoch_ms>
}
```

### State Fields

| Implementation Field | TLA+ Variable | Location |
|---------------------|---------------|----------|
| `TransactionRouter::CommitType` | `rCommitType` | `transaction_router.h` — `o().commitType` |
| `TransactionRouter::participants` | `rPK` | `transaction_router.cpp:1667-1682` — participant.readOnly |
| Commit attempt counter | `rAttempt` | Derived from `isFirstCommitAttempt` |
| `disallowSingleWriteShardCommit` | `rDisallowSWS` | `transaction_router.cpp:1704` — `p().disallowSingleWriteShardCommit` |
| `TransactionCoordinator::_step` | `cPhase` | `transaction_coordinator.cpp` — Step enum |
| `TransactionCoordinator::_decision` | `cDecision` | `transaction_coordinator.cpp:_decision` |
| `TransactionParticipant::txnState` | `sState` | `transaction_participant.cpp` — `o().txnState` |
| WT write tickets available | `tickets` | `WiredTigerKVEngine::getAvailableWriteTickets()` |

## Section 2: Action-to-Code Mapping

### RouterStartTxn

| Field | Value |
|-------|-------|
| **Spec action** | `RouterStartTxn(r, t)` |
| **Code location** | `transaction_router.cpp` — `beginOrContinueTxn()` |
| **Trigger point** | After first participant is added to the transaction |
| **Event name** | `RouterStartTxn` |
| **Fields** | `router`, `txn`, `participants` (map of shardId → PK_ro/PK_wr), `rPhase` |
| **Notes** | Emit after all initial participants are known. If participants are added incrementally, emit after each `processParticipantResponse` call that adds a NEW participant. |

### RouterCommitTxn

| Field | Value |
|-------|-------|
| **Spec action** | `RouterCommitTxn(r, t)` |
| **Code location** | `transaction_router.cpp:1649-1771` — `_commitTransaction()` |
| **Trigger point** | After commit type is selected and set (after the `o(lk).commitType = ...` line) |
| **Event name** | `RouterCommitTxn` |
| **Fields** | `router`, `txn`, `commitType`, `rPhase`, `attempt` |
| **Notes** | Emit once per commit attempt, right after the commit type assignment. The commit type string must match the TLA+ constant names. Map: kNoShards→CT_noShards, kSingleShard→CT_single, kSingleWriteShard→CT_sws, kReadOnly→CT_readOnly, kTwoPhaseCommit→CT_2pc, kRecoverWithToken→CT_recover. |

### DirectCommit

| Field | Value |
|-------|-------|
| **Spec action** | `DirectCommit(r, t)` |
| **Code locations** | `transaction_router.cpp:1701` (singleShard), `transaction_router.cpp:1762` (readOnly) |
| **Trigger point** | After `sendCommitDirectlyToShards` returns successfully |
| **Event name** | `DirectCommit` |
| **Fields** | `router`, `txn`, `rPhase` = "RP_done" |
| **Notes** | Only emit on success. On partial failure (error mid-send), emit nothing — the failure will be apparent from missing event or subsequent retry. |

### SWSCommitReadOnly

| Field | Value |
|-------|-------|
| **Spec action** | `SWSCommitReadOnly(r, t)` |
| **Code location** | `transaction_router.cpp:1734` — `sendCommitDirectlyToShards(opCtx, readOnlyShards)` |
| **Trigger point** | After read-only shards commit successfully (line 1737 check passes) |
| **Event name** | `SWSCommitReadOnly` |
| **Fields** | `router`, `txn` |
| **Notes** | Only emit if both `readOnlyCmdStatus.isOK()` and `readOnlyWCE.isOK()`. If either fails, emit `SWSReadOnlyFail` instead. |

### SWSCommitWrite

| Field | Value |
|-------|-------|
| **Spec action** | `SWSCommitWrite(r, t)` |
| **Code location** | `transaction_router.cpp:1745` — `sendCommitDirectlyToShards(opCtx, writeShards)` |
| **Trigger point** | After write shard commit returns successfully |
| **Event name** | `SWSCommitWrite` |
| **Fields** | `router`, `txn`, `rPhase` = "RP_done" |

### SWSRetryRecovery

| Field | Value |
|-------|-------|
| **Spec action** | `SWSRetryRecovery(r, t)` |
| **Code location** | `transaction_router.cpp:1718-1731` — recovery token path |
| **Trigger point** | After `_commitWithRecoveryToken` returns |
| **Event name** | `SWSRetryRecovery` |
| **Fields** | `router`, `txn`, `rPhase` (RP_done or RP_aborted), `commitType` = "CT_recover" |
| **Notes** | This is the recovery token fallback for retried SWS commits. |

### RouterRetry

| Field | Value |
|-------|-------|
| **Spec action** | `RouterRetry(r, t)` |
| **Code location** | `transaction_router.cpp` — `commitTransaction()` retry entry |
| **Trigger point** | At the start of a retried commit attempt |
| **Event name** | `RouterRetry` |
| **Fields** | `router`, `txn`, `attempt` |

### CoordDecideCommit

| Field | Value |
|-------|-------|
| **Spec action** | `CoordDecideCommit(t)` |
| **Code location** | `transaction_coordinator.cpp:270-290` — prepare vote collection |
| **Trigger point** | After all prepare votes collected, decision = commit |
| **Event name** | `CoordDecideCommit` |
| **Fields** | `txn`, `cPhase` = "CP_decided", `cDecision` = "D_commit", `tickets` |
| **Notes** | Emit from the coordinator shard (not the router). Capture write ticket count from WiredTiger stats. |

### CoordDecideAbort

| Field | Value |
|-------|-------|
| **Spec action** | `CoordDecideAbort(t)` |
| **Code location** | `transaction_coordinator.cpp:270-290` — first abort vote received |
| **Trigger point** | After coordinator decides abort |
| **Event name** | `CoordDecideAbort` |
| **Fields** | `txn`, `cPhase` = "CP_decided", `cDecision` = "D_abort" |

### CoordPersistAndSend

| Field | Value |
|-------|-------|
| **Spec action** | `CoordPersistAndSend(t)` |
| **Code location** | `transaction_coordinator_util.cpp:479-511` — `persistDecision()` |
| **Trigger point** | After decision is persisted (OpTime returned) |
| **Event name** | `CoordPersistAndSend` |
| **Fields** | `txn`, `cPhase` = "CP_sending" |

### CoordSendDecisionToShard

| Field | Value |
|-------|-------|
| **Spec action** | `CoordSendDecisionToShard(t, s)` |
| **Code location** | `transaction_coordinator_util.cpp:877-957` — `sendDecisionToShard()` |
| **Trigger point** | After response received from shard and classified |
| **Event name** | `CoordSendDecisionToShard` |
| **Fields** | `txn`, `shard`, `sState`, `response` |
| **Notes** | Emit the response classification: if `isTwoPhaseDecisionAckError` matched, `response` = the error code (R_noSuchTxn or R_txnTooOld). If success, `response` = "R_ok". |

### CoordFinish

| Field | Value |
|-------|-------|
| **Spec action** | `CoordFinish(t)` |
| **Code location** | `transaction_coordinator.cpp:350-370` — `_done()` continuation |
| **Trigger point** | After coordinator doc deleted and completion future resolved |
| **Event name** | `CoordFinish` |
| **Fields** | `txn`, `cPhase` = "CP_done" |

### SessionReaperFire

| Field | Value |
|-------|-------|
| **Spec action** | `SessionReaperFire(s, t)` |
| **Code location** | `kill_sessions_local.cpp` — `killSessionsAbortUnpreparedTransactions()` |
| **Trigger point** | After session reaper kills a transaction |
| **Event name** | `SessionReaperFire` |
| **Fields** | `shard`, `txn`, `sState` = "SS_reaped" |
| **Notes** | This is a fault injection event. In normal operation, the reaper should NOT touch prepared transactions (filtered by `expiredAsOf()` at `transaction_participant.cpp:2586-2588`). Instrumentation should log if a prepared txn IS reaped. |

### RouterReceive2PCResult

| Field | Value |
|-------|-------|
| **Spec action** | `RouterReceive2PCResult(r, t)` |
| **Code location** | `transaction_router.cpp:1770` — `_handOffCommitToCoordinator()` return |
| **Trigger point** | After coordinateCommitTransaction returns to the router |
| **Event name** | `RouterReceive2PCResult` |
| **Fields** | `router`, `txn`, `rPhase` (RP_done or RP_aborted) |

## Section 3: Special Considerations

### 1. Commit Type String Mapping

The C++ `CommitType` enum must be mapped to TLA+ string constants:

| C++ enum | TLA+ constant |
|----------|---------------|
| `CommitType::kNoShards` | `"CT_noShards"` |
| `CommitType::kSingleShard` | `"CT_single"` |
| `CommitType::kSingleWriteShard` | `"CT_sws"` |
| `CommitType::kReadOnly` | `"CT_readOnly"` |
| `CommitType::kTwoPhaseCommit` | `"CT_2pc"` |
| `CommitType::kRecoverWithToken` | `"CT_recover"` |

### 2. Participant Kind Mapping

| C++ enum | TLA+ constant |
|----------|---------------|
| `Participant::ReadOnly::kReadOnly` | `"PK_ro"` |
| `Participant::ReadOnly::kNotReadOnly` | `"PK_wr"` |

### 3. Shard State Mapping

| C++ state | TLA+ constant |
|-----------|---------------|
| `kNone` | `"SS_none"` |
| `kInProgress` | `"SS_inProg"` |
| `kPrepared` | `"SS_prepared"` |
| `kCommitted` | `"SS_committed"` |
| `kAbortedWithPrepare` / `kAbortedWithoutPrepare` | `"SS_aborted"` |
| (session reaped) | `"SS_reaped"` |

### 4. Router vs Coordinator Events

Router events are emitted by the mongos process (`transaction_router.cpp`).
Coordinator events are emitted by the mongod shard acting as coordinator (`transaction_coordinator*.cpp`).
These run on different processes, so timestamps may be skewed. Events within the same process are ordered; cross-process ordering depends on the trace collection mechanism.

### 5. Ticket Count Accuracy

WiredTiger ticket counts are a point-in-time snapshot. The spec variable `tickets` tracks the logical count. In the real system, ticket counts can change between the instrumentation point and the actual operation. For trace validation, use the ticket count captured at the `CoordDecideCommit` event as the reference, and accept small deviations (±1) in subsequent events.

### 6. Transaction Identity

Each event includes a `txn` field formatted as `"<lsid>_<txnNumber>"`. The Trace.tla module derives the `Txn` constant set from unique `txn` values in the trace. Ensure all events for the same transaction use exactly the same string.

### 7. disallowSingleWriteShardCommit Flag

This flag is private state (`p().disallowSingleWriteShardCommit`). It is NOT directly observable from outside the TransactionRouter. To instrument it, add a trace point in `_commitTransaction()` after the flag check at line 1704, capturing the flag value in the `RouterCommitTxn` event.
