# CR-1 investigation

## Finding metadata

- Source: Code Review
- Candidate title: Restored Leadership Before Application Recovery
- Source revision: `d5da3a0f168c532fa348edda44427649b422139e`

## Step 1: Code audit

### Relevant code and ordering

- `openraft/src/storage/helper.rs:87-148`: `StorageHelper::get_initial_state()` reads the persisted vote and optional committed pointer, reads state-machine progress, awaits `restore_from_snapshot()`, and, when `last_applied < committed`, awaits `reapply_committed()` before returning the `RaftState`.
- `openraft/src/raft/mod.rs:330-420`: the public `Raft::new()` entry point awaits `get_initial_state()` at lines 371-374, constructs the `Engine` at line 376, transfers the recovered state machine to its worker at lines 378-385, and only then spawns `RaftCore::main()` at line 420. No `Raft` handle is returned while `get_initial_state()` is still recovering storage.
- `openraft/src/core/raft_core.rs:241-252`: `RaftCore::do_main()` calls `engine.startup()` and runs its commands before entering the runtime loop that receives public API requests.
- `openraft/src/engine/engine_impl.rs:145-159`: `Engine::startup()` restores Leader state when the recovered committed vote names this node.
- `openraft/src/storage/v2/raft_log_storage.rs:64-85`: `save_committed()` is optional. The interface explicitly warns that a non-durable state machine may revert on restart when committed is not saved and tells the application not to serve reads until a new commit message is received.

Thus, when `committed` is persisted, the proposed overlap between leadership restoration and startup application recovery is not reachable: recovery is awaited before `Engine` exists and before its runtime/API loop starts. When `committed` is not persisted, however, `get_initial_state()` cannot know the pre-restart committed tail and may return a state machine restored only to its snapshot. A persisted committed self-vote can then restore Leader state. This is a normal, reachable configuration explicitly permitted by the storage API, with an application-side read-serving restriction.

### Read-path safeguards observed

- `openraft/src/core/raft_core.rs:267-317`: a `ReadIndex` request first checks that the node is a leader. It returns immediately only for a single-node quorum; otherwise it sends empty `AppendEntries` requests and requires a current quorum response.
- `openraft/src/engine/handler/leader_handler/mod.rs:106-117`: the returned `read_log_id` is at least the first/no-op log of the restored leader term, even when the recovered committed pointer is `None`.
- `openraft/src/raft/mod.rs:725-769` and `openraft/src/raft/linearizable_read/linearizer.rs:58-134`: the documented `ensure_linearizable()` consumer waits for the local state machine to apply through that `read_log_id` before returning. The lower-level `get_read_linearizer()` documentation likewise requires `try_await_ready()` before the application reads state.
- `openraft/src/core/raft_core.rs:289-303`: `LeaseRead` does not reuse a persisted lease. It succeeds only after `last_quorum_acked_time()` has been established in the new in-memory leader state; otherwise it returns an error.
- `examples/raft-kv-memstore-network-v2/src/api.rs:20-37`: the real example read caller obtains a `ReadIndex` linearizer, awaits `await_ready()`, and only then reads the state machine.

These safeguards are relevant to whether the specific documented per-read APIs expose the reverted state, but they do not erase the broader externally served raw-read window described by the storage contract and upstream report.

### Natural trigger scenario

1. A node is Leader and applies a committed client write to state that is not durable across process restart.
2. Its log store durably retains the committed self-vote and log, but uses the allowed default `save_committed()` implementation, so no committed pointer is retained.
3. The node restarts before another node establishes a higher vote.
4. `Raft::new()` restores only the last snapshot because the committed pointer is absent, then `Engine::startup()` restores Leader from the committed self-vote.
5. An application that directly exposes its state machine before a fresh cluster commit/recovery barrier can return the older value. Correct callers that persist `committed`, wait for recovery, or use the documented linearizer-and-await sequence avoid that outcome.

## Step 2: Developer-knowledge search

### Comments and documentation in the supplied revision

- `openraft/src/storage/v2/raft_log_storage.rs:66-72` states that when the state machine does not flush before `apply()` returns and committed is not saved, the application must handle state reversion carefully and must not serve reads before a new commit message.
- `openraft/src/docs/data/log_pointers.md:74-102` explains that committed persistence is optional, that without it OpenRaft recovers only to the last snapshot, and that reverted state creates application-level problems.
- `openraft/src/storage/helper.rs:208-212` separately notes that a persisted lease must not be reused on restart; the code constructs the recovered vote with a zero-duration lease.

### History and issue tracker

- Upstream issue [#1511](https://github.com/databendlabs/openraft/issues/1511), opened 2025-11-18, reports this exact mechanism at this site: leader survival via the persisted vote, non-durable state-machine state, an optional/unpersisted committed index, and stale/incomplete data observed by external readers after restart.
- Upstream PR [#1771](https://github.com/databendlabs/openraft/pull/1771), merged 2026-06-12 as commit [`f4b5f61d`](https://github.com/databendlabs/openraft/commit/f4b5f61dea3a70c8bb5207e3b56b1013997ebe67), says `Fixes #1511` and adds `Config::enable_leader_restore`, allowing users to disable immediate leadership restoration. The commit documents the same two prerequisites: an unflushed/transient state machine and an unpersisted committed index.
- Later commits `d5491a13411a4ce5e872655ca8d72a0e007b17b1` and `97d92771f83c29819d2928acab0ee751f1eb0c77` added and strengthened `Raft::wait_for_recovery()` guidance, including waiting for a fresh cluster commit that covers the durable local log tail.

Tracker/API query evidence:

```text
issue 1511: state=closed, state_reason=completed, created_at=2025-11-18T06:08:45Z, closed_at=2026-06-12T06:59:55Z
PR 1771: state=closed, merged=true, merged_at=2026-06-12T06:59:54Z, merge_commit_sha=f4b5f61dea3a70c8bb5207e3b56b1013997ebe67
PR 1771 body: Fixes #1511
```

## Step 3: Known status and pre-filter

- Novelty: `KNOWN (cite: https://github.com/databendlabs/openraft/issues/1511; fix-status: fixed)`.
- This is not merely a similar precedent: issue #1511 names the same persisted-leader-vote restoration, optional committed persistence, state-machine reversion, and external stale-read consequence.
- Status: `DROPPED (code-review x known, cite: https://github.com/databendlabs/openraft/issues/1511)`.
- In accordance with the bug-confirmation skill's sole Phase-1 pre-filter, Phase 2 was not entered and no reproduction test was written or executed.
