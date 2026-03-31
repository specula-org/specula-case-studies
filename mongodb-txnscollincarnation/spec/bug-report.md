# Bug Report: MongoDB TxnsCollectionIncarnation

## Summary

- **Bug families tested**: 5
- **Bugs found**: 0
- **Configs run**: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family4.cfg, MC_hunt_family5.cfg
- **Total states explored**: ~723M (BFS)
- **Convergence**: 2 rounds (5 spec iterations)

## Not Reproduced

| Bug Family | Config | States | Invariants Checked | Result |
|-----------|--------|--------|-------------------|--------|
| Family 1: DDL Failover | MC_hunt_family1.cfg | 84.4M | DDLLockHeldDuringCommit, NoOrphanedCriticalSection, CommittedTxnImpliesConsistentKeySet | PASS |
| Family 2: DDL+Txn Interleaving | MC_hunt_family2.cfg | 315M | CommittedTxnConsistentKeySet, CommitSafeAfterStatements | PASS |
| Family 3: createdDatabases Bypass | MC_hunt_family3.cfg | 12.3M | NoCrossDatabaseBypassLeak, CommittedTxnImpliesConsistentKeySet | PASS |
| Family 4: Stale Error Retry | MC_hunt_family4.cfg | 7.9M | PlacementConflictTimeMonotonicity, CommittedTxnConsistentKeySet | PASS |
| Family 5: Commit Without Validation | MC_hunt_family5.cfg | 302.7M | CommitSafeAfterStatements, CommittedTxnConsistentKeySet | PASS |

### Analysis

**Family 1 (DDL Failover)**: With 2 failover events, 2 creates, 2 drops, 1 rename, and 1 movePrimary, the multi-phase DDL model with failover recovery/abort correctly preserves DDL lock and critical section consistency. The atomic MovePrimary failover (all-or-nothing) prevents partial moves that could leave orphaned data.

**Family 2 (DDL+Txn Interleaving)**: The critical section mechanism correctly blocks shard responses during DDL commit phases, preventing DDL from interleaving with active transaction statement processing. The separate commit step (RouterSendCommit) also passes — snapshot isolation at the shard level prevents the commit from seeing post-DDL state. 315M states is the deepest exploration (depth 34), covering many DDL/txn interleaving orderings.

**Family 3 (createdDatabases Bypass)**: With 2 databases modeled (db1, db2) and per-database bypass checking, no cross-database bypass leak was found. The new path (`std::ranges::find(createdDatabases, dbName)`) correctly scopes the bypass to only the database that was created.

**Family 4 (Stale Error Retry)**: The reset-and-retry protocol is safe: after resetting placementConflictTime on stale error, the fresh timestamp from VectorClock captures any DDL that committed. PlacementConflictTimeMonotonicity and CommittedTxnConsistentKeySet both hold.

**Family 5 (Commit Without Validation)**: The design assumption holds: snapshot isolation + shard-side locks protect data consistency even though the commit step does not re-check placement. This is the largest state space (302.7M states) since it allows the most DDL operations (3 creates, 2 drops, 1 rename, 1 movePrimary) to exercise all DDL/commit interleavings.

## Spec Fixes During Convergence

The following spec issues were discovered and fixed during the convergence loop (not real bugs — spec modeling improvements):

1. **DDL_CREATE split**: Tracked and untracked creates share DDL_CREATE type, allowing phase mixing. Split into DDL_CREATE_TRACKED and DDL_CREATE_UNTRACKED.

2. **DDL lock guard**: AcquireLock actions didn't check `ddlLockHeld[ns]`, allowing concurrent DDL on namespaces locked by rename. Added `~ddlLockHeld[ns]` guard.

3. **Database-level DDL lock**: MovePrimary holds a database-level DDL lock, blocking all other DDL. Added `NoMovePrimaryInProgress` guard to all DDL initiation actions.

4. **MovePrimary atomic failover**: DDLFailover operated per-namespace, but MovePrimary is a single coordinator. Added `MovePrimaryFailover` that atomically fails over all MOVE namespaces.

5. **RouterHandleOK guards**: Required only ONE OK response (should be ALL). Also allowed firing during pending stale retry. Fixed both.

6. **RouterReceiveStaleError**: Missing `response` in UNCHANGED clause.

7. **Router database cache refresh**: Added nondeterministic `rDatabaseCache' = databaseMetadata` to model gossip/background refresh.

8. **NoOrphanedCriticalSection invariant**: Didn't account for rename targets. Added exception for namespaces that are rename targets.
