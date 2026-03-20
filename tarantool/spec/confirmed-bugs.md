# Confirmed Bug Report — Tarantool Raft

## Summary

- Total findings reviewed: 10
- Confirmed: 1 (1 reproduced)
- False positives: 5
- Retracted (by MC report): 1
- Not applicable (MC-validated safe): 3

## Bug TT-1: Stale Witness Bits Block Elections After Leader Resignation

- **Source**: MC (18-state BFS counterexample) + Code Review (Family 1)
- **Status**: REPRODUCED
- **Severity**: Medium (liveness — elections blocked, not safety)
- **Location**: `src/lib/raft/raft.c:455-468` (`raft_notify_is_leader_seen`), `raft.c:978` (`raft_sm_election_update_cb`), `raft.c:346` (`raft_sm_election_update`)
- **MC Config**: `MC_hunt_witness.cfg`, invariant `WitnessMapAccuracy` violated
- **MC Output**: `spec/output/MC_hunt_witness_v2.out`

### Description

After a leader resigns, in-flight `is_leader_seen=TRUE` messages from peers who haven't yet learned about the resignation can re-populate the `leader_witness_map` with stale bits. These stale bits block all elections because `raft_sm_election_update` (line 346) gates on `leader_witness_map != 0`.

The election timeout handler (`raft_sm_election_update_cb`, line 978) only clears the **self** bit (`bit_clear(&raft->leader_witness_map, raft->self)`), not remote stale bits. So the stale remote bit persists until one of:
1. The peer sends a new message with `is_leader_seen=FALSE` (after its own death timeout)
2. Disconnect detection clears the bit (`replica_update_applier_health` at `replication.cc:748-749`)
3. A term bump clears the entire map (`raft_sm_schedule_new_term` at line 909)

In a partition scenario where the peer is unreachable AND disconnect detection is delayed, the stale bit persists indefinitely, blocking all elections and leaving the cluster leaderless.

### Root Cause

`raft_notify_is_leader_seen` (line 455-468) unconditionally sets/clears witness bits based on the `is_leader_seen` flag in incoming messages. It does not verify whether a leader actually exists when setting a bit:

```c
void raft_notify_is_leader_seen(struct raft *raft, bool is_leader_seen,
                                uint32_t source)
{
    assert(source > 0 && source < VCLOCK_MAX && source != raft->self);
    if (raft->state == RAFT_STATE_LEADER)
        return;
    if (is_leader_seen)
        bit_set(&raft->leader_witness_map, source);  // No leader existence check!
    else if (bit_clear(&raft->leader_witness_map, source))
        raft_sm_election_update(raft);
}
```

### Trigger Scenario (from MC counterexample, 18 states)

1. Server 1 becomes leader in term 2 (via election + WAL write)
2. Server 1 broadcasts as leader (message enters network)
3. Server 1 **resigns** → becomes follower, `leader=0`
4. Server 2 receives the leader broadcast (from step 2, still in transit) → accepts server 1 as leader, sets self witness bit
5. Server 2 broadcasts with `is_leader_seen=TRUE`
6. Server 1 receives server 2's broadcast → `raft_notify_is_leader_seen(raft, TRUE, 2)` sets server 2's bit in `leader_witness_map[1]`
7. `leader_witness_map[1] = {2}` but **no leader exists** → elections blocked indefinitely

### Reproduction

**Test file**: `test/unit/raft.c` — function `raft_test_stale_witness_blocks_election`

The reproduction uses the existing unit test infrastructure (fake event loop, simulated WAL, message delivery) to exercise the exact scenario from the MC counterexample:

1. Create a node, make it leader (quorum=1, promote)
2. Resign from leadership
3. Send a stale `is_leader_seen=TRUE` from peer 2 (simulating a delayed message)
4. Verify the stale witness bit is set despite no leader existing
5. Wait for death_timeout + election_timeout
6. Verify the node is still FOLLOWER — elections blocked

**Result**: All 9 assertions pass, confirming the bug:
- `ok 5 - BUG: stale witness bit set despite no leader`
- `ok 7 - BUG: stale witness bit persists after timeout`
- `ok 8 - BUG: election blocked by stale witness bit`
- `ok 9 - no leader — cluster is stuck without elections`

The test runs deterministically and triggers every time.

### Recommendation

Clear ALL witness bits (not just self) when the election timer fires without a leader, or add a leader existence check in `raft_notify_is_leader_seen`:

