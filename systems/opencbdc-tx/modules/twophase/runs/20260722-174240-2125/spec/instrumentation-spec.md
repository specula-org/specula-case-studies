# Instrumentation Spec: opencbdc-tx (2PC Architecture)

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is an NDJSON line with the following common envelope:

```json
{
  "event": "<string>",
  "node": "<string>",
  "dtx_id": "<string | null>",
  "tx_id": "<string | null>",
  "timestamp": "<uint64>",
  "fields": { <state-snapshot> }
}
```

### State Fields (Captured at Every Event)

| Field | Type | TLA+ Variable | Source |
|-------|------|---------------|--------|
| `is_leader` | bool | `isLeader[node]` | `m_raft_serv->is_leader()` |
| `handler_active` | bool | `handlerActive[node]` | RPC server running state |
| `rsm_phase` | string | `rsmPhase[dtx_id]` | RSM committed state |
| `batch_tx_count` | uint | `batchTxCount[node]` | `m_current_txs->size()` |
| `exec_busy` | bool | `execBusy[node]` | Thread pool busy flag |

### Message Fields (Event-Specific)

Events involving a shard RPC additionally capture:

```json
{
  "shard_locked": "<bool>",
  "shard_applied": "<bool>",
  "shard_discarded": "<bool>"
}
```

## Section 2: Action-to-Code Mapping

### Family 1: Leader/Follower Asymmetry

#### `CoordRaftCallbackBecomeLeader`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:115-130` |
| Trigger point | After `nuraft::cb_func::BecomeLeader` check |
| Trace event name | `"CoordRaftCallbackBecomeLeader"` |
| Fields | `node`, `is_leader`, `start_flag`, `stop_flag` |
| Notes | Capture before `m_start_cv.notify_one()` |

#### `CoordRaftCallbackBecomeFollower`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:131-142` |
| Trigger point | After `nuraft::cb_func::BecomeFollower` check |
| Trace event name | `"CoordRaftCallbackBecomeFollower"` |
| Fields | `node`, `is_leader`, `start_flag`, `stop_flag` |
| Notes | Capture flags before `m_start_cv.notify_one()` |

#### `CoordActivateHandler`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:572-581` (within `start_stop_func`) |
| Trigger point | After `start()` completes |
| Trace event name | `"CoordActivateHandler"` |
| Fields | `node`, `handler_active`, `current_batch_dtx`, `start_flag` |
| Notes | Capture after `m_rpc_server` initialization |

#### `CoordDeactivateHandler`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:564-571` (within `start_stop_func`) |
| Trigger point | After `stop()` completes |
| Trace event name | `"CoordDeactivateHandler"` |
| Fields | `node`, `handler_active`, `current_batch_dtx`, `stop_flag` |
| Notes | Capture after `join_execs()` |

#### `ShardRaftCallbackBecomeLeader`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/controller.cpp:122-131` |
| Trigger point | After `m_server->init()` succeeds |
| Trace event name | `"ShardRaftCallbackBecomeLeader"` |
| Fields | `node`, `is_leader`, `handler_active` |
| Notes | Inline handler start — no deferral |

#### `ShardRaftCallbackBecomeFollower`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/controller.cpp:117-120` |
| Trigger point | After `m_server.reset()` |
| Trace event name | `"ShardRaftCallbackBecomeFollower"` |
| Fields | `node`, `is_leader`, `handler_active` |
| Notes | Inline handler stop |

### Family 2: Non-Atomic RSM Transitions

#### `RSMReplicatePrepare`

| Field | Value |
|-------|-------|
| Code locations | `coordinator/distributed_tx.cpp:24-30` (prepare), `coordinator/controller.cpp:146-155` (prepare_cb) |
| Trigger point | After `replicate_sm_command` succeeds |
| Trace event name | `"RSMReplicatePrepare"` |
| Fields | `dtx_id`, `rsm_phase` |
| Notes | Captures BEFORE shard lock_outputs (RSM first, then shard) |

