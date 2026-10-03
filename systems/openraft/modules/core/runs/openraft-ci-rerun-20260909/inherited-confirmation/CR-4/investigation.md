# CR-4 investigation

## Finding metadata

- Source: Code Review (the supplied finding has no model-checking counterexample)
- Novelty: KNOWN (cite: https://github.com/databendlabs/openraft/issues/1808; fix-status: fixed)
- Status: DROPPED (code-review × known, cite: https://github.com/databendlabs/openraft/issues/1808)
- Source revision: `d5da3a0f168c532fa348edda44427649b422139e`
- Primary location: `openraft/src/raft_state/membership_state/mod.rs:97`
- Snapshot-install call site: `openraft/src/engine/handler/following_handler/mod.rs:291`

## Step 1: Code audit

### Relevant behavior

- `FollowingHandler::install_full_snapshot()` accepts only a snapshot newer than the local committed point, records its metadata, and then reconciles membership through `update_committed_membership()` (`openraft/src/engine/handler/following_handler/mod.rs:249-298`).
- `MembershipState::update_committed()` compares the snapshot membership and the local effective membership by log index. It replaces `effective` only when the snapshot membership's own index is at least the effective membership's index (`openraft/src/raft_state/membership_state/mod.rs:97-109`). It does not consider the snapshot's later `last_log_id`, which is also the purge boundary.
- The same install sets `purge_upto` to `snapshot.last_log_id` and queues purge (`openraft/src/engine/handler/following_handler/mod.rs:295-298`). Therefore, a stale uncommitted effective-membership entry can have an index greater than `snapshot.last_membership` while still being at or below `snapshot.last_log_id`; the code retains that cached effective membership and purges its backing log entry.

### Public/normal call chain

The path is reachable through normal protocol handling:

1. A leader replicates a membership entry with `AppendEntries`; the follower's normal append path calls `append_membership()` and makes the last membership entry effective (`openraft/src/engine/handler/following_handler/mod.rs:63-91,145-157,187-213`).
2. Later, a leader sends a full snapshot through the public `Raft::install_full_snapshot()` protocol API (`openraft/src/raft/mod.rs:655-660` and `openraft/src/raft/api/protocol.rs:115-123`).
3. `RaftCore::handle_api_msg()` dispatches the legitimate `InstallFullSnapshot` message (`openraft/src/core/raft_core.rs:1319-1324`) to `Engine::handle_install_full_snapshot()` (`openraft/src/engine/engine_impl.rs:473-503`) and then to `FollowingHandler::install_full_snapshot()`.

### Concrete trigger scenario

1. Node B accepts an uncommitted membership `M_stale` at index `i`, making it the local effective membership.
2. B loses leadership or connectivity before `M_stale` commits. Later leaders commit a different membership `M_committed` at index `j < i` but in a higher term, demoting B, and advance beyond `i`.
3. B catches up by installing a legitimate snapshot whose `last_membership` is `M_committed @ j` and whose `last_log_id` is greater than or equal to `i`.
4. The index-only comparison retains `M_stale @ i`; the install then schedules purge through the snapshot last log id, deleting the entry that backed `M_stale`.

### Safeguards and adjacent lifecycle behavior

- Durable snapshot ordering protects the separate "purge before snapshot durability" concern: `Command::PurgeLog` carries `Condition::Snapshot` (`openraft/src/engine/command.rs:244-267`), `run_command()` postpones it until `io_state.snapshot.flushed` reaches the boundary (`openraft/src/core/raft_core.rs:1812-1825`), and snapshot flush advances only after the state-machine worker's `install_snapshot()` succeeds (`openraft/src/core/sm/worker.rs:124-140`; `openraft/src/core/raft_core.rs:1606-1622`). This does not repair stale in-memory effective membership.
- Conflicting `AppendEntries` would call `truncate_logs()`, whose membership truncation reverts effective to committed (`openraft/src/engine/handler/following_handler/mod.rs:160-185`; `openraft/src/raft_state/membership_state/mod.rs:151-185`). Catching up directly by snapshot bypasses that reconciliation, which is the exact gap.
- Background snapshot completion is monotonic: `try_update_all()` and `update_snapshot()` refuse progress/metadata regression (`openraft/src/engine/engine_impl.rs:537-578`; `openraft/src/engine/handler/snapshot_handler/mod.rs:55-76`). This is adjacent to, but does not mask, the stale-membership mechanism.
- Policy bookkeeping records `snapshot_tried_at` before calling the trigger (`openraft/src/core/raft_core.rs:737-747`), while `SnapshotHandler::trigger_snapshot()` can refuse a duplicate build (`openraft/src/engine/handler/snapshot_handler/mod.rs:29-52`). This is not needed for the exact known defect.

## Step 2: Developer-knowledge search

### Tracker and merged-fix evidence

- Closed upstream Issue #1808, "Snapshot install can retain a stale `effective` membership, producing disjoint quorums and lost committed entries," reports the same mechanism at the same snapshot-install membership site: https://github.com/databendlabs/openraft/issues/1808. It gives the same ordering (`i > j`, snapshot last log beyond `i`), the retained effective membership, purge of its backing entry, and the potential disjoint-quorum consequence.
- Merged upstream PR #1809, "fix: reset purged membership on snapshot install," explicitly closes #1808: https://github.com/databendlabs/openraft/pull/1809. It merged on 2026-06-27 as merge commit `275cce95b6c9ca87021757b821670b9e598f4d0b`.
- The PR passes the snapshot last log index into membership reconciliation and resets committed/effective membership when the effective entry is inside the covered/purged range. It adds regression tests for both conflict-truncating and non-truncating snapshot installs.
- The current checkout predates the report/fix and retains the vulnerable index-only comparison.

### Local intent, history, docs, and tests

- The current comment at `openraft/src/raft_state/membership_state/mod.rs:100-109` says local effective membership may conflict and deliberately compares by log index. It does not state that retaining a membership whose backing log is purged is intended.
- The truncation documentation says a conflicting effective membership must revert to the last committed membership (`openraft/src/raft_state/membership_state/mod.rs:151-185`).
- Snapshot replication docs describe purge as the final step of installation (`openraft/src/docs/protocol/snapshot_replication.md:16,112`).
- Existing snapshot-install unit tests assert the command sequence and ordinary membership replacement, but this checkout lacks the later regression case where `snapshot.last_membership.index < stale_effective.index <= snapshot.last_log_id.index` (`openraft/src/engine/handler/following_handler/install_snapshot_test.rs`).
- Git history attributes the asynchronous-build and policy-trigger code to October 2025 commits `e7e0a3f7` and `4b840e86`; their comments explicitly rely on monotonic snapshot progress. Neither reports or fixes this membership purge-boundary defect.

## Step 3: Known-status / precedent

The issue-tracker search covered open and closed issues and open, closed, and merged pull requests using the terms `snapshot`, `membership`, and `purge`. Issue #1808 and merged PR #1809 are an exact same-site, same-mechanism match. This is therefore `KNOWN`, with upstream fix status `fixed`.

Because the supplied finding is Code Review sourced, the bug-confirmation workflow's only Phase-1 pre-filter applies. CR-4 is dropped before Phase 2, so no `repro/test_bugCR-4_*` file is created or executed.
