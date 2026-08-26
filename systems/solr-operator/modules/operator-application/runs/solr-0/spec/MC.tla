--------------------------- MODULE MC ---------------------------
(*
 * Model-checking spec for the Solr-Operator <-> Solr admin-API boundary.
 *
 * Wraps base.tla with counter-bounded fault-injection actions:
 *   - EvictAsyncEntry      (10k FIFO eviction of a terminal async response; S1)
 *   - SolrNodeDown/Up      (live_nodes churn; S3/S4)
 *   - PodReadyChange       (pod-ready != node-live; S3)
 *   - SolrFailAsync        (Solr returns a failed terminal result)
 *   - OperatorRestart      (crash between submit and observe; S1/S4/S5)
 *
 * Reactive / deterministic operator + Solr-async-progression actions pass
 * through unbounded (bounding them would prune the very interleavings that
 * expose the bugs).
 *)

EXTENDS base

\* Access original (un-overridden) base operator definitions.
solr == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxEvictLimit      \* max async FIFO evictions
CONSTANT MaxNodeChurnLimit  \* max SolrNodeDown+SolrNodeUp firings
CONSTANT MaxPodReadyLimit   \* max PodReadyChange firings
CONSTANT MaxFailLimit       \* max SolrFailAsync firings
CONSTANT MaxRestartLimit    \* max OperatorRestart firings
CONSTANT MaxStaleFetchLimit \* max lagged (under-reporting) CLUSTERSTATUS reads

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

MCEvictAsyncEntry(r) ==
    /\ faultCounters.evict < MaxEvictLimit
    /\ solr!EvictAsyncEntry(r)
    /\ faultCounters' = [faultCounters EXCEPT !.evict = @ + 1]

MCSolrNodeDown(n) ==
    /\ faultCounters.churn < MaxNodeChurnLimit
    /\ solr!SolrNodeDown(n)
    /\ faultCounters' = [faultCounters EXCEPT !.churn = @ + 1]

MCSolrNodeUp(n) ==
    /\ faultCounters.churn < MaxNodeChurnLimit
    /\ solr!SolrNodeUp(n)
    /\ faultCounters' = [faultCounters EXCEPT !.churn = @ + 1]

MCPodReadyChange(n) ==
    /\ faultCounters.podready < MaxPodReadyLimit
    /\ solr!PodReadyChange(n)
    /\ faultCounters' = [faultCounters EXCEPT !.podready = @ + 1]

MCSolrFailAsync(r) ==
    /\ faultCounters.fail < MaxFailLimit
    /\ solr!SolrFailAsync(r)
    /\ faultCounters' = [faultCounters EXCEPT !.fail = @ + 1]

MCOperatorRestart ==
    /\ faultCounters.restart < MaxRestartLimit
    /\ solr!OperatorRestart
    /\ faultCounters' = [faultCounters EXCEPT !.restart = @ + 1]

MCFetchClusterStatusStale ==
    /\ faultCounters.stalefetch < MaxStaleFetchLimit
    /\ solr!FetchClusterStatusStale
    /\ faultCounters' = [faultCounters EXCEPT !.stalefetch = @ + 1]

\* ============================================================================
\* UNBOUNDED (REACTIVE / DETERMINISTIC) ACTIONS
\* ============================================================================

MCSolrPickupAsync(r)   == solr!SolrPickupAsync(r)   /\ UNCHANGED faultVars
MCSolrCompleteAsync(r) == solr!SolrCompleteAsync(r) /\ UNCHANGED faultVars

MCFetchClusterStatus   == solr!FetchClusterStatus   /\ UNCHANGED faultVars
MCAcquireScaleDownLock == solr!AcquireScaleDownLock /\ UNCHANGED faultVars
MCAcquireBalanceLock   == solr!AcquireBalanceLock   /\ UNCHANGED faultVars

MCEvictSubmitReplaceNode  == solr!EvictSubmitReplaceNode  /\ UNCHANGED faultVars
MCEvictNoReplicasCanDelete == solr!EvictNoReplicasCanDelete /\ UNCHANGED faultVars
MCEvictCheckCompleted     == solr!EvictCheckCompleted     /\ UNCHANGED faultVars
MCEvictCheckFailed        == solr!EvictCheckFailed        /\ UNCHANGED faultVars
MCEvictCheckRunning       == solr!EvictCheckRunning       /\ UNCHANGED faultVars