#### `ShardLockOutputs`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/locking_shard.cpp:78-102` |
| Trigger point | After `lock_outputs` returns (success or failure) |
| Trace event name | `"ShardLockOutputs"` |
| Fields | `node`, `dtx_id`, `shard_locked` |
| Notes | Called via `std::async` in `distributed_tx.cpp:31-45` |

#### `RSMReplicateCommit`

| Field | Value |
|-------|-------|
| Code locations | `coordinator/distributed_tx.cpp:74-80` (commit), `coordinator/controller.cpp:157-168` (commit_cb) |
| Trigger point | After `replicate_sm_command` succeeds |
| Trace event name | `"RSMReplicateCommit"` |
| Fields | `dtx_id`, `rsm_phase` |
| Notes | Captures BEFORE shard apply_outputs |

#### `ShardApplyOutputs`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/locking_shard.cpp:135-182` |
| Trigger point | After `apply_outputs` returns |
| Trace event name | `"ShardApplyOutputs"` |
| Fields | `node`, `dtx_id`, `shard_applied` |
| Notes | Called via `std::async` in `distributed_tx.cpp:81-97` |

#### `RSMReplicateDiscard`

| Field | Value |
|-------|-------|
| Code location | `coordinator/distributed_tx.cpp:180-187` (discard), `coordinator/controller.cpp:170-174` (discard_cb) |
| Trigger point | After `replicate_sm_command` succeeds |
| Trace event name | `"RSMReplicateDiscard"` |
| Fields | `dtx_id`, `rsm_phase` |

#### `ShardDiscardDtx`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/locking_shard.cpp:15-22` |
| Trigger point | After `discard_dtx` returns |
| Trace event name | `"ShardDiscardDtx"` |
| Fields | `node`, `dtx_id`, `shard_discarded` |

#### `RSMReplicateDone`

| Field | Value |
|-------|-------|
| Code location | `coordinator/distributed_tx.cpp:207-212` (done), `coordinator/controller.cpp:176-180` (done_cb) |
| Trigger point | After `replicate_sm_command` succeeds |
| Trace event name | `"RSMReplicateDone"` |
| Fields | `dtx_id`, `rsm_phase` |

### Family 3: Sentinel Communication

#### `SentinelSubmitTx`

| Field | Value |
|-------|-------|
| Code location | `sentinel_2pc/controller.cpp:210-227` (send_compact_tx) |
| Trigger point | When `m_coordinator_client.execute_transaction` returns true (accepted) |
| Trace event name | `"SentinelSubmitTx"` |
| Fields | `node`, `tx_id`, `is_leader`, `request_in_flight` |
| Notes | Sentinel retries infinitely until accepted. Event captured on successful submit. |

#### `SentinelRequestToNonLeader`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:688-690` |
| Trigger point | When `execute_transaction` returns false due to `!is_leader()` |
| Trace event name | `"SentinelRequestToNonLeader"` |
| Fields | `node`, `tx_id`, `is_leader` |
| Notes | Request silently dropped. Sentinel retries (infinite while loop at line 219). |

### Family 4: Raft Log Growth

#### `CoordLogGrow`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:37` |
| Trigger point | After each RSM command replication |
| Trace event name | `"CoordLogGrow"` |
| Fields | `node`, `log_entries` |

#### `ShardLogGrow`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/controller.cpp:46` |
| Trigger point | After each shard RSM command |
| Trace event name | `"ShardLogGrow"` |
| Fields | `node`, `log_entries` |

### Family 5: Batch Processing

#### `CoordAddTxToBatch`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:684-731` |
| Trigger point | After tx added to `m_current_txs` (line 721) |
| Trace event name | `"CoordAddTxToBatch"` |
| Fields | `node`, `batch_tx_count`, `batch_size` |
| Notes | Captures the N+1 count after insertion |

