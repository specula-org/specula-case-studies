---- MODULE MC ----
\* Model checking wrapper for base.tla
\* Counter-bounds fault-injection actions (DDLFailover, stale error retry).
\* Does NOT bound deterministic/reactive actions (ShardResponse, RouterHandleOK, etc.).

EXTENDS base

\* Counter limits — overridden in .cfg files
CONSTANTS
    MaxDDLFailoverLimit,    \* Bug Family 1: DDL failover events
    MaxStaleRetryLimit,     \* Bug Family 4: stale error retry events
    MaxDDLCreateLimit,      \* DDL create operations (tracked + untracked)
    MaxDDLDropLimit,        \* DDL drop operations
    MaxDDLRenameLimit,      \* DDL rename operations
    MaxDDLMoveLimit,        \* DDL movePrimary operations
    MaxAnnotateDBLimit      \* Bug Family 3: database creation annotations

\* Counter variables
VARIABLE faultCounters

\* Fault counter fields
fcDDLFailover   == faultCounters.ddlFailover
fcStaleRetry    == faultCounters.staleRetry
fcDDLCreate     == faultCounters.ddlCreate
fcDDLDrop       == faultCounters.ddlDrop
fcDDLRename     == faultCounters.ddlRename
fcDDLMove       == faultCounters.ddlMove
fcAnnotateDB    == faultCounters.annotateDB

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

\* ===========================================================================
\* Counter-Bounded Wrappers
\* ===========================================================================

\* --- Fault injection actions (bounded) ---

MCDDLFailover(ns) ==
    /\ fcDDLFailover < MaxDDLFailoverLimit
    /\ DDLFailover(ns)
    /\ faultCounters' = [faultCounters EXCEPT !.ddlFailover = @ + 1]

MCMovePrimaryFailover ==
    /\ fcDDLFailover < MaxDDLFailoverLimit
    /\ MovePrimaryFailover
    /\ faultCounters' = [faultCounters EXCEPT !.ddlFailover = @ + 1]

MCStaleRetry(t) ==
    /\ fcStaleRetry < MaxStaleRetryLimit
    /\ RouterReceiveStaleError(t)
    /\ faultCounters' = [faultCounters EXCEPT !.staleRetry = @ + 1]

\* --- DDL initiation actions (bounded to control state space) ---

MCCreateTrackedAcquireLock(ns) ==
    /\ fcDDLCreate < MaxDDLCreateLimit
    /\ CreateTrackedAcquireLock(ns)
    /\ faultCounters' = [faultCounters EXCEPT !.ddlCreate = @ + 1]

MCCreateUntrackedAcquireLock(ns) ==
    /\ fcDDLCreate < MaxDDLCreateLimit
    /\ CreateUntrackedAcquireLock(ns)
    /\ faultCounters' = [faultCounters EXCEPT !.ddlCreate = @ + 1]

MCDropAcquireLock(ns, type) ==
    /\ fcDDLDrop < MaxDDLDropLimit
    /\ DropAcquireLock(ns, type)
    /\ faultCounters' = [faultCounters EXCEPT !.ddlDrop = @ + 1]

MCRenameAcquireLock(from, to, type) ==
    /\ fcDDLRename < MaxDDLRenameLimit
    /\ RenameAcquireLock(from, to, type)
    /\ faultCounters' = [faultCounters EXCEPT !.ddlRename = @ + 1]

MCMovePrimaryAcquireLock(toShard) ==
    /\ fcDDLMove < MaxDDLMoveLimit
    /\ MovePrimaryAcquireLock(toShard)
    /\ faultCounters' = [faultCounters EXCEPT !.ddlMove = @ + 1]

MCAnnotateCreatedDatabase(t, dbName) ==
    /\ fcAnnotateDB < MaxAnnotateDBLimit
    /\ RouterAnnotateCreatedDatabase(t, dbName)
    /\ faultCounters' = [faultCounters EXCEPT !.annotateDB = @ + 1]

\* --- Unconstrained (reactive/deterministic) actions ---

MCRouterSendTxnStmt(t, ns) ==
    /\ RouterSendTxnStmt(t, ns) /\ UNCHANGED faultVars

MCRouterHandleAbort(t, stm) ==
    /\ RouterHandleAbort(t, stm) /\ UNCHANGED faultVars

MCRouterHandleOK(t, stm) ==
    /\ RouterHandleOK(t, stm) /\ UNCHANGED faultVars

MCRouterSendCommit(t) ==
    /\ RouterSendCommit(t) /\ UNCHANGED faultVars

MCRouterRetryFirstStatement(t, ns) ==
    /\ RouterRetryFirstStatement(t, ns) /\ UNCHANGED faultVars

MCShardResponse(self, t) ==
    /\ ShardResponse(self, t) /\ UNCHANGED faultVars

\* --- DDL phase progression (unconstrained — reactive) ---

MCCreateTrackedEnterCS(ns) ==
    /\ CreateTrackedEnterCS(ns) /\ UNCHANGED faultVars

MCCreateTrackedCommitMetadata(ns, d) ==
    /\ CreateTrackedCommitMetadata(ns, d) /\ UNCHANGED faultVars

MCCreateTrackedExitCS(ns) ==
    /\ CreateTrackedExitCS(ns) /\ UNCHANGED faultVars

MCCreateUntrackedCommit(ns) ==
    /\ CreateUntrackedCommit(ns) /\ UNCHANGED faultVars

MCDropEnterCS(ns) ==
    /\ DropEnterCS(ns) /\ UNCHANGED faultVars

