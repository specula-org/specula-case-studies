# Changelog: MongoDB TxnsCollectionIncarnation Spec Validation

## Round 1 - Trace Validation

- [fix] RouterSendTxnStmt: added nondeterministic rDatabaseCache refresh to model gossip/background cache update. Without this, after MovePrimary the router's stale database cache routed to the wrong shard. (Trace: move_primary_txn.ndjson)
- [fix] TxnStmtLogEntries: changed dbVersion and OwnershipFromCacheEntry to use primed rDatabaseCache' (post-refresh value) instead of unprimed. Also parameterized OwnershipFromCacheEntry to take dbCache argument. (Trace: move_primary_txn.ndjson)
- [fix] RouterRetryFirstStatement: same nondeterministic rDatabaseCache refresh + primed value usage. (Trace: consistency fix)
- [fix] move_primary_txn.ndjson: prepended CreateUntrackedAcquireLock+CreateUntrackedCommit events that were missing from harness capture. MovePrimary requires collection to exist. (Trace: move_primary_txn.ndjson)
- All 4 traces pass (basic_create_txn: 67 states, move_primary_txn: 20 states, both client traces: 14 states)

## Round 1 - Model Checking

- No violations. 9.4M states generated, 3.4M distinct, depth 28, 19 seconds.
- Structural invariants all pass.

## Round 2 - Trace Validation (regression check after hunting fixes)

- All traces still pass after spec fixes from bug hunting analysis.

## Round 2 - Model Checking

- [fix-inv] NoOrphanedCriticalSection: added rename-target exception — rename target ns has CS but DDL phase is managed by source ns (Case A: invariant too strong)
- [fix-spec] DDL_CREATE split into DDL_CREATE_TRACKED and DDL_CREATE_UNTRACKED — prevents mixing tracked/untracked create phases (Case B: spec issue)
- [fix-spec] All DDL AcquireLock actions: added `~ddlLockHeld[ns]` guard — prevents starting DDL on a namespace whose lock is already held by another operation (Case B: spec issue)
- [fix-spec] All DDL AcquireLock actions: added `NoMovePrimaryInProgress` guard — models database-level DDL lock that prevents concurrent DDL during MovePrimary (Case B: spec issue)
- [fix-spec] DDLFailover: split into DDLFailover (non-MOVE types) + MovePrimaryFailover (atomic for all MOVE namespaces) — models MovePrimary as single coordinator (Case B: spec issue)
- [fix-spec] RouterReceiveStaleError: added `response` to UNCHANGED — variable assignment bug (spec error)
- [fix-spec] RouterHandleOK: changed `\E rsp : rsp.status = OK` to `\A rsp : rsp.status = OK` — must check ALL responses are OK (Case B: spec issue)
- [fix-spec] RouterHandleOK: added `rRetryState[t] # "pending"` — prevent handling OK while stale retry is pending (Case B: spec issue)
- 5.6M states, depth 28, no violations.

## Result

Converged in 2 rounds (5 iterations total). Bug hunting: 0 bugs found across all 5 families (~723M states total).
