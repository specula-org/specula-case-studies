# Bug Report: logcabin/logcabin

## Summary

No bugs found across 5 bug-family hunting configurations. The LogCabin Raft implementation appears to be correct within the modeled scope.

## Methodology

### Convergence
- **Trace validation**: 2 traces (basic_consensus: 14 events, leader_stepdown: 4 events) — both pass
- **Simulation**: 191M states, 1.48M traces, 10 min — all 10 invariants pass (ElectionSafety, LogMatching, LeaderCompleteness, CommitSafety, SnapshotLogContinuity, ConfigSafety, JointQuorumAgreement, StepDownCorrectness, PersistenceConsistency, MCCommitIndexBound + structural)

### Bug Hunting

| Config | Bug Family | States | Traces | Duration | Result |
|--------|-----------|--------|--------|----------|--------|
| MC_hunt_truncation | Family 1: Log Truncation + Entry Integrity | 40M | 547K | 10 min | PASS |
| MC_hunt_snapshot | Family 2: Snapshot-Log Interaction | 37M | 410K | 10 min | PASS |
| MC_hunt_config | Family 3: Configuration Change Safety | 48M | 397K | 10 min | PASS |
| MC_hunt_stepdown | Family 4: Leader Liveness + Disk Sensitivity | 155M | 1.88M | 10 min | PASS |
| MC_hunt_persistence | Family 5: Non-Atomic Persistence + Crash Recovery | 38M | 459K | 10 min | PASS |
| **Total** | | **318M** | **3.69M** | **50 min** | **PASS** |

## Spec Corrections During Convergence

The following spec modeling issues were identified and fixed during convergence. These are spec errors, not implementation bugs:

1. **Timeout guard**: Added `withholdVotes[i] = FALSE` precondition. The spec allowed elections immediately after voting, but `stepDown()` calls `setElectionTimer()` in the implementation.

2. **Conflict-aware AppendEntries truncation**: The original spec unconditionally truncated the log to `prevLogIndex` and appended all entries. The implementation (RaftConsensus.cc:1356-1408) only truncates from the first conflicting entry. This is critical when stale AppendEntries messages arrive.

3. **Snapshot boundary handling in AppendEntries**: When `prevLogIndex < logStartIndex`, entries in the snapshot region must be skipped (they're already committed and covered by the snapshot).

4. **Snapshot prefix-only truncation**: The original spec discarded the entire log on InstallSnapshot. The implementation (readSnapshot, RaftConsensus.cc:2697-2714) only truncates the prefix up to the snapshot index, keeping the suffix.

5. **LeaderCompleteness invariant**: Reformulated from "leader's log matches committed entries" to "committed entries agree across all servers". The original formulation was too strong for stale leaders.

6. **StepDownCorrectness invariant**: Relaxed to account for one-epoch lag. StepDownCheck increments the epoch before checking, so peers need one round to respond.

## Discussion

LogCabin was written by Diego Ongaro, the co-author of the Raft consensus algorithm. The implementation is notably clean and correct:

- **Atomic persistence**: `updateLogMetadata()` persists `currentTerm` and `votedFor` atomically in a single metadata write (not the two-step pattern that caused bugs in other implementations like hashicorp/raft).
- **Correct commit rule**: The current-term check in `advanceCommitIndex` (fixing historical bug #44) is properly implemented.
- **Robust conflict detection**: AppendEntries only truncates from the first conflicting entry, not from `prevLogIndex` — this prevents stale messages from damaging committed state.
- **Clean snapshot-log boundary**: `readSnapshot` correctly handles both full-log and prefix-only snapshot installations.

The 5 bug families from the modeling brief (log truncation, snapshot interaction, config changes, leader liveness, crash recovery) were all tested with targeted fault injection. No safety violations were found in 318M states across 3.69M simulation traces.

## Model Scope

### Modeled
- Leader election with withholdVotesUntil
- Log replication with conflict-aware truncation
- Commit index advancement with current-term check
- Joint consensus configuration changes (Cold,new → Cnew)
- Epoch-based leader step-down
- Deferred leader disk sync (lastSyncedIndex)
- Snapshot-log boundary (InstallSnapshot, TakeSnapshot)
- Crash and recovery with atomic persistence
- Message loss and reordering

### Not Modeled
- Thread lifecycle / destructor races (C++ threading issues)
- Session management / exactly-once semantics
- Network transport details
- Snapshot data integrity (checksums)
- Multi-chunk InstallSnapshot (modeled as atomic)
- Staging server catch-up timeout (#202)
