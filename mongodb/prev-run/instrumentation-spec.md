# Instrumentation Spec: MongoDB Distributed Transactions

Maps TLA+ spec actions to C++ source code locations for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "event": {
    "name": "<action_name>",
    "nid": "<node_id>",
    "ntype": "shard" | "router",
    "tid": "<transaction_id>",
    "state": { ... },
    "msg": { ... }
  }
}
```

### Common State Fields (Shard Events)

| Impl Field | TLA+ Variable | Capture |
|-----------|---------------|---------|
| `txnParticipant.isActive()` | `tid \in shardTxns[s]` | `state.inShardTxns` (bool) |
| `txnParticipant.transactionIsPrepared()` | `tid \in shardPreparedTxns[s]` | `state.prepared` (bool) |
| `txnParticipant.transactionIsAborted()` | `aborted[s][tid]` | `state.aborted` (bool) |

### Common State Fields (Router Events)

| Impl Field | TLA+ Variable | Capture |
|-----------|---------------|---------|
| `txnRouter.getParticipants()` | `rParticipants[r][tid]` | `state.participants` (array of shard IDs) |
| `txnRouter._isCommitting` | `rInCommit[r][tid]` | `state.inCommit` (bool) |

### Coordinator Doc State Fields

| Impl Field | TLA+ Variable | Capture |
|-----------|---------------|---------|
| `coordDoc.state` | `coordDoc[s][tid].state` | `state.coordDocState` (string) |

## 2. Action-to-Code Mapping

### Router Actions

#### RouterTxnStart

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::_beginOrContinueTxn()` (~line 600)
- **Trigger point**: After read timestamp is selected
- **Event name**: `RouterTxnStart`
- **Fields**: `tid`, `readTs` (the selected read timestamp)
- **Notes**: The router picks the read timestamp from `atClusterTime` or the latest known clusterTime.

#### RouterTxnOp

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::attachTxnFieldsIfNeeded()` (~line 850)
- **Trigger point**: After routing decision, before sending to shard
- **Event name**: `RouterTxnOp`
- **Fields**: `tid`, `shard` (target shard ID), `key` (the key being accessed), `op` ("read" or "write")
- **Notes**: Key must be extracted from the command's query/update filter. The shard is determined by `rCatalog` lookup.

#### RouterTxnCoordinateCommit

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::_commitWithRecoveryToken()` (~line 1200)
- **Trigger point**: Before sending coordinateCommit to coordinator shard
- **Event name**: `RouterTxnCoordinateCommit`
- **Fields**: `tid`, `shard` (coordinator shard)
- **Notes**: The coordinator is always `rParticipants[0]`.

#### RouterTxnCommitReadOnly

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::_commitReadOnlyTransaction()` (~line 1100)
- **Trigger point**: Before sending commit messages to shards
- **Event name**: `RouterTxnCommitReadOnly`
- **Fields**: `tid`

#### RouterTxnCommitSingleShard

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::_commitSingleShardTransaction()` (~line 1050)
- **Trigger point**: Before sending commit message to the single shard
- **Event name**: `RouterTxnCommitSingleShard`
- **Fields**: `tid`, `shard`

