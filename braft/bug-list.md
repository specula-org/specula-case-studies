# braft Bug List

Bugs found during formal verification of braft. Each bug is reviewed and confirmed individually.

**Status legend:**
- `PENDING` — Awaiting review
- `CONFIRMED` — Confirmed as a real bug
- `NOT_A_BUG` — Confirmed not a bug
- `DUPLICATE` — Same root cause as another recorded bug
- `DISPUTED` — Disputed

---

## I. TLC Model Checking Bugs

Bugs found via TLA+ model checking with TLC counterexamples. Some reproduced with integration tests.

### Bug-MC-2: Snapshot Response Missing Term Check

| Field | Details |
|-------|---------|
| **Status** | PENDING |
| **Discovery** | TLC model checking (MC-bug2.cfg) |
| **Invariant violated** | `NoPhantomSnapshotContact` |
| **TLC counterexample** | 3M states, 17-step counterexample |
| **Integration test** | None (modeling bias — spec updates leaderContact but real code does not) |
| **Severity** | MEDIUM-HIGH |
| **Existing Issue** | None (developer comment at replicator.cpp:895 acknowledges it) |

**Code locations:**
- `replicator.cpp:870-933` — `_on_install_snapshot_returned()` **no term check**
- `replicator.cpp:895` — Comment: "Let heartbeat do step down"
- `replicator.cpp:472-479` — `_on_rpc_returned()` success path: term mismatch only logs error, no step_down
- `replicator.cpp:315-333` — `_on_heartbeat_returned()` **correctly checks** term
- `replicator.cpp:418-436` — `_on_rpc_returned()` failure path **correctly checks** term

**Mechanism:**
Of 5 response handlers, 3 correctly check term and step_down, 2 have gaps:
1. `_on_install_snapshot_returned()` — does not check response term at all
2. `_on_rpc_returned()` success path — checks term mismatch but only logs error + resets, no step_down

**Impact:**
Stale leader does not step down after receiving snapshot response, relies on next heartbeat to discover term change. Leader may continue serving reads/writes during the window.

**TLA+ invariant definition (base.tla:975-979):**
```tla
NoPhantomSnapshotContact ==
    \A s \in Server :
        state[s] = Leader =>
            \A f \in leaderContact[s] :
                currentTerm[f] <= currentTerm[s]
```

**Note:** This bug has a modeling bias issue — the TLA+ spec updates `leaderContact` on snapshot response (a spec modeling choice), while the real code `_on_install_snapshot_returned()` does not update any contact information. The invariant `NoPhantomSnapshotContact` detects contacts with higher-term followers in the spec, but in real code, contacts are never updated, so actual impact depends on heartbeat latency.

---

## II. Code Analysis Bugs

Bugs found via code review and analysis. Not independently verified by TLC.

### Bug-CA-1: AppendEntries Success Response Term Mismatch Without step_down

| Field | Details |
|-------|---------|
| **Status** | PENDING |
| **Discovery** | Code analysis |
| **Severity** | MEDIUM |

**Code location:**
- `replicator.cpp:472-479` — `_on_rpc_returned()` success path

**Mechanism:**
Checks `response->term() != r->_options.term` but only logs error + resets replicator, no step_down. Related to Bug-MC-2, same Bug Family (Response Handler Path Inconsistency).

**Note:** May be part of Bug-MC-2 rather than an independent issue.

---

### Bug-CA-4: MixedMetaStorage Dual-Write Crash Window

| Field | Details |
|-------|---------|
| **Status** | PENDING |
| **Discovery** | Code analysis |
| **Severity** | HIGH |

**Code location:**
- `raft_meta.cpp:270-292` — `MixedMetaStorage::set_term_and_votedfor()`

**Mechanism:**
MixedMetaStorage writes to file first, then LevelDB. The two writes are not atomic. A crash between them causes file and LevelDB term/votedFor inconsistency.

**Note:** `raft_meta.cpp:294-397` has reconciliation logic on restart to handle inconsistencies. Need to confirm if reconciliation fully covers all inconsistency scenarios.

---

### Bug-CA-5: step_down Persist Failure Silently Ignored

