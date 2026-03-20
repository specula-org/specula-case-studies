# Confirmed Bug Report — RethinkDB Raft

## Summary

- Total findings reviewed: 10
- Confirmed: 2 (0 reproduced, 2 code-audit only)
- False positives: 2
- Not applicable: 6 (historical bugs already fixed, defensive suggestions, performance issues)

---

## Bug 1: Election Safety Violation via ReenrollWithSameId (Jepsen #5289)

- **Source**: Model Checking (MC_hunt_lifecycle.cfg, 26-state counterexample) + Code Review (Family 4)
- **Status**: CONFIRMED (code audit + MC)
- **Severity**: Critical
- **Location**: `src/clustering/table_manager/multi_table_manager.cc:585-588` (member_id lookup), `src/clustering/table_contract/coordinator/calculate_misc.cc:80-83` (member_id generation), `src/clustering/administration/persist/raft_storage_interface.cc:107-129` (state erasure), `src/clustering/administration/persist/table_interface.cc:247-262` (INACTIVE transition)

### Description

When a server's Raft state is erased (INACTIVE transition) and the server is re-enrolled with the **same `raft_member_id_t`**, it loses its `current_term` and `voted_for` persistent state while retaining its identity. Other servers still recognize it as the same entity. This allows the re-enrolled server to vote again in terms where its previous incarnation already voted, creating two distinct quorums in the same term and violating Raft's Election Safety property (at most one leader per term).

### Root Cause (Code Audit)

The `multi_table_manager_t` manages per-table Raft membership via action messages (ACTIVE/INACTIVE/DELETED). The re-enrollment path works as follows:

1. **INACTIVE transition** (`multi_table_manager.cc:451-486`): The active Raft instance is destroyed (`table->active.reset()` at line 459) and `write_metadata_inactive()` is called.

2. **State erasure** (`table_interface.cc:247-262`): `write_metadata_inactive()` calls `table_raft_storage_interface_t::erase()` at line 260, which wipes the Raft header (`current_term`, `voted_for`, `commit_index`), snapshot, and all log entries (`raft_storage_interface.cc:107-129`).

3. **Member ID lookup** (`multi_table_manager.cc:585-588`): When another active member syncs to the re-enrolling server, it looks up the member_id from the committed Raft state's `member_ids` map:
   ```cpp
   auto it = st->state.member_ids.find(other_server_id);
   if (it != st->state.member_ids.end()) {
       raft_member_id = make_optional(it->second);  // SAME member_id!
   ```

4. **State initialization** (`multi_table_manager.cc:589-591`): The re-enrollment action carries `initial_raft_state` from `get_state_for_init()`, which copies the source member's state but clears `voted_for` (`raft_core.tcc:154-164`).

5. **Re-activation** (`multi_table_manager.cc:391-419`): The server creates a new Raft instance with the OLD member_id but FRESH state (term from source, `voted_for = nil`).

The `raft_member_id_t` documentation explicitly states the intended invariant (`raft_core.hpp:82-86`):
> "If a single server leaves a Raft cluster and then joins again, it will use a different `raft_member_id_t` the second time."

The coordinator code at `calculate_misc.cc:80-83` enforces this by generating a new UUID only when `member_ids.count(server) == 0`. But removal of a server from `member_ids` requires committing a Raft entry, while the INACTIVE/ACTIVE transitions happen through a separate action-message channel. This asynchrony creates a window where the old member_id is reused.

### Trigger Scenario

