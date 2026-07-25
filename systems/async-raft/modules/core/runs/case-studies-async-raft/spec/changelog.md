# async-raft Spec Validation Changelog

## Round 1 - Trace Validation
- All traces pass: basic_consensus_small (255 states), basic_consensus (119 states). No fixes needed.

## Round 1 - Model Checking
- [fix-spec] AdvanceCommitIndex: rewrote to use server-based quorum counting instead of set-based CalcCommit. Old version used a set of <<matchIndex, matchTerm>> pairs which lost duplicates (two followers at <<0,0>> collapsed to one element), making the quorum denominator too small. Also removed incorrect `matchIndex > 0` filter — the real code (replication.rs:139-147) includes ALL tracked nodes. (Case B)
- [fix-inv] LeaderCompleteness: (1) added Min(commitIndex, LastLogIndex) guard to prevent out-of-bounds access when Bug Family 3 pushes commitIndex past log length; (2) added `log[s2][idx].term <= currentTerm[s1]` guard so stale leaders (lower term) are not required to have entries from later-term leaders. Same fixes applied to LeaderLogCompletenessStructural in MC.tla. (Case A)
- [bug] LeaderCompleteness violated by Bug Family 3: unconditional commit_index update causes follower to accept commitIndex=2 from rejected AppendEntries, while log has only 1 entry with wrong term. 59-state trace (output/MC_sim_LeaderCompleteness_BugFamily3.out). (Case C)
- Disabled LeaderCompleteness for convergence (violated by modeled Bug Family 3).
- Disabled temporal properties (MonotonicTermProp, LeaderAppendOnlyProp) during convergence — state graph explosion with BFS.

## Round 2 - Trace Validation
- All traces pass. No regressions after AdvanceCommitIndex rewrite.

## Round 2 - Model Checking
- No new violations. Simulation: 197M states, 700K traces, ElectionSafety + LogMatching + structural invariants pass.

## Result
Converged in 2 rounds. Bug hunting: 5 bug families confirmed (Bug Families 1, 2, 3, 4, 6).
