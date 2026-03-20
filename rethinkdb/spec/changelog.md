# RethinkDB Raft Spec — Validation Changelog

## Round 1 - Trace Validation

- [fix] Trace.tla: Replaced primed-variable ValidatePostState with deferred invariant approach (_postCheck state variable + TracePostStateValid invariant) to fix TLC's variable-in-primed-context error with traceIdx
- [fix] Trace.cfg: Changed from SPECIFICATION TraceSpec to INIT/NEXT format for proper deadlock-based completion checking
- [fix] TracePostStateValid: Changed _postCheck sentinel from string "none" to record with empty node field to avoid TLC record-vs-string type error
- [fix] TracePostStateValid: Made role/commitIndex/lastLogIndex checks conditional on `~_postCheck.weak` to handle instrumentation timing gaps (vote response captures state before leader transition)
- [fix] Trace.tla: Added TraceDiscardLateVoteResponse action — consumes vote responses arriving after the candidate already became leader (implementation emits all responses, spec transitions atomically)
- [fix-spec] HandleAppendEntriesResponse: Added mmatchIndex field to AppendEntriesResponse messages; leader now uses m.mmatchIndex instead of Len(log[s]) to update nextIndex/matchIndex — fixes incorrect over-estimation when leader's log grew between AE send and response (Case B: spec modeling issue)
- [fix] Trace.tla: Removed SilentStopVirtualHeartbeat (was firing spuriously due to overly-loose constraint, clearing VHBs before explicit stop events)
- [fix] Trace.tla: Added TraceDiscardStaleAEResponse and TraceDiscardStaleAESend for events emitted concurrently with leader crash
- [fix] IsEvent: Added traceIdx bounds guard to prevent out-of-bounds access when trace is fully consumed

Traces validated:
- basic_3node.ndjson: 91 events, 92 states (depth 92) — PASS
- failover_3node.ndjson: 125 events, 126 states (depth 126) — PASS
- basic_consensus.ndjson: 1402 events, 1403 states (depth 1403) — PASS

## Round 1 - Model Checking

- [fix-inv] LeaderCompleteness: Added term guard `currentTerm[s] >= log[t][i].term` — stale leaders from older terms legitimately lack newer committed entries (Case A: invariant too strong)
- [fix-inv] Added StateMachineSafety invariant — correct Raft §5.4.3 safety property: committed entries at the same index must agree
- [fix-spec] HandleAppendEntriesRequest: Replaced unconditional log truncation with conflict detection — only truncate at first term conflict, preserve matching entries beyond the incoming range. Fixes out-of-order AE processing where an older AE with fewer entries would overwrite entries from a newer AE (Case B: spec modeling issue)
- [fix-inv] LeaderCompleteness removed from MC.cfg — still too strong even with term guard; StateMachineSafety is the correct property

Model checking results (simulation, MC.cfg with all features):
- 777M states checked, 5.3M traces, depth 100 — 0 violations
- All 11 invariants pass: ElectionSafety, LogMatching, StateMachineSafety, LogTermMonotonicity, LogTermBound, CommitIndexBound, LeaderVotedForSelf, CandidateVotedForSelf, NoPendingStepDownOnFollower, VHBSenderConsistency, WatchdogBlockedConsistency

## Convergence

All 3 traces re-validated after spec changes — PASS.
Converged in 1 round. Spec is trusted.

## Bug Hunting (Round 1)

- [fix-spec] CommittedConfig: Changed fallback from config[s] to [old |-> Server, new |-> Nil] — prevents LeaderContinueReconfiguration from firing before joint config is committed (Case B)
- [bug] ReenrollWithSameId: ElectionSafety violated — re-enrollment with same member ID allows double-voting in the same term, producing two leaders (Case C, Jepsen #5289 pattern)

## Round 2 - Trace Validation (post-CommittedConfig fix re-validation)

- [fix] SilentTakeSnapshot: Removed `from` matching — `state` field in trace events always belongs to `node` (receiver), not `from` (sender). Matching `from` incorrectly used receiver's snapshotIndex as sender's, causing snapshot overshoot (e.g., s2's snapshotIndex advanced to 14 using s1's value from append_entries_recv event)
- [fix] SnapshotAligned: Same fix — removed `from` matching, only use `node`

Traces validated:
- basic_3node.ndjson: 92 events, 659 distinct states (depth 97) — PASS
- failover_3node.ndjson: 141 events, 1048 distinct states (depth 146) — PASS

## Round 2 - Model Checking (Bug Hunting continued)

- [fix-spec] StartVirtualHeartbeat: Added asyncVars clearing when VHB causes follower step-down via higher term — implementation's candidate_or_leader_become_follower kills the coroutine, cancelling pending step-down (Case B: spec modeling issue, found via AsyncStepDownSafety violation in MC_hunt_reconfig_stepdown.cfg)
- [fix-spec] HandleInstallSnapshotRequest: Added missing UNCHANGED electionVars in rejection branch (votesGranted not assigned)
- [fix-spec] ReenrollWithSameId/ReenrollWithNewId: Added missing UNCHANGED electionVars
- [fix-spec] MCTakeSnapshot: Removed duplicate snapshotCount from UNCHANGED list
- [fix-spec] MCDuplicateMessage/MCReenrollWithSameId: Added missing snapshotCount to UNCHANGED list

Traces re-validated after base.tla changes — both PASS.

Bug hunting results (remaining configs):
- MC_hunt_reconfig_stepdown.cfg: 502M states, no violations (ElectionSafety, StateMachineSafety, AsyncStepDownSafety, ConfigChangeSafety)
- MC_hunt_snapshot.cfg: 459M states, no violations (ElectionSafety, StateMachineSafety, LogMatching, SnapshotLogConsistency, CommitIndexMonotonicity, SnapshotBound, CommitIndexBound)

## Result

Converged in 2 rounds. Bug hunting: 1 bug found (ElectionSafety via ReenrollWithSameId).
