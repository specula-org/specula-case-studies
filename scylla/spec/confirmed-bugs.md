# Confirmed Bug Report — ScyllaDB Raft Library

## Summary

- Total findings reviewed: 12
- Confirmed: 1 (0 reproduced, 1 code-audit only)
- False positives: 3
- Already fixed (verified): 3
- Dead code (not a bug): 1
- Out of scope: 4 (external issues, code quality, design concerns)

---

## Bug 1: Read Barrier Stall During Voter Demotion in Joint Consensus

- **Source**: Code Review (modeling brief MC-3/MC-4) + MC (Family 2 analysis)
- **Status**: CONFIRMED (code audit)
- **Severity**: Medium (liveness — reduced fault tolerance, no data loss)
- **Location**: `raft/tracker.cc:114-118` (root cause), `raft/fsm.cc:1055` (symptom)

### Description

During a joint consensus configuration change that **demotes** a server from voter to non-voter (keeping it in the config), the `follower_progress::can_vote` field retains the value from the `current` config only. This contradicts `configuration::can_vote()` (`raft.hh:206-217`) which correctly ORs the voter status across both configs.

**Root cause**: In `tracker::set_configuration()` (`tracker.cc:109-132`), the `emplace_simple_config` lambda processes `current` first (line 129), then `previous` (line 131). When processing `previous`, a server already in the progress map (from `current`) hits the `continue` at line 118, **skipping the `can_vote` update at line 126**. A server that is `is_voter::no` in `current` but `is_voter::yes` in `previous` gets `can_vote = false`.

**Consequence**: `broadcast_read_quorum()` (`fsm.cc:1055`) filters on `p.can_vote`, so the demoted server never receives `read_quorum` requests. However, `tracker::committed<read_id>()` (`tracker.cc:188-202`) requires a majority in `_previous_voters` — which correctly includes the demoted server (line 111-113). The demoted server's `max_acked_read` stays at its initial value, reducing the pool of respondents available for the previous-config quorum.

### Trigger Scenario

**Setup**: 3-node cluster {A, B, C}, all voters. A is leader.

**Config change**: Demote C to non-voter. New config = `{A(voter), B(voter), C(non-voter)}`.

**Joint config created**:
- `current = {A(v), B(v), C(nv)}`, `previous = {A(v), B(v), C(v)}`
- `_current_voters = {A, B}`, `_previous_voters = {A, B, C}`
- C's `follower_progress::can_vote = false` (from current; previous update skipped)

**Read barrier issued**: `broadcast_read_quorum` sends to A (self-ack) and B only. **C is skipped.**

**Previous-config quorum**: Needs `count >= 3/2 + 1 = 2` (majority of {A, B, C}).
- If A and B both respond: count = 2 >= 2 → OK. Read barrier completes.
- If B is slow or partitioned: count = 1 < 2 → **STALL**. Read barrier cannot complete.

**Without the bug**: C also receives the request. A + C = 2/3 → quorum satisfied even if B is slow.

**Impact**: Fault tolerance for read barriers is reduced from tolerating 1 failure to tolerating 0 failures during the joint config transition. In larger clusters (e.g., 5 nodes, 2 demoted), the effect scales: read barriers require ALL non-demoted servers to respond, tolerating zero failures instead of the expected two.

**Worst case**: If ALL non-leader voters are being demoted simultaneously (e.g., shrinking a 3-node cluster to 1 voter while keeping others as non-voters), the read barrier **deterministically stalls** — only the leader's self-ack counts toward the previous quorum, which is never sufficient for majority.

### Why the Existing Test Doesn't Catch This

The existing `test_read_barrier` in `test/raft/fsm_test.cc:2183-2211` tests a joint config where new servers are **added** (current = {A, E}, previous = {A, B, C, D}). In that scenario, B/C/D are only in the `previous` config — they are freshly added to the progress map from `previous` with `can_vote = true` (line 124-126). The bug only triggers for servers in **both** configs with a voter → non-voter demotion.

### Reproduction Test (Not Executed)

The following test would demonstrate the bug in the existing `fsm_test.cc` framework. It cannot be executed without building ScyllaDB (requires Seastar framework).