MCDropCommitMetadata(ns) ==
    /\ DropCommitMetadata(ns) /\ UNCHANGED faultVars

MCDropExitCS(ns) ==
    /\ DropExitCS(ns) /\ UNCHANGED faultVars

MCRenameEnterCS(ns) ==
    /\ RenameEnterCS(ns) /\ UNCHANGED faultVars

MCRenameCommitMetadata(ns) ==
    /\ RenameCommitMetadata(ns) /\ UNCHANGED faultVars

MCRenameExitCS(ns) ==
    /\ RenameExitCS(ns) /\ UNCHANGED faultVars

MCMovePrimaryEnterCS(to) ==
    /\ MovePrimaryEnterCS(to) /\ UNCHANGED faultVars

MCMovePrimaryCommitMetadata(to) ==
    /\ MovePrimaryCommitMetadata(to) /\ UNCHANGED faultVars

MCMovePrimaryExitCS(to) ==
    /\ MovePrimaryExitCS(to) /\ UNCHANGED faultVars

\* ===========================================================================
\* MCInit / MCNext
\* ===========================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
          ddlFailover |-> 0,
          staleRetry  |-> 0,
          ddlCreate   |-> 0,
          ddlDrop     |-> 0,
          ddlRename   |-> 0,
          ddlMove     |-> 0,
          annotateDB  |-> 0
       ]

MCNext ==
    \* Router actions (unconstrained)
    \/ \E t \in Txns, ns \in NameSpaces : MCRouterSendTxnStmt(t, ns)
    \/ \E t \in Txns, stm \in Stmts : MCRouterHandleAbort(t, stm)
    \/ \E t \in Txns, stm \in Stmts : MCRouterHandleOK(t, stm)
    \/ \E t \in Txns : MCRouterSendCommit(t)
    \/ \E t \in Txns, ns \in NameSpaces : MCRouterRetryFirstStatement(t, ns)
    \* Shard actions (unconstrained)
    \/ \E s \in Shards, t \in Txns : MCShardResponse(s, t)
    \* DDL initiation (bounded)
    \/ \E ns \in NameSpaces : MCCreateTrackedAcquireLock(ns)
    \/ \E ns \in NameSpaces : MCCreateUntrackedAcquireLock(ns)
    \/ \E ns \in NameSpaces : MCDropAcquireLock(ns, TRACKED)
    \/ \E ns \in NameSpaces : MCDropAcquireLock(ns, UNTRACKED)
    \/ \E from, to \in NameSpaces : MCRenameAcquireLock(from, to, TRACKED)
    \/ \E from, to \in NameSpaces : MCRenameAcquireLock(from, to, UNTRACKED)
    \/ \E to \in Shards : MCMovePrimaryAcquireLock(to)
    \* DDL phase progression (unconstrained)
    \/ \E ns \in NameSpaces : MCCreateTrackedEnterCS(ns)
    \/ \E ns \in NameSpaces, d \in ValidDataDistributions : MCCreateTrackedCommitMetadata(ns, d)
    \/ \E ns \in NameSpaces : MCCreateTrackedExitCS(ns)
    \/ \E ns \in NameSpaces : MCCreateUntrackedCommit(ns)
    \/ \E ns \in NameSpaces : MCDropEnterCS(ns)
    \/ \E ns \in NameSpaces : MCDropCommitMetadata(ns)
    \/ \E ns \in NameSpaces : MCDropExitCS(ns)
    \/ \E ns \in NameSpaces : MCRenameEnterCS(ns)
    \/ \E ns \in NameSpaces : MCRenameCommitMetadata(ns)
    \/ \E ns \in NameSpaces : MCRenameExitCS(ns)
    \/ \E to \in Shards : MCMovePrimaryEnterCS(to)
    \/ \E to \in Shards : MCMovePrimaryCommitMetadata(to)
    \/ \E to \in Shards : MCMovePrimaryExitCS(to)
    \* Fault injection (bounded)
    \/ \E ns \in NameSpaces : MCDDLFailover(ns)
    \/ MCMovePrimaryFailover
    \/ \E t \in Txns : MCStaleRetry(t)
    \/ \E t \in Txns, dbName \in DatabaseNames : MCAnnotateCreatedDatabase(t, dbName)
    \* Termination
    \/ (\A t \in Txns : rCompletedStmt[t] = TXN_STMTS /\ UNCHANGED mcVars)

\* ===========================================================================
\* Symmetry
\* ===========================================================================

ModelSymmetry == Permutations(Shards)

\* ===========================================================================
\* State Constraint
\* ===========================================================================

\* Bound cluster time to prevent infinite state space
MCStateConstraint ==
    clusterTime <= INITIAL_CLUSTER_TIME + 8

\* ===========================================================================
\* Structural Invariants
\* ===========================================================================

\* All invariants from base, plus:

\* Fault counters are non-negative and bounded
FaultCountersBounded ==
    /\ fcDDLFailover >= 0 /\ fcDDLFailover <= MaxDDLFailoverLimit
    /\ fcStaleRetry >= 0  /\ fcStaleRetry <= MaxStaleRetryLimit
    /\ fcDDLCreate >= 0   /\ fcDDLCreate <= MaxDDLCreateLimit
    /\ fcDDLDrop >= 0     /\ fcDDLDrop <= MaxDDLDropLimit
    /\ fcDDLRename >= 0   /\ fcDDLRename <= MaxDDLRenameLimit
    /\ fcDDLMove >= 0     /\ fcDDLMove <= MaxDDLMoveLimit
    /\ fcAnnotateDB >= 0  /\ fcAnnotateDB <= MaxAnnotateDBLimit

====
