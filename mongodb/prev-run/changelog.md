# MongoDB Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] TraceInit: added TraceCatalogMap constraint to force initial catalog to match trace routing decisions. Without this, non-deterministic catalog initialization creates states incompatible with the trace, causing spurious deadlocks.
- [fix] Trace.tla: added SilentShardTxnWrite and SilentShardTxnRead — shard-level read/write execution is not separately traced (happens as part of the router command). The spec requires these to consume shardTxnReqs entries before commit/coordCommit can proceed.
- [fix] Trace.tla: added SilentShardTxnCoordinateCommit, SilentShardTxnPrepare, SilentShardTxnCoordinatorRecvCommitVote, SilentCoordinatorWriteCommitDecision, SilentCoordinatorSendCommit — the 2PC intermediate steps are not captured in trace logs. These fire silently between RouterTxnCoordinateCommit and ShardTxnCommit.
- Validated traces: basic_commit (8 events), abort (5 events), single_shard (5 events) — all pass.

## Round 1 - Model Checking
- [fix-spec] RouterTxnCommitSingleWriteShard: WriteParticipants was checking shard-side state (shardTxnReqs) which races with ShardTxnWrite — after one shard consumes its write, WriteParticipants shrinks and the router incorrectly uses single-write-shard optimization for a multi-write transaction. Fixed: replaced WriteParticipants(tid) with RouterWriteParticipants(r, tid) that uses router-side rParticipants. (Case B)
- BFS: MCSnapshotIsolation violated at 170M states (21-state trace). After fix: 697M states, 38M traces (simulation) — no violations.

## Round 2 - Trace Validation (regression check)
- All 3 traces pass after base spec change. No regressions.

## Bug Hunting
- [fix-spec] Restart: txnSnapshots preservation used in-memory shardPreparedTxns (cleared on restart) instead of durable storage state. After double restart, prepared snapshots were lost. Fixed: use `"prepared" \in DOMAIN txnSnapshots[s][t] /\ txnSnapshots[s][t].prepared`. Same fix applied to shardOps and ops preservation.
- [fix-spec] ShardTxnRePrepare: accessed .prepared field on records that might not have it (after restart resets snapshots). Added DOMAIN guard.
- [bug] Family 1: MCTwoPCAtomicity violated (29 states) — coordinator crash during 2PC commit window.
- [bug] Family 2: MCReaperSafety violated (26 states) — reaper destroys prepared session (SERVER-105751).
- [bug] Family 4: MCRoutingConsistency violated (11 states) — stale router cache after MoveKey.
- [bug] Family 6: MCTwoPCAtomicity violated (32 states) — router abort races with 2PC commit (SERVER-66067).

## Result
Converged in 2 rounds. Bug hunting: 4 bugs found across 5 configs.