```cpp
BOOST_AUTO_TEST_CASE(test_read_barrier_voter_demotion_joint_config) {
    // Setup: 3-node cluster {A, B, C}, all voters
    raft::server_id A_id = id(), B_id = id(), C_id = id();
    raft::log log(raft::snapshot_descriptor{.idx = raft::index_t{0},
        .config = config_from_ids({A_id, B_id, C_id})});
    auto A = create_follower(A_id, log);
    auto B = create_follower(B_id, log);
    auto C = create_follower(C_id, log);

    // Elect A as leader
    election_timeout(A);
    communicate(A, B, C);
    BOOST_CHECK(A.is_leader());
    A.tick();
    communicate(A, B, C);

    // Enter joint config: demote C to non-voter
    // current = {A(v), B(v), C(nv)}, previous = {A(v), B(v), C(v)}
    raft::config_member_set new_config;
    new_config.emplace(raft::config_member{server_addr_from_id(A_id), raft::is_voter::yes});
    new_config.emplace(raft::config_member{server_addr_from_id(B_id), raft::is_voter::yes});
    new_config.emplace(raft::config_member{server_addr_from_id(C_id), raft::is_voter::no});
    A.add_entry(raft::configuration(std::move(new_config)));
    auto output = A.get_output(); // Process log + drop append_entries

    // Start read barrier
    auto rid = A.start_read_barrier(A_id);
    BOOST_CHECK(rid);

    // BUG CHECK: read_quorum should be sent to B AND C (both are voters
    // in the previous config). But due to the can_vote mismatch, C is skipped.
    output = A.get_output();

    // Count how many read_quorum messages were sent (excluding self-ack)
    size_t read_quorum_count = 0;
    bool sent_to_C = false;
    for (auto& [to, msg] : output.messages) {
        if (std::holds_alternative<raft::read_quorum>(msg)) {
            read_quorum_count++;
            if (to == C_id) sent_to_C = true;
        }
    }

    // This assertion FAILS due to the bug:
    // Expected: 2 messages (to B and C), sent_to_C = true
    // Actual:   1 message (to B only), sent_to_C = false
    BOOST_CHECK_EQUAL(read_quorum_count, 2);  // FAILS: actual = 1
    BOOST_CHECK(sent_to_C);                    // FAILS: C was skipped

    // Demonstrate the stall: only A self-acks, B is "slow" (no reply)
    // Without C's response possibility, read barrier cannot complete
    output = A.get_output();
    BOOST_CHECK(!output.max_read_id_with_quorum);
    // Tick multiple times — barrier never completes without B
    for (int i = 0; i < 10; i++) {
        A.tick();
        output = A.get_output();
        BOOST_CHECK(!output.max_read_id_with_quorum);
    }
}
```

### Recommendation

Fix `tracker::set_configuration()` at `tracker.cc:118` to update `can_vote` before continuing:

```cpp
if (newp != this->progress::end()) {
    // Processing joint configuration and already added
    // an entry for this id. Update can_vote to the union.
    newp->second.can_vote = newp->second.can_vote || s.can_vote;
    continue;
}
```

This aligns `follower_progress::can_vote` with `configuration::can_vote()` (`raft.hh:213`), which already ORs the voter status from both configs.

---

## Findings Classified as FALSE POSITIVE

### FP-1: Pre-Persistence Stable Index Advance (MC-6)

- **Source**: Code Review
- **Location**: `raft/fsm.cc:397-403`
- **Claim**: `get_output()` advances `stable_idx` before entries are persisted, so `commit_idx` could advance before disk write.
- **Why false positive**: Safe by design via two mechanisms:
  1. **Batch ordering**: `get_output()` collects `output.committed` (line 358-366) BEFORE advancing `stable_idx` (line 397). The newly committed entries appear in the **next** batch, not the current one. `io_fiber` processes batches sequentially (`server.cc:1265-1267`), so `store_log_entries` (line 1146) completes before `store_commit_idx` (line 1197) of the next batch.
  2. **Crash-stop on failure**: If persistence throws, `handle_background_error` (`server.cc:1598-1605`) sets `_is_alive = false`, halting the server. The optimistic in-memory advance is never acted upon.
  3. **Client notification ordering**: `notify_waiters` in `applier_fiber` (`server.cc:1353`) runs strictly after both `store_log_entries` and `store_commit_idx`.

### FP-2: Family 5 — Failure Detector Staleness (MC findings)

- **Source**: MC (MC_hunt_family5.cfg)
- **Location**: `raft/fsm.cc:523-529` (`tick_leader`), `raft/fsm.cc:590-606` (`has_stable_leader`)
- **Why false positive**: MC explored 99M states with non-deterministic FD staleness — all safety invariants hold. The FD affects only liveness (election timing, leader stepdown delay), not safety. This is by design: the shared failure detector replaces per-group heartbeats for liveness only.

