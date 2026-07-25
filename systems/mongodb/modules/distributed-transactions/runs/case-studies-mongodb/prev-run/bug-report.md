# Bug Report — MongoDB Distributed Transactions

## Summary

- Bug families tested: 5 (restart/failover, session reaper, chunk migration, abort path, combined)
- Bugs found: 4
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family4.cfg, MC_hunt_family6.cfg, MC_hunt_combined.cfg

---

## Bug 1: Session Reaper Destroys Prepared Transaction (SERVER-105751)

- **Bug Family**: Family 2 (Session reaper)
- **Severity**: Critical
- **Invariant violated**: MCReaperSafety
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 26 states (output/MC_hunt_family2.out)

### Trace Summary

1. Transaction t2 starts on router, writes to both s1 and s2
2. Router initiates 2PC: coordinator (s2) sends prepare to both shards
3. Both shards prepare (shardPreparedTxns includes t2)
4. Coordinator collects votes and writes abort decision (coordDoc.state = "abort")
5. **MCReapPreparedSession(s2, t2)**: session reaper fires on s2, destroying the session holding t2's prepared transaction
6. t2 is aborted on s2 despite being prepared: `aborted[s2][t2] = TRUE`, `shardPreparedTxns[s2] = {}`

### Root Cause

The session reaper timer fires asynchronously. In router mode, the reaper can destroy a `TransactionParticipant` that holds a prepared transaction. The destructor implicitly aborts the prepared write. When the coordinator later sends the commit/abort message, the shard returns `NoSuchTransaction`, which the coordinator treats as success — causing a torn cross-shard commit if the other shard committed.

### Affected Code

- `src/mongo/db/session/session_catalog.cpp`: session reaping callback — no guard against prepared transactions
- `src/mongo/db/s/transaction_coordinator_util.cpp:~951`: error classification treats NoSuchTransaction as success

### Recommendation

Add a guard in the session reaper to skip sessions with prepared transactions. Alternatively, make the `TransactionParticipant` destructor check for prepared state before aborting.

---

## Bug 2: Stale Router Cache After Chunk Migration

- **Bug Family**: Family 4 (Chunk migration)
- **Severity**: High
- **Invariant violated**: MCRoutingConsistency
- **Config**: MC_hunt_family4.cfg
- **Counterexample**: 11 states (output/MC_hunt_family4.out)

### Trace Summary

1. Initial catalog: k1→s1, k2→s2
2. **MoveKey(k1, s1, s2)**: chunk migration moves k1 from s1 to s2. Ground-truth catalog updates (k1→s2), but router's cached catalog (rCatalog) is stale: k1→s1
3. Transaction t2 starts, router routes k1 write to s1 (stale cache)
4. t2 writes k1 on s1 and commits via single-shard commit
5. **Violation**: t2 committed write to k1 on s1, but catalog says k1 is now on s2

### Root Cause

The router caches the chunk-to-shard mapping. After a migration, the router doesn't immediately learn about the new ownership. A transaction that starts after migration but before cache refresh writes to the wrong shard. The write succeeds on the old shard but is invisible to readers that go to the new shard.

### Affected Code

- `src/mongo/db/s/migration_chunk_cloner_source.cpp`: migration doesn't invalidate router cache
- `src/mongo/s/transaction_router.cpp`: routing uses stale rCatalog

### Recommendation

This is a known class of issues (SERVER-71219, SERVER-78050, SERVER-89529). Mitigations include version-based routing (StaleConfigException), placement conflict detection, and migration-aware transaction retries.

---

## Bug 3: Router Abort Races with 2PC Commit (SERVER-66067)

- **Bug Family**: Family 6 (Abort path)
- **Severity**: Critical
- **Invariant violated**: MCTwoPCAtomicity
- **Config**: MC_hunt_family6.cfg
- **Counterexample**: 32 states (output/MC_hunt_family6.out)

### Trace Summary

1. Transaction t1 starts, writes to s1 and s2 (multi-shard)
2. **RouterTxnAbort(r1, t1)** fires at state 4: router sends best-effort abort to participant s2
3. Despite the abort, t1 continues through 2PC on a different path:
   - Coordinator collects votes, writes commit decision (coordDoc.state = "commit", commitTs = 2)
4. The abort message reaches s2 via ShardTxnRecvAbort, aborting t1 on s2
5. **Violation**: coordDoc says "commit" with commitTs=2 for t1, but `aborted[s2][t1] = TRUE`
6. s1 will see the commit message and commit, but s2 has already aborted — torn commit

### Root Cause

The router's `implicitAbort()` sends a best-effort abort to participants without coordinating with the 2PC coordinator. The abort message can arrive at a participant shard after the coordinator has already collected all votes and persisted the commit decision. This creates a race: the participant aborts the prepared transaction, but the coordinator has already committed.

### Affected Code

- `src/mongo/s/transaction_router.cpp:~1400`: `TransactionRouter::implicitAbort()` sends abort without checking 2PC state
- `src/mongo/db/transaction/transaction_participant.cpp`: abort path doesn't check for committed coordDoc

### Recommendation

The abort command at the shard level should check whether a commit decision has been persisted for this transaction. If a commit decision exists, the abort should be rejected.

---

## Bug 4: 2PC Atomicity Violation Under Coordinator Failover

- **Bug Family**: Family 1 (Coordinator crash/failover)
- **Severity**: Critical
- **Invariant violated**: MCTwoPCAtomicity
- **Config**: MC_hunt_family1.cfg
- **Counterexample**: 29 states (output/MC_hunt_family1.out)

### Trace Summary

1. Transaction t2 starts, writes to both s1 and s2 (multi-shard)
2. 2PC proceeds: coordinator (s1) collects votes, writes commit decision (coordDoc.state = "commit", commitTs = 2)
3. **Restart(s2)** at state 20: shard s2 crashes, clearing in-memory state
4. **Restart(s1)** at state 21: coordinator s1 crashes, clearing in-memory state
5. CoordinatorRecover: coordinator recovers from persistent coordDoc, re-drives commit
6. However, during recovery, t2 on s1 gets aborted: `aborted[s1][t2] = TRUE`
7. **Violation**: coordDoc says "commit" for t2, but participant s1 has aborted

### Root Cause

After coordinator failover, the recovery process re-sends prepare/commit messages. However, the timing window between recovery and re-sending allows the transaction to be aborted on the coordinator's own shard (as a participant). The abort happens because the in-memory state was cleared by restart, and the transaction is treated as a new/unknown transaction that can be spontaneously aborted.

### Affected Code

- `src/mongo/db/s/transaction_coordinator_service.cpp:~300`: `_scheduleRecoveryTask()` — recovery timing
- `src/mongo/db/transaction/transaction_participant.cpp`: abort of recovered transactions during 2PC

### Recommendation

After recovering a coordinator doc with "commit" state, the recovery process should protect participant transactions from abort by immediately restoring their in-memory state before any other operations can proceed.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Combined | MC_hunt_combined.cfg | 992 states, 55 traces | MCRoutingConsistency violated (same as Family 4, with restart + migration + reaper + abort) |

The combined config found the same MCRoutingConsistency violation (Family 4 type) with additional fault injection. No new bug families discovered beyond the 4 found by targeted configs.

---

## Spec Fixes During Hunting

- **Restart action**: Fixed txnSnapshots/shardOps preservation to use storage-level `prepared` field instead of in-memory `shardPreparedTxns`. This correctly handles consecutive restarts.
- **ShardTxnRePrepare action**: Added DOMAIN guard for `prepared` field to prevent TLC runtime error when accessing records that were reset after restart.
