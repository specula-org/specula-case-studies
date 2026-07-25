--------------------------- MODULE MC ---------------------------------
(*
 * Model checking wrapper for MongoDB distributed transactions.
 * Adds counter-bounded fault injection for:
 *   - Shard restart (Family 1)
 *   - Chunk migration (Family 4)
 *   - Session reaper (Family 2)
 *   - Router abort (Family 6)
 *)
EXTENDS base

\* Counter bounds for fault injection actions.
CONSTANTS MaxRestarts, MaxMoveKeys, MaxReaps, MaxRouterAborts, MaxOpsPerTxn

VARIABLES restartCount, moveKeyCount, reapCount, routerAbortCount

faultVars == <<restartCount, moveKeyCount, reapCount, routerAbortCount>>
allVars == <<vars, faultVars>>

KeysOwnedByShard(s) == { k \in Keys : catalog[k] = s }

\* Prevents cases where all keys are distributed to a single shard.
InitCatalogConstraint ==
    /\ (Cardinality(Shard) > 1) => \A s \in Shard : Cardinality(KeysOwnedByShard(s)) < Cardinality(Keys)

MCInit ==
    /\ Init
    /\ InitCatalogConstraint
    /\ restartCount = 0
    /\ moveKeyCount = 0
    /\ reapCount = 0
    /\ routerAbortCount = 0

\* --- Counter-bounded fault injection ---

MCRestart(s) ==
    /\ restartCount < MaxRestarts
    /\ Restart(s)
    /\ restartCount' = restartCount + 1
    /\ UNCHANGED <<moveKeyCount, reapCount, routerAbortCount>>

MCMoveKey(k, sfrom, sto) ==
    /\ moveKeyCount < MaxMoveKeys
    /\ MoveKey(k, sfrom, sto)
    /\ moveKeyCount' = moveKeyCount + 1
    /\ UNCHANGED <<restartCount, reapCount, routerAbortCount>>

MCReapPreparedSession(s, tid) ==
    /\ reapCount < MaxReaps
    /\ ReapPreparedSession(s, tid)
    /\ reapCount' = reapCount + 1
    /\ UNCHANGED <<restartCount, moveKeyCount, routerAbortCount>>

MCRouterTxnAbort(r, tid) ==
    /\ routerAbortCount < MaxRouterAborts
    /\ RouterTxnAbort(r, tid)
    /\ routerAbortCount' = routerAbortCount + 1
    /\ UNCHANGED <<restartCount, moveKeyCount, reapCount>>

\* --- Next state relation ---
\* Deterministic/reactive actions pass through with UNCHANGED faultVars.
\* Fault injection actions are counter-bounded.

MCNext ==
    \* Router actions (not bounded — reactive).
    \/ \E r \in Router, t \in TxId, ts \in Timestamps : RouterTxnStart(r, t, ts) /\ UNCHANGED faultVars
    \/ \E r \in Router, s \in Shard, t \in TxId, k \in Keys, op \in Ops : RouterTxnOp(r, s, t, k, op) /\ UNCHANGED faultVars
    \/ \E r \in Router, s \in Shard, t \in TxId, op \in Ops : RouterTxnCoordinateCommit(r, s, t, op) /\ UNCHANGED faultVars
    \/ \E r \in Router, s \in Shard, t \in TxId : RouterTxnCommitReadOnly(r, s, t) /\ UNCHANGED faultVars
    \/ \E r \in Router, s \in Shard, t \in TxId : RouterTxnCommitSingleShard(r, s, t) /\ UNCHANGED faultVars
    \/ \E r \in Router, t \in TxId : RouterTxnCommitSingleWriteShard(r, t) /\ UNCHANGED faultVars
    \* Shard transaction actions (not bounded — reactive).
    \/ \E s \in Shard, tid \in TxId : ShardTxnStart(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId, k \in Keys, v \in TxId \cup {NoValue} : ShardTxnRead(s, tid, k, v) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId, k \in Keys : ShardTxnWrite(s, tid, k) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnAbort(s, tid) /\ UNCHANGED faultVars
    \* Shard 2PC actions (not bounded — reactive).
    \/ \E s \in Shard, tid \in TxId : ShardTxnCoordinateCommit(s, tid) /\ UNCHANGED faultVars
    \/ \E s, from \in Shard, tid \in TxId : ShardTxnCoordinatorRecvCommitVote(s, tid, from) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnPrepare(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnRePrepare(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnCommit(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnCommitNoOp(s, tid) /\ UNCHANGED faultVars
    \* Coordinator doc lifecycle (not bounded — reactive).
    \/ \E s \in Shard, tid \in TxId : CoordinatorWriteCommitDecision(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : CoordinatorSendCommit(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : CoordinatorRecover(s, tid) /\ UNCHANGED faultVars
    \* Abort path (not bounded — reactive).
    \/ \E s \in Shard, tid \in TxId : CoordinatorWriteAbortDecision(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : CoordinatorSendAbort(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnRecvAbort(s, tid) /\ UNCHANGED faultVars
    \/ \E s \in Shard, tid \in TxId : ShardTxnRecvAbortNoOp(s, tid) /\ UNCHANGED faultVars
    \* --- Fault injection (counter-bounded) ---
    \/ \E s \in Shard : MCRestart(s)
    \/ \E k \in Keys, sfrom, sto \in Shard : MCMoveKey(k, sfrom, sto)
    \/ \E s \in Shard, tid \in TxId : MCReapPreparedSession(s, tid)
    \/ \E r \in Router, tid \in TxId : MCRouterTxnAbort(r, tid)

MCSpec == MCInit /\ [][MCNext]_allVars

\* --- State constraint ---

StateConstraint ==
    /\ \A t \in TxId, r \in Router : rtxn[r][t] <= MaxOpsPerTxn
    /\ MsgBufferConstraint(12)

\* --- Symmetry ---

MCSymmetry == Permutations(TxId) \cup Permutations(Keys)

\* --- Invariants (re-exported from base) ---

\* Standard safety.
MCSnapshotIsolation == SnapshotIsolation
MCReadCommittedIsolation == ReadCommittedIsolation

\* Extension invariants (one per bug family).
MCTwoPCAtomicity == TwoPCAtomicity
MCNoOrphanedPrepared == NoOrphanedPrepared
MCCoordinatorDocConsistency == CoordinatorDocConsistency
MCReaperSafety == ReaperSafety
MCRoutingConsistency == RoutingConsistency

=======================
