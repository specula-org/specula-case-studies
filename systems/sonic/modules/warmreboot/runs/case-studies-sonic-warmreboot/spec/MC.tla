--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for SONiC Warm Reboot.
 *
 * Wraps the base spec with counter-bounded fault-injection actions.
 * Deterministic/reactive actions pass through unbounded.
 *
 * Counter-bounded actions (fault injection):
 *   - EventArrivalAfterReady (Family 2: TOCTOU)
 *   - ApplyViewStage1Fail (Family 3: comparison failure)
 *   - ApplyViewStage2Fail (Family 3: destructive failure)
 *   - CrashBetweenAsicAndRedis (Family 3: crash point)
 *   - SyncdInitFail (Family 5: init failure)
 *   - ComponentFail (Family 5: shutdown/reconciliation failure)
 *   - ReconcileTimeout (Family 5: global timeout)
 *
 * Unbounded actions (deterministic/reactive):
 *   - Shutdown sequence (StartWarmReboot, CompleteSanity, etc.)
 *   - Component state transitions (Freeze, Quiesce, Checkpoint)
 *   - Orchagent freeze protocol (CheckReady, SendReady, Drain, Freeze)
 *   - Syncd normal path (InitView, Stage1, Stage2, Complete)
 *   - Reconciliation (ReadTable, ReplayEntry, TimerTick/Fire, Reconcile)
 *   - Orchagent restore (WarmRestore, SendApplyView, ReconcileComplete)
 *)

EXTENDS base

\* Access original (un-overridden) operator definitions
warmreboot == INSTANCE base

\* Dependency map constant (for use via CONSTANT OVERRIDE in MC.cfg)
MCDependsConst ==
    "orchagent"  :> {} @@
    "syncd"      :> {} @@
    "teamd"      :> {} @@
    "neighsyncd" :> {"orchagent", "teamd"} @@
    "fdbsyncd"   :> {"neighsyncd", "vxlanmgrd"} @@
    "vxlanmgrd"  :> {"orchagent"}

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxEventArrivalLimit    \* Max post-READY event arrivals (Family 2)
CONSTANT MaxApplyFailLimit       \* Max APPLY_VIEW failure events (Family 3)
CONSTANT MaxCrashLimit           \* Max crash events (Family 3)
CONSTANT MaxSyncdInitFailLimit   \* Max syncd init failures (Family 5)
CONSTANT MaxComponentFailLimit   \* Max component failures (Family 5)
CONSTANT MaxReconcileTimeoutLimit \* Max reconcile timeout events (Family 5)
CONSTANT MaxPrematureReconcileLimit \* Max premature reconcile events (Family 1)

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

\* --- Family 2: Event arrival after READY (TOCTOU) ---
MCEventArrivalAfterReady ==
    /\ faultCounters.eventArrival < MaxEventArrivalLimit
    /\ warmreboot!EventArrivalAfterReady
    /\ faultCounters' = [faultCounters EXCEPT !.eventArrival = @ + 1]

\* --- Family 3: APPLY_VIEW Stage 1 failure ---
MCApplyViewStage1Fail ==
    /\ faultCounters.applyFail < MaxApplyFailLimit
    /\ warmreboot!ApplyViewStage1Fail
    /\ faultCounters' = [faultCounters EXCEPT !.applyFail = @ + 1]

\* --- Family 3: APPLY_VIEW Stage 2 failure ---
MCApplyViewStage2Fail ==
    /\ faultCounters.applyFail < MaxApplyFailLimit
    /\ warmreboot!ApplyViewStage2Fail
    /\ faultCounters' = [faultCounters EXCEPT !.applyFail = @ + 1]

\* --- Family 3: Crash between ASIC and Redis update ---
MCCrashBetweenAsicAndRedis ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ warmreboot!CrashBetweenAsicAndRedis
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

\* --- Family 5: Syncd init failure ---
MCSyncdInitFail ==
    /\ faultCounters.syncdInitFail < MaxSyncdInitFailLimit
    /\ warmreboot!SyncdInitFail
    /\ faultCounters' = [faultCounters EXCEPT !.syncdInitFail = @ + 1]

\* --- Family 5: Component failure during shutdown ---
MCComponentFailDuringShutdown(c) ==
    /\ faultCounters.componentFail < MaxComponentFailLimit
    /\ warmreboot!ComponentFailDuringShutdown(c)
    /\ faultCounters' = [faultCounters EXCEPT !.componentFail = @ + 1]

