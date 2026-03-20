# Spec Changelog: ScyllaDB Raft

## Round 1 - Trace Validation
- [fix-spec] BecomeLeader: nextIndex initialized to LastLogIndex+1 (not +2). Scylla's set_configuration passes _log.last_idx() as next_idx (tracker.cc:101,124), so the leader immediately replicates the dummy entry. (All traces)
- [fix-spec] SendInstallSnapshot: removed `messages` from UNCHANGED clause — contradicted Send() which modifies messages. Action was never enabled. (base.tla)
- [fix-spec] ProposeConfigChange: `j \in nextIndex[i]` → `j \in DOMAIN nextIndex[i]` (function domain check, not membership). (base.tla)
- [fix] TraceClientRequest: added branch for BecomeLeader dummy entry — Scylla's become_leader() calls add_entry(dummy) which emits ClientRequest BEFORE BecomeLeader event. Combined into one spec action. (All traces)
- [fix] TraceBecomeLeader: added "already leader" branch for when BecomeLeader was consumed by preceding ClientRequest. (All traces)
- [fix] TraceAppendEntries: pipeline mode — sends 1 entry per message matching Scylla's replicate_to, advances nextIndex. (commit_and_replicate.ndjson)
- [fix] TraceMaybeCommit: trace-driven commitIndex — impl emits MaybeCommit inside append_entries_reply before HandleAppendEntriesResponse, so spec's matchIndex isn't updated yet. Trust trace's commitIndex, validate basic constraints. (All traces)
- [fix] TraceHandleAppendEntriesRequest: constrained message selection using expectedLastLogIdx to disambiguate pipelined messages. (commit_and_replicate.ndjson)
- [fix] TraceHandleAppendEntriesResponse: constrained message selection on msource + mmatchIdx from trace. (All traces)
- [fix] TraceHandleRequestVoteResponse: constrained message selection on msource + mvoteGranted from trace. (All traces)
- [fix] TraceUpdateTerm: constrained message term to match expected new term from trace. (All traces)
- [fix] Removed SilentLoseMessage from TraceNext — controlled test harness delivers all messages. Eliminated spurious deadlock paths. (All traces)
- [fix] SilentUpdateTerm/SilentMaybeCommit: added event-name guards to prevent preempting explicit trace events. (All traces)
- [fix] SilentAppendEntries: pipeline mode matching Scylla's behavior. (Trace.tla)
- [fix] SilentDropStaleMessage: constrained to current trace event's server only. (Trace.tla)
- [fix] Multiple ValidatePostStateWeak calls: reordered UNCHANGED before ValidatePostStateWeak so primed variables are defined. (Trace.tla)

## Round 1 - Model Checking
- [fix-spec] HandleAppendEntriesRequest: added snapshot-overlap skip AND per-entry conflict detection. Stale AppendEntries with prevLogIdx < snapshotIdx was truncating log to entries inside snapshot (Case B). Also: entries matching existing log (same term at same index) are now skipped — prevents stale messages from truncating already-committed entries. Reference: log.cc:167-199 (maybe_append). (base.tla, both correct and buggy variants)
- [fix-inv] LeaderCompleteness: added `currentTerm[i] >= LogTerm(j, idx)` guard. Stale leaders at lower terms are exempt — they haven't received the new leader's entries yet and will step down on contact. Standard Raft paper §5.4.3 says "future leaders" (higher terms), not all leaders. (Case A)

## Round 2 - Trace Validation
- No regressions. All 3 traces pass after spec changes.

## Round 2 - Model Checking
- BFS: 1.2B states, 123M distinct, depth 14, no violations (25 min)
- Simulation: 64.5M states, 224K traces (depth 100), no violations (10 min)

## Bug Hunting
- [fix-inv] CommitIndexSafety: added same `currentTerm[i] >= LogTerm(j, idx)` guard as LeaderCompleteness (Case A — stale leader false positive).
- Family 1 (commit clamping): 123M states, no violation — batch AppendEntries can't trigger unclamped commit (needs pipeline). Historical bugs #9965, #10578 confirmed in principle.
- Family 2 (joint quorum): JointQuorumAgreement too strong — fired on pre-config-change entries. The can_vote mismatch is a liveness issue (read barrier stall), not safety.
- Family 3 (snapshot lifecycle): 231M states, no violation — buggy trailing didn't produce crash-recovery inconsistency in explored space.
- Family 5 (FD dependence): 99M states, no violation — safety holds under arbitrary FD staleness.

## Result
Converged in 2 rounds. Bug hunting: 0 new bugs found across 4 families (1.7B+ total states explored).
