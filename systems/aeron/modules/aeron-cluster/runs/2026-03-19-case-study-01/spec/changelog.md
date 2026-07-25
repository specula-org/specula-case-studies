# Aeron Cluster Spec Changelog

## Round 1 - Trace Validation
- [fix] SilentLoseMessage/SilentDropStaleMessage: removed from TraceNext — unconstrained silent message removal created spurious deadlocks by draining messages needed for future trace events (Trace: basic_election.ndjson)
- [fix] TraceHandleNewLeadershipTerm: switched to ValidatePostStateNoElection — harness captures pre-transition electionState (FOLLOWER_BALLOT instead of FOLLOWER_REPLAY/ES_Follower) (Trace: basic_election.ndjson)
- [fix] TraceElectionReceiveCommitPosition: added FollowerReceiveCommitPosition fallback — implementation dispatches commit positions through Election.onCommitPosition even during FOLLOWER_REPLAY (mapped to ES_Follower in spec) (Trace: election_commit_position.ndjson)
- [fix] SilentPublishCommitPosition: uses trace's mcommitPosition when available — bridges gaps where leader's commitPosition advanced through untraced intermediate events (Trace: election_commit_position.ndjson)

## Round 1 - Model Checking
- No violations found. 1.34B states generated, 263M distinct, BFS depth 18, 15 min, 48 workers. All 7 structural invariants pass (ElectionSafety, LogMatching, TruncationSafety, CommitBound, TermConsistency, VoteRecovery, NotifiedCommitBound).

## Convergence
Converged in 1 round. No base spec modifications needed — only Trace.tla adjustments for harness capture timing and gap-bridging.

## Bug Hunting
- [fix-inv] VoteUniqueness: weakened to exclude self-votes — two candidates CAN both self-vote at the same candidateTermId (independent term increment from same base). Fixed to check external voter grants only. (Case A, MC_hunt_election.cfg, MC_hunt_crash.cfg)
- [fix-inv] CommitBoundedByQuorum: added memberActive[i] guard — leader becoming inactive after valid commit should not retroactively invalidate commit. (Case A, MC_hunt_quorum.cfg)
- [bug] CommitBoundedByQuorum: stale canvass message overwrites leader's tracked member position causing quorum regression below commitPosition. updateMemberLogPosition() unconditionally overwrites without max-check. (Case C, MC_hunt_commit.cfg, MC_hunt_quorum.cfg, 15-state counterexample)

## Result
Converged in 1 round. Bug hunting: 1 bug found (quorum position regression from stale canvass).