\* --- Family 5: Component failure during reconciliation ---
MCComponentFailDuringReconciliation(c) ==
    /\ faultCounters.componentFail < MaxComponentFailLimit
    /\ warmreboot!ComponentFailDuringReconciliation(c)
    /\ faultCounters' = [faultCounters EXCEPT !.componentFail = @ + 1]

\* --- Family 5: Reconcile timeout ---
MCReconcileTimeout ==
    /\ faultCounters.reconcileTimeout < MaxReconcileTimeoutLimit
    /\ warmreboot!ReconcileTimeout
    /\ faultCounters' = [faultCounters EXCEPT !.reconcileTimeout = @ + 1]

\* --- Family 1: Premature reconcile (without timer, models vxlanmgrd) ---
MCReconcileComponentWithoutTimer(c) ==
    /\ faultCounters.prematureReconcile < MaxPrematureReconcileLimit
    /\ warmreboot!ReconcileComponentWithoutTimer(c)
    /\ faultCounters' = [faultCounters EXCEPT !.prematureReconcile = @ + 1]

\* ============================================================================
\* UNBOUNDED (DETERMINISTIC/REACTIVE) ACTIONS
\* ============================================================================

\* --- Shutdown sequence ---
MCStartWarmReboot ==
    /\ warmreboot!StartWarmReboot
    /\ UNCHANGED faultVars

MCCompleteSanityChecks ==
    /\ warmreboot!CompleteSanityChecks
    /\ UNCHANGED faultVars

MCComponentReceiveFreeze(c) ==
    /\ warmreboot!ComponentReceiveFreeze(c)
    /\ UNCHANGED faultVars

MCComponentQuiesce(c) ==
    /\ warmreboot!ComponentQuiesce(c)
    /\ UNCHANGED faultVars

MCEnterCheckpointPhase ==
    /\ warmreboot!EnterCheckpointPhase
    /\ UNCHANGED faultVars

MCComponentCheckpoint(c) ==
    /\ warmreboot!ComponentCheckpoint(c)
    /\ UNCHANGED faultVars

MCEnterRebootPhase ==
    /\ warmreboot!EnterRebootPhase
    /\ UNCHANGED faultVars

MCSystemReboot ==
    /\ warmreboot!SystemReboot
    /\ UNCHANGED faultVars

\* --- Orchagent freeze protocol ---
MCOrchCheckReady ==
    /\ warmreboot!OrchCheckReady
    /\ UNCHANGED faultVars

MCOrchSendReadyReply ==
    /\ warmreboot!OrchSendReadyReply
    /\ UNCHANGED faultVars

MCOrchDrainRingBuffer ==
    /\ warmreboot!OrchDrainRingBuffer
    /\ UNCHANGED faultVars

MCOrchFreeze ==
    /\ warmreboot!OrchFreeze
    /\ UNCHANGED faultVars

\* --- Syncd normal path ---
MCSyncdReceiveInitView ==
    /\ warmreboot!SyncdReceiveInitView
    /\ UNCHANGED faultVars

MCApplyViewStage1 ==
    /\ warmreboot!ApplyViewStage1
    /\ UNCHANGED faultVars

MCApplyViewStage2 ==
    /\ warmreboot!ApplyViewStage2
    /\ UNCHANGED faultVars

MCApplyViewComplete ==
    /\ warmreboot!ApplyViewComplete
    /\ UNCHANGED faultVars

MCSyncdRejectInShutdownWait ==
    /\ warmreboot!SyncdRejectInShutdownWait
    /\ UNCHANGED faultVars

\* --- Reconciliation ---
MCComponentStartReconcileTimer(c) ==
    /\ warmreboot!ComponentStartReconcileTimer(c)
    /\ UNCHANGED faultVars

MCComponentReadTable(c) ==
    /\ warmreboot!ComponentReadTable(c)
    /\ UNCHANGED faultVars

MCReplayEntry(c, k) ==
    /\ warmreboot!ReplayEntry(c, k)
    /\ UNCHANGED faultVars

MCReconcileTimerTick(c) ==
    /\ warmreboot!ReconcileTimerTick(c)
    /\ UNCHANGED faultVars

MCReconcileTimerFire(c) ==
    /\ warmreboot!ReconcileTimerFire(c)
    /\ UNCHANGED faultVars

MCReconcileComponent(c) ==
    /\ warmreboot!ReconcileComponent(c)
    /\ UNCHANGED faultVars

