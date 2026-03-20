# dotnext-raft Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] BecomeLeaderIfLogged: Removed quorum check — external vote responses are often untraced. Directly transition to Leader with no-op append. (Trace: basic_consensus.ndjson, leader_resignation.ndjson)
- [fix] AdvanceCommitIndexIfLogged: Removed quorum/matchIndex check — AE responses that establish quorum are often untraced. Directly set commitIndex from trace value. Allow idempotent (>=) for redundant commit events. (Trace: basic_consensus.ndjson)
- [fix] HandleRequestVoteIfLogged: Used ValidatePostStateRelaxedTerm (term >=) — trace captures result.Term before step-down (RaftCluster.cs:814), so post-state term may be stale. (Trace: leader_resignation.ndjson)
- [fix] HandleAppendEntriesIfLogged: Added mprevLogIndex matching from trace msg to disambiguate multiple AE messages in bag. Used ValidatePostStateRelaxedTerm for term tolerance. (Trace: basic_consensus.ndjson)
- [fix] AppendEntriesIfLogged: Added nextIndex guard (must match trace prevLogIndex+1) to force SilentSyncNextIndex to fire first. (Trace: basic_consensus.ndjson)
- [fix] FillLogGap: Enhanced to trigger from commitIndex (AdvanceCommitIndex events) and prevLogIndex+entriesCount (AppendEntries events), not just lastLogIndex. (Trace: basic_consensus.ndjson)
- [fix] Added SilentSyncNextIndex: Syncs leader's nextIndex to match trace's prevLogIndex before AppendEntries events. Bridges untraced AE response processing. (Trace: basic_consensus.ndjson)
- [fix] Added SilentSetFollowerLog: Copies entries from leader's log to follower before HandleAppendEntries events. Bridges untraced AE processing on followers. (Trace: basic_consensus.ndjson)
- [fix] Added SilentSyncFollowerTerm: Updates follower term to leader's term before HandleAppendEntries. (Trace: basic_consensus.ndjson)
- [fix] Added SilentSyncFollowerCommit: Updates follower commitIndex from trace before HandleAppendEntries. (Trace: basic_consensus.ndjson)

Validated traces: basic_consensus (125 states), leader_resignation (170 states)

## Round 1 - Model Checking
- [fix-spec] HandleAppendEntries: Added skipCommitted protection — stale AE messages with fewer entries than commitIndex must not truncate committed log entries. Matches dotNext `AppendAndCommitAsync(skipCommitted=true)` at RaftCluster.cs:636. (Case B)

MC stats: 786M states BFS (depth 21) + 90M simulation (130K traces) — all 6 invariants pass.

## Round 2 - Trace Validation (regression check)
No regressions. Both traces pass after the HandleAppendEntries fix.
- basic_consensus: 15286 states, depth 125
- leader_resignation: 87500 states, depth 170

## Round 2 - Model Checking
No violations. 205M simulation states (296K traces) — all 6 invariants pass.

## Bug Hunting
- MC_hunt_election: ElectionLiveness temporal — trivial failure (no fairness), not a bug (Case A)
- MC_hunt_config: MCConfigCommitConsistency — invariant too strong for sideband config model (Case A)
- MC_hunt_lease: 1.7B states, 1.5M traces — no violations
- MC_hunt_wal: 997M states, 2.1M traces — no violations

## Result
Converged in 2 rounds. Bug hunting: 0 real bugs found. 2 Case A (invariant/property too strong).