### FP-3: Family 1 — Commit Index Over-Advancement (MC findings)

- **Source**: MC (MC_hunt_family1.cfg)
- **Location**: `raft/fsm.cc:667`, `raft/fsm.cc:1059`
- **Why not a current bug**: Both historical bugs (#9965, #10578) are fixed in the current code. MC explored 123M states with buggy action variants but could not trigger violations because the batch AppendEntries model prevents the precondition (`leaderCommitIdx > lastNewIdx`). The fixes are verified present:
  - `fsm.cc:667`: `advance_commit_idx(std::min(leader_commit_idx, last_new_idx))` (references #9965 in comment)
  - `fsm.cc:1059`: `send_to(p.id, read_quorum{_current_term, std::min(p.match_idx, _commit_idx), id})`

---

## Findings Classified as ALREADY FIXED

### Fixed-1: Commit Index Clamping in AppendEntries (#9965)

- **Location**: `raft/fsm.cc:665-667`
- **Fix verified**: `advance_commit_idx(std::min(leader_commit_idx, last_new_idx))` with comment referencing #9965.

### Fixed-2: Commit Index Clamping in ReadQuorum (#10578)

- **Location**: `raft/fsm.cc:1059`
- **Fix verified**: `std::min(p.match_idx, _commit_idx)` clamps leader commit index sent in read quorum messages.

### Fixed-3: Remote Snapshot Trailing (#9551)

- **Location**: `raft/fsm.hh:546`
- **Fix verified**: Remote snapshots use `apply_snapshot(std::move(msg.snp), 0, 0, false)` — trailing = 0 for remote snapshots. Local snapshots use configured trailing values.

---

## Findings Classified as DEAD CODE (Not a Bug)

### DC-1: `vote_request::force` Flag Never Read

- **Source**: Code Review (T-1/CR-1)
- **Location**: `raft/raft.hh:406-408` (field), `raft/fsm.cc:296` (write), `raft/fsm.cc:778-831` (handler ignores it)
- **Description**: The `force` field is set to `true` during leadership transfer (`become_candidate` at line 296 passes `is_leadership_transfer` as the `force` parameter) but **never read** by the `request_vote()` handler. The field was designed to bypass a "disruptive server" check (reject votes if leader is alive, per Raft PhD §4.2.3). That check was deliberately removed — the README (`raft/README.md:167-171`) explains: *"With pre-voting ON and use of shared failure detector we found this extension unnecessary, and even leading to reduced liveness. It was thus removed from the implementation."*
- **Impact**: None. The `force` bypass is unnecessary because the check it overrides no longer exists. Leadership transfer works correctly through the `timeout_now` path (candidate starts at a higher term, causing receivers to step down with no known leader, satisfying the existing `current_leader() == server_id{}` guard at line 789).
- **Recommendation**: Remove the `force` field from `vote_request` and the `is_leadership_transfer` parameter from `become_candidate()` to reduce confusion.

---

## Findings Not Investigated (Out of Scope)

| ID | Description | Reason |
|----|-------------|--------|
| T-2 | Use-after-free in applier_fiber (#23816) | External GitHub issue, not our finding |
| T-3 | Add_entry spanning multiple terms (#26189) | External GitHub issue, not our finding |
| CR-2 | FIXME exception type in wait_for_entry | Code quality, not a logic bug |
| CR-3 | Snapshot lifecycle fragility (#9956) | Design concern, no concrete trigger |

---

## MC Coverage Summary

| Config | States | Distinct | Depth | Duration | Result |
|--------|--------|----------|-------|----------|--------|
| MC.cfg (BFS) | 1.2B | 123M | 14 | 25 min | 7 invariants pass |
| MC.cfg (sim) | 64.5M | — | 100 | 10 min | 7 invariants pass |
| Family 1 | 123M | 27M | 20 | 12 min | 3 invariants pass |
| Family 2 | 305K | 118K | 14 | 13 sec | Invariant too strong (liveness, not safety) |
| Family 3 | 231M | 45M | 20 | 17 min | 4 invariants pass |
| Family 5 | 99M | 10M | 12 | 5 min | 4 invariants pass |

**Total**: 1.7B+ states explored across BFS + simulation. 0 new safety violations found. 1 liveness bug confirmed via code audit.
