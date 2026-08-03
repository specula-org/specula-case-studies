-------------------------------- MODULE MC --------------------------------
(**************************************************************************)
(* Counter-bounded model-checking wrapper for the SONiC warm-reboot model. *)
(* Only actions that introduce an external/nondeterministic choice are     *)
(* bounded. Deterministic and reactive protocol steps pass through.        *)
(**************************************************************************)

EXTENDS base

\* Access the original definitions even when a cfg applies operator overrides.
B == INSTANCE base

(**************************************************************************)
(* Fault/action bounds.                                                    *)
(**************************************************************************)

CONSTANTS
    RequestLimit, CancellationLimit, EnqueueLimit, FreezeFailureLimit,
    StopFailureLimit, ModeDowngradeLimit, IdentityChoiceLimit,
    ApplyCrashLimit, UnsafeRecoveryLimit, EarlyInputLimit,
    InputCompleteLimit, RouteTimeoutLimit, LateInputLimit,
    ComponentFailureLimit, FinalizerTimeoutLimit

ASSUME
    /\ RequestLimit \in Nat
    /\ CancellationLimit \in Nat
    /\ EnqueueLimit \in Nat
    /\ FreezeFailureLimit \in Nat
    /\ StopFailureLimit \in Nat
    /\ ModeDowngradeLimit \in Nat
    /\ IdentityChoiceLimit \in Nat
    /\ ApplyCrashLimit \in Nat
    /\ UnsafeRecoveryLimit \in Nat
    /\ EarlyInputLimit \in Nat
    /\ InputCompleteLimit \in Nat
    /\ RouteTimeoutLimit \in Nat
    /\ LateInputLimit \in Nat
    /\ ComponentFailureLimit \in Nat
    /\ FinalizerTimeoutLimit \in Nat

VARIABLE constraintCounters

faultVars == <<constraintCounters>>

(**************************************************************************)
(* Bounded choices, derived from the six concrete brief mechanisms.       *)
(**************************************************************************)

MCFastRebootRequest(c, kind) ==
    /\ constraintCounters.request < RequestLimit
    /\ B!FastReboot_Request(c, kind)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.request = @ + 1]

MCClearBoot(c) ==
    /\ constraintCounters.cancellation < CancellationLimit
    /\ B!ClearBoot(c)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.cancellation = @ + 1]

MCProducerEnqueue(p) ==
    /\ constraintCounters.enqueue < EnqueueLimit
    /\ B!Producer_Enqueue(p)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.enqueue = @ + 1]

MCPauseOrchagentIgnoreFailure(a) ==
    /\ constraintCounters.freezeFailure < FreezeFailureLimit
    /\ B!PauseOrchagent_IgnoreFailure(a)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.freezeFailure = @ + 1]

MCStopSystemdServiceMaskedFailure(a) ==
    /\ constraintCounters.stopFailure < StopFailureLimit
    /\ B!StopSystemdService_MaskedFailure(a)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.stopFailure = @ + 1]

MCSyncdDowngradeWarmShutdown(a) ==
    /\ constraintCounters.modeDowngrade < ModeDowngradeLimit
    /\ B!Syncd_DowngradeWarmShutdown(a)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.modeDowngrade = @ + 1]

MCBestCandidateFinderSelectRandomCandidate(v, r) ==
    /\ constraintCounters.identityChoice < IdentityChoiceLimit
    /\ B!BestCandidateFinder_SelectRandomCandidate(v, r)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.identityChoice = @ + 1]

MCSyncdCrashDuringApply ==
    /\ constraintCounters.applyCrash < ApplyCrashLimit
    /\ B!Syncd_CrashDuringApply
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.applyCrash = @ + 1]

MCSyncdAcceptDirtyWarmRecovery ==
    /\ constraintCounters.unsafeRecovery < UnsafeRecoveryLimit
    /\ B!Syncd_AcceptDirtyWarmRecovery
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.unsafeRecovery = @ + 1]

MCWarmStartHelperInsertRefreshMap(r) ==
    /\ constraintCounters.earlyInput < EarlyInputLimit
    /\ B!WarmStartHelper_InsertRefreshMap(r)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.earlyInput = @ + 1]

MCFpmSyncdEoiuInputComplete ==
    /\ constraintCounters.inputCompleteSignal < InputCompleteLimit
    /\ B!FpmSyncd_EoiuInputComplete
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.inputCompleteSignal = @ + 1]

MCFpmSyncdWarmRestartTimerExpired ==
    /\ constraintCounters.routeTimeout < RouteTimeoutLimit
    /\ B!FpmSyncd_WarmRestartTimerExpired
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.routeTimeout = @ + 1]

MCWarmStartHelperLateInput(r) ==
    /\ constraintCounters.lateInput < LateInputLimit
    /\ B!WarmStartHelper_LateInput(r)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.lateInput = @ + 1]

MCComponentPublishFailure(comp) ==
    /\ constraintCounters.componentFailure < ComponentFailureLimit
    /\ B!Component_PublishFailure(comp)
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.componentFailure = @ + 1]