| Field | Details |
|-------|---------|
| **Status** | PENDING |
| **Discovery** | Code analysis |
| **Severity** | MEDIUM-HIGH |
| **Developer TODO** | `node.cpp:1848` — `// TODO report error` |

**Code location:**
- `node.cpp:1844-1849` — persist failure in `step_down()`

**Code snippet:**
```cpp
status = _meta_storage->set_term_and_votedfor(term, _voted_id, _v_group_id);
if (!status.ok()) {
    // TODO report error
    LOG(ERROR) << ...;
}
```

**Mechanism:**
Persist failure only logs error, node continues running. In-memory state (new term) diverges from disk state (old term). Crash-restart recovers to old term.

**Note:** Same Bug Family as MC-3 (Non-Atomic Persistence).

---

### Bug-CA-6: Removed Node Can Still Win Elections

| Field | Details |
|-------|---------|
| **Status** | PENDING |
| **Discovery** | Code analysis |
| **Severity** | MEDIUM |

**Code locations:**
- `node.cpp:2176-2289` — `handle_request_vote_request()` no config membership check
- `node.cpp:2109-2174` — `handle_pre_vote_request()` no config membership check

**Mechanism:**
Vote handlers do not verify whether the candidate is in the current configuration. A removed node can continue to initiate elections and receive votes.

**Note:** This may be intentional. The Raft paper does not require membership checks in vote handlers. braft checks `_conf.contains(_server_id)` at `node.cpp:1626` to prevent the node itself from initiating PreVote, but does not block receiving votes from nodes outside the configuration. Needs further discussion.

---

## III. Historical Bugs (Fixed via Git Commits)

These bugs were already fixed. Listed to show systemic weaknesses in braft and confirm our TLA+ model covers similar scenarios.

### Replicator (12 commits)

| ID | Commit | Summary | Severity |
|----|--------|---------|----------|
| H-R1 | 68cd340 | Deadlock: missing _destroy() on higher term | CRITICAL |
| H-R2 | 43f9dcd | Deadlock: forgotten bthread_id unlock in install_snapshot | CRITICAL |
| H-R3 | 247d5cc | Missing bthread_id unlock in _continue_sending | CRITICAL |
| H-R4 | 902cc43 | State not pre-set to INSTALLING_SNAPSHOT | HIGH |
| H-R5 | 643f0d7 | Pipeline + readonly race | HIGH |
| H-R6 | b24858c | Duplicate install_snapshot triggers reader assert | HIGH |
| H-R7 | 42cfd9a | Node reference leak during step_down | HIGH |

### Node / Election (7 commits)

| ID | Commit | Summary | Severity |
|----|--------|---------|----------|
| H-N1 | b9e1293 | handle_timeout_now_request use-after-free | CRITICAL |
| H-N2 | d23dd8c | Follower lease blocks election | HIGH |
| H-N3 | 740908b | grant_self timer race triggers CHECK core | CRITICAL |
| H-N4 | 3300a83 | Duplicate Node removal removes wrong node | HIGH |

### Snapshot (2 commits)

| ID | Commit | Summary | Severity |
|----|--------|---------|----------|
| H-S1 | 5204e09 | Snapshot transfer read size error | CRITICAL |
| H-S2 | d8e4e21 | Writer close failure not propagated | CRITICAL |

### Log Manager (4 commits)

| ID | Commit | Summary | Severity |
|----|--------|---------|----------|
| H-L1 | 10cd9e3 | Log truncation order violates crash safety | CRITICAL |
| H-L2 | 5dd342f | get_term() crash on stale index | CRITICAL |
| H-L3 | 04092b2 | disk_id.term zero after empty storage init | HIGH |
| H-L4 | bd2387a | Config entry not synced immediately | HIGH |

### Other (3 commits)

| ID | Commit | Summary | Severity |
|----|--------|---------|----------|
| H-O1 | a15f5a4 | on_configuration_committed condition inverted | HIGH |
| H-O2 | 382441b | max_committed_index not updated in batch processing | HIGH |
| H-O3 | efa0712 | Concurrent Raft Group creation coredump | HIGH |

---

## IV. Open Community Issues

