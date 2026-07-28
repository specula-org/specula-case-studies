# Instrumentation Guide: opencbdc-tx (2PC)

## Trace Module

Files: `src/util/common/tla_trace.{hpp,cpp}`

- Thread-safe NDJSON emitter (mutex-protected).
- Singleton via `trace_emitter::get()`.
- `SPECULA_EMIT(event, node, dtx_id, tx_id, state_json)` macro for compact calls.
- Init with `trace_emitter::get().init(path, node_label)`.
- Config line emitted on init.

## Instrumentation Points (file:line after apply)

### Coordinator (`src/uhs/twophase/coordinator/controller.cpp`)

| Event | Approx Line | Context |
|-------|------------|---------|
| `CoordRaftCallbackBecomeLeader` | ~125 | Inside `raft_callback`, after `m_stop_flag = false` in `BecomeLeader` block |
| `CoordRaftCallbackBecomeFollower` | ~138 | Inside `raft_callback`, after `m_stop_flag = true` in `BecomeFollower` block |
| `RSMReplicatePrepare` | ~155 | Inside `prepare_cb`, after `replicate_sm_command` returns |
| `RSMReplicateCommit` | ~168 | Inside `commit_cb`, after `replicate_sm_command` returns |
| `RSMReplicateDiscard` | ~174 | Inside `discard_cb`, after `replicate_sm_command` returns |
| `RSMReplicateDone` | ~180 | Inside `done_cb`, after `replicate_sm_command` returns |
| `CoordLogGrow` | ~156-179 | After each RSM command replication in callbacks |
| `CoordCrash` | ~185 | Inside `stop()`, before `m_rpc_server.reset()` |
| `CoordRecoverPrepare` | ~259-287 | Inside `recovery_func`, after each `recover_*` call |
| `CoordSwapBatch` | ~408 | After atomic batch swap in `batch_executor_func` |
| `CoordCompleteExec` | ~452 | Inside executor lambda after `m_exec_threads[thread_idx].second = false` |
| `CoordScheduleExec` | ~512 | In `schedule_exec`, after `std::make_shared<std::thread>` |
| `CoordDeactivateHandler` | ~567 | In `start_stop_func`, after `stop()` in stopping block |
| `CoordActivateHandler` | ~581 | In `start_stop_func`, after `start()` in starting block |
| `CoordAddTxToBatch` | ~721 | In `execute_transaction`, after `m_current_txs->emplace(...)` |
| `SentinelRequestToNonLeader` | ~689 | In `execute_transaction`, inside `if(!m_raft_serv->is_leader())` |

### Locking Shard (`src/uhs/twophase/locking_shard/`)

| Event | File | Approx Line | Context |
|-------|------|------------|---------|
| `ShardRaftCallbackBecomeFollower` | `controller.cpp` | ~119 | After `m_logger->warn("Became follower, stopping listener")` |
| `ShardRaftCallbackBecomeLeader` | `controller.cpp` | ~127 | After `m_server->init()` succeeds |
| `ShardLockOutputs` | `locking_shard.cpp` | ~101 | After `m_prepared_dtxs.emplace(...)` |
| `ShardApplyOutputs` | `locking_shard.cpp` | ~180 | After `m_applied_dtxs.insert(dtx_id)` (x2: early return + normal path) |
| `ShardDiscardDtx` | `locking_shard.cpp` | ~22 | After `m_applied_dtxs.erase(dtx_id)` |
| `ShardReplayLog` | `state_machine.cpp` | ~46 | Inside `commit()`, after `blocking_call` |
| `ShardLogGrow` | `state_machine.cpp` | ~48 | Inside `commit()`, after replay event |

### Sentinel (`src/uhs/twophase/sentinel_2pc/controller.cpp`)

| Event | Approx Line | Context |
|-------|------------|---------|
| `SentinelSubmitTx` | ~227 | Inside `send_compact_tx`, after `while` retry loop succeeds |

## How to Add a New Field

1. Find the `SPECULA_EMIT(...)` call for the event.
2. Add the field to the JSON object string, e.g.:
   ```
   "{\"field_name\":" + std::to_string(value) + "}"
   ```
3. If you need a new helper (e.g., `kv_bool`, `kv_int`), add it to `tla_trace.hpp`.

## How to Add a New Event Type

1. Define the event name (must match `Trace.tla`).
2. Find the trigger point in the source code (from the instrumentation spec).
3. Insert:
   ```
   SPECULA_EMIT("EventName", node_str, dtx_id_str, tx_id_str, "{\"field\":value}");
   ```
4. Optionally wrap in `if(trace_emitter::get().is_initialized())` check.

## How to Move a Capture Point

- Change the location of the `SPECULA_EMIT` call relative to the surrounding logic.
- `prepare_cb`/`commit_cb`/etc. must capture AFTER `replicate_sm_command` returns (before would capture incorrect state).

## Test Coverage Notes

### Events Instrumented but Not Triggered by Current Tests

| Event | Why Not Triggered |
|-------|------------------|
| `CoordRaftCallbackBecomeFollower` | Requires leader change (multi-node Raft) |
| `CoordDeactivateHandler` | Requires leader change (multi-node Raft) |
| `ShardRaftCallbackBecomeFollower` | Requires leader change (multi-node Raft) |
| `SentinelRequestToNonLeader` | Requires contacting a non-leader coordinator |
| `ShardCrash` | Requires simulated crash + restart |
| `CoordRecoverPrepare` | Requires leader change with pending DTXs in RSM |

Adding tests for these events requires:
1. Multi-node setup (2+ coordinators, 2+ shards)
2. Fault injection (kill leader, verify recovery)
3. Config with `coordinator_count=2`, `shard_count=2`

### Event Types Covered (19 of 25)

All core protocol paths are covered: leader election & handler lifecycle, 2PC RSM transitions, shard lock/apply/discard, sentinel submission, batch processing, and log growth.

## How to Rebuild and Re-run

```bash
cd /home/ubuntu/2pc/opencbdc-tx/.specula-output
bash harness/run.sh
```

Or manually:

```bash
cd /home/ubuntu/2pc/opencbdc-tx
bash .specula-output/harness/apply.sh
cd build
cmake .. -DCMAKE_BUILD_TYPE=Debug
make -j$(nproc) run_integration_tests
cd ../tests/integration
../../build/tests/integration/run_integration_tests --gtest_filter="normal_tx_test.*"
```