MCFinalizeWarmbootWaitTimeout ==
    /\ constraintCounters.finalizerTimeout < FinalizerTimeoutLimit
    /\ B!FinalizeWarmboot_WaitTimeout
    /\ constraintCounters' =
          [constraintCounters EXCEPT !.finalizerTimeout = @ + 1]

(**************************************************************************)
(* Initialization.                                                        *)
(**************************************************************************)

MCInit ==
    /\ B!Init
    /\ constraintCounters =
          [request          |-> 0,
           cancellation     |-> 0,
           enqueue          |-> 0,
           freezeFailure    |-> 0,
           stopFailure      |-> 0,
           modeDowngrade    |-> 0,
           identityChoice   |-> 0,
           applyCrash       |-> 0,
           unsafeRecovery   |-> 0,
           earlyInput       |-> 0,
           inputCompleteSignal |-> 0,
           routeTimeout     |-> 0,
           lateInput        |-> 0,
           componentFailure |-> 0,
           finalizerTimeout |-> 0]

(**************************************************************************)
(* Next-state relation. Reactive actions never consume a fault counter.    *)
(**************************************************************************)

MCNextEpoch ==
    \/ \E c \in Owners, kind \in RequestKinds : MCFastRebootRequest(c, kind)
    \/ \E c \in Owners :
          /\ B!CheckWarmRestartInProgress_Admit(c)
          /\ UNCHANGED faultVars
    \/ \E c \in Owners :
          /\ B!CheckWarmRestartInProgress_Reject(c)
          /\ UNCHANGED faultVars
    \/ \E c \in Owners :
          /\ B!EnableWarmRestart(c)
          /\ UNCHANGED faultVars
    \/ \E c \in Owners : MCClearBoot(c)
    \/ \E c \in Owners :
          /\ B!FastReboot_ContinueAfterSignal(c)
          /\ UNCHANGED faultVars
    \/ \E c \in Owners :
          /\ B!FastReboot_PauseOrchagentComplete(c)
          /\ UNCHANGED faultVars
    \/ \E c \in Owners :
          /\ B!FastReboot_BeginIrreversibleWork(c)
          /\ UNCHANGED faultVars
    \/ \E c \in Owners :
          /\ B!FastReboot_RecordOutcome(c)
          /\ UNCHANGED faultVars

