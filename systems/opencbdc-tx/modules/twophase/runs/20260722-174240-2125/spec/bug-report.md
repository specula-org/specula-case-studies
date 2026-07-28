# Bug Report — opencbdc-tx (2PC Architecture)

## Summary

- Bug families tested: 6
- Bugs found: 2 (Case C), 1 (Case A), 1 (Case B)
- Configs run: MC_hunt_family{1,2,3,4,5,6}.cfg

## Bug 1: Leader/Handler Activation Gap (Family 1)

- **Bug Family**: 1 — Leader/Follower Asymmetry in Message Handler Lifecycle
- **Severity**: High
- **Invariant violated**: `MCLeaderHasHandler` (`isLeader[n] => handlerActive[n]`)
- **Config**: MC_hunt_family1.cfg
- **Counterexample**: 2 states, `output/MC_hunt_family1_full.out`

### Trace Summary

1. **State 1 (Init)**: All nodes are non-leader, handlers inactive.
2. **State 2 `MCCoordRaftCallbackBecomeLeader(c1)`**: `isLeader[c1] = TRUE` but `handlerActive[c1] = FALSE`. The `BecomeLeader` action sets `startFlag[c1] = TRUE` but does NOT activate the handler. The handler is only activated later by `CoordActivateHandler` (start_stop_func).

### Root Cause

The coordinator's `raft_callback` (controller.cpp:112-130) handles `BecomeLeader` by setting internal flags (`m_start_flag`, `m_stop_flag`). The actual RPC server start/stop is deferred to a separate `start_stop_func` thread (controller.cpp:536-583) that processes these flags. Between `raft_callback` setting the flag and `start_stop_func` calling `start()`, the coordinator has `is_leader() = true` but its RPC server is not running.

The locking shard has a different pattern — `ShardRaftCallbackBecomeLeader` directly starts the server. This asymmetry creates a window where the coordinator reports as leader but cannot process transactions.

### Affected Code

- `coordinator/controller.cpp:112-130` — `raft_callback` (BecomeLeader sets flags but doesn't start handler)
- `coordinator/controller.cpp:536-583` — `start_stop_func` (defers handler start/stop)

### Recommendation

Either start the RPC server synchronously in the callback (like the locking shard does), or add a readiness check that sentinels can query before submitting transactions.

---

## Bug 2: Request In Flight During Leadership Change (Family 3)

- **Bug Family**: 3 — Sentinel-to-Coordinator Communication Gaps
- **Severity**: Medium
- **Invariant violated**: `MCNonLeaderRejectsRequest` (`requestInFlight[c] => isLeader[c]`)
- **Config**: MC_hunt_family3.cfg
- **Counterexample**: 1,121 states, `output/MC_hunt_family3_full.out`

### Trace Summary

A sentinel submits a transaction to a coordinator that is leader at the time of submission (`requestInFlight[c] = TRUE`). A subsequent leadership change makes that coordinator a follower (`isLeader[c] = FALSE`) while the request is still in flight, violating the invariant.

### Root Cause

Sentinels have no Raft leader discovery mechanism. They select a coordinator endpoint via `sentinel_id % coordinators.size()` (sentinel_2pc/controller.cpp:21-25). If the selected coordinator loses leadership between accepting the request and completing the 2PC, the in-flight transaction proceeds on a non-leader. The coordinator's `execute_transaction()` (controller.cpp:688) checks `is_leader()` only at entry — not during the entire execution.

Additionally, `send_compact_tx` (controller.cpp:219-226) retries infinitely with `while(!m_coordinator_client.execute_transaction(...))` — no mechanism to discover leader changes.

### Affected Code

- `sentinel_2pc/controller.cpp:21-25` — Modulo-based coordinator selection without leader awareness
- `coordinator/controller.cpp:688-731` — `execute_transaction()` checks leadership only at start
- `sentinel_2pc/controller.cpp:210-227` — `send_compact_tx` infinite retry loop

### Recommendation

Add leader discovery to the sentinel (e.g., Raft leader RPC, or query coordinator for current leader). If leader changes mid-request, propagate an error so the sentinel retries with the new leader.

---

## Case A: Invariant Mismatch — Shard Crash Resets State (Family 6)

- **Bug Family**: 6 — Locking Shard In-Memory State Loss
- **Severity**: N/A (invariant mismatch)
- **Invariant violated**: `MCRSMDoneImpliesShardsDiscarded`
- **Config**: MC_hunt_family6.cfg
- **Counterexample**: 247,465 states, `output/MC_hunt_family6_full.out`

### Explanation

The invariant `MCRSMDoneImpliesShardsDiscarded` requires that when `rsmPhase[d] = "done"`, all shards have `shardDiscarded[s, d] = TRUE`. When a locking shard crashes and restarts, `ShardCrash` resets all in-memory state (including `shardDiscarded`) to FALSE. The coordinator RSM state persists via Raft log, so `rsmPhase[d]` remains "done".

This is expected behavior: the locking shard is purely in-memory with no snapshots (`snapshot_distance_ = 0`). The invariant needs to account for crash recovery. Removed from structural invariants during convergence; kept as a bug-hunting invariant for non-crash scenarios.

---

## Case B: Spec Modeling Issue — RSM Commit Before Shard Lock (Family 2)

- **Bug Family**: 2 — Non-Atomic Coordinator State Machine Transitions
- **Severity**: N/A (spec modeling gap)
- **Invariant violated**: `MCRSMCommitImpliesShardsLocked`
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 1,026 states, `output/MC_hunt_family2_full.out`

### Explanation

The spec allows `RSMReplicateCommit` to fire before `ShardLockOutputs` completes, violating the invariant that all shards must have locked before commit. In the actual implementation (`distributed_tx.cpp:47-70`), the code waits for `lock_outputs` futures via `std::async` before calling `commit_cb`. The spec does not model this ordering dependency.

Fix: Add a precondition to `RSMReplicateCommit` requiring `shardLocked[s, d]` for all shards that will participate. This was recorded as a spec fidelity gap but does not affect the main findings.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 4 (Log Growth) | MC_hunt_family4.cfg | 16,409 states (depth 21) | No violation |
| 5 (Batch Races) | MC_hunt_family5.cfg | 839,282 states (depth 32) | No violation |
| 6 (Shard Crash) | MC_hunt_family6.cfg | 247,465 states | Case A (invariant mismatch) — crash resets state |
| 2 (RSM Atomicity) | MC_hunt_family2.cfg | 1,026 states | Case B (spec modeling gap) — missing ordering dependency |
