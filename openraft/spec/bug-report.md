# Bug Report — openraft

## Summary

- Bug families tested: 5 (vote/lease, snapshot, heartbeat/commit, membership, restart/recovery)
- **Bugs found: 1** (code audit, low severity)
- Model checking: 447M+ states, 0 violations
- Code audit candidates: 3 investigated, 1 confirmed, 2 dismissed

---

## Model Checking Results

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 1: Vote/Lease | MC_hunt_vote.cfg | 2.6M states, 1M distinct, 37s | No violation (after LeaseImpliesLeadership removed — see Spec Fixes) |
| 2: Snapshot/Log | MC_hunt_snapshot.cfg | 59M states, 19M distinct, 12 min | No violation |
| 3: Heartbeat/Commit | (covered by MC.cfg) | 272M states, 87M distinct, 21 min | No violation |
| 4: Membership | MC_hunt_membership.cfg | 53M states, 19M distinct, 12 min | No violation |
| 5: Restart/Recovery | MC_hunt_restart.cfg | 61M states, 21M distinct, 12 min | No violation |

**Total state space explored**: 447M+ states across all configs.

---

## Code Audit Results

Three potential bugs were identified during code analysis and subjected to Phase 1 (code audit) and Phase 2 (reproduction).

### #5: `update_vote` debug_assert in `establish_leader` — CONFIRMED (Low)

**Location**: `engine_impl.rs:691-692`

**Mechanism**: In `establish_leader()`, `update_vote()` is called with the candidate's committed vote. The return value is only checked by `debug_assert!`, which is compiled out in release builds. The developer's comment (line 689) asserts "This could not fail because `internal_server_state` will be cleared once `state.vote` is changed to a value of other node." This reasoning misses a case created by the developer's own `to_non_committed()` mitigation (line 358): state.vote can change to a **same-node higher-term uncommitted** vote, which does not clear the candidate.

**Trigger** (state reversion — within openraft's design scope per line 349: "when state reversion is allowed"):
1. Node 0 was previously leader at T7; remote node 1 holds Vote(T7, 0, committed)
2. Node 0 state reverts, restarts at T4, starts election at T5
3. Node 1 rejects with Vote(T7, 0, committed) → `to_non_committed()` → state.vote = Vote(T7, 0, uncommitted)
4. Node 2 grants at T5 → quorum → `establish_leader()` → `update_vote(T5, committed)` fails (T5 < T7)
5. `debug_assert!` panics in debug; silently swallowed in release

**Reproduction**: `tests/tests/elect/t12_bug5_update_vote_debug_assert.rs` — confirmed debug_assert panic using fake stores + RPC pre-hook timing control. No code modifications to the system under test.

**Impact**: Low. The leader's core operational paths (`try_leader_handler`, `try_replication_handler`, commit, step-down) use `self.leader`, not `state.vote`. The inconsistency affects metadata only (`is_leader()` returns false, metrics may be inaccurate). No protocol safety violation.

**Recommended fix**: Replace `debug_assert!` with proper error handling — either abort leader establishment on failure, or add a guard in `handle_vote_resp` to prevent same-node higher-term bumps while a candidate is active.

### #6: LeaseRead stale read after restart — FALSE POSITIVE

**Claim**: After leader-survival restart, LeaseRead could serve stale reads before quorum re-confirmation.

**Why dismissed**: `Leader::new()` initializes `clock_progress` to `None` for all nodes. `last_quorum_acked_time()` returns `None` until actual quorum acknowledgement arrives. The LeaseRead path (raft_core.rs:347) correctly falls through to "lease expired" and rejects the read. The TODO comments at lines 337 and 1829 concern unrelated issues.

### #7: Transient SM + no save_committed → state loss — DISMISSED (documented behavior)

**Claim**: With transient SM and default no-op `save_committed()`, restart causes silent state loss (SM reverts to snapshot position, missing committed entries).

**Investigation**: Reproduced with a 3-node cluster: snapshot at index 15, 5 more committed entries, restart node 0 with cleared SM and other nodes down. Confirmed applied_index=15 < full_committed=20.

**Why dismissed**: This is explicitly documented behavior, not a bug.
- `log_pointers.md` line 90-91: "If the committed log id is not saved, Openraft will just recover the state machine to the state of the last snapshot taken."
- Developer acknowledges consequences (line 98-99): metrics fallback, stale node info.
- Developer provides `save_committed()` as the opt-in solution.
- During the recovery window (before quorum forms), the leader cannot serve any requests anyway: writes need quorum, LeaseRead rejects (no quorum ack), ReadIndex fails (no quorum heartbeat). Once quorum returns, committed is re-derived and logs are replayed automatically.

---

## Spec Fixes During Hunting

### LeaseImpliesLeadership — Case A: Invariant Too Strong

**Original invariant**:
```
\A i \in Server :
    (~crashed[i] /\ leaseActive[i] /\ voteCommitted[i] /\ votedFor[i] # i) =>
        \E j \in Server : state[j] = Leader /\ currentTerm[j] = currentTerm[i] /\ j = votedFor[i]
```

**Violations found**:
1. **9-state trace** (MC_hunt_vote.cfg, 8s): Leader node 2 crashes. Node 1 receives in-transit heartbeat from crashed leader. Node 1 sets lease+committed, but leader is dead.
2. **10-state trace** (MC_hunt_vote.cfg v2, 37s): Leader node 1 at term 1 sends heartbeat, then steps down to term 2 (received higher-term response from node 2). Node 3 receives stale heartbeat (term 1). Node 3 sets lease+committed for node 1, but node 1 is now at term 2.

**Root cause**: LeaseImpliesLeadership is fundamentally wrong for openraft's lease design. Leases mean "recently received a heartbeat from an apparently valid leader." They do NOT guarantee:
- The leader is still alive (it may have crashed)
- The leader is still at the same term (it may have stepped down)

The actual safety guarantee from leases is: "while lease is active, the follower rejects VoteRequests from candidates" — this is enforced by the `HandleVoteRequest` action's lease check (`voteCommitted[i] /\ leaseActive[i] => reject`), NOT by a leader-liveness invariant.

**Resolution**: Removed LeaseImpliesLeadership from hunting configs. The lease mechanism's safety is already covered by the VoteStateConsistency and CommitSafety invariants, which passed all checks.

---

## Convergence Summary

The spec converged in 1 round:
- **Trace validation**: basic_consensus trace (105 events) validated with 39,956 states
- **Model checking**: 272M states at depth 15, 6 invariants — no violations
- **Key abstractions**:
  - Config stays at <<{1}>> (single-node config; openraft replicates to learners, not just voters)
  - No post-state validation in Trace.tla due to TLC cross-module variable resolution bug
  - Silent actions bridge un-traced bootstrap events (learner additions, membership changes)