Issues reported by the community but not yet fixed.

| Issue | Title | Severity | Our relevance |
|-------|-------|----------|---------------|
| #462/#461 | Snapshot error masking -> unrecoverable data loss | CRITICAL | Found via code analysis |
| #407 | Joint consensus restart deadlock | HIGH | Modelable with MC-bug4 |
| #365/#366 | Leader grants PreVote to rebooted node | HIGH | Bug-MC-1 |
| #492 | Leader doesn't check leader_lease on PreVote | HIGH | Bug-MC-1 |
| #405/#406 | Follower lease not renewed after voting | MEDIUM-HIGH | Known issue |
| #465 | Election timer not reset after step_down | MEDIUM | Known issue |
| #371 | Config entry data loss with raft_sync disabled | HIGH | Code analysis |
| #323 | Deadlock during step_down under high concurrency | MEDIUM-HIGH | Not modelable (impl-level concurrency) |
| #309 | NodeImpl/LogManager lock ordering violation | MEDIUM-HIGH | Not modelable (impl-level concurrency) |
| #498 | list_peers returns wrong config during reconfiguration | MEDIUM | Code analysis |
| #494 | Follower with cleared data doesn't trigger snapshot fetch | MEDIUM | Code analysis |

---

## V. Developer Signals (TODO/FIXME)

| Location | Signal | Related Bug |
|----------|--------|-------------|
| `ballot_box.cpp:79` | "not well proved right now" | New bug #6 (recorded) |
| `node.cpp:1848` | `// TODO report error` | Bug-CA-5 |
| `node.cpp:1737,1841,2269` | `// TODO: outof lock` | Performance, not safety |
| `log_manager.cpp:551` | `// FIXME: it's buggy` | Lock-free read of _disk_id |
| `snapshot_executor.cpp:268` | `// FIXME: race with set_peer` | Snapshot/config race |
| `ballot_box.cpp:52` | `// FIXME: critical section unacceptable` | Performance bottleneck |

---

## VI. Summary

| Discovery method | Count | Notes |
|-----------------|-------|-------|
| TLC model checking (pending) | 1 (Bug-MC-2) | 3 others already recorded in tracker |
| Code analysis (pending) | 3 (CA-4, CA-5, CA-6) | CA-2/CA-3 were known issues, not our discovery |
| Historical fixed bugs (H-*) | 18 | Shows systemic weaknesses |
| Open community issues | 11 | Includes 1 CRITICAL |
| Developer TODO/FIXME | 6 | 2 directly related to confirmed bugs |

**Recorded in tracker:**
- Known bug #3: Bug-MC-1 (Leader Lease PreVote Asymmetry)
- New bug #6: Bug-MC-4 (Config Change Force-Commit)
- New bug #7: Bug-MC-3 (elect_self persist failure)

---

## Review Log

| Bug ID | Verdict | Date | Notes |
|--------|---------|------|-------|
| Bug-MC-2 | NOT_A_BUG | 2026-03-05 | Intentional design ("Let heartbeat do step down"), not an oversight. Heartbeat provides fallback term check. TLC counterexample based on modeling bias (spec updates leaderContact but code does not). No community reports. |
| Bug-CA-1 | NOT_A_BUG | 2026-03-05 | term > leader.term impossible in successful response: follower has already check_step_down'd to request.term. Term mismatch can only be response.term < leader.term (pre-set race), which doesn't require step_down. Code is correct. |
| Bug-CA-4 | NOT_A_BUG | 2026-03-05 | get_term_and_votedfor() has full reconciliation logic (raft_meta.cpp:294-397): detects inconsistency on restart and fixes using the newer value. Write order file->LevelDB ensures correct reconciliation direction. |
| Bug-CA-5 | DUPLICATE | 2026-03-05 | Same Bug Family as MC-3 (New bug #7, Non-Atomic Persistence). Another trigger path via step_down(), not an independent bug. |
| Bug-CA-6 | NOT_A_BUG | 2026-03-05 | Initiator has _conf.contains check (node.cpp:1666). Receiver not checking is standard Raft behavior: old members participating in elections before new config commits is correct; after new config commits, removed node cannot form quorum. |
