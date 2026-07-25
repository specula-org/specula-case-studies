# MongoDB Distributed Transaction Bug Reproduction

Reproduction tests for 4 bugs found via TLA+ model checking of MongoDB's
distributed transaction (2PC) protocol.

## Target Version

MongoDB **8.0.12** — chosen because:
- Bug 1 (SERVER-105751): Fixed in 8.0.13 → 8.0.12 is **vulnerable**
- Bug 4 (SERVER-106075): Fixed in 8.0.16 → 8.0.12 is **vulnerable**
- Bug 2 (stale cache): Defense-in-depth test (shard version checks present)
- Bug 3 (SERVER-66067): Fixed pre-8.0, included for completeness

## Prerequisites

- Docker and Docker Compose
- Python 3 with `pymongo` (`pip install pymongo`)

## Running

```bash
# Run all tests
bash run_all.sh

# Or run individually:
docker compose up -d
sleep 5
bash init_cluster.sh
python3 test_bug1_session_reaper.py
python3 test_bug4_coordinator_failover.py
```

## Test Descriptions

### Bug 1: Session Reaper Destroys Prepared Transaction (SERVER-105751)

**MC counterexample**: 26 states, MCReaperSafety violated.

The session reaper can destroy a TransactionParticipant holding a prepared
transaction. The destructor aborts the prepared write. The coordinator treats
NoSuchTransaction as success → torn cross-shard commit.

**Test approach**:
1. Start a multi-shard transaction (writes to shard1 and shard2)
2. Use `hangBeforeSendingCommitDecision` failpoint to pause after prepare
3. Force session reaper via `refreshLogicalSessionCacheNow` / `killSessions`
4. Release failpoint, check for torn commit (one shard committed, other lost)

### Bug 2: Stale Router Cache After Chunk Migration

**MC counterexample**: 11 states, MCRoutingConsistency violated.

After chunk migration, the router's cached catalog is stale. Writes go to the
wrong shard. The shard version check (StaleConfigException) should catch this,
but has been bypassed historically (SERVER-71219, SERVER-78050, SERVER-89529).

**Test approach**:
1. Set up a range-sharded collection with known chunk distribution
2. Migrate a chunk while a mongos connection has cached the old routing
3. Immediately write to the migrated key — check if StaleConfigException fires

### Bug 3: Router Abort Races with 2PC Commit (SERVER-66067)

**MC counterexample**: 32 states, MCTwoPCAtomicity violated.

The router's implicitAbort() sends a best-effort abort without coordinating
with the 2PC coordinator. The abort can arrive after the coordinator has
committed → torn cross-shard commit.

**Test approach**:
1. Start a multi-shard transaction
2. Use failpoint to pause coordinator during 2PC
3. Kill the session from a separate connection (simulates implicitAbort)
4. Release failpoint, check if commit and abort race

### Bug 4: Coordinator Failover Atomicity Violation

**MC counterexample**: 29 states, MCTwoPCAtomicity violated.

After coordinator failover, recovery re-adds the transaction to shardTxns but
NOT to shardPreparedTxns. A spontaneous abort can fire in the window before
re-prepare. The coordinator then commits despite the abort → torn commit.

**Test approach**:
1. Start a multi-shard transaction, let it reach prepared state
2. Stop shard2 (participant), then shard1 (coordinator) — double crash
3. Restart both shards
4. Check if the transaction recovers consistently

## Expected Results

| Bug | Expected on 8.0.12 | Reason |
|-----|---------------------|--------|
| Bug 1 | Possible reproduction | 8.0.12 < 8.0.13 (fix version) |
| Bug 2 | Safeguard catches it | Shard version checks present |
| Bug 3 | No reproduction | Fixed pre-8.0 |
| Bug 4 | Possible reproduction | 8.0.12 < 8.0.16 (fix version) |

## Notes on Reproduction Difficulty

These are distributed concurrency bugs with narrow race windows. Even on
vulnerable versions, reproduction requires precise timing alignment:

- **Bug 1**: The session reaper must fire during the 2PC prepare-to-commit
  window. We lower `logicalSessionRefreshMillis` to 5s and use failpoints
  to widen the window.

- **Bug 4**: Requires both coordinator and participant to crash in the right
  order, then recovery to race with spontaneous abort. The failpoint widens
  the window, but the crash/restart introduces non-determinism.

If tests don't reproduce, this does NOT mean the bugs are false positives —
the MC counterexamples provide formal proof. The race windows may simply be
too narrow to hit reliably in a real system test.