MCBalanceSingleNodeShortcut == solr!BalanceSingleNodeShortcut /\ UNCHANGED faultVars
MCBalanceSubmit           == solr!BalanceSubmit           /\ UNCHANGED faultVars
MCBalanceCheckCompleted   == solr!BalanceCheckCompleted   /\ UNCHANGED faultVars
MCBalanceCheckFailed      == solr!BalanceCheckFailed      /\ UNCHANGED faultVars
MCBalanceCheckRunning     == solr!BalanceCheckRunning     /\ UNCHANGED faultVars

MCBackupStart == solr!BackupStart /\ UNCHANGED faultVars
MCBackupCheck == solr!BackupCheck /\ UNCHANGED faultVars

\* ============================================================================
\* INIT / NEXT
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [evict |-> 0, churn |-> 0, podready |-> 0,
                        fail |-> 0, restart |-> 0, stalefetch |-> 0]

MCNext ==
    \* --- Solr async progression (reactive) ---
    \/ \E r \in ReqIds : MCSolrPickupAsync(r)
    \/ \E r \in ReqIds : MCSolrCompleteAsync(r)
    \* --- Bounded faults ---
    \/ \E r \in ReqIds : MCSolrFailAsync(r)
    \/ \E r \in ReqIds : MCEvictAsyncEntry(r)
    \/ \E n \in Nodes : MCSolrNodeDown(n)
    \/ \E n \in Nodes : MCSolrNodeUp(n)
    \/ \E n \in Nodes : MCPodReadyChange(n)
    \/ MCOperatorRestart
    \/ MCFetchClusterStatusStale
    \* --- Operator (reactive/deterministic) ---
    \/ MCFetchClusterStatus
    \/ MCAcquireScaleDownLock
    \/ MCAcquireBalanceLock
    \/ MCEvictSubmitReplaceNode
    \/ MCEvictNoReplicasCanDelete
    \/ MCEvictCheckCompleted
    \/ MCEvictCheckFailed
    \/ MCEvictCheckRunning
    \/ MCBalanceSingleNodeShortcut
    \/ MCBalanceSubmit
    \/ MCBalanceCheckCompleted
    \/ MCBalanceCheckFailed
    \/ MCBalanceCheckRunning
    \/ MCBackupStart
    \/ MCBackupCheck

mc_vars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* Fair variant for liveness hunting (S1/S5). Weak fairness on all operator +
\* Solr-progression steps so that non-faulty progress is guaranteed to be taken.
MCFairSpec ==
    /\ MCInit
    /\ [][MCNext]_mc_vars
    /\ WF_mc_vars(\E r \in ReqIds : MCSolrPickupAsync(r))
    /\ WF_mc_vars(\E r \in ReqIds : MCSolrCompleteAsync(r))
    /\ WF_mc_vars(MCFetchClusterStatus)
    /\ WF_mc_vars(MCAcquireScaleDownLock)
    /\ WF_mc_vars(MCAcquireBalanceLock)
    /\ WF_mc_vars(MCEvictSubmitReplaceNode)
    /\ WF_mc_vars(MCEvictNoReplicasCanDelete)
    /\ WF_mc_vars(MCEvictCheckCompleted)
    /\ WF_mc_vars(MCEvictCheckFailed)
    /\ WF_mc_vars(MCEvictCheckRunning)
    /\ WF_mc_vars(MCBalanceSingleNodeShortcut)
    /\ WF_mc_vars(MCBalanceSubmit)
    /\ WF_mc_vars(MCBalanceCheckCompleted)
    /\ WF_mc_vars(MCBalanceCheckFailed)
    /\ WF_mc_vars(MCBackupStart)
    /\ WF_mc_vars(MCBackupCheck)

\* ============================================================================
\* SYMMETRY / VIEW / STATE-SPACE PRUNING
\* ============================================================================

\* Non-target nodes are interchangeable (TargetNode is a distinguished constant,
\* so we only permute the remaining nodes). Kept simple: no symmetry by default
\* to avoid mis-declaring symmetry over a set that contains a named constant.
ModelView == <<vars>>

\* ============================================================================
\* STRUCTURAL INVARIANTS (MC layer)
\* ============================================================================

FaultCountersBounded ==
    /\ faultCounters.evict   <= MaxEvictLimit
    /\ faultCounters.churn   <= MaxNodeChurnLimit
    /\ faultCounters.podready <= MaxPodReadyLimit
    /\ faultCounters.fail    <= MaxFailLimit
    /\ faultCounters.restart <= MaxRestartLimit
    /\ faultCounters.stalefetch <= MaxStaleFetchLimit

====
