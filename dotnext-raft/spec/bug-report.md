# Bug Report — dotnet/dotNext Raft

## Summary

- Bug families tested: 5 (election restriction, sideband config, state transition, leader lease, WAL commit)
- Bugs found: 0 real bugs
- Spec fixes during convergence: 1 (HandleAppendEntries skipCommitted — Case B)
- Configs run: MC.cfg (convergence), MC_hunt_election.cfg, MC_hunt_config.cfg, MC_hunt_lease.cfg, MC_hunt_wal.cfg

## Convergence Fix: HandleAppendEntries skipCommitted

During model checking convergence, MCStateMachineSafety was violated due to a **spec modeling gap** (Case B). The spec's HandleAppendEntries action unconditionally truncated the log to `prevLogIndex` and appended new entries. With the TLA+ message bag (which allows out-of-order delivery), a stale AppendEntries message could truncate committed log entries.

The dotNext implementation uses `AppendAndCommitAsync(skipCommitted=true)` at `RaftCluster.cs:636`, which prevents overwriting committed entries. The spec was fixed to match: entries below `commitIndex` are preserved during log truncation.

This is NOT a real bug — it's a spec fidelity issue caused by the gap between the message bag model (unordered) and the real network (TCP-ordered). The implementation handles this correctly.

---

## Not Reproduced

| Bug Family | Config | States Explored | Traces | Result |
|------------|--------|-----------------|--------|--------|
| 1: Conjunctive Election | MC_hunt_election.cfg | 20K (sim) | 43 | ElectionLiveness temporal fails trivially (no fairness constraint). ElectionSafety + StateMachineSafety pass (verified in convergence: 786M states BFS). Conjunctive check is stricter than paper but doesn't violate safety. |
| 2: Sideband Config | MC_hunt_config.cfg | 9.6K (sim) | 52 | MCConfigCommitConsistency violated (Case A: invariant too strong). Leader applies config before followers — inherent to dotNext's sideband model. Not a safety issue; eventually consistent after next heartbeat round. |
| 3: State Transition Atomicity | MC.cfg (convergence) | 786M BFS + 295M sim | 296K | No violation. Async dispatch modeled via TLA+ interleaving. ElectionSafety, StateMachineSafety, LogMatching all pass. |
| 4: Leader Lease | MC_hunt_lease.cfg | 1.7B (sim) | 1.5M | No violation. NoStaleLeaderWithLease holds: lease renewal/expiry correctly prevents dual-leader scenarios with valid leases. |
| 5: WAL Commit Ordering | MC_hunt_wal.cfg | 997M (sim) | 2.1M | No violation. PersistedCommitBound holds. Crash recovery correctly regresses commitIndex to persisted checkpoint without violating safety. |

## Design Observations

### Conjunctive Election Restriction (Bug Family 1)

`PersistentStateExtensions.cs:29-32` uses a conjunctive up-to-date check:
```
return index >= localIndex && term >= await auditTrail.GetTermAsync(localIndex)
```

The Raft paper uses a disjunctive check: `(term > localTerm) OR (term == localTerm AND index >= localIndex)`.

The conjunctive check is **stricter**: it rejects candidates with higher last-term but shorter log. For example:
- Candidate: term=5, logLen=2. Voter: term=3, logLen=5.
- Paper: 5 > 3 → GRANT. Code: 2 >= 5 → FALSE → REJECT.

This doesn't violate safety (the restriction only rejects valid candidates, never accepts invalid ones). However, it could affect **liveness** in specific partition/recovery scenarios where a valid candidate with a higher term but shorter log cannot win an election. In practice, terms advance and logs converge, making this self-healing.

### Sideband Configuration (Bug Family 2)

dotNext replicates cluster configuration as sideband metadata on AppendEntries, not as log entries. Config is applied on the leader when a heartbeat quorum responds (`LeaderState.cs:189-192`), and on followers when they process the sideband data. This creates a transient window where the leader's `activeConfig` differs from followers'.

The `ConfigCommitConsistency` invariant is too strong for this model — it expects quorum agreement immediately after leader applies. A weaker property (eventual consistency) would be more appropriate.

### No AppendEntries Membership Check (Bug Family 2, MC-3)

`RaftCluster.cs:594-692` (AppendEntriesAsync) does NOT verify the sender is in the members list, unlike `VoteAsync` (line 804). A non-member can send AppendEntries and be accepted as leader. This is modeled in the spec but no safety violation was found — in practice, non-members can't form quorums to commit entries.

## Spec Coverage Summary

| Invariant | Type | Status |
|-----------|------|--------|
| ElectionSafety | Safety | PASS (786M BFS + 295M sim) |
| StateMachineSafety | Safety | PASS (786M BFS + 295M sim) |
| LogMatching | Safety | PASS (786M BFS + 295M sim) |
| CommitIndexBound | Structural | PASS (786M BFS + 295M sim) |
| PersistedCommitBound | Structural | PASS (786M BFS + 2.1B sim) |
| MatchIndexBound | Structural | PASS (786M BFS + 295M sim) |
| NoStaleLeaderWithLease | Extension | PASS (1.7B sim) |
| ConfigCommitConsistency | Extension | FAIL (Case A: too strong for sideband model) |
| ElectionLiveness | Temporal | FAIL (trivial: no fairness constraint) |