#### RouterTxnCommitSingleWriteShard

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::_commitMultiShardWithSingleWriteShardOptimization()` (~line 1150)
- **Trigger point**: Before sending commit messages
- **Event name**: `RouterTxnCommitSingleWriteShard`
- **Fields**: `tid`

#### RouterTxnAbort

- **Code location**: `src/mongo/s/transaction_router.cpp`: `TransactionRouter::implicitAbort()` (~line 1400)
- **Trigger point**: Before sending abort messages to participants
- **Event name**: `RouterTxnAbort`
- **Fields**: `tid`

### Shard Transaction Actions

#### ShardTxnStart

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: `TransactionParticipant::beginOrContinue()` (~line 500)
- **Trigger point**: After transaction snapshot is established
- **Event name**: `ShardTxnStart`
- **Fields**: `tid`
- **State**: `inShardTxns=true`, `prepared=false`, `aborted=false`

#### ShardTxnRead

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: within command execution, after `SnapshotRead`
- **Trigger point**: After read completes
- **Event name**: `ShardTxnRead`
- **Fields**: `tid`, `key`, `value` (the read result)

#### ShardTxnWrite

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: within command execution, after `TransactionWrite`
- **Trigger point**: After write completes
- **Event name**: `ShardTxnWrite`
- **Fields**: `tid`, `key`

#### ShardTxnAbort

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: `TransactionParticipant::abortTransaction()` (~line 1200)
- **Trigger point**: After abort completes
- **Event name**: `ShardTxnAbort`
- **Fields**: `tid`
- **State**: `inShardTxns=false`, `aborted=true`

### Shard 2PC Actions

#### ShardTxnCoordinateCommit

- **Code location**: `src/mongo/db/s/transaction_coordinator.cpp`: `TransactionCoordinator::_runCommitLogic()` (~line 200)
- **Trigger point**: After participant list is persisted to coordinator doc
- **Event name**: `ShardTxnCoordinateCommit`
- **Fields**: `tid`
- **State**: `coordDocState="participants"`

#### ShardTxnCoordinatorRecvCommitVote

- **Code location**: `src/mongo/db/s/transaction_coordinator_util.cpp`: in `persistParticipantsList` future chain, after receiving voteCommit response
- **Trigger point**: After vote is recorded
- **Event name**: `RecvCommitVote`
- **Fields**: `tid`, `from` (voting shard ID)

#### ShardTxnPrepare

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: `TransactionParticipant::prepareTransaction()` (~line 900)
- **Trigger point**: After prepare succeeds and vote is sent
- **Event name**: `ShardTxnPrepare`
- **Fields**: `tid`
- **State**: `inShardTxns=true`, `prepared=true`

#### ShardTxnCommit

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: `TransactionParticipant::commitPreparedTransaction()` (~line 1000) or `commitUnpreparedTransaction()` (~line 1050)
- **Trigger point**: After commit completes
- **Event name**: `ShardTxnCommit`
- **Fields**: `tid`
- **State**: `inShardTxns=false`, `prepared=false`

### Coordinator Doc Lifecycle Actions

#### CoordinatorWriteCommitDecision

- **Code location**: `src/mongo/db/s/transaction_coordinator_util.cpp`: `persistDecision()` (~line 800)
- **Trigger point**: After commit decision is majority-written to `config.transaction_coordinators`
- **Event name**: `WriteCommitDecision`
- **Fields**: `tid`
- **State**: `coordDocState="commit"`

#### CoordinatorSendCommit

- **Code location**: `src/mongo/db/s/transaction_coordinator_util.cpp`: `sendCommit()` (~line 850)
- **Trigger point**: After commit messages are sent to all participants
- **Event name**: `SendCommit`
- **Fields**: `tid`
- **State**: `coordDocState="done"`

#### CoordinatorWriteAbortDecision

- **Code location**: `src/mongo/db/s/transaction_coordinator_util.cpp`: `persistDecision()` (abort branch)
- **Trigger point**: After abort decision is majority-written
- **Event name**: `WriteAbortDecision`
- **Fields**: `tid`
- **State**: `coordDocState="abort"`

#### CoordinatorSendAbort

- **Code location**: `src/mongo/db/s/transaction_coordinator_util.cpp`: `sendAbort()` (~line 900)
- **Trigger point**: After abort messages are sent to all participants
- **Event name**: `SendAbort`
- **Fields**: `tid`
- **State**: `coordDocState="done"`

#### CoordinatorRecover

- **Code location**: `src/mongo/db/s/transaction_coordinator_service.cpp`: `_scheduleRecoveryTask()` (~line 300)
- **Trigger point**: After reading coordinator doc during step-up recovery
- **Event name**: `CoordinatorRecover`
- **Fields**: `tid`
- **Notes**: Recovery may re-send prepares, commits, or aborts depending on `coordDoc.state`.

### Abort, Reaper, Migration, Restart

#### ShardTxnRecvAbort

- **Code location**: `src/mongo/db/transaction/transaction_participant.cpp`: `TransactionParticipant::abortTransaction()` when triggered by abort command
- **Trigger point**: After abort completes in response to abort message
- **Event name**: `ShardTxnRecvAbort`
- **Fields**: `tid`
- **State**: `inShardTxns=false`, `aborted=true`

#### ReapPreparedSession

- **Code location**: `src/mongo/db/session/session_catalog.cpp`: session reaping callback
- **Trigger point**: After session is reaped (destructor aborts prepared txn)
- **Event name**: `ReapPreparedSession`
- **Fields**: `tid`
- **Notes**: The reaper fires asynchronously. The destructor of `TransactionParticipant` implicitly aborts. This is the bug scenario (SERVER-105751).

#### MoveKey

- **Code location**: `src/mongo/db/s/migration_chunk_cloner_source.cpp` (approximate)
- **Trigger point**: After chunk migration commits
- **Event name**: `MoveKey`
- **Fields**: `key`, `from` (source shard), `to` (destination shard)
- **Notes**: This is a coarse-grained event covering the entire migration. The `rCatalog` is NOT updated (stale cache modeled).

#### Restart

- **Code location**: `src/mongo/db/repl/replication_coordinator_impl.cpp`: step-down / step-up
- **Trigger point**: After shard primary steps down (crash equivalent)
- **Event name**: `Restart`
- **Fields**: (none — just node ID)
- **Notes**: All in-memory state is lost. Majority-committed data (log, prepared txn snapshots, coordinator docs) survive.

## 3. Special Considerations

### Multi-Node Coordination

MongoDB traces come from two types of nodes:
- **Routers (mongos)**: handle client requests, routing, commit classification
- **Shards (mongod)**: execute transactions, 2PC, storage operations

Trace events must include `ntype` ("router" or "shard") to disambiguate.

### Transaction ID Mapping

MongoDB uses `lsid` + `txnNumber` to identify transactions. The trace harness must map these to TLA+ `TxId` constants (e.g., "t1", "t2"). Use a deterministic mapping based on order of first encounter.

### Coordinator Doc Observation

The `coordDoc` state is not directly observable from a single trace point. It must be inferred from the coordinator's actions:
- After `persistParticipantsList()` → `"participants"`
- After `persistDecision(commit)` → `"commit"`
- After `persistDecision(abort)` → `"abort"`
- After `sendCommit/sendAbort()` → `"done"`

### Reaper Events

Session reaping is timer-driven and may not produce explicit trace events. The harness should instrument the session catalog's reaping callback to emit `ReapPreparedSession` events when a prepared session is destroyed.

### Key-to-Shard Mapping

The `catalog` mapping (key → shard) is initialized non-deterministically in the TLA+ spec. The trace harness must capture the initial catalog state and include it in the trace (or derive it from the first routing decisions).

### Storage Layer Timestamps

The Storage module manages timestamps internally. Trace events do not need to capture storage-layer timestamps — these are determined by the spec's `NextTs(s)` computation. Only the `readTs` for `RouterTxnStart` needs to be captured.
