--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for SONiC Warm Reboot.
 *
 * Replays implementation traces against the base spec to verify
 * that the base spec can reproduce every observed state transition.
 *
 * Category A (Distributed): Single-file linear trace with cursor `l`.
 *
 * Trace format: NDJSON with tag="trace" and event records containing:
 *   - event.name: action name
 *   - event.component: component ID (orchagent, syncd, etc.)
 *   - event.state: post-action state snapshot
 *   - event.detail: action-specific fields
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* Read JSON file path from environment variable or use default.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load NDJSON, filter to trace events only.
TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

\* ============================================================================
\* COMPONENT EXTRACTION FROM TRACE
\* ============================================================================

TraceComponent == TLCEval(
    UNION {
        {TraceLog[k].event.component}
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceComponent /= {}
ASSUME TraceComponent \subseteq Component

\* Dependency map (used via CONSTANT OVERRIDE in Trace.cfg)
DependsConst ==
    "orchagent"  :> {} @@
    "syncd"      :> {} @@
    "teamd"      :> {} @@
    "neighsyncd" :> {"orchagent", "teamd"} @@
    "fdbsyncd"   :> {"neighsyncd", "vxlanmgrd"} @@
    "vxlanmgrd"  :> {"orchagent"}

\* ============================================================================
\* VALUE MAPPING
\* ============================================================================

\* Map trace phase strings to spec phase constants
PhaseMapping ==
    "Running"      :> PhaseRunning     @@
    "Sanity"       :> PhaseSanity      @@
    "Freeze"       :> PhaseFreeze      @@
    "Checkpoint"   :> PhaseCheckpoint  @@
    "Reboot"       :> PhaseReboot      @@
    "Booting"      :> PhaseBooting     @@
    "Reconciling"  :> PhaseReconciling

\* Map trace component state strings to spec constants
CompStateMapping ==
    "Running"      :> CRunning        @@
    "Frozen"       :> CFrozen         @@
    "Quiescent"    :> CQuiescent      @@
    "Checkpointed" :> CCheckpointed   @@
    "Initialized"  :> CInitialized    @@
    "Restored"     :> CRestored       @@
    "Reconciled"   :> CReconciled     @@
    "Failed"       :> CFailed

\* Map trace syncd mode strings to spec constants
SyncdModeMapping ==
    "Normal"         :> SyncdNormal       @@
    "InitView"       :> SyncdInitView     @@
    "ApplyStage1"    :> SyncdApplyStage1  @@
    "ApplyStage2"    :> SyncdApplyStage2  @@
    "Done"           :> SyncdDone         @@
    "ShutdownWait"   :> SyncdShutdownWait @@
    "Crashed"        :> SyncdCrashed

\* Map trace orchagent state strings to spec constants
OrchStateMapping ==
    "Running"        :> OrchRunning        @@
    "CheckingReady"  :> OrchCheckingReady  @@
    "ReadyReplied"   :> OrchReadyReplied   @@
    "Draining"       :> OrchDraining       @@
    "Frozen"         :> OrchFrozen         @@
    "Restoring"      :> OrchRestoring      @@
    "WaitApplyView"  :> OrchWaitApplyView  @@
    "Reconciling"    :> OrchReconciling

\* Map trace cache state strings to spec constants
CacheStateMapping ==
    "Empty"  :> CacheEmpty  @@
    "STALE"  :> CacheSTALE  @@
    "SAME"   :> CacheSAME   @@
    "NEW"    :> CacheNEW    @@
    "DELETE" :> CacheDELETE

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsComponentEvent(name, c) ==
    /\ IsEvent(name)
    /\ logline.event.component = c

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

\* Validate global phase
ValidatePhase ==
    /\ "phase" \in DOMAIN logline.event.state
    /\ phase' = PhaseMapping[logline.event.state.phase]

\* Validate component state for a specific component
ValidateComponentState(c) ==
    /\ "componentState" \in DOMAIN logline.event.state
    /\ componentState'[c] =
        CompStateMapping[logline.event.state.componentState]

\* Validate syncd mode
ValidateSyncdMode ==
    /\ "syncdMode" \in DOMAIN logline.event.state
    /\ syncdMode' = SyncdModeMapping[logline.event.state.syncdMode]

\* Validate orchagent internal state
ValidateOrchState ==
    /\ "orchState" \in DOMAIN logline.event.state
    /\ orchInternalState' =
        OrchStateMapping[logline.event.state.orchState]

\* Validate pending events count
ValidatePendingEvents ==
    /\ "pendingEvents" \in DOMAIN logline.event.state
    /\ pendingEvents' = logline.event.state.pendingEvents

\* Validate point of no return flag
ValidatePointOfNoReturn ==
    /\ "pointOfNoReturn" \in DOMAIN logline.event.state
    /\ pointOfNoReturn' = logline.event.state.pointOfNoReturn

\* Validate ASIC state
ValidateAsicState ==
    /\ "asicConnected" \in DOMAIN logline.event.state
    /\ asicConnected' = logline.event.state.asicConnected
    /\ "asicConsistent" \in DOMAIN logline.event.state
    /\ asicConsistent' = logline.event.state.asicConsistent

\* Validate cache entry state for a component and key
ValidateCacheState(c, k) ==
    /\ "cacheState" \in DOMAIN logline.event.detail
    /\ cache'[c][k] =
        CacheStateMapping[logline.event.detail.cacheState]

\* ============================================================================
\* STEP TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS: SHUTDOWN SEQUENCE
\* ============================================================================

\* --- StartWarmReboot ---
StartWarmRebootIfLogged ==
    /\ IsEvent("StartWarmReboot")
    /\ StartWarmReboot
    /\ ValidatePhase
    /\ StepTrace

\* --- CompleteSanityChecks ---
CompleteSanityChecksIfLogged ==
    /\ IsEvent("CompleteSanityChecks")
    /\ CompleteSanityChecks
    /\ ValidatePhase
    /\ StepTrace

\* --- ComponentReceiveFreeze ---
ComponentReceiveFreezeIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentReceiveFreeze", c)
        /\ ComponentReceiveFreeze(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- ComponentQuiesce ---
ComponentQuiesceIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentQuiesce", c)
        /\ ComponentQuiesce(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- EnterCheckpointPhase ---
EnterCheckpointPhaseIfLogged ==
    /\ IsEvent("EnterCheckpointPhase")
    /\ EnterCheckpointPhase
    /\ ValidatePhase
    /\ ValidatePointOfNoReturn
    /\ StepTrace

\* --- ComponentCheckpoint ---
ComponentCheckpointIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentCheckpoint", c)
        /\ ComponentCheckpoint(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- EnterRebootPhase ---
EnterRebootPhaseIfLogged ==
    /\ IsEvent("EnterRebootPhase")
    /\ EnterRebootPhase
    /\ ValidatePhase
    /\ StepTrace

\* --- SystemReboot ---
SystemRebootIfLogged ==
    /\ IsEvent("SystemReboot")
    /\ SystemReboot
    /\ ValidatePhase
    /\ StepTrace

\* ============================================================================
\* ACTION WRAPPERS: ORCHAGENT FREEZE PROTOCOL (Family 2)
\* ============================================================================

\* --- OrchCheckReady ---
OrchCheckReadyIfLogged ==
    /\ IsComponentEvent("OrchCheckReady", Orchagent)
    /\ OrchCheckReady
    /\ ValidateOrchState
    /\ StepTrace

\* --- OrchSendReadyReply ---
OrchSendReadyReplyIfLogged ==
    /\ IsComponentEvent("OrchSendReadyReply", Orchagent)
    /\ OrchSendReadyReply
    /\ ValidateOrchState
    /\ ValidateComponentState(Orchagent)
    /\ StepTrace

\* --- EventArrivalAfterReady ---
EventArrivalAfterReadyIfLogged ==
    /\ IsComponentEvent("EventArrivalAfterReady", Orchagent)
    /\ EventArrivalAfterReady
    /\ ValidatePendingEvents
    /\ StepTrace

\* --- OrchDrainRingBuffer ---
OrchDrainRingBufferIfLogged ==
    /\ IsComponentEvent("OrchDrainRingBuffer", Orchagent)
    /\ OrchDrainRingBuffer
    /\ ValidateOrchState
    /\ ValidatePendingEvents
    /\ StepTrace

\* --- OrchFreeze ---
OrchFreezeIfLogged ==
    /\ IsComponentEvent("OrchFreeze", Orchagent)
    /\ OrchFreeze
    /\ ValidateOrchState
    /\ StepTrace

\* ============================================================================
\* ACTION WRAPPERS: SYNCD APPLY_VIEW (Families 3, 5)
\* ============================================================================

\* --- SyncdReceiveInitView ---
SyncdReceiveInitViewIfLogged ==
    /\ IsComponentEvent("SyncdReceiveInitView", Syncd)
    /\ SyncdReceiveInitView
    /\ ValidateSyncdMode
    /\ StepTrace

\* --- ApplyViewStage1 ---
ApplyViewStage1IfLogged ==
    /\ IsComponentEvent("ApplyViewStage1", Syncd)
    /\ ApplyViewStage1
    /\ ValidateSyncdMode
    /\ StepTrace

\* --- ApplyViewStage1Fail ---
ApplyViewStage1FailIfLogged ==
    /\ IsComponentEvent("ApplyViewStage1Fail", Syncd)
    /\ ApplyViewStage1Fail
    /\ ValidateSyncdMode
    /\ StepTrace

\* --- ApplyViewStage2 ---
ApplyViewStage2IfLogged ==
    /\ IsComponentEvent("ApplyViewStage2", Syncd)
    /\ ApplyViewStage2
    /\ ValidateSyncdMode
    /\ StepTrace

\* --- ApplyViewStage2Fail ---
ApplyViewStage2FailIfLogged ==
    /\ IsComponentEvent("ApplyViewStage2Fail", Syncd)
    /\ ApplyViewStage2Fail
    /\ ValidateSyncdMode
    /\ ValidateAsicState
    /\ StepTrace

\* --- ApplyViewComplete ---
ApplyViewCompleteIfLogged ==
    /\ IsComponentEvent("ApplyViewComplete", Syncd)
    /\ ApplyViewComplete
    /\ ValidateSyncdMode
    /\ ValidateAsicState
    /\ StepTrace

\* --- CrashBetweenAsicAndRedis ---
CrashBetweenAsicAndRedisIfLogged ==
    /\ IsComponentEvent("CrashBetweenAsicAndRedis", Syncd)
    /\ CrashBetweenAsicAndRedis
    /\ ValidateSyncdMode
    /\ ValidateAsicState
    /\ StepTrace

\* --- SyncdInitFail ---
SyncdInitFailIfLogged ==
    /\ IsComponentEvent("SyncdInitFail", Syncd)
    /\ SyncdInitFail
    /\ ValidateSyncdMode
    /\ StepTrace

\* ============================================================================
\* ACTION WRAPPERS: RECONCILIATION (Families 1, 4)
\* ============================================================================

\* --- ComponentStartReconcileTimer ---
ComponentStartReconcileTimerIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentStartReconcileTimer", c)
        /\ ComponentStartReconcileTimer(c)
        /\ StepTrace

\* --- ComponentReadTable ---
ComponentReadTableIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentReadTable", c)
        /\ ComponentReadTable(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- ReplayEntry ---
ReplayEntryIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ReplayEntry", c)
        /\ "key" \in DOMAIN logline.event.detail
        /\ LET k == logline.event.detail.key IN
            /\ ReplayEntry(c, k)
            /\ ValidateCacheState(c, k)
            /\ StepTrace

\* --- ReconcileTimerFire ---
ReconcileTimerFireIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ReconcileTimerFire", c)
        /\ ReconcileTimerFire(c)
        /\ StepTrace

\* --- ReconcileComponent ---
ReconcileComponentIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ReconcileComponent", c)
        /\ ReconcileComponent(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- ReconcileComponentWithoutTimer ---
ReconcileComponentWithoutTimerIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ReconcileComponentWithoutTimer", c)
        /\ ReconcileComponentWithoutTimer(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* ============================================================================
\* ACTION WRAPPERS: ORCHAGENT WARM RESTORE
\* ============================================================================

\* --- OrchWarmRestore ---
OrchWarmRestoreIfLogged ==
    /\ IsComponentEvent("OrchWarmRestore", Orchagent)
    /\ OrchWarmRestore
    /\ ValidateOrchState
    /\ ValidateComponentState(Orchagent)
    /\ StepTrace

\* --- OrchSendApplyView ---
OrchSendApplyViewIfLogged ==
    /\ IsComponentEvent("OrchSendApplyView", Orchagent)
    /\ OrchSendApplyView
    /\ StepTrace

\* --- OrchReconcileComplete ---
OrchReconcileCompleteIfLogged ==
    /\ IsComponentEvent("OrchReconcileComplete", Orchagent)
    /\ OrchReconcileComplete
    /\ ValidateOrchState
    /\ ValidateComponentState(Orchagent)
    /\ ValidatePhase
    /\ StepTrace

\* ============================================================================
\* ACTION WRAPPERS: FAILURES
\* ============================================================================

\* --- ComponentFailDuringShutdown ---
ComponentFailDuringShutdownIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentFailDuringShutdown", c)
        /\ ComponentFailDuringShutdown(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- ComponentFailDuringReconciliation ---
ComponentFailDuringReconciliationIfLogged ==
    \E c \in Component :
        /\ IsComponentEvent("ComponentFailDuringReconciliation", c)
        /\ ComponentFailDuringReconciliation(c)
        /\ ValidateComponentState(c)
        /\ StepTrace

\* --- ReconcileTimeout ---
ReconcileTimeoutIfLogged ==
    /\ IsEvent("ReconcileTimeout")
    /\ ReconcileTimeout
    /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

\* Silent: timer ticks (not traced, timer decrements happen internally)
\* Constrained: only fire when timer is active and next event needs it
SilentReconcileTimerTick ==
    /\ l <= Len(TraceLog)
    \* Only tick if next event requires timer to have fired
    /\ logline.event.name \in {"ReconcileTimerFire", "ReconcileComponent"}
    /\ \E c \in Component :
        /\ logline.event.component = c
        /\ ReconcileTimerTick(c)
    /\ UNCHANGED <<l>>

\* Silent: component quiesce for non-orchagent components during freeze
\* (may not be individually traced if Warmboot Manager polls STATE_DB)
SilentComponentQuiesce ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = "EnterCheckpointPhase"
    /\ \E c \in Component :
        /\ c /= Orchagent
        /\ ComponentQuiesce(c)
    /\ UNCHANGED <<l>>

\* Silent: component checkpoint (similar to quiesce — may be polled)
SilentComponentCheckpoint ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"EnterRebootPhase", "SystemReboot"}
    /\ \E c \in Component :
        /\ ComponentCheckpoint(c)
    /\ UNCHANGED <<l>>

\* Silent: component freeze (non-orchagent components)
SilentComponentReceiveFreeze ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"ComponentQuiesce", "EnterCheckpointPhase",
                                "OrchCheckReady"}
    /\ \E c \in Component :
        /\ c /= Orchagent
        /\ ComponentReceiveFreeze(c)
    /\ UNCHANGED <<l>>

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<vars, l>>

TraceNext ==
    \/ TraceDone
    \* --- Shutdown sequence ---
    \/ StartWarmRebootIfLogged
    \/ CompleteSanityChecksIfLogged
    \/ ComponentReceiveFreezeIfLogged
    \/ ComponentQuiesceIfLogged
    \/ EnterCheckpointPhaseIfLogged
    \/ ComponentCheckpointIfLogged
    \/ EnterRebootPhaseIfLogged
    \/ SystemRebootIfLogged
    \* --- Orchagent freeze protocol ---
    \/ OrchCheckReadyIfLogged
    \/ OrchSendReadyReplyIfLogged
    \/ EventArrivalAfterReadyIfLogged
    \/ OrchDrainRingBufferIfLogged
    \/ OrchFreezeIfLogged
    \* --- Syncd APPLY_VIEW ---
    \/ SyncdReceiveInitViewIfLogged
    \/ ApplyViewStage1IfLogged
    \/ ApplyViewStage1FailIfLogged
    \/ ApplyViewStage2IfLogged
    \/ ApplyViewStage2FailIfLogged
    \/ ApplyViewCompleteIfLogged
    \/ CrashBetweenAsicAndRedisIfLogged
    \/ SyncdInitFailIfLogged
    \* --- Reconciliation ---
    \/ ComponentStartReconcileTimerIfLogged
    \/ ComponentReadTableIfLogged
    \/ ReplayEntryIfLogged
    \/ ReconcileTimerFireIfLogged
    \/ ReconcileComponentIfLogged
    \/ ReconcileComponentWithoutTimerIfLogged
    \* --- Orchagent warm restore ---
    \/ OrchWarmRestoreIfLogged
    \/ OrchSendApplyViewIfLogged
    \/ OrchReconcileCompleteIfLogged
    \* --- Failures ---
    \/ ComponentFailDuringShutdownIfLogged
    \/ ComponentFailDuringReconciliationIfLogged
    \/ ReconcileTimeoutIfLogged
    \* --- Silent actions ---
    \/ SilentReconcileTimerTick
    \/ SilentComponentQuiesce
    \/ SilentComponentCheckpoint
    \/ SilentComponentReceiveFreeze

\* ============================================================================
\* TRACE COMPLETION
\* ============================================================================

\* Temporal property: the entire trace must be consumed.
TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* SPECIFICATION (with fairness for temporal property checking)
\* ============================================================================

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>> /\ WF_<<vars, l>>(TraceNext)

\* ============================================================================
\* VIEW AND ALIAS
\* ============================================================================

TraceView == <<vars, l>>

TraceAlias == [
    phase              |-> phase,
    pointOfNoReturn    |-> pointOfNoReturn,
    componentState     |-> componentState,
    orchInternalState   |-> orchInternalState,
    pendingEvents      |-> pendingEvents,
    readyReplySent     |-> readyReplySent,
    syncdMode          |-> syncdMode,
    asicConnected      |-> asicConnected,
    asicConsistent     |-> asicConsistent,
    redisUpdated       |-> redisUpdated,
    tracePos           |-> l,
    traceLen           |-> Len(TraceLog),
    nextEvent          |-> IF l <= Len(TraceLog)
                          THEN logline.event.name
                          ELSE "DONE"
]

=============================================================================
