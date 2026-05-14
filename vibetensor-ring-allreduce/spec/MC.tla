--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for VibeTensor Ring AllReduce.
 *
 * Wraps the base spec with counter-bounded fault-injection actions.
 * Deterministic / reactive actions pass through unbounded.
 *
 * Counter-bounded actions (fault injection):
 *   - RS_WaitTimeout, AG_WaitTimeout (Family 7, 3)
 *   - DrainTimeout (Family 7)
 *   - BarrierGather/Release timeouts (Family 1, 3)
 *   - AG_DebugAbortBefore/AfterPublish (Family 1, 2)
 *   - HostWatchdogFire (Family 5)
 *   - StaleFlagInject (Family 6)
 *
 * Unbounded actions (deterministic / reactive):
 *   - RS_Step, RS_AbortBail, AG_PublishStep0, AG_Step, AG_AbortBail
 *   - SignalTileFinished, DrainComplete
 *   - Barrier publish / forward / wait-succeed / latch
 *   - KernelEpilogue
 *)

EXTENDS base

ringbase == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxWaitTimeoutLimit       \* RS+AG wait_flag timeout firings
CONSTANT MaxDrainTimeoutLimit      \* DrainTimeout firings
CONSTANT MaxBarrierTimeoutLimit    \* Barrier wait timeout firings (gather/release)
CONSTANT MaxDebugAbortLimit        \* AG_DebugAbort{Before,After}Publish firings
CONSTANT MaxAbortBailLimit         \* RS/AG abort-bail firings (model bound)
CONSTANT MaxWatchdogLimit          \* Host watchdog fires (0 or 1)
CONSTANT MaxStaleFlagLimit         \* Stale-flag injections (Family 6)

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION WRAPPERS
\* ============================================================================

\* --- Wait-flag timeouts (RS / AG) — bounded together (Family 3, 7) ---

MCRS_WaitTimeout(r, t) ==
    /\ faultCounters.waitTimeout < MaxWaitTimeoutLimit
    /\ ringbase!RS_WaitTimeout(r, t)
    /\ faultCounters' = [faultCounters EXCEPT !.waitTimeout = @ + 1]

MCAG_WaitTimeout(r, t) ==
    /\ faultCounters.waitTimeout < MaxWaitTimeoutLimit
    /\ ringbase!AG_WaitTimeout(r, t)
    /\ faultCounters' = [faultCounters EXCEPT !.waitTimeout = @ + 1]

\* --- Drain timeout (Family 7) ---

MCDrainTimeout(r) ==
    /\ faultCounters.drainTimeout < MaxDrainTimeoutLimit
    /\ ringbase!DrainTimeout(r)
    /\ faultCounters' = [faultCounters EXCEPT !.drainTimeout = @ + 1]

\* --- Barrier timeouts (Family 1, 3) ---

MCBarrierGather_Rank0_WaitTimeout(r) ==
    /\ faultCounters.barrierTimeout < MaxBarrierTimeoutLimit
    /\ ringbase!BarrierGather_Rank0_WaitTimeout(r)
    /\ faultCounters' = [faultCounters EXCEPT !.barrierTimeout = @ + 1]

MCBarrierGather_Nonzero_WaitTimeout(r) ==
    /\ faultCounters.barrierTimeout < MaxBarrierTimeoutLimit
    /\ ringbase!BarrierGather_Nonzero_WaitTimeout(r)
    /\ faultCounters' = [faultCounters EXCEPT !.barrierTimeout = @ + 1]

MCBarrierRelease_Rank0_WaitTimeout(r) ==
    /\ faultCounters.barrierTimeout < MaxBarrierTimeoutLimit
    /\ ringbase!BarrierRelease_Rank0_WaitTimeout(r)
    /\ faultCounters' = [faultCounters EXCEPT !.barrierTimeout = @ + 1]

MCBarrierRelease_Nonzero_WaitTimeout(r) ==
    /\ faultCounters.barrierTimeout < MaxBarrierTimeoutLimit
    /\ ringbase!BarrierRelease_Nonzero_WaitTimeout(r)
    /\ faultCounters' = [faultCounters EXCEPT !.barrierTimeout = @ + 1]

\* --- AG debug abort hooks (Family 1, 2) ---

MCAG_DebugAbortBeforePublish(r, s, t) ==
    /\ faultCounters.debugAbort < MaxDebugAbortLimit
    /\ ringbase!AG_DebugAbortBeforePublish(r, s, t)
    /\ faultCounters' = [faultCounters EXCEPT !.debugAbort = @ + 1]

MCAG_DebugAbortAfterPublish(r, s, t) ==
    /\ faultCounters.debugAbort < MaxDebugAbortLimit
    /\ ringbase!AG_DebugAbortAfterPublish(r, s, t)
    /\ faultCounters' = [faultCounters EXCEPT !.debugAbort = @ + 1]

