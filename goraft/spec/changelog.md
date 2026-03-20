# Changelog: goraft/raft Spec Validation

## Round 1 - Trace Validation
- [fix] TraceInit: Compute initial state for ALL servers from trace data, not just first event's node. Handles non-empty bootstrap logs (leader_election trace has 1 entry at term 1 per server).
- [fix] TraceClientRequest/TraceAppendNOP: Inlined to accept commitIndex from trace (models auto-commit at server.go:920-924 when len(peers)==0 and invisible AE response processing).
- [fix] TraceHandleAppendEntriesRequest: Inlined to accept commitIndex from trace. Added log-length guard and Min for committed' safety.
- [fix] TraceAdvanceCommitIndex: Inlined to accept commitIndex from trace (dynamic membership quorum differs from spec's fixed-server quorum).
- [fix] TraceSendHeartbeat: Inlined with currentTerm (not heartbeatTerm) for bootstrap leader support; uses Max(nextIndex-1, follower log length) as prevLogIndex to prevent stale truncation.
- [fix] SilentReplicate/SilentSendHeartbeat: Added no-duplicate-message guard to prevent state space explosion.
- [fix] Removed SilentAdvanceCommitIndex and SilentAppendNOP from TraceNext (unnecessary with inlined ci handling).
- [fix] TraceNext: Added l <= Len(TraceLog) guard for out-of-bounds protection.
- Validated: basic_consensus (75 states), leader_election (81 states), leader_failover (109 states)

## Round 1 - Model Checking
- [fix-spec] Timeout: Clear votesGranted when Follower becomes Candidate (Case B — server.go:729 candidateLoop creates fresh vote tracking; spec kept stale votes from previous elections)
- [fix-spec] HandleAppendEntriesRequest: Conflict-aware log truncation — only truncate when AE entries conflict with existing log entries; preserve existing entries when all new entries already match (Raft paper Section 5.3; implementation at log.go:409-467 checks conflicts before truncating)

## Round 2 - Trace Validation (regression check)
- All 3 traces pass after spec changes (no regressions)

## Round 2 - Model Checking
- 461M states BFS (no violations), 512M states simulation (1.9M traces, no violations)
- All 5 invariants pass: TypeOK, ElectionSafety, LogMatching, CommitIndexBound, CounterBound

## Result
Converged in 2 rounds. Proceeding to bug hunting.
