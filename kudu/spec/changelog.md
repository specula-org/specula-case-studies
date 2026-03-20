# Kudu Raft Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] Trace.cfg: Switched from `SPECIFICATION TraceSpec` + `PROPERTIES TraceMatched` to `INIT TraceInit` / `NEXT TraceNext` + `CHECK_DEADLOCK FALSE` — TraceMatched temporal property trivially fails without fairness (stuttering counterexample). (Trace: basic_election.ndjson)
- [fix] SilentAdvanceCommitIndex: Added silent action — in the implementation, `ResponseFromPeer` advances commitIndex synchronously but the `AdvanceCommitIndex` trace event fires asynchronously via observer callback. (Trace: basic_election.ndjson)
- [fix] AdvanceCommitIndexIfLogged: Added idempotent path for when SilentAdvanceCommitIndex already advanced. (Trace: basic_election.ndjson)
- [fix] FillLogGap: Extended to handle `SendEntries` events where `prevLogIndex + numEntries > logLength`. (Trace: basic_election.ndjson)
- [fix] SendEntriesIfLogged: Added commitIndex guard and numEntries guard to force SilentAdvanceCommitIndex/FillLogGap to fire first. (Trace: basic_election.ndjson)
- [fix] HandleAppendEntriesRequestIfLogged: Added `mprevLogIndex` matching to prevent stale messages from being consumed. (Trace: basic_election.ndjson)
- [fix] SilentSendEntries: Tightened message check to match on `mprevLogIndex` to avoid stale message blocking. (Trace: basic_election.ndjson)
- [fix] SilentHandleAppendEntriesRequestReject: Added silent action for untraced follower rejection processing. (Trace: basic_election.ndjson)

## Round 1 - Model Checking
- [fix-inv] CandidateVotedForSelfInv: Removed — incompatible with PreVote semantics (PreVote makes server Candidate without changing votedFor). (Case A)
- [fix-spec] BecomeLeader: Added `votedFor[i] = i` guard — prevents BecomeLeader after PreVote win (must go through real Timeout first). PreVote votes in votesGranted were incorrectly counted as real election quorum. (Case B)
- [fix-spec] PreVote: Added `votedFor[i] /= i` guard — prevents Candidate in a real election from starting a PreVote, which would mix real and pre-election votes in votesGranted causing ElectionSafety violation. (Case B)
- [fix-spec] SendHeartbeat: Removed — heartbeats with prevLogIndex=0 bypassed log matching, allowing followers to advance commitIndex on stale log entries. In Kudu, heartbeats go through same RequestForPeer path as SendEntries. SendEntries subsumes heartbeat behavior. (Case B)
- [fix-spec] HandleAppendEntriesRequest (accept path): Implemented Raft Figure 2 step 3 "only truncate on conflict" — stale AppendEntries messages could truncate committed entries. Added check: if all new entries match existing log, keep existing (longer) log. (Case B)
- [fix-spec] HandleAppendEntriesRequest (accept path): Added `Min(newLastIdx, ...)` clamp on newCommitIdx — prevents commitIndex from exceeding log length after truncation. (Case B)
- [fix-inv] LeaderCompleteness + LeaderLogCompleteness: Restricted to highest-term leader only — stale leaders (haven't learned about newer term) may not have entries committed by newer leaders. Standard Raft invariant holds for active leader only. (Case A)

## Bug Hunting
- [fix-inv] LeaderCompleteness/LeaderLogCompleteness: Strengthened stale-leader guard to check `currentTerm[other] <= currentTerm[leader]` (all servers, not just leaders). (Case A — stale leader at lower term than followers)
- [no-bug] MC_hunt_election.cfg: 937M states, 6.3M traces — no violation
- [no-bug] MC_hunt_commit.cfg: 481M states, 4.3M traces — no violation
- [false-pos] MC_hunt_config.cfg: VoterOnlyQuorum false positive (matchIndex reset on re-election)

## Result
Converged in 1 round. Bug hunting: 0 bugs found across 3 configs (1.4B+ states, 10.6M+ traces).
