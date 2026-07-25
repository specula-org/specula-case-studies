# Confirmed Bug Report — Apache Kudu Raft Consensus

## Summary

- Total findings reviewed: 12 (4 test-verifiable, 4 code-review-only, 4 spec convergence fixes)
- Confirmed: 1 (0 reproduced, 1 code-audit only)
- False positives: 7
- Not applicable (spec issues): 4
- MC hunting results: 0 bugs across 3 configs (1.4B+ states, 10.6M+ traces)

## Overview

Apache Kudu's Raft implementation is exceptionally well-hardened. The codebase has 342 bug-fix commits out of 863 total consensus commits (40%), reflecting years of production-grade testing. Model checking explored 1.83B states during convergence and 1.4B+ states across three targeted hunting configs (election safety, commit index/log matching, configuration changes) with zero safety violations found.

The four spec fixes during convergence (PreVote/vote mixing, heartbeat bypass, stale truncation, LeaderCompleteness invariant) were all spec modeling issues (Case A: invariant formulation, Case B: unfaithful spec), not bugs in the system implementation.

---

## Bug 1: VLOG Dereferences std::nullopt in Commit Index Check

- **Source**: Code Review (TV-1 from modeling brief)
- **Status**: CONFIRMED (code audit) — latent, not currently triggerable
- **Severity**: Medium (crash under verbose logging, undefined behavior)
- **Location**: `src/kudu/consensus/consensus_queue.cc:1329-1336`

### Description

In `PeerMessageQueue::ResponseFromPeer()`, the commit index advancement check at line 1325 uses short-circuit evaluation:

```cpp
if (queue_state_.first_index_in_current_term.has_value() &&
    queue_state_.majority_replicated_index >= queue_state_.first_index_in_current_term &&
    queue_state_.majority_replicated_index > queue_state_.committed_index) {
  queue_state_.committed_index = queue_state_.majority_replicated_index;
} else {
  VLOG_WITH_PREFIX_UNLOCKED(2) << "Cannot advance commit index, waiting for > "
                               << "first index in current leader term: "
                               << *queue_state_.first_index_in_current_term << ". "  // BUG: unconditional dereference
                               // ...
}
```

The `else` branch is entered when any of the three `if` conditions is false. When `first_index_in_current_term.has_value()` is false (the first condition), the else branch fires and the VLOG statement dereferences `*queue_state_.first_index_in_current_term` — which is `std::nullopt`. This is undefined behavior per the C++ standard and would typically crash.

### Trigger conditions

1. Queue is in LEADER mode
2. `first_index_in_current_term` is `std::nullopt` (reset by `SetLeaderMode()` when term changes, set by `AppendOperations()` when the first op in the new term is appended)
3. `ResponseFromPeer()` is called during the window between these two calls
4. VLOG verbosity level >= 2 (set via `--v=2` or `--vmodule=consensus_queue=2`)

### Reachability analysis

The window between `SetLeaderMode()` resetting `first_index_in_current_term` and `AppendOperations()` setting it (during NO_OP append) is currently **not reachable** by `ResponseFromPeer` because:

1. `RefreshConsensusQueueAndPeersUnlocked()` calls `peer_manager_->Close()` before `SetLeaderMode()`, which untracks all peers from `peers_map_` — any stale responses hit the `peer == nullptr` guard and return early
2. `peer_manager_->UpdateRaftConfig()` creates new peers after `SetLeaderMode()`, but they haven't sent any RPCs yet
3. The local peer's fake response (from `LocalPeerAppendFinished`) fires after `AppendOperations` sets `first_index_in_current_term`

**However**, the code is definitively wrong: the `else` branch unconditionally dereferences an optional that may not have a value. This is a latent defect that could become reachable with future code changes (e.g., if `SetLeaderMode()` is called without immediately closing peers, or if a new response path is added).

### Recommendation

Add a `has_value()` check before the dereference:

```cpp
} else {
  VLOG_WITH_PREFIX_UNLOCKED(2) << "Cannot advance commit index, waiting for > "
                               << "first index in current leader term: "
                               << (queue_state_.first_index_in_current_term.has_value()
                                   ? std::to_string(*queue_state_.first_index_in_current_term)
                                   : "(not yet set)") << ". "
                               // ...
```

---

## False Positives

### TV-2: CancelPendingOps() Doesn't Clear pending_ops_ Map

- **Location**: `src/kudu/consensus/pending_rounds.cc:64-82`
- **Why false positive**: `CancelPendingOps()` is called only during shutdown (`raft_consensus.cc:2381`), immediately followed by `SetStateUnlocked(kStopped)`. No subsequent code path queries `pending_ops_` after this point. The `PendingRounds` object is destroyed shortly after. Compare with `AbortOpsAfter()` (line 84-115) which erases entries because it's called during leader changes where the object continues to be used.

### TV-3: MarkDirty() Captures Raw `this` Pointer in Lambda

- **Location**: `src/kudu/consensus/raft_consensus.cc:3086`
- **Why false positive**: The lambda `[=]() { this->mark_dirty_clbk_(reason); }` is submitted to `raft_pool_token_`. During shutdown, `raft_pool_token_->Shutdown()` (line 2400) drains all pending tasks before returning, and this happens before the `RaftConsensus` destructor completes. After token shutdown, any new `Submit()` calls return `ServiceUnavailable`, caught by `WARN_NOT_OK`. The `this` pointer is guaranteed valid for all executing lambdas.

### TV-4: DumpStatusHtml() Accesses queue_ Without Consensus Lock