\* --- Abort-bail (RS/AG) — bounded so MC explores both fault and non-fault paths ---

MCRS_AbortBail(r, t) ==
    /\ faultCounters.abortBail < MaxAbortBailLimit
    /\ ringbase!RS_AbortBail(r, t)
    /\ faultCounters' = [faultCounters EXCEPT !.abortBail = @ + 1]

MCAG_AbortBail(r, t) ==
    /\ faultCounters.abortBail < MaxAbortBailLimit
    /\ ringbase!AG_AbortBail(r, t)
    /\ faultCounters' = [faultCounters EXCEPT !.abortBail = @ + 1]

\* --- Host watchdog (Family 5) ---

MCHostWatchdogFire ==
    /\ faultCounters.watchdog < MaxWatchdogLimit
    /\ ringbase!HostWatchdogFire
    /\ faultCounters' = [faultCounters EXCEPT !.watchdog = @ + 1]

\* --- Stale-flag injection (Family 6) ---
\* Models the "epoch reuse from prior allocation" scenario by writing a
\* stale value (StaleEpoch) into a flag. The flag freshness invariant
\* should reject this — but only if the implementation gates on epoch
\* equality. (Used to verify the spec actually checks freshness.)
MCStaleFlagInject(r, s, t) ==
    /\ faultCounters.staleFlag < MaxStaleFlagLimit
    /\ s \in 0..NumSteps
    /\ ag_ready[r][s][t] = 0
    /\ ag_ready' = [ag_ready EXCEPT ![r][s][t] = StaleEpoch]
    /\ faultCounters' = [faultCounters EXCEPT !.staleFlag = @ + 1]
    /\ UNCHANGED <<phaseVars, rs_ready, errVars, drainVars, barrierVars,
                   hostVars, injectVars, dataVars, outVars>>

\* ============================================================================
\* UNBOUNDED (DETERMINISTIC / REACTIVE) WRAPPERS
\* ============================================================================

MCRS_Step(r, s, t) ==
    /\ ringbase!RS_Step(r, s, t)
    /\ UNCHANGED faultVars

MCAG_PublishStep0(r, t) ==
    /\ ringbase!AG_PublishStep0(r, t)
    /\ UNCHANGED faultVars

MCAG_Step(r, s, t) ==
    /\ ringbase!AG_Step(r, s, t)
    /\ UNCHANGED faultVars

MCSignalTileFinished(r) ==
    /\ ringbase!SignalTileFinished(r)
    /\ UNCHANGED faultVars

MCDrainComplete(r) ==
    /\ ringbase!DrainComplete(r)
    /\ UNCHANGED faultVars

MCBarrierGather_Rank0_Publish(r) ==
    /\ ringbase!BarrierGather_Rank0_Publish(r)
    /\ UNCHANGED faultVars

MCBarrierGather_Rank0_WaitSucceed(r) ==
    /\ ringbase!BarrierGather_Rank0_WaitSucceed(r)
    /\ UNCHANGED faultVars

MCBarrierGather_Nonzero_WaitSucceed(r) ==
    /\ ringbase!BarrierGather_Nonzero_WaitSucceed(r)
    /\ UNCHANGED faultVars

MCBarrierGather_Nonzero_PublishMerged(r) ==
    /\ ringbase!BarrierGather_Nonzero_PublishMerged(r)
    /\ UNCHANGED faultVars

MCBarrierRelease_Rank0_Publish(r) ==
    /\ ringbase!BarrierRelease_Rank0_Publish(r)
    /\ UNCHANGED faultVars

MCBarrierRelease_Rank0_WaitSucceed(r) ==
    /\ ringbase!BarrierRelease_Rank0_WaitSucceed(r)
    /\ UNCHANGED faultVars

MCBarrierRelease_Nonzero_ArmTimeouts(r) ==
    /\ ringbase!BarrierRelease_Nonzero_ArmTimeouts(r)
    /\ UNCHANGED faultVars

MCBarrierRelease_Nonzero_WaitSucceed(r) ==
    /\ ringbase!BarrierRelease_Nonzero_WaitSucceed(r)
    /\ UNCHANGED faultVars

MCBarrierRelease_Nonzero_Forward(r) ==
    /\ ringbase!BarrierRelease_Nonzero_Forward(r)
    /\ UNCHANGED faultVars

MCBarrierLatch(r) ==
    /\ ringbase!BarrierLatch(r)
    /\ UNCHANGED faultVars

MCKernelEpilogue(r) ==
    /\ ringbase!KernelEpilogue(r)
    /\ UNCHANGED faultVars

MCHostFreeResources ==
    /\ ringbase!HostFreeResources
    /\ UNCHANGED faultVars

\* ============================================================================
\* INIT / NEXT
\* ============================================================================

