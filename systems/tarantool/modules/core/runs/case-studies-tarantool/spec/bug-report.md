# Bug Report — Tarantool Raft

## Summary

- Bug families tested: 4
- Bugs found: 1 confirmed liveness concern (Family 1), 1 retracted (Family 4 — invariant too strong)
- Configs run: MC_hunt_witness.cfg, MC_hunt_wal.cfg, MC_hunt_persistence.cfg, MC_hunt_promote.cfg

---

## Bug TT-1: Stale Witness Bits Block Elections After Leader Resignation

- **Bug Family**: Family 1 — Leader Witness Map Election Blocking
- **Severity**: Medium (liveness concern, not safety)
- **Invariant violated**: WitnessMapAccuracy
- **Config**: MC_hunt_witness.cfg
- **Counterexample**: 18 states, BFS 22s (output: spec/output/MC_hunt_witness_v2.out)

### Trace Summary

1. **States 1-6**: Server 1 starts election in term 2 (ElectionTimeout → WAL write → CompleteWalWrite → becomes Candidate)
2. **States 7-8**: Server 1 broadcasts vote request; server 2 receives and votes for server 1 (term bump to 2, WAL multi-pass write)
3. **States 9-11**: Server 2 completes WAL write (term+vote persisted)
4. **State 12**: Server 2 broadcasts its state (follower, term 2, vote=1)
5. **State 13**: Server 1 receives server 2's vote → **becomes Leader** (2 votes: self + s2)
6. **State 14**: Server 1 broadcasts as Leader (isLeaderSeen=FALSE, leaderId=1)
7. **State 15**: Server 1 **resigns** → becomes Follower, leader=Nil. **No leader exists anywhere.**
8. **State 16**: Server 2 receives server 1's leader broadcast (from state 14, still in transit) → accepts server 1 as leader, sets self witness bit (leaderWitnessMap[2]={2})
9. **State 17**: Server 2 broadcasts with **isLeaderSeen=TRUE** (because its self bit is set, it thinks it sees the leader)
10. **State 18**: Server 1 receives server 2's broadcast → witness update sets server 2's bit in server 1's map → **leaderWitnessMap[1]={2}**. But **no leader exists** — server 1 resigned at step 7.

### Root Cause

The `raft_notify_is_leader_seen` function (raft.c:455-468) unconditionally sets/clears witness bits based on the `isLeaderSeen` flag in incoming messages. It does not verify whether a leader actually exists. After a leader resigns, in-flight messages with `isLeaderSeen=TRUE` (from peers who haven't yet learned about the resignation) can re-populate the witness map with stale bits.

The stale bit in `leaderWitnessMap[1]` blocks `CanStartElection(1)` because the gate check at raft.c:346 requires the witness map to be empty. Server 1's election timeout (raft.c:978) only clears the **self** bit (`bit_clear(&raft->leader_witness_map, raft->self)`), not remote bits. So the stale remote bit for server 2 persists.

The stale bit is only cleared by:
1. A new message from server 2 with `isLeaderSeen=FALSE` (when server 2 eventually learns the leader is gone)
2. Disconnect detection: `replica_on_disconnect` (replication.cc:657) calls `raft_notify_is_leader_seen(false, replica->id)`
3. A term bump (raft.c:909 clears the entire witness map)

In a partition scenario where server 2 is unreachable, the stale bit persists indefinitely, blocking server 1 from starting elections.

### Affected Code

- `raft.c:455-468` (`raft_notify_is_leader_seen`): Sets witness bits without verifying leader existence
- `raft.c:978` (`raft_sm_election_update_cb`): Only clears self bit, not remote stale bits
- `raft.c:346` (`raft_sm_election_update`): Gate check requires empty witness map

### Recommendation

Consider clearing ALL witness bits (not just self) when the election timer fires, or when the node detects that its known leader is no longer valid. This would prevent stale remote bits from blocking elections.

Alternatively, add a check in `raft_sm_election_update` that ignores witness bits from peers whose leader status cannot be confirmed within a timeout window.

---

## Retracted

### ~~TT-2: Promote During WAL Write~~

- **Bug Family**: Family 4 — Promote/Demote Race Conditions
- **Invariant**: PromoteNotDuringWrite
- **Status**: Retracted (Case A — invariant too strong)

The model checker found that `raft_promote` can be called while `is_write_in_progress=TRUE`. Initial analysis suggested this was a bug (the spec comment at raft.c:1212 notes "no guard against is_write_in_progress").

However, code review shows the implementation handles this gracefully:
- `raft_start_candidate` (raft.c:1144): explicitly checks `is_write_in_progress` and safely defers action
- `raft_sm_pause_and_dump` (raft.c:831): returns early if a write is already in progress
- The WAL worker eventually persists the updated volatile state when the current write completes

No assertion failure, no safety violation. The invariant is too strong — it assumed promote and write-in-progress cannot coexist, but the implementation handles this case safely.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 2: WAL Write State Machine Fragility | MC_hunt_wal.cfg | 32 (complete BFS) | ElectionSafety, WalWriteSafety, NotWritingWhenLeader PASS. PromoteNotDuringWrite violated but retracted (Case A). |
| Family 3: Non-Atomic Term/Vote Persistence | MC_hunt_persistence.cfg | 230M (BFS depth 12, 10 min) | ElectionSafety, OneVotePerTerm, NoStaleVoteAfterCrash, VoteConsistency, LeaderHasVotedForSelf all PASS. No double-vote or stale vote after crash found. |
| Family 4: Promote/Demote Race Conditions | MC_hunt_promote.cfg | 33 (complete BFS) | PromoteNotDuringWrite violated but retracted (Case A — see above). ElectionSafety PASS. |

## Convergence Summary

- Trace validation: basic_election.ndjson PASS (249 states)
- Model checking (MC.cfg, 8 structural invariants):
  - BFS: 1.65B states, depth 17, 0 violations (12 min)
  - Simulation: 823M states, 32.6M traces, 0 violations (10 min)
- Converged in 1 round (no base spec modifications needed)

## Spec Adjustments During Hunting

1. **MCNext NotifyLeaderSeen restriction**: Standalone `NotifyLeaderSeen` in `MCNext` restricted to `isSeen=FALSE` only. External callers (`replica_on_disconnect`, `replica_update_applier_health`) only pass `FALSE`; `TRUE` is only passed from `raft_process_msg` which is already modeled by `ReceiveMessage`. This makes the hunting config more faithful to the implementation.