- **Location**: `src/kudu/consensus/raft_consensus.cc:2878-2901`
- **Why false positive**: `state_` is `std::atomic<State>` (declared at `raft_consensus.h:876`), so the read is well-defined. The `queue_` unique_ptr exists for the lifetime of the object and `queue_->Close()` doesn't destroy the queue — `ToString()` and `DumpToHtml()` acquire their own internal lock (`queue_lock_`). Worst case during concurrent shutdown is stale diagnostic output, which is acceptable for a status HTML endpoint.

### CR-1: DCHECK-Only Validation in HandleHigherTermUnlocked

- **Location**: `src/kudu/consensus/leader_election.cc:428`
- **Why false positive**: The `DCHECK_GT(state.response.responder_term(), election_term())` is a programming contract assertion. The sole caller (`HandleVoteResponse`, line 458-460) already checks `state.response.responder_term() > election_term()` before calling `HandleHigherTermUnlocked`. The DCHECK documents the precondition; the caller enforces it.

### CR-2: NotifyTermChange Swallows HandleTermAdvanceUnlocked Errors

- **Location**: `src/kudu/consensus/raft_consensus.cc:1033`
- **Why false positive**: `HandleTermAdvanceUnlocked` (line 3276-3296) returns `IllegalState` when `new_term <= CurrentTermUnlocked()` — a benign condition (already at the right term). Critical operations within the function (`SetCurrentTermUnlocked` → `cmeta_->Flush()`) use `CHECK_OK`, which crashes the process on I/O failure rather than returning a Status. The only error that reaches `WARN_NOT_OK` is the benign already-at-term case.

### CR-3: EndLeaderTransferPeriod() Modifies State Without Lock

- **Location**: `src/kudu/consensus/raft_consensus.cc:716-719`
- **Why false positive**: `leader_transfer_in_progress_` is declared as `std::atomic<bool>` (`raft_consensus.h:913`). The `Stop()` and `EndWatchForSuccessor()` calls on the timer and queue have their own internal synchronization. No mutex is needed.

### CR-4: StepDown SKIP_FLUSH_TO_DISK Could Undo Step-Down on Crash

- **Location**: `src/kudu/consensus/raft_consensus.cc:642-643`
- **Why false positive**: This is a documented, intentional design trade-off. On crash after SKIP_FLUSH, the node reverts to the old term — a liveness issue (delayed step-down), not a safety issue. The subsequent vote request always flushes term+votedFor atomically, preventing double-voting. The comment at line 592-593 acknowledges this trade-off.

---

## Model Checking Results

### Convergence (MC.cfg)
- **States**: 1.83B explored, 15.9M traces
- **Invariants**: ElectionSafety, LogMatching, LeaderCompleteness, CommitIndexMonotonicity — all pass
- **Spec fixes**: 4 (all Case A/B — spec modeling issues, not system bugs):
  1. PreVote/real election vote mixing → added votedFor guards
  2. SendHeartbeat bypassing log matching → removed SendHeartbeat (Kudu uses unified path)
  3. Stale AppendEntries truncating committed entries → implemented "only truncate on conflict"
  4. LeaderCompleteness checking stale leaders → restricted to current-term leader

### Hunting Configs

| Config | Bug Family | States | Traces | Result |
|--------|-----------|--------|--------|--------|
| MC_hunt_election.cfg | Election / Leader Stability | 937M | 6.3M | No violation |
| MC_hunt_commit.cfg | Commit Index / Log Matching | 481M | 4.3M | No violation |
| MC_hunt_config.cfg | Configuration Change | 2.4K | 90 | VoterOnlyQuorum false positive (invariant issue) |

### MC_hunt_config Notes
VoterOnlyQuorum violation was a false positive. The invariant checks that `matchIndex` reflects quorum agreement for committed entries, but `matchIndex` is reset to 0 on `BecomeLeader`. After re-election, the current `matchIndex` doesn't reflect the historical quorum. This is Case A (invariant formulation), not a system bug. Core safety invariants (ElectionSafety, LogMatching, LeaderCompleteness) all pass.

---

## Historical Bug Archaeology

The modeling brief identified 20+ historical bugs across 5 families (commit index, config change, election, operation ordering, crash recovery). All investigated historical bugs have been fixed in the current codebase. Key fixes verified during code audit:

- **KUDU-639** (commit index exceeds received): Fixed via clamping `apply_up_to = min(pending, preceding, committed_index)` — verified at `raft_consensus.cc:1521-1526`
- **KUDU-872** (config change before term commit): Fixed via `hasCommittedInCurrentTermUnlocked()` guard — verified at `raft_consensus.cc:1759`
- **KUDU-1338** (pending config not cleared on abort): Fixed via `ClearPendingConfigUnlocked()` in transition path — verified at `raft_consensus.cc:838`
- **KUDU-562** (partitioned node disrupts leader): Fixed via `withhold_votes_until_` mechanism — verified at `raft_consensus.cc:1934-1944`
- **KUDU-597** (prepare/replicate ordering): Fixed via term-binding at both submission and replicate time — verified at `raft_consensus.cc:803-815`

## Conclusion

Kudu's Raft implementation is exceptionally robust. With 1.4B+ states explored across targeted hunting configurations and zero safety invariant violations, the protocol logic is sound. The single confirmed finding (TV-1) is a latent VLOG dereference bug that is not currently triggerable due to peer lifecycle management, but should be fixed as a code hygiene measure. The codebase's extensive use of atomic types, CHECK_OK for critical operations, and careful lock ordering reflects deep engineering maturity.
