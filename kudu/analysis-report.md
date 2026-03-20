# Analysis Report: Apache Kudu Raft Consensus

## Executive Summary

Apache Kudu implements a production-grade Raft consensus protocol in C++ with ~16,000 LOC of core consensus logic. The git history reveals 342 bug-fix commits out of 863 total consensus commits (40%), with 4 critical safety violations (replica divergence), 14+ high-severity bugs (deadlocks, election storms, liveness failures), and 1 open unfixed bug (KUDU-3082). The implementation uses spinlock-based concurrency with a well-designed atomic persistence model for term+vote, but has had significant historical issues with commit index safety, configuration changes, and election stability.

---

## Phase 1: Reconnaissance

### Codebase Structure

| Component | File(s) | Lines | Description |
|-----------|---------|-------|-------------|
| Core state machine | raft_consensus.h/cc | 4,434 | Main Raft logic: replicate, update, vote, config change |
| Replication queue | consensus_queue.h/cc | 2,233 | Per-peer tracking, commit advancement, watermarks |
| Peer management | consensus_peers.h/cc | 1,136 | Per-peer RPC, heartbeat timers |
| Leader election | leader_election.h/cc | 699 | Vote counting, election driver |
| Persistent metadata | consensus_meta.h/cc | 695 | Term, votedFor, config persistence |
| Pending operations | pending_rounds.h/cc | 377 | In-flight op tracking |
| Time management | time_manager.h/cc | 645 | Safe timestamp tracking |
| Quorum utilities | quorum_util.h/cc | 970 | Config validation, majority calc |
| Log (WAL) | log.h/cc | 1,926 | Segment-based write-ahead log |
| Log cache | log_cache.h/cc | 733 | Write-through cache for log entries |
| Proto definitions | consensus.proto, metadata.proto | 854 | RPC messages, persistent state |
| **Total core** | | **~16,000** | |
| Tests | 14 test files | 9,286 | |

### Concurrency Model

- **Main lock (`lock_`)**: simple_spinlock protecting all mutable consensus state (term, role, config, pending ops)
- **Update lock (`update_lock_`)**: Serializes Update() RPC processing; must be taken BEFORE `lock_`
- **Queue lock (`queue_lock_`)**: simple_spinlock in PeerMessageQueue for peer tracking and watermarks
- **Atomics**: `state_` (lifecycle), `shutdown_`, `leader_is_ready_`, `withhold_votes_until_`, `last_leader_communication_time_micros_`
- **Per-peer**: Each `Peer` has its own `peer_lock_`, `request_pending_` atomic, heartbeat timer
- **Thread pool**: `raft_pool_token_` for async work; observer notifications dispatched via `raft_pool_observers_token_`

### Key Architectural Decisions

1. **Atomic term+vote persistence**: Unlike hashicorp/raft, Kudu writes term and votedFor in a single protobuf Flush(). SKIP_FLUSH_TO_DISK defers the flush when a subsequent vote flush is guaranteed.
2. **Pending config takes effect immediately**: Config change affects active config (and thus quorum, elections) as soon as the operation is added, not when committed.
3. **WithholdVotes mechanism**: Ongaro thesis §4.2.3 — followers suppress votes for `MinimumElectionTimeout()` after hearing from leader, preventing partitioned nodes from disrupting the cluster.
4. **Pre-election**: Non-binding election round — no term advance, no vote persistence. Prevents unnecessary term inflation.
5. **StepDown increments term**: Non-standard — forces cluster-wide term advance on explicit step-down.

---

## Phase 2: Bug Archaeology

### Coverage Statistics

- **Total consensus commits analyzed**: 863
- **Bug-fix commits identified**: 342 (40%)
- **JIRA issues referenced in commits**: 152 unique KUDU-* IDs
- **Critical safety bugs**: 4 (replica divergence)
- **High-severity bugs**: 14+ (deadlocks, liveness, election)
- **Open unfixed bugs**: 1 (KUDU-3082)

### Bug-Fix Commit Hotspots

| Rank | File | Bug-Fix Commits |
|------|------|-----------------|
| 1 | raft_consensus.cc | 129 |
| 2 | consensus_queue.cc | 66 |
| 3 | raft_consensus.h | 60 |
| 4 | log.cc | 59 |
| 5 | consensus_peers.cc | 54 |
| 6 | log_cache.cc | 33 |
| 7 | leader_election.cc | 23 |
| 8 | quorum_util.cc | 21 |

### Critical Safety Bugs (Replica Divergence)

#### KUDU-639: Replica commits operations from wrong term
- **Commit**: 639d8d90d
- **Root cause**: When leader sends partial batch after LMP mismatch, commit index in RPC (e.g., 2.102) exceeds what was sent (e.g., 1.50). Follower commits locally-pending ops from wrong term.
- **Fix**: Clamp `apply_up_to` to `min(pending, preceding_opid, committed_index)` (raft_consensus.cc:1521-1526)
- **Production impact**: Replica divergence on YCSB cluster