\* --- Orchagent warm restore ---
MCOrchWarmRestore ==
    /\ warmreboot!OrchWarmRestore
    /\ UNCHANGED faultVars

MCOrchSendApplyView ==
    /\ warmreboot!OrchSendApplyView
    /\ UNCHANGED faultVars

MCOrchReconcileComplete ==
    /\ warmreboot!OrchReconcileComplete
    /\ UNCHANGED faultVars

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
         eventArrival      |-> 0,
         applyFail         |-> 0,
         crash             |-> 0,
         syncdInitFail     |-> 0,
         componentFail     |-> 0,
         reconcileTimeout  |-> 0,
         prematureReconcile |-> 0]

\* ============================================================================
\* NEXT STATE
\* ============================================================================

MCNext ==
    \* --- Terminal state (stutter) ---
    \/ (Done /\ UNCHANGED <<vars, faultVars>>)
    \* --- Shutdown sequence (unbounded) ---
    \/ MCStartWarmReboot
    \/ MCCompleteSanityChecks
    \/ \E c \in Component : MCComponentReceiveFreeze(c)
    \/ \E c \in Component : MCComponentQuiesce(c)
    \/ MCEnterCheckpointPhase
    \/ \E c \in Component : MCComponentCheckpoint(c)
    \/ MCEnterRebootPhase
    \/ MCSystemReboot
    \* --- Orchagent freeze protocol (unbounded) ---
    \/ MCOrchCheckReady
    \/ MCOrchSendReadyReply
    \/ MCOrchDrainRingBuffer
    \/ MCOrchFreeze
    \* --- Family 2 fault injection (bounded) ---
    \/ MCEventArrivalAfterReady
    \* --- Syncd normal path (unbounded) ---
    \/ MCSyncdReceiveInitView
    \/ MCApplyViewStage1
    \/ MCApplyViewStage2
    \/ MCApplyViewComplete
    \/ MCSyncdRejectInShutdownWait
    \* --- Family 3 fault injection (bounded) ---
    \/ MCApplyViewStage1Fail
    \/ MCApplyViewStage2Fail
    \/ MCCrashBetweenAsicAndRedis
    \* --- Family 5 fault injection (bounded) ---
    \/ MCSyncdInitFail
    \/ \E c \in Component : MCComponentFailDuringShutdown(c)
    \/ \E c \in Component : MCComponentFailDuringReconciliation(c)
    \/ MCReconcileTimeout
    \* --- Reconciliation (unbounded) ---
    \/ \E c \in Component : MCComponentStartReconcileTimer(c)
    \/ \E c \in Component : MCComponentReadTable(c)
    \/ \E c \in Component, k \in Key : MCReplayEntry(c, k)
    \/ \E c \in Component : MCReconcileTimerTick(c)
    \/ \E c \in Component : MCReconcileTimerFire(c)
    \/ \E c \in Component : MCReconcileComponent(c)
    \* --- Family 1 fault injection (bounded) ---
    \/ \E c \in Component : MCReconcileComponentWithoutTimer(c)
    \* --- Orchagent warm restore (unbounded) ---
    \/ MCOrchWarmRestore
    \/ MCOrchSendApplyView
    \/ MCOrchReconcileComplete

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* View excludes fault counters from state space
ModelView == <<vars>>

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

\* Fault counters are non-negative
FaultCounterNonNeg ==
    /\ faultCounters.eventArrival >= 0
    /\ faultCounters.applyFail >= 0
    /\ faultCounters.crash >= 0
    /\ faultCounters.syncdInitFail >= 0
    /\ faultCounters.componentFail >= 0
    /\ faultCounters.reconcileTimeout >= 0
    /\ faultCounters.prematureReconcile >= 0

\* Phase only increases (structural version)
MCPhaseValid ==
    phase \in {PhaseRunning, PhaseSanity, PhaseFreeze, PhaseCheckpoint,
               PhaseReboot, PhaseBooting, PhaseReconciling}

\* Component states are valid for their phase
MCComponentStateValid ==
    \A c \in Component :
        componentState[c] \in {CRunning, CFrozen, CQuiescent,
                               CCheckpointed, CInitialized, CRestored,
                               CReconciled, CFailed}

\* Syncd mode transitions are valid
MCSyncdModeValid ==
    syncdMode \in {SyncdNormal, SyncdInitView, SyncdApplyStage1,
                   SyncdApplyStage2, SyncdDone, SyncdShutdownWait,
                   SyncdCrashed}

=============================================================================
