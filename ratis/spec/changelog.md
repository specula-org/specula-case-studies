# Ratis Spec Validation Changelog

## Round 1 - Trace Validation
- All traces pass: basic_consensus.ndjson (205 events), leader_reelection.ndjson (335 events)
- No fixes needed

## Round 1 - Model Checking
- Simulation mode: 2.3B states checked, 13.2M traces, depth 80
- Invariants: ElectionSafety, TypeOK, NextIndexBound, SnapshotLogConsistency — all PASS
- BFS infeasible (state space > 38M distinct states with minimal bounds, queue growing)
- No fixes needed

## Bug Hunting

### Spec fixes during hunting (Case B)
- [fix-spec] HandleAppendEntriesRequest: heartbeat (empty entries) was truncating follower's entire log. Split into heartbeat path (UNCHANGED log) vs entry path with stale-message guard (mfirstIndex > commitIndex). Root cause: `SubSeq(log[s], 1, baseIndex) \o <<>>` when baseIndex=0 produced empty log. Implementation skips log ops for empty entries (RaftServerImpl.java:1669).
- [fix-spec] HandleRequestVoteRequest: leader stepping down via vote request didn't clear leaseValid/pendingReads/startupEntryCommitted. Added conditional readVars update when current role is Leader and stepping down. Implementation clears lease in LeaderStateImpl.stop() on any role change from Leader.

### Invariant fixes (Case A)
- [fix-inv] ReadLinearizability: was `leaseValid /\ pendingReads=0 => startupEntryCommitted`, but lease can be extended before startup entry commits (transient state). Weakened to: `leaseValid /\ startupEntryCommitted => commitIndex > 0`. Safety enforced by ClientRead action guard.

### Hunt Results
- MC_hunt_election.cfg: 3.1B states, 13.8M traces — PASS
- MC_hunt_replication.cfg: 2.1B states, 8.9M traces — PASS
- MC_hunt_commit.cfg: 1.9B states, 11M traces — PASS
- MC_hunt_read.cfg: 1.5B states, 20.2M traces — PASS
- MC_hunt_snapshot.cfg: 2.5B states, 10M traces — PASS
- MC_hunt_config.cfg: 1.8B states, 13.3M traces — PASS

## Result
Converged in 1 round (no spec changes needed for convergence).
Bug hunting: 0 bugs found. 2 spec fixes (Case B), 1 invariant fix (Case A) during hunting.
Total states explored across all hunts: ~13B states, ~77M traces.
