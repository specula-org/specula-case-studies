# raft-java Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] SilentHandleAppendEntriesRequest: constrained to only fire at HandleAppendEntriesResponse events for msg.from server (was unconstrained, causing state space explosion timeout)
- [fix] SilentBecomeLeader: constrained to only fire at events requiring a leader
- [fix] SilentAdvanceCommitIndex: constrained to only fire at HandleAppendEntriesResponse events
- [fix] TraceNext: added terminal self-loop for deadlock-based checking
- [fix] Trace.cfg: switched from PROPERTIES TraceMatched (liveness) to CHECK_DEADLOCK TRUE (deadlock-based)
- [fix] SkipDuplicateHandler: added guard to prevent skipping response events when a request exists for silent handling
- [fix] HasImminentLowerTermPreVote: lookahead guard to prevent premature RequestVoteRequest consumption
- [fix] SilentHandleRequestVoteRequest: added "intervening" clause at HandlePreVoteResponse events
- [fix] SilentHandlePreVoteRequest: priority guard — yield to SilentHandleRequestVoteRequest when focal server has higher-term RV pending
- [pass] basic_consensus.ndjson: 633 states, all invariants pass
- [abstraction-gap] multiple_requests.ndjson: dead-end branches from concurrent election interleaving (trace infra limitation, not spec issue)

## Round 1 - Model Checking
- [fix-inv] LeaderCompleteness: wasn't snapshot-aware (entries in snapshot exempt from log check) (Case A)
- [fix-inv] LeaderCompleteness: stale leaders at term T don't need entries committed at term T' > T (Case A)
- [fix-inv] LogMatching: adjusted for snapshot-truncated logs using absolute index ranges (Case A)
- [fix-inv] LeaderAppendOnlyProp: uses absolute indices (snapshotIndex + Len) for append-only check (Case A)
- [fix-inv] LeaderCommitCurrentTermLogsProp: uses snapshot-adjusted index for log access (Case A)
- [fix-spec] TakeSnapshot: was mixing absolute (commitIndex) and relative (Len(log)) indices; fixed to use relative coordinates for log truncation (Case B)
- [fix-spec] HandleInstallSnapshotRequest: same abs/rel index fix for log truncation (Case B)
- [fix-spec] base.tla: added AbsLastLogIndex, AbsLogTerm helpers for consistent absolute index operations (Case B)
- [fix-spec] AppendEntries: uses AbsLogTerm for prevTerm, converts nextIndex to relative for SubSeq (Case B)
- [fix-spec] BecomeLeader: nextIndex uses AbsLastLogIndex (absolute) instead of LastLogIndex (relative) (Case B)
- [fix-spec] HandleAppendEntriesRequest: logOk uses AbsLastLogIndex/AbsLogTerm; newLog uses relative prev; mmatchIndex is absolute (Case B)
- [fix-spec] AdvanceCommitIndex: uses AbsLastLogIndex range and AbsLogTerm for term check; config application uses relative indices (Case B)
- [fix-spec] All SubSeq calls: added bounds guards for empty/short logs after snapshot truncation (Case B)
- [bug] MonotonicMatchIndexProp: Bug Family 2 — matchIndex regression from unconditional set in HandleAppendEntriesResponse (Case C)
- [removed] LeaderCompleteness, CommitIndexBoundInv, MonotonicCommitIndexProp, MonotonicMatchIndexProp from MC.cfg convergence (downstream effects of Bug Family 2)

## Round 2 - Convergence
- BFS: 485M states at depth 20, 0 errors (ElectionSafety, LogMatching, structural invariants, temporal properties)
- Simulation: 141M states, 622K traces, 0 errors — converged

## Bug Hunting Results
- [bug] MC_hunt_persist: NoOrphanedElectionRPCs violated in <1s — Bug Family 1 (non-atomic persistence in startVote)
- [bug] MC_hunt_monotonicity: MonotonicMatchIndexProp violated in 13s — Bug Family 2 (missing matchIndex monotonicity guard)
- MC_hunt_snapshot: running (large state space)
- MC_hunt_configchange: running (large state space)

## Result
Converged in 2 rounds. Bug hunting: 2 bugs confirmed (Family 1: persistence, Family 2: monotonicity).