#### KUDU-597: PREPARE/REPLICATE mis-ordering
- **Commit**: d36cd08a5
- **Root cause**: Client op queued while node is FOLLOWER, then prepared after becoming LEADER — out-of-Raft-order processing causes non-commutative ops to diverge.
- **Fix**: Double-check term at submission and replicate time; prevent ABA race.
- **Production impact**: NotFound errors on ITBLL cluster

#### Stale ops replicated after abort
- **Commit**: 1eb24183a
- **Root cause**: LogCache/queue not truncated when ops aborted due to new leader. Old-term ops sent to followers.
- **Fix**: Explicit `TruncateOpsAfter()` on abort.
- **Repro rate**: 17/1000 test runs

#### Bootstrap ordering violation
- **Commit**: cdb725387
- **Root cause**: COMMIT messages applied out of order during bootstrap; INSERT before MUTATE violations.
- **Fix**: Buffer commits and apply in strict order.

### High-Severity Bugs

#### Deadlocks
| ID | Commit | Description |
|----|--------|-------------|
| KUDU-618 | e5b2260fa | PeerMessageQueue ↔ Log circular lock dependency |
| KUDU-534 | 01444896a | Peer shutdown ↔ ReplicaState lock |

#### Election Storms
| ID | Commit | Description |
|----|--------|-------------|
| KUDU-2947 | ee22ddcc7 | Slow WAL causes vote granting despite live leader |
| KUDU-2149/2155 | edd41cb40/b32283d2e | Election stacking from async failure detector |
| KUDU-1057 | c2b2eb0eb | Election flapping due to slow disk |
| KUDU-562 | 4870ef20b | Partitioned node disrupts active leader |

#### Liveness
| ID | Commit | Description |
|----|--------|-------------|
| KUDU-1469 | d68574742 | Tight RPC loop after leader change (dedup edge case) |
| KUDU-1778 | b15c0f6e3 | LMP mismatch after restart (committed_index=0) |
| KUDU-1586 | 5ba18b623 | Consensus stuck when op larger than batch size |

#### Configuration
| ID | Commit | Description |
|----|--------|-------------|
| KUDU-1338 | c693d878f | Pending config not cleared on abort |
| KUDU-872 | 0b7a4fe82 | Config change accepted before committing in term |
| NON_VOTER | 1277f69a1 | Non-voters counted toward quorum |

#### Crash/Recovery
| ID | Commit | Description |
|----|--------|-------------|
| KUDU-783 | dd81cd4d4 | Bootstrap failure with duplicate ops |
| KUDU-1678 | d1f8c23b4 | Abort order dependency during shutdown |
| KUDU-1735 | cf976a40e | Crash when aborting skipped config change |
| KUDU-1933 | 8363b7450 | int32 overflow in log index |

### Open Bugs

#### KUDU-3082: Tablets stuck in CONSENSUS_MISMATCH
- **Status**: Open, no fix
- **Description**: Tablets remain in CONSENSUS_MISMATCH state for days; replicas' active configs disagree with leader master. "Config change already in progress" blocks promotion. Requires tablet server restart to recover.

### Reverted Commits (indicating problematic changes)

| Commit | Description |
|--------|-------------|
| 8caa46793 | Revert "KUDU-548. Fix leader election memory leak" |
| 12ae13b03 | Revert "KUDU-2356. Idle WALs should not consume significant memory" |
| 430d864d2 | Revert "KUDU-131 - Part 5 - Allow replicas to advance the safe timestamp" |

---

## Phase 3: Deep Analysis

### File: raft_consensus.cc (3,332 lines)

#### Developer Signals (TODO/FIXME)

| Line | Signal | Description | Severity |
|------|--------|-------------|----------|
| 866-871 (.h) | TODO | `update_lock_` is a "hack to serialize updates" — "should probably be refactored out" | Low |
| 1285-1288 | TODO | Truncation on term mismatch is "critical" but developers don't understand why | HIGH |
| 1467-1470 | TODO | UpdateReplica failure scenarios not exercised in tests; "need more fault injection spots" | MEDIUM |
| 2815-2817 | TODO | `BecomeLeaderUnlocked()` races with shutdown — `CHECK_OK` will crash | HIGH |
| 2885 | TODO | Lock held during callback invocation — may need refactoring | LOW |

#### Finding: StepDown SKIP_FLUSH_TO_DISK (line 592-593)

`StepDown()` calls `HandleTermAdvanceUnlocked(CurrentTermUnlocked() + 1, SKIP_FLUSH_TO_DISK)` — the term advance is NOT written to disk. If the node crashes before any subsequent flush, it restarts with the old term.

**Verification**: This is a LIVENESS concern, not SAFETY. Any subsequent vote operation calls `SetVotedForCurrentTermUnlocked()` which flushes the entire cmeta protobuf (including the term). So vote safety is preserved — the term is always flushed before a vote is recorded. The worst case is a crash that "undoes" the step-down, causing the node to restart at the old term.

#### Finding: NotifyTermChange swallows errors (line 936)

```cpp
WARN_NOT_OK(HandleTermAdvanceUnlocked(term), "Couldn't advance consensus term.");
```

