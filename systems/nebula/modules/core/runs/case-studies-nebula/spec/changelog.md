# Spec Validation Changelog: nebula Raft

## Round 1 - Trace Validation
- [fix] SilentHandlePreVoteRequest: Added silent action — pre-vote request handling is not instrumented. Fires before SendRequestVote to build pre-vote quorum. (Trace: all)
- [fix] SilentHandlePreVoteResponse: Added silent action — pre-vote response handling is not instrumented. Fires before SendRequestVote to accumulate pre-vote grants. (Trace: all)
- [fix] SilentHandleRequestVoteResponse: Added silent action — formal vote response handling is not instrumented. Fires when candidate needs to become Leader. (Trace: all)
- [fix] SilentBecomeLeader: Added silent action — BecomeLeader trace event arrives AFTER the server already acts as Leader (async trace emission). Fires when next event expects Leader. (Trace: all)
- [fix] TraceBecomeLeader: Made idempotent — accepts role=Leader (already became leader via SilentBecomeLeader) with just a term validation and UNCHANGED vars. (Trace: all)
- [fix] TraceHandleAppendEntriesResponse: Trace event has no msg.from field. Replaced individual message matching with batch-processing ALL pending AE responses at once (matching implementation's processAppendLogResponses which commits after quorum). Sets commitIndex directly from trace. (Trace: all)
- [fix] TraceHandleHeartbeatResponse: Trace event has no msg.from field. Batch-consumes ALL pending HB responses to prevent message bag accumulation. (Trace: all)
- [fix] HandleAppendEntriesResponse/HandleHeartbeatResponse: Removed msg.from matching since trace events don't include msg field. (Trace: all)
- [fix] SilentSendRequestVote: Added guard votesGranted[i] = {} to prevent re-firing after formal votes already sent. (Trace: basic_consensus)
- [fix] SilentSendPreVote: Added guard preVotesGranted[i] = {} to prevent re-firing. (Trace: basic_consensus)
- [fix] SilentClientRequest: Added guard logline.event.name /= "ClientRequest" to prevent double-counting explicit requests. (Trace: basic_consensus)
- [fix] TraceDone: Added stuttering action when l > Len(TraceLog) to prevent false deadlocks. (Trace: all)
- [fix] TraceView: Added VIEW excluding message bag from state fingerprint for tractable trace validation. (Trace: all)

## Round 1 - Model Checking
- [fix-spec] HandleRequestVoteResponse: Added term match check (m.mterm = term[i]) before counting votes. Stale vote responses from previous election rounds were being counted for current-term elections. Implementation has this check at RaftPart.cpp:1345 (proposedTerm != term_). (Case B)
- [fix-spec] HandleHeartbeatRequest: Fixed role update to step down ALL roles to Follower (not just Leaders). Implementation at RaftPart.cpp:2043-2044 sets role_=FOLLOWER for all non-Learner roles. Candidates receiving heartbeats were staying Candidate with stale votesGranted. (Case B)
- MC simulation: 301M states, 837K traces, no violations (ElectionSafety, LogMatching, structural invariants all pass)

## Round 2 - Trace Validation
- All 3 traces pass (no regressions from Round 1 MC spec changes)

## Convergence
Converged in 2 rounds (1 trace validation + 1 model checking + 1 re-validation).
- Trace validation: 3/3 pass (basic_consensus, log_replication, leader_crash_reelection)
- Model checking: 301M states, 837K traces, 0 violations (simulation mode, depth 100)

## Bug Hunting
- [fix-inv] LeaderCompleteness: Weakened to check only highest-term leader (Case A)
- [bug] NB-1: NoStaleLeaseRead violated — stale leader lease without CheckQuorum (Family 2, Case C)
- [bug] NB-2: LeaderCompleteness violated — committed entries lost via crash/prevote/heartbeat interaction (Family 3+4, Case C)
- [bug] NB-3: NoStaleLeaseRead violated — pre-vote step-down enables lease violation (Family 5, Case C)

## Result
Converged in 2 rounds. Bug hunting: 3 bugs found (NB-1 Critical, NB-2 Critical, NB-3 High).

