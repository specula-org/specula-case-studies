# nuraft Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] SilentAdvanceCommitIndex: Enabled in TraceNext. In nuraft, AdvanceCommitIndex runs inside handle_append_entries_resp before sending the next AE, but trace emits AdvanceCommitIndex AFTER AppendEntries. Silent action fires between HandleAppendEntriesResponse and AppendEntries. (Trace: basic_consensus.ndjson)
- [fix] TraceAppendEntries: Added `commitIndex[i] >= logline.state.commitIndex` precondition to force SilentAdvanceCommitIndex first when trace shows advanced commitIndex. (Trace: basic_consensus.ndjson)
- [fix] TraceAdvanceCommitIndex: Added idempotent path for when commitIndex already advanced by SilentAdvanceCommitIndex. (Trace: basic_consensus.ndjson)

## Round 1 - Model Checking
- [fix-spec] HandleVoteRequest/HandleAppendEntries/HandleAppendEntriesResponse: Reset votesGranted and preVotesGranted when stepping down due to higher term. Matches update_term() in code (raft_server.cxx:1554-1585) which resets election state. Without this, stale votes from previous term enable BecomeLeader after step-down. (Case B, ElectionSafety violated)
- [fix-spec] HandleAppendEntries: Fixed log truncation to only truncate on conflict (different term at same index), per Raft §5.3. Previously blindly replaced log with `SubSeq \o entries`, causing incorrect truncation when stale AE with matching entries arrived. (Case B, PrecommitOrdering violated)
- [fix-inv] PrecommitOrdering: Weakened from `smCommitIndex <= precommitIndex <= LastLogIndex` to `smCommitIndex <= precommitIndex`. The `precommitIndex <= LastLogIndex` check is too strong — after conflict truncation, precommitIndex transiently exceeds log length because try_update_precommit_index (handle_append_entries.cxx:1146-1167) only advances via CAS. This is safe: no committed entries are truncated. (Case A)

## Round 1 - Convergence
Simulation: 1.08B states, 3.95M traces, 0 violations (ElectionSafety, LogMatching, PrecommitOrdering).

## Bug Hunting
- [bug] BypassConfigGuard (F3/MC-5): ConfigChangeAtomicity violated. set_priority() bypasses config_changing_ guard, enabling two concurrent uncommitted config changes. 22-state counterexample. (MC_hunt_F3.cfg)
- [bug] AdjustQuorum (F4/MC-1): ElectionSafety violated. Both nodes in 2-node cluster independently lower quorum to 1, both self-elect in same term. 18-state counterexample. Known risk (Issue #151). (MC_hunt_F4.cfg)
- [pass] F2 (Non-atomic persistence): VoteUniqueness holds. 199M states, 1.3M traces. (MC_hunt_F2.cfg)
- [pass] F5 (Stale responses): NoStaleMatchIndex holds. 193M states, 773K traces. (MC_hunt_F5.cfg)
- [pass] F7 (Leader completeness): LeaderCompleteness holds (with barrier). 224M states, 880K traces. (MC_hunt_F7.cfg)

## Result
Converged in 1 round. Bug hunting: 2 bugs found (F3 config guard bypass, F4 split-brain quorum).
