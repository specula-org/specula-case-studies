# Bug Report — willemt/raft

## Summary

- Bug families tested: 6 (commit advancement, log consistency, vote safety, snapshot lifecycle, broadcast starvation)
- Bugs found: 0 new bugs
- Invariant fixes: 1 (LeaderCompleteness was too strong — Case A)
- Known modeled bugs: 2 (term decrease in HandleInstallSnapshot, missing no-op after election)
- Configs run: MC_hunt_commit.cfg, MC_hunt_vote.cfg, MC_hunt_log.cfg, MC_hunt_snapshot.cfg, MC_hunt_broadcast.cfg

## Convergence

Spec converged in 1 round:
- **Trace validation**: 3 traces pass (basic_consensus: 25 states, leader_reelection: 28 states, trace: 25 states)
- **Model checking**: BFS complete, 18.9M states, 3.8M distinct, depth 42, 74s — TypeOK, ElectionSafety, LogConsistency, CountersOK all pass

## Invariant Fix: LeaderCompleteness (Case A)

- **Config**: MC_hunt_commit.cfg
- **Counterexample**: 11 states (output/MC_hunt_commit.out)

### Trace Summary

1. s1 times out → candidate term 1, sends RV to s2, s3
2. s2 grants vote to s1 (term 1, votedFor=s1)
3. s2 times out → candidate term 2 (votedFor cleared to s2)
4. s3 grants vote to s2 (term 2)
5. s2 becomes leader term 2 (majority: {s2, s3})
6. s2 appends client entry [term=2, v1]
7. s2 broadcasts AE, s3 replicates entry
8. s2 advances commitIndex to 1 (majority: s2+s3)
9. s1 receives s2's stale vote response from step 2 → becomes leader term 1 (stale leader)
10. **Violation**: s1 is leader with empty log, but s2 has commitIndex=1

### Analysis

This is **not a real bug**. The Raft paper's Leader Completeness property (Section 5.4.3) states: "If a log entry is committed in a given term, that entry will be present in the logs of the leaders for **all higher-numbered terms**." The stale leader s1 (term 1) is not a "future leader" — it's a past-term leader that will step down upon receiving any message from term 2. It cannot commit new entries because no server will accept its term-1 messages.

### Fix

Added `currentTerm[i] >= currentTerm[j]` guard to LeaderCompleteness invariant:
```tla
LeaderCompleteness ==
    \A i \in Server :
        state[i] = Leader =>
        \A j \in Server :
            currentTerm[i] >= currentTerm[j] =>   \* NEW: only check "future" leaders
            \A idx \in 1..commitIndex[j] :
                idx > snapshotLastIdx[i] /\ idx > snapshotLastIdx[j] =>
                (idx <= LastLogIndex(i) /\ LogTermAt(i, idx) = LogTermAt(j, idx))
```

---

## Known Modeled Bugs (from modeling brief)

These bugs are explicitly modeled in the spec but require specific conditions (crash-recovery, snapshot loading) to trigger. BFS with temporal properties is needed but infeasible for the full state space.

### KB-1: HandleInstallSnapshot Term Decrease (Family 3+4)

- **Code**: `raft_server.c:1383-1384`
- **Bug**: `raft_begin_load_snapshot` directly writes `me->current_term = last_included_term` without calling persist callbacks. This can **decrease** the term, violating term monotonicity.
- **Impact**: After snapshot load, a server at term 5 could drop to term 2, then re-vote in terms 3-4, potentially causing two leaders in the same term.
- **Spec**: Modeled faithfully in `HandleInstallSnapshot` (base.tla:668). The `TermNeverDecreases` temporal property in MC.tla is designed to detect this.
- **Status**: UNFIXED (PR #118 Bug 4, ignored since Aug 2021)

### KB-2: Missing No-Op After Election (Family 1)

- **Code**: `raft_become_leader` (raft_server.c:157-177)
- **Bug**: New leader does NOT append a no-op entry. Per Raft Section 5.4.2, this is needed to commit entries from prior terms.
- **Impact**: Entries from prior terms may remain uncommitted indefinitely until a new client request arrives.
- **Spec**: Modeled faithfully — `HandleRequestVoteResponse` transitions to Leader without appending a no-op (base.tla:308-309).
- **Status**: Known issue (#120), UNFIXED

### KB-3: Vote Re-Grant Denial (Family 3)

- **Code**: `raft_server.c:543-545` (`__should_grant_vote`)
- **Bug**: Denies re-vote to the same candidate (checks `votedFor == Nil` strictly). The Raft paper Section 5.2 allows re-granting to the same candidate.
- **Impact**: If a RequestVote is retransmitted, the follower denies the duplicate vote. With message loss, this can delay elections.
- **Spec**: Modeled faithfully (base.tla:244: `votedFor[i] = Nil`).
- **Status**: Known issue (PR #116, closed without merge)

---

## Not Reproduced

| Bug Family | Config | Method | States/Traces | Result |
|------------|--------|--------|---------------|--------|
| Family 1: Commit Advancement | MC_hunt_commit.cfg | Simulation 5min | Terminated | No violation (after invariant fix) |
| Family 2: Log Consistency | MC_hunt_log.cfg | Simulation | 4.9M states, 23K traces | No violation |
| Family 3: Vote Safety | MC_hunt_vote.cfg | Simulation | 24K states, 154 traces | No violation (invariants only; TermNeverDecreases needs BFS) |
| Family 4: Snapshot Lifecycle | MC_hunt_snapshot.cfg | Simulation | 13M states, 72K traces | No violation |
| Family 6: Broadcast Starvation | MC_hunt_broadcast.cfg | Simulation | 3.6M states, 17K traces | No violation |

### Notes on Coverage

1. **Temporal properties** (TermNeverDecreases, CommitNeverDecreases) require BFS and liveness checking, which is infeasible for the full state space (~100M+ distinct states with crash/snapshot/loss bounds enabled).
2. **Family 1 bugs** (single-point commit check, missing no-op) are **liveness** issues, not safety violations. The spec models the implementation's actual behavior; the invariants check that the behavior doesn't cause safety violations (committed entry loss, log divergence). No safety violations were found.
3. **Family 3+4 bugs** (snapshot term decrease) require crash-recovery paths and specific snapshot-then-election sequences. Simulation found no violations in safety invariants, but the TermNeverDecreases temporal property violation is expected and models a real bug.
4. The spec models 14 state variables, 15 actions (including fault injection), and uses bag-based message passing. The state space is dominated by message interleavings.