MCInit ==
    /\ ringbase!Init
    /\ faultCounters = [waitTimeout |-> 0,
                        drainTimeout |-> 0,
                        barrierTimeout |-> 0,
                        debugAbort |-> 0,
                        abortBail |-> 0,
                        watchdog |-> 0,
                        staleFlag |-> 0]

MCNext ==
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 : MCRS_Step(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles : MCRS_AbortBail(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles : MCRS_WaitTimeout(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles : MCAG_PublishStep0(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 : MCAG_Step(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 :
            MCAG_DebugAbortBeforePublish(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles, s \in 0..NumSteps - 1 :
            MCAG_DebugAbortAfterPublish(r, s, t)
    \/ \E r \in Rank, t \in 1..NumTiles : MCAG_AbortBail(r, t)
    \/ \E r \in Rank, t \in 1..NumTiles : MCAG_WaitTimeout(r, t)
    \/ \E r \in Rank : MCSignalTileFinished(r)
    \/ \E r \in Rank : MCDrainComplete(r)
    \/ \E r \in Rank : MCDrainTimeout(r)
    \/ \E r \in Rank : MCBarrierGather_Rank0_Publish(r)
    \/ \E r \in Rank : MCBarrierGather_Rank0_WaitSucceed(r)
    \/ \E r \in Rank : MCBarrierGather_Rank0_WaitTimeout(r)
    \/ \E r \in Rank : MCBarrierGather_Nonzero_WaitSucceed(r)
    \/ \E r \in Rank : MCBarrierGather_Nonzero_WaitTimeout(r)
    \/ \E r \in Rank : MCBarrierGather_Nonzero_PublishMerged(r)
    \/ \E r \in Rank : MCBarrierRelease_Rank0_Publish(r)
    \/ \E r \in Rank : MCBarrierRelease_Rank0_WaitSucceed(r)
    \/ \E r \in Rank : MCBarrierRelease_Rank0_WaitTimeout(r)
    \/ \E r \in Rank : MCBarrierRelease_Nonzero_ArmTimeouts(r)
    \/ \E r \in Rank : MCBarrierRelease_Nonzero_WaitSucceed(r)
    \/ \E r \in Rank : MCBarrierRelease_Nonzero_WaitTimeout(r)
    \/ \E r \in Rank : MCBarrierRelease_Nonzero_Forward(r)
    \/ \E r \in Rank : MCBarrierLatch(r)
    \/ \E r \in Rank : MCKernelEpilogue(r)
    \/ MCHostWatchdogFire
    \/ MCHostFreeResources
    \/ \E r \in Rank, s \in 0..NumSteps, t \in 1..NumTiles : MCStaleFlagInject(r, s, t)

\* MC fairness: every always-enabled action eventually fires
\* (so liveness properties can be checked).
MCFairness ==
    /\ \A r \in Rank : WF_vars(MCKernelEpilogue(r))
    /\ \A r \in Rank : WF_vars(MCSignalTileFinished(r))
    /\ \A r \in Rank : WF_vars(MCDrainComplete(r))
    /\ \A r \in Rank : WF_vars(MCBarrierLatch(r))
    /\ \A r \in Rank : WF_vars(MCBarrierGather_Rank0_Publish(r))
    /\ \A r \in Rank : WF_vars(MCBarrierGather_Rank0_WaitSucceed(r))
    /\ \A r \in Rank : WF_vars(MCBarrierGather_Nonzero_WaitSucceed(r))
    /\ \A r \in Rank : WF_vars(MCBarrierGather_Nonzero_PublishMerged(r))
    /\ \A r \in Rank : WF_vars(MCBarrierRelease_Rank0_Publish(r))
    /\ \A r \in Rank : WF_vars(MCBarrierRelease_Rank0_WaitSucceed(r))
    /\ \A r \in Rank : WF_vars(MCBarrierRelease_Nonzero_WaitSucceed(r))
    /\ \A r \in Rank : WF_vars(MCBarrierRelease_Nonzero_Forward(r))

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>> /\ MCFairness

\* ============================================================================
\* SYMMETRY / VIEW / CONSTRAINTS
\* ============================================================================

\* Note: the ring imposes ordering on Rank, so full Permutations(Rank) is NOT
\* sound (rank 0 plays a special role). We do NOT declare SYMMETRY in MC.cfg.

\* Exclude the fault counters from the view — they don't represent
\* program-meaningful state, they're just bounds.
MCView == vars

\* Bound flag-array growth: cap stale flag injections (already bounded by
\* MaxStaleFlagLimit). Cap host watchdog (bounded). No buffer constraint
\* needed here because there are no message bags.
StateConstraint ==
    /\ \A r \in Rank : tiles_finished[r] <= NumTiles
    /\ \A r \in Rank : rs_step[r] <= NumSteps
    /\ \A r \in Rank : ag_step[r] <= NumSteps
==============================================================================
