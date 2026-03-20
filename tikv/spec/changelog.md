# tikv/raft-rs Spec Validation Changelog

## Round 1 - Trace Validation
- [fix-spec] BecomeLeader: nextIndex for followers set to `Len(log[i])+1` (pre-noop), not `Len(newLog)+1`. reset() runs before append_entry; only leader's nextIndex is updated after noop. (raft.rs:1034,1051-1059)
- [fix-spec] BecomeLeader: pendingConfIndex set to `Len(log[i])` (pre-noop), matching raft.rs:1267
- [fix-spec] HandleRequestPreVoteResponse winning path: changed SendAll → DiscardAndSendAll to consume processed PreVoteResponse message
- [fix-spec] HandleRequestVoteResponse winning path: changed SendAll → DiscardAndSendAll to consume processed VoteResponse message
- [fix-spec] HandleAppendEntriesResponse accepted path: use `Max(matchIndex, m.mindex)` for matchIndex and nextIndex to match raft.rs:1828 maybe_update (only advance, never decrease)
- [fix-trace] Moved HandleAppendEntriesResponse trace event emission to BEFORE maybe_commit() in patch_raft.py. This ensures trace order is HandleAppendEntriesResponse → AdvanceCommitIndex, matching spec atomicity. (raft.rs:1845-1855)
- [fix-trace] Added SilentSendAppendEntries for bcast_append AE messages after commit advance
- [fix-trace] Added SilentDropStaleMessage for zombie vote/prevote responses and committed AE responses
- [fix-trace] Added highest-mindex guard on TraceHandleAppendEntriesResponse to skip stale orphaned responses
- [fix-trace] SilentPersistEntries guard: don't fire when next event IS PersistEntries for same node
- [fix-trace] SilentAdvanceCommitIndex guard: don't fire when next event IS AdvanceCommitIndex
- [fix-trace] Removed SilentBecomeLeader (caused premature state transition at HandleRequestVoteResponse)
- [fix-trace] Removed TraceBecomeLeader (BecomeLeader event removed from instrumentation)

Validated traces: basic_consensus (45 states), prevote_election (28 states), leader_transfer (43 states)

## Round 1 - Model Checking
- [fix-spec] MCBecomeLeader: added UNCHANGED <<votesGranted, preVotesGranted, messages>> (BecomeLeader called standalone doesn't set these — caller handles them)
- [fix-spec] BecomeLeader: added `HasQuorum(i, votesGranted[i])` guard. Without it, any Candidate can become Leader without winning election, violating ElectionSafety. (Case B — spec more permissive than implementation)

MC results (ongoing BFS, ConfChangeLimit=0): 1.04B+ states generated, 143M distinct, depth 19.
All 7 invariants pass: ElectionSafety, LogMatching, LeaderCompleteness, CommitIndexBoundInv, PersistedBoundInv, SinglePendingConfInv, VotedForConsistencyInv.

## Result
Converged in 1 round. Round 1 trace validation fixes modified base spec; Round 1 model checking fixes also modified base spec (quorum guard on BecomeLeader). Traces re-verified after MC fixes — all 3 pass. MC running clean at 1B+ states. Proceeding to bug hunting.
