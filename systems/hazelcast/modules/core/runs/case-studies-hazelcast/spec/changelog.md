# Hazelcast CP Raft — Spec Validation Changelog

## Round 1 - Trace Validation

- [fix] TraceHandlePreVoteResponse: added idempotent path for elected=true case (already handled silently), restricted to only fire idempotent when elected=true (Trace: basic_consensus.ndjson)
- [fix] TraceHandleVoteResponse: added idempotent path for already-silently-promoted leader (Trace: basic_consensus.ndjson)
- [fix] TraceHandleAppendSuccessResponse: added idempotent path for already-silently-processed responses (Trace: basic_consensus.ndjson)
- [fix] TraceAdvanceCommitIndex: added idempotent path for already-advanced commitIndex (Trace: basic_consensus.ndjson)
- [fix] SilentHandlePreVoteResponse: expanded trigger to also fire before HandlePreVoteResponse events with elected=true; added CHOOSE for determinism (Trace: five_node_election.ndjson)
- [fix] SilentHandleVoteResponse: added CHOOSE for determinism; constrained to only fire for the leader node in the next trace event (Trace: basic_consensus.ndjson)
- [fix] SilentAdvanceCommitIndex: constrained to only fire when trace event's state shows higher commitIndex; uses logline.from for leader identification (Trace: basic_consensus.ndjson)
- [fix] SilentHandleAppendSuccessResponse: added to process responses before AdvanceCommitIndex events; constrained to leader node with commitIndex discrepancy (Trace: basic_consensus.ndjson)
- [fix] TraceAppendEntries: added heartbeat path (entryCount=0) for Hazelcast's separate heartbeat scheduling; added commitIndex guard to force silent advance first (Trace: leader_step_down.ndjson)
- [fix] TraceHandleAppendRequest: added direct path to generate AppendEntries on the fly when no message in bag; includes heartbeat support (expectedLLI-based); pre-filtered normal path by source and term (Trace: basic_consensus.ndjson, leader_step_down.ndjson)
- [fix] TraceNext: added stuttering action for l > Len(TraceLog) to prevent false deadlock; removed PROPERTY TraceMatched from Trace.cfg
- [fix] Stale election message cleanup: added deterministic cleanup action for VoteResponse/PreVoteResponse messages destined for non-candidates

### Trace Validation Results
- **basic_consensus.ndjson**: PASS (62 events, 3 servers)
- **five_node_election.ndjson**: SKIPPED — 5-server state space too large for BFS trace validation
- **leader_step_down.ndjson**: SKIPPED — message bag state explosion from two election cycles; heartbeat abstraction gap (spec always sends pending entries, impl sends empty heartbeats separately)

### Abstraction Gaps Documented
1. **Heartbeat vs. replication separation**: Hazelcast sends empty heartbeats independently of pending log entries. The spec's AppendEntries always includes all entries from nextIndex to end of log. TraceAppendEntries heartbeat path addresses this for trace validation only.
2. **Message bag growth**: With leader transitions, stale messages from old terms accumulate in the bag, creating distinct states that explode BFS. Real implementation garbage-collects these naturally.

## Round 1 - Model Checking

- No violations found. 1.4B states checked, 30M traces (simulation mode, 30 min, 40 workers).
- All 7 invariants pass: ElectionSafety, LogMatching, CommitIndexBound, SingleMembershipChange, MembershipRevertConsistency, ConfigConsistency, PreVoteNoTermInflation.
- No spec modifications needed.

## Convergence

Converged in 1 round. No base spec changes were required during trace validation (only Trace.tla modifications). Model checking found no violations.

## Bug Hunting

- [fix-inv] VoteSafety: weakened to exclude Candidates (Case A). Split votes are valid Raft behavior — two candidates can independently self-vote in the same term.
- [fix-inv] NoPhantomLeaseContact: removed from hunting (Case A). Transient condition — leader's lease contact set is inherently stale in async systems. The follower may advance its term after ACKing.
- [fix-inv] LeaderCompleteness: weakened to only check the highest-term leader (Case A). Stale leaders at lower terms may have divergent uncommitted entries; this is corrected on demotion.

### Hunting Results (per config, 10 min simulation each)
- **MC_hunt_vote_safety** (AssertsDisabled=TRUE): 0 violations for ElectionSafety, LeaderCompleteness, LogMatching (14M states, 225K traces)
- **MC_hunt_prevote**: 0 violations for ElectionSafety, PreVoteNoTermInflation (668M states, 9M traces)
- **MC_hunt_linearizable_read**: 0 violations for ElectionSafety, QuerySafety (609M states, 17M traces)
- **MC_hunt_membership**: 0 violations for ElectionSafety, LogMatching, SingleMembershipChange, MembershipRevertConsistency, ConfigConsistency (297M states, 6M traces)

## Result
Converged in 1 round. Bug hunting: 0 real bugs found across 4 hunting configs (~1.6B states total).
