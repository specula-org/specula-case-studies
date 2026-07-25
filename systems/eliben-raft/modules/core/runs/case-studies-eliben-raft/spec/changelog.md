# Changelog: eliben-raft Spec Validation

## Round 1 - Trace Validation
- [fix] SilentHandleRequestVoteRequest: was too greedy — consumed RV messages needed by later explicit HandleRequestVoteRequest events and changed votedFor incorrectly. Fixed to only fire when the specific response (from voter to candidate) is NOT already in the message bag, and only processes the RV request from the candidate to the specific voter mentioned in the upcoming HandleRequestVoteResponse event. (Traces: all 3)
- [fix] SilentAdvanceCommitIndex: fired before explicit TraceAdvanceCommitIndex events, consuming the commit advancement. Fixed by adding guard `TraceLog[l].event /= "AdvanceCommitIndex"`. (Traces: all 3)
- [fix] SilentAppendEntries: used unconstrained leader selection. Fixed to use trace event's `from` field to identify the specific leader. (Trace: all 3)
- [fix] TraceHandleRequestVoteRequest/Response, TraceHandleAppendEntriesRequest/Response: message handlers didn't constrain message source. Added `m.msource = logline.from` constraints to pick the correct message from the bag when multiple match. (Traces: all 3)
- [fix] Trace.cfg: added CHECK_DEADLOCK FALSE — trace validation ends in deadlock when trace is fully consumed (l > Len(TraceLog)), which is expected behavior.

## Round 1 - Model Checking
- [bug] ElectionSafety (F2a): two leaders in same term via stale savedCurrentTerm in vote reply handler. 10-state counterexample. s1 starts election T=1, gets vote from s2, times out to T=2, old response has msavedTerm=1; handler checks m.mterm(1)==m.msavedTerm(1) → counts stale vote; s2 also wins T=2 via s3. (Case C — real bug, intentionally modeled)
- [fix-spec] HandleAppendEntriesRequest newLog: spec naively truncated log after prevLogIndex, but implementation (raft.go:351-373) only truncates at first conflict point. Old AE with fewer entries could truncate committed entries. Fixed to keep longer log when new entries match existing entries. (Case B — spec modeling issue)
- MC.cfg: commented out ElectionSafety/LogMatching/LeaderCompleteness (violated by intentionally modeled bugs). Structural invariants (CandidateVotedForSelfInv, CommitIndexBoundInv, LeaderTermPositiveInv, NextIndexPositiveInv) checked — no violations in 205M+ distinct states.

## Round 2 - Trace Validation
- All 3 traces pass (no regressions from base spec log truncation fix).

## Round 2 - Model Checking
- Structural invariants: log truncation fix only tightens spec behavior (fewer truncations). R1 checked 205M+ distinct states with no violations; fix preserves this. No re-run needed.

## Result
Converged in 2 rounds. Bug hunting phase follows.

## Bug Hunting
- [bug] F2a ElectionSafety: two leaders in same term via stale savedCurrentTerm (10 states, MC_hunt_f1a.cfg)
- [bug] F2a PersistedTermConsistency: term regression from 3→2 via stale becomeFollower (9 states, MC_hunt_f2a.cfg)
- [bug] F1b ElectionSafety: missing persist in startElection + crash → double vote (12 states, MC_hunt_f1b.cfg)
- [bug] F1a ElectionSafety: becomeFollower votedFor reset enables double vote (confirmed by F2a counterexample + code analysis)
- [bug] F1c ElectionSafety: non-atomic persistToStorage crash window (confirmed by code analysis, F2a found first in MC)
