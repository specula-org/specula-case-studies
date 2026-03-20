# Bug Report — ebay/nuraft

## Summary

- Bug families tested: 5 (F2, F3, F4, F5, F7)
- Bugs found: 2
- Configs run: MC_hunt_F2.cfg, MC_hunt_F3.cfg, MC_hunt_F4.cfg, MC_hunt_F5.cfg, MC_hunt_F7.cfg

---

## Bug 1: set_priority() bypasses config_changing_ guard (MC-5)

- **Bug Family**: 3 — Configuration Change Races
- **Severity**: Medium
- **Invariant violated**: ConfigChangeAtomicity
- **Config**: MC_hunt_F3.cfg
- **Counterexample**: 22 states, output in spec/output/MC_hunt_F3.out

### Trace Summary

1. s2 wins election (pre-vote + vote, term 1) and becomes leader
2. BecomeLeader appends ConfigEntry at index 1 (clone of current config), sets `configChanging = TRUE`
3. s2 sends AppendEntries to s3 (twice, with the ConfigEntry)
4. **BypassConfigGuard(s2)** fires: appends a SECOND ConfigEntry at index 2 despite `configChanging = TRUE`
5. Result: s2's log has two uncommitted ConfigEntries (indices 1 and 2), `smCommitIndex = 0`

### Root Cause

`set_priority()` (handle_priority.cxx:39-107) modifies the cluster config by appending a ConfigEntry to the log, but does NOT check the `config_changing_` flag. Every other config-modifying path (`handle_add_srv_req`, `handle_rm_srv_req`) checks this flag before proceeding.

This means a priority change can create a concurrent config change while another config change (including the BecomeLeader config entry) is still uncommitted.

### Affected Code

- `handle_priority.cxx:39-107`: Missing `config_changing_` guard
- `raft_server.cxx:1183-1195`: BecomeLeader appends ConfigEntry (sets config_changing_)

### Recommendation

Add `config_changing_` check at the start of `set_priority()`:
```cpp
if (config_changing_) {
    return cb_func::ReturnCode::ConfigChangePending;
}
```

---

## Bug 2: Auto-quorum adjustment enables split-brain in 2-node cluster (MC-1)

- **Bug Family**: 4 — Quorum Calculation Edge Cases
- **Severity**: High
- **Invariant violated**: ElectionSafety (two leaders in same term)
- **Config**: MC_hunt_F4.cfg
- **Counterexample**: 18 states, output in spec/output/MC_hunt_F4.out

### Trace Summary

1. 2-node cluster (s1, s2), both start as Follower in term 0
2. s2 times out multiple times, starts pre-vote rounds
3. s1 times out, starts pre-vote
4. s2 adjusts quorum to 1 (`customQuorumSize = 1`) — peer unresponsive
5. s1 adjusts quorum to 1 — peer unresponsive
6. s2 initiates vote (term 1), self-votes. With quorum=1, `{s2}` is sufficient
7. s1 initiates vote (term 1), self-votes. With quorum=1, `{s1}` is sufficient
8. s1 becomes leader (term 1) with just its own vote
9. s2 becomes leader (term 1) with just its own vote
10. **Two leaders in term 1** — ElectionSafety violated

### Root Cause

The auto-quorum-adjustment feature (designed for 2-node clusters with one unresponsive peer) reduces `custom_commit_quorum_size_` to 1. When both nodes in a partitioned 2-node cluster independently detect the other as unresponsive, both reduce quorum to 1. This enables each node to elect itself independently, creating split-brain.

The quorum adjustment code is in:
- `handle_vote.cxx:105-123` (candidate path during pre-vote)
- `handle_append_entries.cxx:195-243` (leader path during heartbeat)

Both paths can fire independently on each node.

### Affected Code

- `handle_vote.cxx:105-123`: Candidate adjusts quorum during pre-vote when peer unresponsive
- `handle_append_entries.cxx:195-243`: Leader adjusts quorum when peer doesn't respond
- `raft_server.cxx:613-634`: `get_quorum_for_election()` returns `custom_size - 1` when set

### Recommendation

This is a **known, documented risk** (GitHub Issue #151). The maintainer acknowledges this trade-off: auto-quorum enables availability in 2-node clusters at the cost of potential split-brain during partitions.

Possible mitigations:
1. Require explicit opt-in per deployment (not default behavior)
2. Add a "split-brain detector" that checks for conflicting committed entries on partition heal
3. Use a witness/arbiter node for 2-node clusters instead of quorum reduction

---

## Not Reproduced

| Bug Family | Config | States Explored | Traces | Result |
|------------|--------|-----------------|--------|--------|
| F2 (Non-atomic persistence) | MC_hunt_F2.cfg | 199M | 1.3M | No violation — VoteUniqueness holds. Pre-vote mechanism may mitigate: crashed node needs pre-vote quorum before real election, preventing double-vote after recovery |
| F5 (Stale responses) | MC_hunt_F5.cfg | 193M | 773K | No violation — ElectionSafety, NoStaleMatchIndex hold. update_term() step-down in response handlers + candidateVars reset (our spec fix) prevents stale votes from causing harm |
| F7 (Missing Figure 2 term check) | MC_hunt_F7.cfg | 224M | 880K | No violation — LeaderCompleteness holds WITH config entry barrier. The implicit BecomeLeader ConfigEntry (raft_server.cxx:1183-1195) acts as Raft §5.4.2 noop barrier, ensuring entries from previous terms are only committed alongside a current-term entry |

### Notes on F7

The MC_hunt_F7.cfg was run with the standard MC.tla (ConfigEntry barrier present). The `MC_noF7.tla` variant (barrier removed) would be expected to violate LeaderCompleteness, confirming the barrier is necessary. This was not tested in this run but is available for future verification.