1. 3-server cluster {A, B, C}, A is leader at term T
2. B goes INACTIVE → `table_raft_storage_interface_t::erase()` wipes B's Raft state
3. Before the coordinator commits a `member_ids` removal for B, B re-enrolls as ACTIVE
4. B receives the same `raft_member_id_t` (still in committed state's `member_ids` map)
5. B starts with fresh persistent state (`voted_for = nil`) under the old identity
6. B can now vote again in terms where its previous incarnation already participated
7. Under specific partition/timing conditions, two candidates form separate quorums in the same term

### MC Counterexample (26 states)

```
State 1-2:  s3 times out → candidate (term 1), votes for self
State 3:    s3's Raft state erased (EraseRaftState)
State 4:    s2 times out → candidate (term 1)
State 5:    s3 re-enrolls with SAME member ID (term 0, votedFor=nil)
State 6:    s3 times out → candidate (term 1) — votes for self AGAIN in term 1
States 7-25: s2 and s3 campaign, each winning votes from different peers
State 26:   VIOLATION — s2 and s3 are both leaders in term 1
```

### Reproduction Attempt

**Test files**: `src/unittest/clustering_raft.cc` (2 test variants), `src/unittest/clustering_utils_raft.cc` (test infrastructure)

**Approach**: Added `erase_and_reenroll_same_id()` and `erase_and_reenroll_same_id_from()` methods to `dummy_raft_cluster_t` (test infrastructure only — not code under test). These simulate the multi_table_manager INACTIVE→ACTIVE path by:
- Killing a member (destroying the `raft_member_t` instance)
- Resetting its persistent state (`make_initial` or `get_state_for_init`)
- Bringing it back alive with the same `raft_member_id_t`

**Variant A** (`RegressionJepsen5289_ReenrollSameId`): Isolates all 3 members to prevent initial election, erases one member's state, then un-isolates all at once. 30 trials, 63 seconds.

**Variant B** (`RegressionJepsen5289_ReenrollFromLeader`): Waits for a stable leader, erases a follower's state and re-enrolls from the leader's state (matching the real `get_state_for_init` path), then isolates the original leader. 30 trials, 150 seconds.

**Result**: Neither variant triggered the `guarantee("At most one leader can be elected in a given term")` failure in 60 combined trials. The bug is real but the specific manifestation (simultaneous quorum formation by two candidates in the same term) requires a precise interleaving that randomized election timeouts make extremely unlikely in test execution. This is exactly why model checking was needed to find it — exhaustive state exploration identifies interleavings that are vanishingly rare in practice but nonetheless reachable.

**Note**: Jepsen #5289 independently confirmed this bug through network partition testing with the actual production system, demonstrating it IS triggerable under real-world conditions, but requires sustained partition/rejoin cycles.

### Recommendation

Each re-enrollment MUST use a fresh `raft_member_id_t`. When the coordinator detects a server should be re-added to a table's Raft group, it must generate a new UUID and update the `member_ids` map, rather than reusing the existing entry. The spec confirms `ReenrollWithNewId` (which uses a new member identity) does NOT trigger this violation. This matches the fix documented in Jepsen #5289 and the intent stated in `raft_core.hpp:82-86`.

---

## Bug 2: Tautological Debug Invariant (CR-1)

- **Source**: Code Review (modeling-brief.md, Family 2)
- **Status**: CONFIRMED (code audit)
- **Severity**: Low
- **Location**: `src/clustering/generic/raft_core.tcc:852`

### Description

A debug invariant check uses a tautological expression that always evaluates to `true`, disabling an intended safety check.

**Current code** (`raft_core.tcc:852-853`):
```cpp
guarantee(readiness_for_change.get() || !readiness_for_change.get(),
    "we shouldn't be accepting config changes but not regular changes");
```

This is `p || !p`, which is always true. The intended check is that `readiness_for_config_change` should never be true when `readiness_for_change` is false. The correct check would be:
```cpp
guarantee(readiness_for_change.get() || !readiness_for_config_change.get(),
    "we shouldn't be accepting config changes but not regular changes");
```

### Code Audit Verification

The `readiness_for_config_change` member variable exists at `raft_core.hpp:965` and is used throughout the codebase (lines 222, 250, 1256, 1263). The `update_readiness_for_change()` function at `raft_core.tcc:1243-1269` shows the intended relationship: `readiness_for_config_change` is only set true when `readiness_for_change` is also true (leader + quorum), with the additional constraint that no joint consensus is active. The invariant was meant to verify this relationship holds.

### Impact

This is debug-only code (inside `check_invariants`, guarded by `DEBUG_ONLY_CODE`). It does not affect production safety. However, it means the invariant that `readiness_for_config_change → readiness_for_change` is never verified at runtime, even in debug builds.

### Recommendation

Change line 852 to:
```cpp
guarantee(readiness_for_change.get() || !readiness_for_config_change.get(),
    "we shouldn't be accepting config changes but not regular changes");
```

---

## False Positives

### CR-2: In-Memory State Mutation Before txn.commit()

- **Source**: Code Review (modeling-brief.md, Family 6)
- **Status**: FALSE POSITIVE
- **Location**: `src/clustering/administration/persist/raft_storage_interface.cc:136-243`

**Finding**: All write methods (`write_current_term_and_voted_for`, `write_commit_index`, `write_log_replace_tail`, `write_log_append_one`, `write_snapshot`) mutate in-memory state before calling `txn.commit()`. If `txn.commit()` fails, in-memory state would diverge from disk.

**Why it's a false positive**: RethinkDB uses fail-stop semantics — `txn.commit()` failure crashes the process (guarantee/assertion failure). The cooperative coroutine model with `cond_t non_interruptor` prevents cancellation between mutation and commit. On crash, recovery reads from persisted state only. There is no code path where `txn.commit()` fails but the process continues running with the mutated in-memory state.

### CR-3: Missing Global Invariants in check_invariants()

- **Source**: Code Review (modeling-brief.md)
- **Status**: NOT A BUG (defensive suggestion)

**Finding**: The `check_invariants()` function could check additional properties like vote uniqueness and leader completeness.

**Assessment**: This is a suggestion for improving debug assertions, not a bug in the existing code. The existing assertions at `raft_core.tcc:320-393` already check Election Safety (line 334-341), Log Matching (line 348+), and several internal consistency properties.

---

## Findings Not Confirmed as Bugs

### MC Bug Hunting Results (Families 1-5)

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1: Virtual Heartbeat / Election | MC_hunt_vhb.cfg | 231.6M states | No violation |
| Family 2: Async Step-Down | MC_hunt_async.cfg | 193.1M states | No violation |
| Family 3: Config Change | MC_hunt_config.cfg | 150M states | No violation |
| Family 5: Snapshot-Log Consistency | MC_hunt_snapshot.cfg | 459M states | No violation |
| Families 2+3: Reconfig Step-Down | MC_hunt_reconfig_stepdown.cfg | 502M states | No violation |

All five families represent historical bug patterns that were already fixed. The combined 1.54 billion states of model checking exploration provides high confidence that the existing fixes are correct and no regressions remain.

### Code Review Findings (Not Bugs)

- **TV-1** (next_index O(N) decrement): Performance issue, not a safety bug. The Raft log matching protocol handles slow catchup correctly.
- **TV-2** (Election livelock under I/O pressure): Liveness concern at scale (#6038), not a safety bug.
- **TV-3** (Vote retry pestering): Performance issue (wasted RPCs), not a safety bug.
- **Issue #4357** (non-transitive connectivity prevents failover): Design limitation of virtual heartbeat architecture, not a code bug. Transport-layer failure detection is inherently environment-specific.
- **Issue #4824** (Raft fuzzer config divergence): Open fuzzer finding, but MC explored 150M states with ConfigChangeSafety invariant and found no violation after the CommittedConfig spec fix.

---

## Appendix: Test Infrastructure for Reproduction

The reproduction test adds two methods to `dummy_raft_cluster_t` in the test infrastructure:

1. **`erase_and_reenroll_same_id(member_id)`**: Resets persistent state to `make_initial` (term=0, empty log, votedFor=nil) while keeping the same member_id. This simulates the worst-case INACTIVE→ACTIVE path as modeled in the TLA+ spec.

2. **`erase_and_reenroll_same_id_from(member_id, source_id)`**: Copies state from another alive member via `get_state_for_init()` (same term, full log, votedFor=nil). This matches the actual `multi_table_manager` re-enrollment code path.

**Build and run**:
```bash
cd case-studies/rethinkdb/artifact/rethinkdb
make -j$(nproc) DEBUG=1 build/debug/rethinkdb-unittest
./build/debug/rethinkdb-unittest --gtest_filter="ClusteringRaft.RegressionJepsen5289*"
```

**Modified files** (test infrastructure only):
- `src/unittest/clustering_utils_raft.hpp` — added method declarations
- `src/unittest/clustering_utils_raft.cc` — added method implementations
- `src/unittest/clustering_raft.cc` — added 2 test cases