#### `CoordSwapBatch`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:398-406` |
| Trigger point | After atomic swap of `m_current_batch` and `m_current_txs` (line 401-406) |
| Trace event name | `"CoordSwapBatch"` |
| Fields | `node`, `batch_tx_count`, `current_batch_dtx` |
| Notes | Captures post-swap state (batch_tx_count = 0) |

#### `CoordScheduleExec`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:491-525` |
| Trigger point | After `std::thread` is created (line 512) |
| Trace event name | `"CoordScheduleExec"` |
| Fields | `node`, `exec_busy`, `batch_swap_pending` |

#### `CoordCompleteExec`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:448-452` |
| Trigger point | When thread marks itself as done (line 451) |
| Trace event name | `"CoordCompleteExec"` |
| Fields | `node`, `exec_busy` |

### Family 6: Crash/Recovery

#### `CoordCrash`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:182-217` (stop) + signal handler |
| Trigger point | Before process terminates or on leader change |
| Trace event name | `"CoordCrash"` |
| Fields | `node`, `is_leader`, `handler_active`, `current_batch_dtx` |
| Notes | RSM state (rsmPhase) persists in Raft log — NOT lost |

#### `ShardCrash`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/locking_shard.hpp:139-144` |
| Trigger point | Before process terminates |
| Trace event name | `"ShardCrash"` |
| Fields | `node`, `is_leader`, `handler_active`, `locked_uhs` |
| Notes | ALL in-memory state lost — uhsSet, lockedSet, prepared/applied dtxs |

#### `CoordRecoverPrepare`

| Field | Value |
|-------|-------|
| Code location | `coordinator/controller.cpp:219-329` (recovery_func) |
| Trigger point | After dtxs reconstructed from RSM state (line 259) |
| Trace event name | `"CoordRecoverPrepare"` |
| Fields | `dtx_id`, `rsm_phase` |
| Notes | Called during `start()` on new leader |

#### `ShardReplayLog`

| Field | Value |
|-------|-------|
| Code location | `locking_shard/controller.cpp:46`, `locking_shard/state_machine.cpp:33-47` |
| Trigger point | After NuRaft replay completes |
| Trace event name | `"ShardReplayLog"` |
| Fields | `node` |
| Notes | No snapshots, full log replay from start |

## Section 3: Special Considerations

### Concurrent Threads

Multiple threads execute simultaneously. Trace events from different threads may interleave in the NDJSON file. The trace spec's cursor-based processing is linear (Category A pattern), so instrumentation must ensure a **single logical event stream**. Recommended approach:

- Insert a **sequence number** in each event.
- Use a **dedicated tracing thread** with a lock-free queue that all other threads push events to.
- The tracing thread writes the NDJSON file in sequence-number order.

### RSM State Persistence

The coordinator's RSM state (`rsmPhase`) persists across crashes via Raft log replication. Instrumentation must read committed state from the state machine, not from in-memory batch state. Recovery trace events (`CoordRecoverPrepare`) should capture the RSM state at the time of recovery, not the (cleared) in-memory state.

### Locking Shard In-Memory Nature

The locking shard has zero persistent state. On crash, all `m_uhs`, `m_locked`, `m_prepared_dtxs`, and `m_applied_dtxs` are lost. The `ShardCrash` trace should capture the pre-crash state (if possible) to validate that the spec correctly models state loss. After crash, the shard restarts with empty state and replays the Raft log.

### Batch Callback Registration

`batch_set_cbs` (controller.cpp:331-362) skips registration for the phase the dtx is currently in. This means recovery dtxs may have different callback sets than fresh dtxs. Instrumentation should capture which callbacks are registered for each dtx, especially during recovery.

### Sentinel Retry Loop

The sentinel's `send_compact_tx` (controller.cpp:219-226) spins in an infinite `while` loop. Each retry iteration should NOT produce a trace event to avoid flooding. Only the **final successful submit** (`SentinelSubmitTx`) and **the first non-leader rejection** (`SentinelRequestToNonLeader`) should be traced.
