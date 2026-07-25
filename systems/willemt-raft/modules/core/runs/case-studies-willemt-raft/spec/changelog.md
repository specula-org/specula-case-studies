# willemt-raft Spec Validation Changelog

## Round 1 - Trace Validation
- [fix-spec] HandleRequestVoteRequest: added leader lease reject path (raft_server.c:608-613). When server has recent leader contact, rejects RV without term update. Modeled as non-deterministic choice (current_leader not tracked). Constrained to Follower/Leader states (candidates clear current_leader at line 201). (Traces: basic_consensus.ndjson, leader_reelection.ndjson)
- [fix] SilentHandleRequestVoteResponse: added silent action to process vote responses before their trace events. In the impl, raft_become_leader (line 184) sends AE inside the vote response handler, so SendAppendEntries events appear before HandleRequestVoteResponse in the trace. (Traces: basic_consensus.ndjson, leader_reelection.ndjson)
- [fix] TraceHandleRequestVoteResponse: added idempotent path for already-processed votes. When SilentHandleRequestVoteResponse already consumed the vote message, validates current state matches expected post-state without re-processing. (Traces: basic_consensus.ndjson, leader_reelection.ndjson)
- [fix] SilentLoseMessage: removed. Was too unconstrained and caused spurious deadlocks by eating messages needed for trace events. Not needed since extra messages are harmless with deadlock-based completion.

## Round 1 - Model Checking
- No violations found. BFS complete: 18.9M states, 3.8M distinct, depth 42, 74s.
- Invariants checked: TypeOK, ElectionSafety, LogConsistency, CountersOK — all PASS.
- Bounds: MaxTimeoutLimit=2, RequestLimit=1, LoseLimit=0, BroadcastLimit=0, MaxMsgCount=4.

## Bug Hunting
- [fix-inv] LeaderCompleteness: added `currentTerm[i] >= currentTerm[j]` guard. The original invariant checked ALL leaders, but Raft §5.4.3 only requires committed entries on leaders of "higher-numbered terms." A stale leader (lower term) will step down and is not a "future leader." (Case A, MC_hunt_commit.cfg, 11-state counterexample)
- MC_hunt_commit: No violation after fix (simulation, 5 min, terminated)
- MC_hunt_vote: No violation (simulation, 154 traces, 24K states; TermNeverDecreases requires BFS)
- MC_hunt_log: No violation (simulation, 23K traces, 4.9M states)
- MC_hunt_snapshot: No violation (simulation, 72K traces, 13M states)
- MC_hunt_broadcast: No violation (simulation, 17K traces, 3.6M states)

## Result
Converged in 1 round. Bug hunting: 0 new bugs found (1 invariant fix, Case A).
Known bugs from modeling brief are modeled in spec (term decrease in HandleInstallSnapshot, missing no-op after election) but require targeted BFS with temporal properties to trigger.