If `HandleTermAdvanceUnlocked` fails (e.g., `BecomeReplicaUnlocked` fails during step-down), this only logs a warning. The node may continue operating at the old term despite a higher term being observed. This is a potential safety gap — in Raft, observing a higher term MUST cause step-down.

**Risk assessment**: The failure path would require `BecomeReplicaUnlocked` to return an error, which currently requires `CheckRunningUnlocked()` or `SetNonLeaderMode()` to fail. These are unlikely in normal operation but possible during shutdown races.

#### Finding: CHECK_OK patterns (multiple lines)

The code uses `CHECK_OK` (crash-on-failure) for several critical operations:
- `cmeta_->Flush()` at lines 3171, 3188, 3225 — disk I/O failure crashes the process
- `pending_->AdvanceCommittedIndex()` at lines 916, 1535, 1646 — internal inconsistency crashes
- `BecomeLeaderUnlocked()` at line 2818 — race with shutdown crashes

These are aggressive error handling choices that convert recoverable errors into process crashes.

#### Finding: Commit index clamping (line 1521-1526)

The KUDU-639 fix is well-implemented:
```cpp
const int64_t early_apply_up_to = std::min({
    pending_->GetLastPendingOpOpId().index(),
    deduped_req.preceding_opid->index(),
    request->committed_index()});
```

This ensures the follower never commits beyond what was actually received from the leader.

### File: consensus_queue.cc (1,607 lines)

#### Finding: majority_replicated_index can go backwards (line 924-926)

`AdvanceQueueWatermark` unconditionally overwrites the watermark:
```cpp
*watermark = new_watermark;
```

No monotonicity guard. If a previously-OK peer encounters an error and drops out of the calculation, the majority watermark regresses. The committed_index itself is protected by a `>` check at line 1309, so it doesn't regress, but the majority_replicated_index does.

#### Finding: VLOG dereference of nullopt (line 1314)

In the else branch at line 1311-1318, the code dereferences `*queue_state_.first_index_in_current_term` in a VLOG message, but this branch is entered when the `if` at line 1307 fails — which includes the case where `first_index_in_current_term` has no value. This is undefined behavior if VLOG level 2 is enabled.

#### Finding: majority_size_ stale during config changes (line 231)

`majority_size_` is computed from the active config at `SetLeaderMode` time and not updated when a config change operation is pending. Between a config change replication and the next `SetLeaderMode`, the old majority size is used for watermark calculations.

### File: leader_election.cc (446 lines)

#### Finding: DCHECK-only term validation (line 413)

```cpp
DCHECK(request_.is_pre_election() ||
       state.response.responder_term() == election_term());
```

In release builds, this is compiled out. A voter granting a vote with a mismatched term would be silently counted.

#### Finding: Late votes from higher terms (line 137-141, 356-365)

After the election is decided, late-arriving responses with higher terms update `highest_voter_term_` but don't re-invoke the callback. The higher term is only checked on the VOTE_DENIED path in DoElectionCallback (raft_consensus.cc:2744-2746), not on VOTE_GRANTED.

### File: consensus_meta.cc (426 lines)

#### Finding: Atomic persistence is sound (line 3185-3188 + 3224-3225)

Term and votedFor are stored in the same protobuf (`pb_`) and flushed atomically via `Flush()`. The SKIP_FLUSH_TO_DISK optimization correctly defers the flush when a subsequent vote flush is guaranteed. This avoids the non-atomic persist bug found in hashicorp/raft.

### File: consensus_peers.cc (785 lines)

#### Finding: Close() TOCTOU race (line 630-646)

Two concurrent calls to `Close()` could both pass the initial `if (closed_)` check and proceed to acquire the lock sequentially, causing double-unsubscribe from multi_raft_batcher. Minor race.

### File: pending_rounds.cc (256 lines)

#### Finding: CancelPendingOps doesn't clear the map (line 64-82)

After notifying all pending ops of their abort status, the ops remain in `pending_ops_`. Compare with `AbortOpsAfter` (line 84-115) which does `erase()`. This leaves stale entries that affect `GetNumPendingOps()` queries.

---

## Phase 4: Bug Family Summary

### Family 1: Commit Index / Log Matching Safety — HIGH
- 7+ historical bugs (4 critical)
- Core Raft safety invariant
- Multiple production incidents
- Active code concerns (TODO at line 1285)

### Family 2: Configuration Change Safety — HIGH
- 6 historical bugs + 1 open (KUDU-3082)
- Complex interaction with elections
- Pending vs committed config distinction

### Family 3: Election / Leader Stability — HIGH
- 7+ historical bugs
- Election storms recurring production issue
- Kudu-specific extensions (withhold votes, pre-election)
- NotifyTermChange error swallowing concern

### Family 4: Operation Ordering / Role Transition — MEDIUM
- 3 historical bugs (1 critical)
- Implementation-specific concern
- Fix well-understood and in place

### Family 5: Crash Recovery / Persistence — MEDIUM
- Atomic persistence is sound
- Config change ordering is the main concern
- Mostly fixed