```c
// Option A: Check leader existence before setting bit
if (is_leader_seen && raft->leader != 0)
    bit_set(&raft->leader_witness_map, source);

// Option B: Clear all remote bits on election timeout
// In raft_sm_election_update_cb:
raft->leader_witness_map = 0;  // Instead of just clearing self bit
```

Option A is more precise; Option B is simpler but may cause unnecessary election attempts.

### Related History

- **#12018** (Critical, FIXED): Disabled nodes broadcast stale `is_leader_seen=true`, causing permanent election deadlock — same root mechanism
- **#7512** (High, FIXED): Relay heartbeats mask TX thread hang — related witness map issue

---

## False Positives

### F2-2/T-1: `raft_cfg_election_quorum` Assertion During WAL Write

- **Source**: Code Review (Family 2)
- **Status**: FALSE POSITIVE
- **Reason**: The claim was that `raft_cfg_election_quorum` (line 1258) could trigger `raft_sm_become_leader` during a WAL write, hitting the `assert(!raft->is_write_in_progress)` at line 846. However, during WAL writes, the state machine is always `RAFT_STATE_FOLLOWER` (enforced by assert at line 704). The condition at line 1264 (`raft->state == RAFT_STATE_CANDIDATE`) implicitly prevents reaching `become_leader` during writes, because `CANDIDATE` and `is_write_in_progress` are mutually exclusive.

### F1-1: Term-Bump Ordering Creates Stale Witness Bit

- **Source**: Code Review (Family 1)
- **Status**: FALSE POSITIVE
- **Reason**: The claim was that `raft_process_term` clearing the witness map (line 909) followed by `raft_notify_is_leader_seen` re-setting bits (line 531) creates stale bits. However, messages from lower terms are dropped at line 520 (`if (req->term < raft->volatile_term) return 0`). For same-term messages, `is_leader_seen=TRUE` reflects a genuine leader sighting. For higher-term messages, the sender would have cleared its own witness bits during its own term bump (since Tarantool is single-threaded, broadcasts are composed after state changes). This path cannot independently create stale bits — it only manifests through the TT-1 resignation scenario.

### F2-1: Death Timeout Extension During WAL Write

- **Source**: Code Review (Family 2)
- **Status**: FALSE POSITIVE (design trade-off)
- **Reason**: During WAL writes, heartbeats update `leader_last_seen` (line 678) but don't reset the timer (return at line 680). This extends effective death detection by the WAL write duration. However, this is explicitly acknowledged in the code comments (lines 673-677: "The instance currently is busy with writing something on disk. Can't react to heartbeats. Still, update leader_last_seen field for the sake of metrics."). The timer is properly restarted after write completion (line 715-717 → `raft_sm_wait_leader_dead`). The extension is bounded by WAL write time (typically milliseconds).

### F4-1: Concurrent Promote Causes Infinite Term Bumps

- **Source**: Code Review (Family 4)
- **Status**: FALSE POSITIVE
- **Reason**: `raft_promote` is user-initiated (via `box.ctl.promote()`), not triggered automatically in response to incoming messages. There is no feedback loop: two servers promoting simultaneously bump their terms, but once both reach the same term, `raft_process_term` stops bumping (line 1337: `if (term <= raft->volatile_term) return`). Standard Raft election contention resolves via randomized timeouts.

### TT-2: Promote During WAL Write

- **Source**: MC (Family 4)
- **Status**: RETRACTED (by MC report)
- **Reason**: The invariant `PromoteNotDuringWrite` was too strong. `raft_promote` can be called during `is_write_in_progress`, but the implementation handles it gracefully: `raft_start_candidate` (line 1144) checks `is_write_in_progress` and safely defers; `raft_sm_pause_and_dump` (line 831) returns early if a write is in progress.

## MC-Validated Safe (No Bugs Found)

| Finding | MC Coverage | Result |
|---------|-------------|--------|
| Family 2: WAL Write State Machine Fragility | 32 states (complete BFS) | ElectionSafety, WalWriteSafety, NotWritingWhenLeader all PASS |
| Family 3: Non-Atomic Term/Vote Persistence | 230M states (BFS depth 12, 10 min) | ElectionSafety, OneVotePerTerm, NoStaleVoteAfterCrash, VoteConsistency, LeaderHasVotedForSelf all PASS |
| Family 4: Promote/Demote Race Conditions | 33 states (complete BFS) | ElectionSafety PASS |

The multi-pass WAL write mechanism (term-first, then vote with vclock recheck) correctly prevents double-voting across crashes. The 230M-state BFS exploration of Family 3 provides high confidence.
