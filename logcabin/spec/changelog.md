# Spec Validation Changelog: logcabin

## Round 1 - Trace Validation
- No fixes needed. Both traces (basic_consensus, leader_stepdown) passed on first run.

## Round 1 - Model Checking
- [fix-spec] Timeout: added `withholdVotes[i] = FALSE` guard. Spec allowed elections immediately after voting for another server, but implementation's `stepDown()` calls `setElectionTimer()` preventing this. (Case B)
- [fix-inv] LeaderCompleteness: reformulated from "leader's log matches any committed entries" to "committed entries agree across all servers". Old formulation was too strong — a stale leader at an older term naturally has different uncommitted entries. (Case A)
- [fix-spec] HandleAppendEntriesRequest: replaced unconditional truncate-to-prevLogIndex with conflict-aware truncation (CanMatch/matchLen). Implementation (RaftConsensus.cc:1356-1408) only truncates from the first conflicting entry; matching entries are kept. Old approach allowed stale AE messages to destroy committed entries. (Case B)
- [fix-spec] HandleAppendEntriesRequest: added skipCount for entries spanning the snapshot boundary. When `prevLogIndex < logStartIndex`, entries in the snapshot region must be skipped, not treated as conflicts. (Case B)
- [fix-spec] HandleInstallSnapshotRequest: replaced `log' = <<>>` (discard entire log) with prefix-only truncation matching implementation's `readSnapshot()` (RaftConsensus.cc:2697-2714). Keeps log suffix when snapshot only covers a prefix. (Case B)

## Bug Hunting
- [fix-spec] AdvanceCommitIndex: added `leaderDiskPending` to UNCHANGED in step-down branch. Missing variable assignment caused TLC error. (spec error)
- [fix-inv] StepDownCorrectness: relaxed to check `currentEpoch - 1` instead of `currentEpoch`. StepDownCheck increments epoch before checking; peers need one round to respond. (Case A)

## Result
Converged in 1 round. Simulation: 191M states, 1.48M traces, 10 min — no violations.
Bug hunting: 0 bugs found across 5 hunting configs (318M total states, 3.7M traces, 10 min each).