MCNextProducer ==
    \/ \E p \in Producers : MCProducerEnqueue(p)
    \/ \E p \in Producers :
          /\ B!Producer_DrainOne(p)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchDaemon_WarmRestartCheck(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchagentRestartCheck_ConsumeReply(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics : MCPauseOrchagentIgnoreFailure(a)
    \/ \E a \in Asics :
          /\ B!OrchDaemon_DrainRing(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchDaemon_SetAgingFDB(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchDaemon_SetBridgePortLearningFDB(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchDaemon_Flush(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchDaemon_WarmRestartReplyAfterFlush(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!OrchDaemon_FreezeAndHeartBeat(a)
          /\ UNCHANGED faultVars

MCNextSnapshot ==
    \/ \E a \in Asics :
          /\ B!StopSystemdService_Success(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics : MCStopSystemdServiceMaskedFailure(a)
    \/ \E a \in Asics :
          /\ B!Syncd_PerformWarmShutdown(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics : MCSyncdDowngradeWarmShutdown(a)
    \/ \E a \in Asics :
          /\ B!CentralizeDatabase_RedisSave(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!BackupDatabase_DockerCopy(a)
          /\ UNCHANGED faultVars
    \/ /\ B!FastReboot_AggregateWarmDecision
       /\ UNCHANGED faultVars
    \/ /\ B!FastReboot_AggregateColdDecision
       /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!DockerImageCtl_PreStartAction(a)
          /\ UNCHANGED faultVars

MCNextApply ==
    \/ \E a \in Asics :
          /\ B!Syncd_ProcessNotifySyncdInitView(a)
          /\ UNCHANGED faultVars
    \/ \E a \in Asics :
          /\ B!Syncd_ApplyViewCompare(a)
          /\ UNCHANGED faultVars
    \/ \E v \in Vids, r \in Rids :
          MCBestCandidateFinderSelectRandomCandidate(v, r)
    \/ /\ B!ComparisonLogic_CompareViewsComplete
       /\ UNCHANGED faultVars
    \/ /\ B!ComparisonLogic_ExecuteOperationsOnAsic
       /\ UNCHANGED faultVars
    \/ /\ B!Syncd_ApplyViewBeginRedisUpdate
       /\ UNCHANGED faultVars
    \/ /\ B!RedisClient_RemoveAsicStateTable
       /\ UNCHANGED faultVars
    \/ /\ B!RedisClient_RemoveTempAsicStateTable
       /\ UNCHANGED faultVars
    \/ \E op \in ApplyOps :
          /\ B!RedisClient_CreateAsicObject(op)
          /\ UNCHANGED faultVars
    \/ /\ B!Syncd_UpdateRedisDatabaseBeginMaps
       /\ UNCHANGED faultVars
    \/ /\ B!RedisClient_SetVidAndRidMapDeleteVidToRid
       /\ UNCHANGED faultVars
    \/ /\ B!RedisClient_SetVidAndRidMapDeleteRidToVid
       /\ UNCHANGED faultVars
    \/ \E v \in Vids :
          /\ B!RedisClient_SetVidAndRidMapWriteVidToRid(v)
          /\ UNCHANGED faultVars
    \/ /\ B!RedisClient_SetVidAndRidMapWriteRidToVid
       /\ UNCHANGED faultVars
    \/ /\ B!Syncd_UpdateRedisDatabaseComplete
       /\ UNCHANGED faultVars
    \/ /\ B!Syncd_ApplyViewCommit
       /\ UNCHANGED faultVars
    \/ MCSyncdCrashDuringApply
    \/ /\ B!Syncd_ResumeFromDurableJournal
       /\ UNCHANGED faultVars
    \/ MCSyncdAcceptDirtyWarmRecovery
    \/ /\ B!Syncd_ForceColdRecovery
       /\ UNCHANGED faultVars

MCNextCompletion ==
    \/ /\ B!WarmStartHelper_RunRestoration
       /\ UNCHANGED faultVars
    \/ \E r \in Routes : MCWarmStartHelperInsertRefreshMap(r)
    \/ MCFpmSyncdEoiuInputComplete
    \/ MCFpmSyncdWarmRestartTimerExpired
    \/ /\ B!RouteSync_OnWarmStartEnd
       /\ UNCHANGED faultVars
    \/ /\ B!FpmSyncd_PipelineFlush
       /\ UNCHANGED faultVars
    \/ \E r \in Routes : MCWarmStartHelperLateInput(r)
    \/ \E comp \in Components :
          /\ B!Component_PublishTerminal(comp)
          /\ UNCHANGED faultVars
    \/ \E comp \in Components : MCComponentPublishFailure(comp)
    \/ MCFinalizeWarmbootWaitTimeout
    \/ /\ B!FinalizeWarmboot_FinalizeGlobal
       /\ UNCHANGED faultVars

MCNext ==
    \/ MCNextEpoch
    \/ MCNextProducer
    \/ MCNextSnapshot
    \/ MCNextApply
    \/ MCNextCompletion

mc_vars == <<vars, constraintCounters>>

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_mc_vars
    /\ WF_mc_vars(MCNextEpoch)
    /\ WF_mc_vars(MCNextProducer)
    /\ WF_mc_vars(MCNextSnapshot)
    /\ WF_mc_vars(MCNextApply)
    /\ WF_mc_vars(MCNextCompletion)

(**************************************************************************)
(* Symmetry, view, constraints, and MC structural invariants.              *)
(**************************************************************************)

MCSymmetry == B!Symmetry

\* Fault counters do not distinguish otherwise equivalent protocol states.
ModelView == vars

StateSpaceConstraint ==
    /\ \A p \in Producers : queue[p] <= MaxQueue
    /\ Cardinality(hardwareView) <= MaxApplyOps
    /\ Cardinality(dbView) <= MaxApplyOps
    /\ Cardinality(outputBuffered) <= Cardinality(Routes)

CounterTypeOK ==
    /\ constraintCounters.request \in Nat
    /\ constraintCounters.cancellation \in Nat
    /\ constraintCounters.enqueue \in Nat
    /\ constraintCounters.freezeFailure \in Nat
    /\ constraintCounters.stopFailure \in Nat
    /\ constraintCounters.modeDowngrade \in Nat
    /\ constraintCounters.identityChoice \in Nat
    /\ constraintCounters.applyCrash \in Nat
    /\ constraintCounters.unsafeRecovery \in Nat
    /\ constraintCounters.earlyInput \in Nat
    /\ constraintCounters.inputCompleteSignal \in Nat
    /\ constraintCounters.routeTimeout \in Nat
    /\ constraintCounters.lateInput \in Nat
    /\ constraintCounters.componentFailure \in Nat
    /\ constraintCounters.finalizerTimeout \in Nat

CounterBounds ==
    /\ constraintCounters.request <= RequestLimit
    /\ constraintCounters.cancellation <= CancellationLimit
    /\ constraintCounters.enqueue <= EnqueueLimit
    /\ constraintCounters.freezeFailure <= FreezeFailureLimit
    /\ constraintCounters.stopFailure <= StopFailureLimit
    /\ constraintCounters.modeDowngrade <= ModeDowngradeLimit
    /\ constraintCounters.identityChoice <= IdentityChoiceLimit
    /\ constraintCounters.applyCrash <= ApplyCrashLimit
    /\ constraintCounters.unsafeRecovery <= UnsafeRecoveryLimit
    /\ constraintCounters.earlyInput <= EarlyInputLimit
    /\ constraintCounters.inputCompleteSignal <= InputCompleteLimit
    /\ constraintCounters.routeTimeout <= RouteTimeoutLimit
    /\ constraintCounters.lateInput <= LateInputLimit
    /\ constraintCounters.componentFailure <= ComponentFailureLimit
    /\ constraintCounters.finalizerTimeout <= FinalizerTimeoutLimit

=============================================================================
